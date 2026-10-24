// Feeding imported listening history to the algorithm (spec B3).
//
// `ImportedHistoryAggregate` folds the stored plays into per-track and per-artist statistics (weighted 1.0 Spotify /
// 0.35 YouTube Music, fading with a 180-day half-life). It does not depend on the library, so it is built once per
// change of the history, not per library change. `recommendationInputs(library:)` then maps tracks to library songs
// (Spotify id first, else normalised title + first artist) and turns them into what the recommendation engine reads:
// - engagement (plays, listened time, last play) per song — the familiarity / recency terms;
// - learned signals per song from the Spotify extended export (sessions, completions, early skips, chosen by hand);
// - an artist affinity per artist from plays of songs NOT in the library, Spotify's top artists and followed artists
//   — so listening outside the library still lifts those artists' songs (the discovery signal).
// Spotify's top tracks add a few plays' worth of familiarity to their songs.

import Foundation
import PixlFoundation
import PixlModel

/// One track's imported listening.
public struct ImportedTrackStat: Sendable, Hashable {
    public var key: String
    public var title: String
    public var artist: String
    public var album: String?
    public var spotifyTrackId: String?
    /// Plays that count (too-short listens excluded).
    public var plays: Int
    /// Σ source weight × decay.
    public var weightedPlays: Double
    public var listenedMs: Int64
    public var lastPlayedMs: Int64
    /// Weighted outcomes of plays whose outcome is known (Spotify extended export).
    public var sessions: Double
    public var completions: Double
    public var earlySkips: Double
    public var voluntary: Double
    public var spotifyPlays: Int
    public var youTubePlays: Int
}

/// One artist's imported listening (keyed by the normalised first artist).
public struct ImportedArtistStat: Sendable, Hashable {
    public var key: String
    public var name: String
    public var plays: Int
    public var weightedPlays: Double
    public var listenedMs: Int64
    public var lastPlayedMs: Int64
}

public struct ImportedHistoryAggregate: Sendable {
    /// Best first (weighted plays, then key).
    public var tracks: [ImportedTrackStat]
    public var artists: [ImportedArtistStat]
    public var taste: ExternalTasteSnapshot
    public var totalPlays: Int
    public var spotifyPlays: Int
    public var youTubePlays: Int
    public var listenedMs: Int64
    public var firstPlayMs: Int64
    public var lastPlayMs: Int64
    public var nowMs: Int64

    public static let empty = ImportedHistoryAggregate(tracks: [], artists: [], taste: ExternalTasteSnapshot(),
                                                       totalPlays: 0, spotifyPlays: 0, youTubePlays: 0, listenedMs: 0,
                                                       firstPlayMs: 0, lastPlayMs: 0, nowMs: 0)

    public var isEmpty: Bool { tracks.isEmpty && taste.isEmpty }

    public static func build(plays: [ImportedPlay], taste: ExternalTasteSnapshot = ExternalTasteSnapshot(),
                             nowMs: Int64) -> ImportedHistoryAggregate {
        // A play without a Spotify id (basic export, YouTube) joins the id'd track with the same name.
        var cache = ImportedPlayKeyCache()
        var idByName: [String: String] = [:]
        for play in plays {
            if let id = play.spotifyTrackId, !id.isEmpty {
                idByName[cache.nameKey(title: play.title, artist: play.artist)] = id
            }
        }
        var tracks: [String: ImportedTrackStat] = [:]
        var artists: [String: ImportedArtistStat] = [:]
        var total = 0, spotify = 0, youTube = 0
        var listened: Int64 = 0
        var first = Int64.max, last: Int64 = 0
        for play in plays where ListeningHistoryWeights.counts(play) {
            let nameKey = cache.nameKey(title: play.title, artist: play.artist)
            let spotifyId = play.spotifyTrackId.flatMap { $0.isEmpty ? nil : $0 } ?? idByName[nameKey]
            let key = spotifyId.map { "sp:\($0)" } ?? "nm:\(nameKey)"
            let weight = ListeningHistoryWeights.weight(play, nowMs: nowMs)
            let outcome = ImportedPlayOutcome(play)
            var stat = tracks[key] ?? ImportedTrackStat(
                key: key, title: play.title, artist: play.artist, album: play.album, spotifyTrackId: spotifyId, plays: 0,
                weightedPlays: 0, listenedMs: 0, lastPlayedMs: 0, sessions: 0, completions: 0, earlySkips: 0, voluntary: 0,
                spotifyPlays: 0, youTubePlays: 0)
            stat.plays += 1
            stat.weightedPlays += weight
            stat.listenedMs &+= play.msPlayed
            if play.timestampMs >= stat.lastPlayedMs {
                stat.lastPlayedMs = play.timestampMs
                // The newest play names the track (Spotify's own spelling wins over a YouTube one).
                if play.source.isSpotify || stat.spotifyPlays == 0 {
                    stat.title = play.title
                    stat.artist = play.artist
                    if play.album != nil { stat.album = play.album }
                }
            }
            if outcome.isKnown {
                stat.sessions += weight
                if outcome.completed { stat.completions += weight }
                if outcome.earlySkip { stat.earlySkips += weight }
                if outcome.voluntary { stat.voluntary += weight }
            }
            if play.source.isSpotify { stat.spotifyPlays += 1; spotify += 1 } else { stat.youTubePlays += 1; youTube += 1 }
            tracks[key] = stat

            let artistKey = cache.artistKey(play.artist)
            if !artistKey.isEmpty {
                var a = artists[artistKey] ?? ImportedArtistStat(key: artistKey, name: primaryArtistName(play.artist),
                                                                 plays: 0, weightedPlays: 0, listenedMs: 0, lastPlayedMs: 0)
                a.plays += 1
                a.weightedPlays += weight
                a.listenedMs &+= play.msPlayed
                a.lastPlayedMs = max(a.lastPlayedMs, play.timestampMs)
                artists[artistKey] = a
            }
            total += 1
            listened &+= play.msPlayed
            first = min(first, play.timestampMs)
            last = max(last, play.timestampMs)
        }
        let sortedTracks = tracks.values.sorted {
            $0.weightedPlays != $1.weightedPlays ? $0.weightedPlays > $1.weightedPlays : $0.key < $1.key
        }
        let sortedArtists = artists.values.sorted {
            $0.weightedPlays != $1.weightedPlays ? $0.weightedPlays > $1.weightedPlays : $0.key < $1.key
        }
        return ImportedHistoryAggregate(tracks: sortedTracks, artists: sortedArtists, taste: taste, totalPlays: total,
                                        spotifyPlays: spotify, youTubePlays: youTube, listenedMs: listened,
                                        firstPlayMs: total == 0 ? 0 : first, lastPlayMs: last, nowMs: nowMs)
    }

    /// The first artist of a credit as written ("A, B" → "A").
    static func primaryArtistName(_ artist: String) -> String {
        var cut = artist.endIndex
        for separator in [", ", " & ", " feat. ", " ft. ", " featuring ", " x ", " / ", "; "] {
            if let range = artist.range(of: separator, options: .caseInsensitive), range.lowerBound < cut {
                cut = range.lowerBound
            }
        }
        return String(artist[..<cut]).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Recommendation inputs

/// What imported history adds to the recommendation engine, by library song id / artist key.
public struct ImportedRecommendationInputs: Sendable {
    public var engagements: [String: EngagementStats]
    public var signals: [String: MusicRecommendationEngine.Signal]
    /// Normalised first artist → extra taste weight (added to the engine's artist weights).
    public var artistAffinity: [String: Double]
    public var mappedTracks: Int
    public var unmappedTracks: Int

    public static let empty = ImportedRecommendationInputs(engagements: [:], signals: [:], artistAffinity: [:],
                                                           mappedTracks: 0, unmappedTracks: 0)

    public init(engagements: [String: EngagementStats], signals: [String: MusicRecommendationEngine.Signal],
                artistAffinity: [String: Double], mappedTracks: Int, unmappedTracks: Int) {
        self.engagements = engagements
        self.signals = signals
        self.artistAffinity = artistAffinity
        self.mappedTracks = mappedTracks
        self.unmappedTracks = unmappedTracks
    }

    /// The app's own engagement plus the imported one (plays and time add up, the latest play wins).
    public func mergedEngagements(_ local: [String: EngagementStats]) -> [String: EngagementStats] {
        guard !engagements.isEmpty else { return local }
        var out = local
        for (id, imported) in engagements {
            var stats = out[id] ?? EngagementStats()
            stats.playCount = min(stats.playCount + imported.playCount, Int(Int32.max))
            stats.totalPlayDurationMs &+= imported.totalPlayDurationMs
            stats.lastPlayedTimestamp = max(stats.lastPlayedTimestamp, imported.lastPlayedTimestamp)
            out[id] = stats
        }
        return out
    }

    /// The learned signals plus the imported ones.
    public func mergedSignals(_ local: [String: MusicRecommendationEngine.Signal]) -> [String: MusicRecommendationEngine.Signal] {
        guard !signals.isEmpty else { return local }
        var out = local
        for (id, imported) in signals {
            var s = out[id] ?? MusicRecommendationEngine.Signal()
            s.sessions = min(s.sessions + imported.sessions, 1_000_000)
            s.completions += imported.completions
            s.earlySkips += imported.earlySkips
            s.voluntaryPlays += imported.voluntaryPlays
            s.lastPlayedMs = max(s.lastPlayedMs, imported.lastPlayedMs)
            s.listenedMs &+= imported.listenedMs
            out[id] = s
        }
        return out
    }
}

/// Finds the library song a track is: by Spotify id first, else by normalised title + first artist.
public struct ImportedHistoryMapper: Sendable {
    private var bySpotifyId: [String: String] = [:]
    private var byName: [String: String] = [:]

    public init(library: [Song]) {
        // Smallest id wins ties, so the mapping does not depend on library order.
        for song in library.sorted(by: { $0.id < $1.id }) {
            if let id = song.spotifyId, !id.isEmpty, bySpotifyId[id] == nil { bySpotifyId[id] = song.id }
            let name = ImportedPlayIdentity.nameKey(title: song.title, artist: song.artist)
            if byName[name] == nil { byName[name] = song.id }
        }
    }

    public func songId(spotifyTrackId: String?, title: String, artist: String) -> String? {
        if let id = spotifyTrackId, let song = bySpotifyId[id] { return song }
        return byName[ImportedPlayIdentity.nameKey(title: title, artist: artist)]
    }
}

public enum ImportedHistoryTuning {
    /// Plays of songs not in the library lift their artist by ln(1 + weighted plays) × 0.6.
    public static let unmappedArtistScale = 0.6
    /// A top artist lifts by scale × (1 − rank / 50), per Spotify time range.
    public static let topArtistScale: [ExternalTasteSnapshot.Range: Double] = [.shortTerm: 1.5, .mediumTerm: 2.0, .longTerm: 2.5]
    public static let followedArtistBonus = 1.0
    /// The artist affinity never exceeds the engine's own per-song cap.
    public static let maxArtistAffinity = 6.0
    /// A top track counts as this many plays × (1 − rank / 50), per range.
    public static let topTrackPlays: [ExternalTasteSnapshot.Range: Double] = [.shortTerm: 4, .mediumTerm: 6, .longTerm: 8]
    static let rankSpan = 50.0

    static func rankFactor(_ rank: Int) -> Double { max(0, 1 - Double(rank) / rankSpan) }
}

extension ImportedHistoryAggregate {
    /// Maps the tracks to `library` and builds the engine's inputs.
    public func recommendationInputs(library: [Song]) -> ImportedRecommendationInputs {
        guard !isEmpty, !library.isEmpty else { return .empty }
        let mapper = ImportedHistoryMapper(library: library)
        var engagements: [String: EngagementStats] = [:]
        var signals: [String: MusicRecommendationEngine.Signal] = [:]
        var unmappedByArtist: [String: Double] = [:]
        var mapped = 0, unmapped = 0
        for track in tracks {
            guard let songId = mapper.songId(spotifyTrackId: track.spotifyTrackId, title: track.title, artist: track.artist)
            else {
                unmapped += 1
                let artist = ImportedPlayIdentity.primaryArtistKey(track.artist)
                if !artist.isEmpty { unmappedByArtist[artist, default: 0] += track.weightedPlays }
                continue
            }
            mapped += 1
            var stats = engagements[songId] ?? EngagementStats()
            stats.playCount += max(1, Int(track.weightedPlays.rounded()))
            stats.totalPlayDurationMs &+= track.listenedMs
            stats.lastPlayedTimestamp = max(stats.lastPlayedTimestamp, track.lastPlayedMs)
            engagements[songId] = stats
            var signal = signals[songId] ?? MusicRecommendationEngine.Signal()
            signal.sessions += Int(track.sessions.rounded())
            signal.completions += Int(track.completions.rounded())
            signal.earlySkips += Int(track.earlySkips.rounded())
            signal.voluntaryPlays += Int(track.voluntary.rounded())
            signal.lastPlayedMs = max(signal.lastPlayedMs, track.lastPlayedMs)
            signal.listenedMs &+= track.listenedMs
            signals[songId] = signal
        }
        // Spotify's top tracks: a few plays' worth of familiarity (no "last played": they don't make a song feel
        // recently heard).
        for top in taste.topTracks {
            guard let songId = mapper.songId(spotifyTrackId: top.spotifyTrackId, title: top.title, artist: top.artist),
                  let scale = ImportedHistoryTuning.topTrackPlays[top.range] else { continue }
            let plays = Int((scale * ImportedHistoryTuning.rankFactor(top.rank)).rounded())
            guard plays > 0 else { continue }
            engagements[songId, default: EngagementStats()].playCount += plays
            if signals[songId] == nil { signals[songId] = MusicRecommendationEngine.Signal() }
        }
        var affinity: [String: Double] = [:]
        for (artist, weighted) in unmappedByArtist where weighted > 0 {
            affinity[artist, default: 0] += log(1 + weighted) * ImportedHistoryTuning.unmappedArtistScale
        }
        for top in taste.topArtists {
            let key = ImportedPlayIdentity.primaryArtistKey(top.name)
            guard !key.isEmpty, let scale = ImportedHistoryTuning.topArtistScale[top.range] else { continue }
            affinity[key, default: 0] += scale * ImportedHistoryTuning.rankFactor(top.rank)
        }
        for name in Set(taste.followedArtists.map(ImportedPlayIdentity.primaryArtistKey)) where !name.isEmpty {
            affinity[name, default: 0] += ImportedHistoryTuning.followedArtistBonus
        }
        for key in affinity.keys { affinity[key] = min(affinity[key]!, ImportedHistoryTuning.maxArtistAffinity) }
        return ImportedRecommendationInputs(engagements: engagements, signals: signals, artistAffinity: affinity,
                                            mappedTracks: mapped, unmappedTracks: unmapped)
    }
}
