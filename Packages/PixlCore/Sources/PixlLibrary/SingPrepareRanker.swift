// Smart auto-prepare (Settings › Sing › "Prepare songs ahead in the cloud"): which songs you are likely to sing next,
// so their instrumentals are ready before the tap. Pure and deterministic; the Android app ranks with the same constants
// and the same test vectors.
//
//   score = 3.0·favourite + 2.5·ln(1 + plays)·completionRate + 2.0·2^(−daysSincePlay / 14)
//         + 1.0·2^(−daysSinceAdded / 30) + neighbour − 3.0·skipRate
//
//   completionRate = (completions + 2) / (sessions + 4)      skipRate = earlySkips / (sessions + 2)
//
// - neighbour: for each of the 5 most recently played distinct songs, in every playlist that holds it, the next 5
//   songs get +1.0 / (1 + distance), the distance being the number of places after it (1 for the very next song). A
//   library song on the same album as one of the 8 best-scoring songs (the "seeds", by every term above) gets +0.8; a
//   seed counts for its own album too.
// - A song without learned signals (learning is off, or it was never listened to with learning on) has no
//   completion-rate and no skip-rate term: those two terms are 0 for it; the others still count.
// - Never a candidate: a song with an instrumental or a pending job (`excluded`), one of 60 s or less, or over 8
//   minutes, one skipped early in more than 40 % of its sessions (skipRate > 0.4), or by a blocked artist.
// - Siblings come from the library only: nothing here asks Spotify for more.

import Foundation
import PixlModel

/// Everything the ranker reads, gathered by the app.
public struct SingPrepareInputs: Sendable {
    public var songs: [Song]
    /// Per song: plays and when it was last played (from the listening history).
    public var engagements: [String: EngagementStats]
    /// Learned feedback per song; empty while "Learn from listening" is off.
    public var signals: [String: MusicRecommendationEngine.Signal]
    /// The listening history (any order): the most recent distinct songs seed the playlist neighbours.
    public var recentEvents: [PlaybackEvent]
    /// Playlists with their songs in order.
    public var playlists: [Playlist]
    /// Songs that are not candidates: those with an instrumental, those with a pending cloud job.
    public var excluded: Set<String>
    public var blocked: BlockedArtistMatcher
    public var nowMs: Int64

    public init(songs: [Song], engagements: [String: EngagementStats] = [:],
                signals: [String: MusicRecommendationEngine.Signal] = [:], recentEvents: [PlaybackEvent] = [],
                playlists: [Playlist] = [], excluded: Set<String> = [], blocked: BlockedArtistMatcher = .empty,
                nowMs: Int64) {
        self.songs = songs
        self.engagements = engagements
        self.signals = signals
        self.recentEvents = recentEvents
        self.playlists = playlists
        self.excluded = excluded
        self.blocked = blocked
        self.nowMs = nowMs
    }
}

public enum SingPrepareRanker {
    // MARK: Constants (the same on both apps)

    public static let favoriteWeight = 3.0
    public static let playsWeight = 2.5
    public static let playRecencyWeight = 2.0
    public static let playRecencyHalfLifeDays = 14.0
    public static let addedWeight = 1.0
    public static let addedHalfLifeDays = 30.0
    public static let skipWeight = 3.0
    /// How many of the most recently played distinct songs seed the playlist neighbours.
    public static let neighbourSeeds = 5
    /// How many songs after a seed count as its neighbours.
    public static let neighbourSpan = 5
    public static let neighbourWeight = 1.0
    /// The best-scoring songs whose albums lift their siblings.
    public static let albumSeeds = 8
    public static let albumWeight = 0.8
    /// A song of this length or shorter, or over `maxDurationMs`, is left alone.
    public static let minDurationMs: Int64 = 60_000
    public static let maxDurationMs: Int64 = 8 * 60_000
    /// More than this share of early skips and the song is left alone.
    public static let maxSkipRate = 0.4

    /// What lifted a song, for the developer's "Why these songs" list.
    public enum Reason: Sendable, Hashable {
        case favorite
        case playedOften
        case playedRecently
        case addedRecently
        case nextInPlaylist
        case sameAlbum
    }

    public struct Candidate: Sendable, Hashable {
        public var song: Song
        public var score: Double
        public var reasons: [Reason]

        public init(song: Song, score: Double, reasons: [Reason]) {
            self.song = song
            self.score = score
            self.reasons = reasons
        }
    }

    // MARK: Terms

    public static func completionRate(_ signal: MusicRecommendationEngine.Signal) -> Double {
        (Double(signal.completions) + 2.0) / (Double(signal.sessions) + 4.0)
    }

    public static func skipRate(_ signal: MusicRecommendationEngine.Signal) -> Double {
        Double(signal.earlySkips) / (Double(signal.sessions) + 2.0)
    }

    /// 2^(−days / halfLife); 0 when the moment is unknown (≤ 0); a moment in the future counts as now.
    static func decay(sinceMs: Int64, nowMs: Int64, halfLifeDays: Double) -> Double {
        guard sinceMs > 0 else { return 0 }
        let days = Double(max(nowMs - sinceMs, 0)) / 86_400_000.0
        return pow(2.0, -days / halfLifeDays)
    }

    /// Every term but the neighbours and the album: the song's own score, and which of its terms are worth naming.
    static func ownScore(_ song: Song, _ inputs: SingPrepareInputs) -> (score: Double, reasons: [Reason]) {
        var score = 0.0
        var reasons: [Reason] = []
        if song.isFavorite {
            score += favoriteWeight
            reasons.append(.favorite)
        }
        let engagement = inputs.engagements[song.id]
        let signal = inputs.signals[song.id]
        if let engagement, let signal, engagement.playCount > 0 {
            let plays = playsWeight * log(1.0 + Double(engagement.playCount)) * completionRate(signal)
            score += plays
            if plays > 0 { reasons.append(.playedOften) }
        }
        let lastPlayed = max(engagement?.lastPlayedTimestamp ?? 0, signal?.lastPlayedMs ?? 0)
        let recency = playRecencyWeight * decay(sinceMs: lastPlayed, nowMs: inputs.nowMs, halfLifeDays: playRecencyHalfLifeDays)
        score += recency
        if recency >= playRecencyWeight * 0.5 { reasons.append(.playedRecently) }
        let added = addedWeight * decay(sinceMs: song.dateAdded, nowMs: inputs.nowMs, halfLifeDays: addedHalfLifeDays)
        score += added
        if added >= addedWeight * 0.5 { reasons.append(.addedRecently) }
        if let signal { score -= skipWeight * skipRate(signal) }
        return (score, reasons)
    }

    /// The most recently played distinct songs, newest first.
    static func recentSeeds(_ events: [PlaybackEvent]) -> [String] {
        let ordered = events.sorted { lhs, rhs in
            lhs.endMillis != rhs.endMillis ? lhs.endMillis > rhs.endMillis : lhs.songId < rhs.songId
        }
        var seen = Set<String>()
        var seeds: [String] = []
        for event in ordered where seen.insert(event.songId).inserted {
            seeds.append(event.songId)
            if seeds.count == neighbourSeeds { break }
        }
        return seeds
    }

    /// Per song, the sum over seeds and playlists of 1 / (1 + distance) for the songs just after the seed.
    static func neighbourBonus(seeds: [String], playlists: [Playlist]) -> [String: Double] {
        var bonus: [String: Double] = [:]
        for seed in seeds {
            for playlist in playlists {
                guard let index = playlist.songIds.firstIndex(of: seed) else { continue }
                for distance in 1...neighbourSpan {
                    let next = index + distance
                    guard next < playlist.songIds.count else { break }
                    bonus[playlist.songIds[next], default: 0] += neighbourWeight / (1.0 + Double(distance))
                }
            }
        }
        return bonus
    }

    /// A real album id (the library's "none" is -1, and 0 is unresolved).
    static func hasAlbum(_ song: Song) -> Bool { song.albumId != -1 && song.albumId != 0 }

    /// Left alone whatever its score.
    static func isExcluded(_ song: Song, _ inputs: SingPrepareInputs) -> Bool {
        if inputs.excluded.contains(song.id) { return true }
        if song.duration <= minDurationMs || song.duration > maxDurationMs { return true }
        if let signal = inputs.signals[song.id], skipRate(signal) > maxSkipRate { return true }
        return inputs.blocked.isBlocked(song)
    }

    // MARK: Ranking

    /// The best `limit` songs to prepare, best first (ties by song id).
    public static func rank(_ inputs: SingPrepareInputs, limit: Int) -> [Candidate] {
        guard limit > 0, !inputs.songs.isEmpty else { return [] }
        let neighbours = neighbourBonus(seeds: recentSeeds(inputs.recentEvents), playlists: inputs.playlists)

        // Every song the person could be listening to is a possible seed, whether or not it can be prepared itself.
        struct Scored {
            var song: Song
            var score: Double
            var reasons: [Reason]
        }
        var scored: [Scored] = []
        scored.reserveCapacity(inputs.songs.count)
        for song in inputs.songs where !inputs.blocked.isBlocked(song) {
            var (score, reasons) = ownScore(song, inputs)
            if let bonus = neighbours[song.id], bonus > 0 {
                score += bonus
                reasons.append(.nextInPlaylist)
            }
            scored.append(Scored(song: song, score: score, reasons: reasons))
        }

        func ahead(_ lhs: Scored, _ rhs: Scored) -> Bool {
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.song.id < rhs.song.id
        }
        let seedAlbums = Set(scored.sorted(by: ahead).prefix(albumSeeds).filter { hasAlbum($0.song) }.map(\.song.albumId))

        var candidates: [Candidate] = []
        for var item in scored where !isExcluded(item.song, inputs) {
            if hasAlbum(item.song), seedAlbums.contains(item.song.albumId) {
                item.score += albumWeight
                item.reasons.append(.sameAlbum)
            }
            candidates.append(Candidate(song: item.song, score: item.score, reasons: item.reasons))
        }
        candidates.sort { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.song.id < rhs.song.id
        }
        return Array(candidates.prefix(limit))
    }
}
