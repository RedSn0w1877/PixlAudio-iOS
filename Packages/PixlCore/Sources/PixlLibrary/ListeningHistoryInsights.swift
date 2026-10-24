// The small read API over all listening — the app's own plays plus imported Spotify / YouTube Music history — that
// the assistant, the greeting and insights read (spec B3): `topArtists(period)`, `topTracks(period)`,
// `recentPlays(n)`, `listeningSummary()`. Scores weigh a Spotify play (and a play in this app) 1.0 and a YouTube Music
// play 0.35; counts are plain play counts. Pure: the app gathers the plays and calls these off the main thread.

import Foundation
import PixlModel

/// A time window ending now.
public enum ListeningPeriod: String, Sendable, Hashable, CaseIterable, Codable {
    case month
    case sixMonths
    case year
    case allTime

    /// The window's length (nil: everything).
    public var lengthMs: Int64? {
        switch self {
        case .month: 30 * 86_400_000
        case .sixMonths: 182 * 86_400_000
        case .year: 365 * 86_400_000
        case .allTime: nil
        }
    }
}

/// Where a play happened.
public enum ListeningSource: String, Sendable, Hashable, Codable {
    /// Played in PixlAudio.
    case app
    case spotify
    case youTubeMusic

    public var weight: Double {
        switch self {
        case .app, .spotify: ListeningHistoryWeights.spotify
        case .youTubeMusic: ListeningHistoryWeights.youTubeMusic
        }
    }

    public init(_ source: ImportedPlaySource) {
        self = source.isSpotify ? .spotify : .youTubeMusic
    }
}

/// One play, whatever its source.
public struct ListeningPlay: Sendable, Hashable, Codable {
    public var title: String
    public var artist: String
    public var album: String?
    public var timestampMs: Int64
    /// Listened time (0 = unknown).
    public var listenedMs: Int64
    public var source: ListeningSource
    /// The library song, when the play is of one.
    public var songId: String?
    public var spotifyTrackId: String?

    public init(title: String, artist: String, album: String? = nil, timestampMs: Int64, listenedMs: Int64 = 0,
                source: ListeningSource, songId: String? = nil, spotifyTrackId: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.timestampMs = timestampMs
        self.listenedMs = listenedMs
        self.source = source
        self.songId = songId
        self.spotifyTrackId = spotifyTrackId
    }
}

public struct ArtistInsight: Sendable, Hashable, Codable {
    public var name: String
    public var plays: Int
    /// Σ source weight.
    public var score: Double
    public var listenedMs: Int64
    public var lastPlayedMs: Int64
}

public struct TrackInsight: Sendable, Hashable, Codable {
    public var title: String
    public var artist: String
    public var songId: String?
    public var spotifyTrackId: String?
    public var plays: Int
    public var score: Double
    public var lastPlayedMs: Int64
}

public struct ListeningSummary: Sendable, Hashable, Codable {
    public var totalPlays: Int
    public var appPlays: Int
    public var spotifyPlays: Int
    public var youTubeMusicPlays: Int
    public var uniqueArtists: Int
    public var uniqueTracks: Int
    public var listenedMs: Int64
    public var firstPlayMs: Int64
    public var lastPlayMs: Int64
    public var playsLast30Days: Int
    /// The five strongest artists of the last six months (all time when that is empty).
    public var topArtists: [String]
    /// Genres of Spotify's top artists, most frequent first.
    public var topGenres: [String]
    public var followedArtists: Int

    public static let empty = ListeningSummary(totalPlays: 0, appPlays: 0, spotifyPlays: 0, youTubeMusicPlays: 0,
                                               uniqueArtists: 0, uniqueTracks: 0, listenedMs: 0, firstPlayMs: 0,
                                               lastPlayMs: 0, playsLast30Days: 0, topArtists: [], topGenres: [],
                                               followedArtists: 0)
}

public enum ListeningHistoryInsights {
    // MARK: Gathering

    /// Imported plays as listening plays (too-short listens left out), mapped to library songs when possible.
    public static func plays(imported: [ImportedPlay], mapper: ImportedHistoryMapper? = nil) -> [ListeningPlay] {
        imported.compactMap { play in
            guard ListeningHistoryWeights.counts(play) else { return nil }
            return ListeningPlay(title: play.title, artist: play.artist, album: play.album, timestampMs: play.timestampMs,
                                 listenedMs: play.msPlayed, source: ListeningSource(play.source),
                                 songId: mapper?.songId(spotifyTrackId: play.spotifyTrackId, title: play.title,
                                                        artist: play.artist),
                                 spotifyTrackId: play.spotifyTrackId)
        }
    }

    /// The app's own history as listening plays (events of songs no longer in the library are left out).
    public static func plays(events: [PlaybackEvent], songsById: [String: Song]) -> [ListeningPlay] {
        events.compactMap { event in
            guard let song = songsById[event.songId] else { return nil }
            return ListeningPlay(title: song.title, artist: song.artist, album: song.album, timestampMs: event.endMillis,
                                 listenedMs: event.durationMs, source: .app, songId: song.id, spotifyTrackId: song.spotifyId)
        }
    }

    static func inPeriod(_ plays: [ListeningPlay], _ period: ListeningPeriod, nowMs: Int64) -> [ListeningPlay] {
        guard let length = period.lengthMs else { return plays }
        let start = nowMs - length
        return plays.filter { $0.timestampMs >= start && $0.timestampMs <= nowMs + 60_000 }
    }

    // MARK: Queries

    public static func topArtists(_ plays: [ListeningPlay], period: ListeningPeriod, nowMs: Int64,
                                  limit: Int = 20) -> [ArtistInsight] {
        var byKey: [String: ArtistInsight] = [:]
        var cache = ImportedPlayKeyCache()
        for play in inPeriod(plays, period, nowMs: nowMs) {
            let key = cache.artistKey(play.artist)
            guard !key.isEmpty else { continue }
            var a = byKey[key] ?? ArtistInsight(name: ImportedHistoryAggregate.primaryArtistName(play.artist), plays: 0,
                                                score: 0, listenedMs: 0, lastPlayedMs: 0)
            a.plays += 1
            a.score += play.source.weight
            a.listenedMs &+= play.listenedMs
            a.lastPlayedMs = max(a.lastPlayedMs, play.timestampMs)
            byKey[key] = a
        }
        return Array(byKey.values.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.name < $1.name
        }.prefix(max(limit, 0)))
    }

    public static func topTracks(_ plays: [ListeningPlay], period: ListeningPeriod, nowMs: Int64,
                                 limit: Int = 20) -> [TrackInsight] {
        var byKey: [String: TrackInsight] = [:]
        var cache = ImportedPlayKeyCache()
        for play in inPeriod(plays, period, nowMs: nowMs) {
            let key = play.spotifyTrackId.map { "sp:\($0)" }
                ?? "nm:\(cache.nameKey(title: play.title, artist: play.artist))"
            var t = byKey[key] ?? TrackInsight(title: play.title, artist: play.artist, songId: play.songId,
                                               spotifyTrackId: play.spotifyTrackId, plays: 0, score: 0, lastPlayedMs: 0)
            t.plays += 1
            t.score += play.source.weight
            if t.songId == nil { t.songId = play.songId }
            t.lastPlayedMs = max(t.lastPlayedMs, play.timestampMs)
            byKey[key] = t
        }
        return Array(byKey.values.sorted {
            $0.score != $1.score ? $0.score > $1.score : ($0.title, $0.artist) < ($1.title, $1.artist)
        }.prefix(max(limit, 0)))
    }

    /// The newest `count` plays, newest first.
    public static func recentPlays(_ plays: [ListeningPlay], count: Int) -> [ListeningPlay] {
        Array(plays.sorted {
            $0.timestampMs != $1.timestampMs ? $0.timestampMs > $1.timestampMs : $0.title < $1.title
        }.prefix(max(count, 0)))
    }

    public static func summary(_ plays: [ListeningPlay], taste: ExternalTasteSnapshot = ExternalTasteSnapshot(),
                               nowMs: Int64) -> ListeningSummary {
        var summary = ListeningSummary.empty
        var artists = Set<String>(), tracks = Set<String>()
        var first = Int64.max
        var cache = ImportedPlayKeyCache()
        for play in plays {
            summary.totalPlays += 1
            switch play.source {
            case .app: summary.appPlays += 1
            case .spotify: summary.spotifyPlays += 1
            case .youTubeMusic: summary.youTubeMusicPlays += 1
            }
            artists.insert(cache.artistKey(play.artist))
            tracks.insert(play.spotifyTrackId ?? cache.nameKey(title: play.title, artist: play.artist))
            summary.listenedMs &+= play.listenedMs
            first = min(first, play.timestampMs)
            summary.lastPlayMs = max(summary.lastPlayMs, play.timestampMs)
            if play.timestampMs >= nowMs - 30 * 86_400_000 { summary.playsLast30Days += 1 }
        }
        artists.remove("")
        summary.uniqueArtists = artists.count
        summary.uniqueTracks = tracks.count
        summary.firstPlayMs = summary.totalPlays == 0 ? 0 : first
        var top = topArtists(plays, period: .sixMonths, nowMs: nowMs, limit: 5)
        if top.isEmpty { top = topArtists(plays, period: .allTime, nowMs: nowMs, limit: 5) }
        summary.topArtists = top.map(\.name)
        if top.isEmpty {
            summary.topArtists = Array(taste.topArtists.filter { $0.range == .mediumTerm }.sorted { $0.rank < $1.rank }
                .prefix(5).map(\.name))
        }
        var genreCounts: [String: Int] = [:]
        var genreOrder: [String] = []
        for artist in taste.topArtists.sorted(by: { ($0.range.rawValue, $0.rank) < ($1.range.rawValue, $1.rank) }) {
            for genre in artist.genres {
                if genreCounts[genre] == nil { genreOrder.append(genre) }
                genreCounts[genre, default: 0] += 1
            }
        }
        summary.topGenres = Array(genreOrder.enumerated().sorted { a, b in
            let ca = genreCounts[a.element]!, cb = genreCounts[b.element]!
            return ca != cb ? ca > cb : a.offset < b.offset
        }.map(\.element).prefix(8))
        summary.followedArtists = taste.followedArtists.count
        return summary
    }
}
