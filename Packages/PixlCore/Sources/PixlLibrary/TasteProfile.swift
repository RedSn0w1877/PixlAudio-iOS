// The taste profile Ask Taizo reads (spec taizo-taste §1): a compact, deterministic summary built by CODE from every
// play there is — the app's own and the imported Spotify / YouTube Music history — never by the model. Everything in it
// is counted; what the data does not know (language, energy, genres of songs outside the library …) is left out and
// named in `not_available`, never guessed. `confidence` says how many plays it rests on, so Taizo can say "I only have
// 40 plays" instead of sounding sure.
//
// Pure: the app gathers the plays and calls `TasteProfileBuilder.build` off the main thread, and caches the result until
// a play, the library or an adjustment changes.

import Foundation
import PixlFoundation
import PixlModel

extension ListeningPeriod {
    /// The `period` of `get_taste_profile`: month | six_months | year | all_time.
    public init?(toolValue: String) {
        switch toolValue {
        case "month": self = .month
        case "six_months": self = .sixMonths
        case "year": self = .year
        case "all_time": self = .allTime
        default: return nil
        }
    }

    public var toolValue: String {
        switch self {
        case .month: "month"
        case .sixMonths: "six_months"
        case .year: "year"
        case .allTime: "all_time"
        }
    }
}

public struct TasteProfileInputs: Sendable {
    public var songs: [Song]
    /// Every play, the app's and the imported ones (`ListeningHistoryInsights.plays`).
    public var plays: [ListeningPlay]
    /// The imported plays themselves: their completion / skip information (Spotify's extended history).
    public var importedPlays: [ImportedPlay]
    public var taste: ExternalTasteSnapshot
    /// The app's own learned feedback per song (empty while "Learn from listening" is off).
    public var localSignals: [String: MusicRecommendationEngine.Signal]
    public var adjustments: [TasteAdjustment]
    public var nowMs: Int64
    public var timeZone: TimeZone

    public init(songs: [Song], plays: [ListeningPlay], importedPlays: [ImportedPlay] = [],
                taste: ExternalTasteSnapshot = ExternalTasteSnapshot(),
                localSignals: [String: MusicRecommendationEngine.Signal] = [:], adjustments: [TasteAdjustment] = [],
                nowMs: Int64, timeZone: TimeZone = TimeZone(identifier: "UTC") ?? .current) {
        self.songs = songs
        self.plays = plays
        self.importedPlays = importedPlays
        self.taste = taste
        self.localSignals = localSignals
        self.adjustments = adjustments
        self.nowMs = nowMs
        self.timeZone = timeZone
    }
}

public struct TasteProfile: Sendable {
    public struct Count: Sendable, Hashable {
        public var name: String
        public var plays: Int
        public var sharePercent: Double
    }

    public struct ArtistEntry: Sendable, Hashable {
        public var name: String
        public var plays: Int
        public var sharePercent: Double
        public var score: Double
        public var sessions: Int
        public var completions: Int
        public var earlySkips: Int
    }

    public struct TrackEntry: Sendable, Hashable {
        public var title: String
        public var artist: String
        public var plays: Int
        public var sharePercent: Double
        public var songId: String?
    }

    public struct SkipEntry: Sendable, Hashable {
        public var name: String
        public var earlySkips: Int
        public var sessions: Int
        public var skipRate: Double
    }

    public struct Pattern: Sendable, Hashable {
        public var basisPlays: Int
        public var timeOfDay: [Count]
        public var weekdayPlaysPercent: Double
        public var weekendPlaysPercent: Double
        public var peakHour: Int
        public var busiestWeekday: String
    }

    public enum Confidence: String, Sendable, Hashable {
        case empty = "none"
        case low, medium, high
    }

    public var period: ListeningPeriod
    /// The period actually used (all time when the asked one had no plays).
    public var periodUsed: ListeningPeriod
    public var playsInPeriod: Int
    public var totalPlays: Int
    public var appPlays: Int
    public var spotifyPlays: Int
    public var youTubeMusicPlays: Int
    public var uniqueArtists: Int
    public var firstPlayMs: Int64
    public var topArtists: [ArtistEntry]
    public var topTracks: [TrackEntry]
    public var recentPlays: [TrackEntry]
    public var sessionsWithKnownOutcome: Int
    public var completions: Int
    public var earlySkips: Int
    public var skippedArtists: [SkipEntry]
    public var genres: [Count]
    public var genreCoveragePercent: Double
    public var decades: [Count]
    public var pattern: Pattern?
    public var spotifyTopArtists: [(range: String, names: [String])]
    public var spotifyTopTracks: [TrackEntry]
    public var spotifyGenres: [String]
    public var followedArtistCount: Int
    public var followedArtistsSample: [String]
    public var adjustments: [AdjustmentLine]
    public var confidence: Confidence
    public var confidenceNote: String
    public var notAvailable: [String]

    public struct AdjustmentLine: Sendable, Hashable {
        public var id: String
        public var action: String
        public var targetType: String
        public var target: String
        public var strength: Int
        public var reason: String
        public var setBy: String
        public var ageDays: Int
        public var expiresInDays: Int?
    }
}

public enum TasteProfileBuilder {
    public static let maxArtists = 15
    public static let maxTracks = 15
    public static let maxGenres = 12
    public static let recentCount = 10
    /// The listening pattern needs this many dated plays.
    public static let minPatternPlays = 30
    /// Skip-heavy: at least this many sessions with a known outcome and this share of early skips.
    public static let minSkipSessions = 5
    public static let minSkipRate = 0.3
    static let day: Int64 = 86_400_000

    // MARK: Build

    public static func build(_ inputs: TasteProfileInputs, period requested: ListeningPeriod) -> TasteProfile {
        let nowMs = inputs.nowMs
        let all = inputs.plays
        var period = requested
        var inPeriod = ListeningHistoryInsights.inPeriod(all, period, nowMs: nowMs)
        if inPeriod.isEmpty, period != .allTime, !all.isEmpty {
            period = .allTime
            inPeriod = all
        }
        let periodCount = inPeriod.count
        func share(_ count: Int) -> Double { periodCount == 0 ? 0 : Double(count) * 100.0 / Double(periodCount) }

        let songsById = Dictionary(inputs.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var cache = ImportedPlayKeyCache()

        // Outcomes: imported plays in the period with a known outcome, plus the app's own learned sessions (all time).
        struct Outcome {
            var sessions = 0, completions = 0, skips = 0
        }
        var overall = Outcome()
        var byArtist: [String: Outcome] = [:]
        var nameByArtist: [String: String] = [:]
        let windowStart = period.lengthMs.map { nowMs - $0 }
        for play in inputs.importedPlays where ListeningHistoryWeights.counts(play) {
            if let windowStart, play.timestampMs < windowStart || play.timestampMs > nowMs + 60_000 { continue }
            let outcome = ImportedPlayOutcome(play)
            guard outcome.isKnown else { continue }
            let key = cache.artistKey(play.artist)
            guard !key.isEmpty else { continue }
            if nameByArtist[key] == nil { nameByArtist[key] = ImportedHistoryAggregate.primaryArtistName(play.artist) }
            overall.sessions += 1
            byArtist[key, default: Outcome()].sessions += 1
            if outcome.completed {
                overall.completions += 1
                byArtist[key, default: Outcome()].completions += 1
            }
            if outcome.earlySkip {
                overall.skips += 1
                byArtist[key, default: Outcome()].skips += 1
            }
        }
        for (songId, signal) in inputs.localSignals {
            guard let song = songsById[songId], signal.sessions > 0 else { continue }
            let key = cache.artistKey(song.artist)
            guard !key.isEmpty else { continue }
            if nameByArtist[key] == nil { nameByArtist[key] = ImportedHistoryAggregate.primaryArtistName(song.artist) }
            overall.sessions += signal.sessions
            overall.completions += signal.completions
            overall.skips += signal.earlySkips
            byArtist[key, default: Outcome()].sessions += signal.sessions
            byArtist[key, default: Outcome()].completions += signal.completions
            byArtist[key, default: Outcome()].skips += signal.earlySkips
        }

        // Top artists and tracks.
        let artists = ListeningHistoryInsights.topArtists(all, period: period, nowMs: nowMs, limit: maxArtists)
        let topArtists = artists.map { artist -> TasteProfile.ArtistEntry in
            let key = cache.artistKey(artist.name)
            let outcome = byArtist[key] ?? Outcome()
            return TasteProfile.ArtistEntry(name: artist.name, plays: artist.plays, sharePercent: share(artist.plays),
                                            score: artist.score, sessions: outcome.sessions,
                                            completions: outcome.completions, earlySkips: outcome.skips)
        }
        let topTracks = ListeningHistoryInsights.topTracks(all, period: period, nowMs: nowMs, limit: maxTracks).map {
            TasteProfile.TrackEntry(title: $0.title, artist: $0.artist, plays: $0.plays, sharePercent: share($0.plays),
                                    songId: $0.songId)
        }
        let recent = ListeningHistoryInsights.recentPlays(all, count: recentCount).map {
            TasteProfile.TrackEntry(title: $0.title, artist: $0.artist, plays: 1, sharePercent: 0, songId: $0.songId)
        }

        // Skip-heavy artists.
        let skipped = byArtist.compactMap { key, outcome -> TasteProfile.SkipEntry? in
            guard outcome.sessions >= minSkipSessions else { return nil }
            let rate = Double(outcome.skips) / Double(outcome.sessions)
            guard rate >= minSkipRate else { return nil }
            return TasteProfile.SkipEntry(name: nameByArtist[key] ?? key, earlySkips: outcome.skips,
                                          sessions: outcome.sessions, skipRate: rate)
        }.sorted { $0.earlySkips != $1.earlySkips ? $0.earlySkips > $1.earlySkips : $0.name < $1.name }

        // Genres and decades: only plays of songs the library knows.
        var genreCounts: [String: Int] = [:]
        var genreNames: [String: String] = [:]
        var decadeCounts: [Int: Int] = [:]
        var withGenre = 0
        for play in inPeriod {
            guard let id = play.songId, let song = songsById[id] else { continue }
            if let genre = song.genre?.trimmingCharacters(in: .whitespacesAndNewlines), !genre.isEmpty,
               let key = TasteKey.genres(song).first {
                genreCounts[key, default: 0] += 1
                if genreNames[key] == nil { genreNames[key] = genre }
                withGenre += 1
            }
            if song.year > 0 { decadeCounts[song.year / 10 * 10, default: 0] += 1 }
        }
        let genres = genreCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(maxGenres).map { TasteProfile.Count(name: genreNames[$0.key] ?? $0.key, plays: $0.value, sharePercent: share($0.value)) }
        let decades = decadeCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(8).map { TasteProfile.Count(name: "\($0.key)s", plays: $0.value, sharePercent: share($0.value)) }

        // The listening pattern, when the plays carry real times.
        let pattern = datedPattern(inPeriod, timeZone: inputs.timeZone)

        // Spotify's own lists.
        let taste = inputs.taste
        var spotifyArtists: [(range: String, names: [String])] = []
        let ranges: [(ExternalTasteSnapshot.Range, String, Int)] = [(.shortTerm, "short_term", 10),
                                                                    (.mediumTerm, "medium_term", 15), (.longTerm, "long_term", 10)]
        for (range, label, limit) in ranges {
            let names = taste.topArtists.filter { $0.range == range }.sorted { $0.rank < $1.rank }.prefix(limit).map(\.name)
            if !names.isEmpty { spotifyArtists.append((label, Array(names))) }
        }
        let spotifyTracks = taste.topTracks.filter { $0.range == .mediumTerm }.sorted { $0.rank < $1.rank }.prefix(10).map {
            TasteProfile.TrackEntry(title: $0.title, artist: $0.artist, plays: 0, sharePercent: 0, songId: nil)
        }
        var spotifyGenreCounts: [String: Int] = [:]
        var spotifyGenreOrder: [String] = []
        for artist in taste.topArtists.sorted(by: { ($0.range.rawValue, $0.rank) < ($1.range.rawValue, $1.rank) }) {
            for genre in artist.genres {
                if spotifyGenreCounts[genre] == nil { spotifyGenreOrder.append(genre) }
                spotifyGenreCounts[genre, default: 0] += 1
            }
        }
        let spotifyGenres = spotifyGenreOrder.enumerated().sorted { a, b in
            let ca = spotifyGenreCounts[a.element] ?? 0, cb = spotifyGenreCounts[b.element] ?? 0
            return ca != cb ? ca > cb : a.offset < b.offset
        }.map(\.element).prefix(10)

        // Totals.
        var appPlays = 0, spotifyPlays = 0, youTubePlays = 0
        var first = Int64.max
        var artistKeys = Set<String>()
        for play in all {
            switch play.source {
            case .app: appPlays += 1
            case .spotify: spotifyPlays += 1
            case .youTubeMusic: youTubePlays += 1
            }
            first = min(first, play.timestampMs)
            artistKeys.insert(cache.artistKey(play.artist))
        }
        artistKeys.remove("")

        let lines = inputs.adjustments.filter { $0.isActive(nowMs: nowMs) }
            .sorted { $0.createdMs != $1.createdMs ? $0.createdMs > $1.createdMs : $0.id < $1.id }
            .map { adjustment in
                TasteProfile.AdjustmentLine(
                    id: adjustment.id, action: adjustment.kind.rawValue, targetType: adjustment.targetType.rawValue,
                    target: adjustment.label, strength: adjustment.strength, reason: adjustment.reason,
                    setBy: adjustment.source.rawValue, ageDays: Int(max(nowMs - adjustment.createdMs, 0) / day),
                    expiresInDays: adjustment.expiresMs.map { Int(max($0 - nowMs, 0) / day) })
            }

        let (confidence, note) = confidenceFor(plays: periodCount, total: all.count, period: period, requested: requested)
        var unavailable = ["language", "energy"]
        if genres.isEmpty { unavailable.append("genres") }
        if decades.isEmpty { unavailable.append("eras") }
        if pattern == nil { unavailable.append("time_of_day") }
        if overall.sessions == 0 { unavailable.append("completions_and_skips") }

        return TasteProfile(
            period: requested, periodUsed: period, playsInPeriod: periodCount, totalPlays: all.count, appPlays: appPlays,
            spotifyPlays: spotifyPlays, youTubeMusicPlays: youTubePlays, uniqueArtists: artistKeys.count,
            firstPlayMs: all.isEmpty ? 0 : first, topArtists: topArtists, topTracks: topTracks, recentPlays: recent,
            sessionsWithKnownOutcome: overall.sessions, completions: overall.completions, earlySkips: overall.skips,
            skippedArtists: Array(skipped.prefix(10)), genres: Array(genres),
            genreCoveragePercent: share(withGenre), decades: Array(decades), pattern: pattern,
            spotifyTopArtists: spotifyArtists, spotifyTopTracks: Array(spotifyTracks), spotifyGenres: Array(spotifyGenres),
            followedArtistCount: taste.followedArtists.count, followedArtistsSample: Array(taste.followedArtists.prefix(20)),
            adjustments: lines, confidence: confidence, confidenceNote: note, notAvailable: unavailable)
    }

    static func confidenceFor(plays: Int, total: Int, period: ListeningPeriod, requested: ListeningPeriod)
        -> (TasteProfile.Confidence, String)
    {
        let basis = "Rests on \(plays) play\(plays == 1 ? "" : "s") (\(total) in all)."
        let fallback = period != requested ? " The asked period had no plays, so this is all time." : ""
        switch plays {
        case 0: return (.empty, "There is no listening history yet. Do not describe the person's taste; say there is not enough data.")
        case 1..<50: return (.low, basis + fallback + " That is thin: say how few plays there are instead of generalising.")
        case 50..<500: return (.medium, basis + fallback + " Good enough for the main artists and genres, not for small claims.")
        default: return (.high, basis + fallback)
        }
    }

    // MARK: Pattern

    static func datedPattern(_ plays: [ListeningPlay], timeZone: TimeZone) -> TasteProfile.Pattern? {
        let dated = plays.filter { $0.timestampMs > 0 }
        guard dated.count >= minPatternPlays else { return nil }
        let clock = ZoneClock(timeZone)
        var hours = [Int](repeating: 0, count: 24)
        var weekdays = [Int](repeating: 0, count: 8)
        for play in dated {
            hours[clock.localHour(at: play.timestampMs)] += 1
            weekdays[clock.localDate(at: play.timestampMs).dayOfWeek] += 1
        }
        let total = dated.count
        func percent(_ n: Int) -> Double { Double(n) * 100.0 / Double(total) }
        func sum(_ hoursRange: [Int]) -> Int { hoursRange.reduce(0) { $0 + hours[$1] } }
        let buckets: [(String, [Int])] = [("morning", Array(5...11)), ("afternoon", Array(12...16)),
                                          ("evening", Array(17...21)), ("night", [22, 23, 0, 1, 2, 3, 4])]
        let timeOfDay = buckets.map { TasteProfile.Count(name: $0.0, plays: sum($0.1), sharePercent: percent(sum($0.1))) }
        let weekend = weekdays[6] + weekdays[7]
        let names = ["", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        var busiest = 1
        for day in 2...7 where weekdays[day] > weekdays[busiest] { busiest = day }
        var peak = 0
        for hour in 1..<24 where hours[hour] > hours[peak] { peak = hour }
        return TasteProfile.Pattern(basisPlays: total, timeOfDay: timeOfDay, weekdayPlaysPercent: percent(total - weekend),
                                    weekendPlaysPercent: percent(weekend), peakHour: peak, busiestWeekday: names[busiest])
    }
}

// MARK: - JSON

extension TasteProfile {
    static func object(_ members: [(String, JSONValue)]) -> JSONValue {
        .object(JSONObject(members.map { (key: $0.0, value: $0.1) }))
    }

    /// A number written the way JSON wants it (no exponent for the sizes used here).
    static func number(_ value: Double, places: Int = 1) -> JSONValue {
        guard value.isFinite else { return .number("0") }
        let scale = pow(10.0, Double(places))
        let rounded = (value * scale).rounded() / scale
        if rounded == rounded.rounded(), abs(rounded) < 1e15 { return .number(String(Int64(rounded))) }
        return .number(String(rounded))
    }

    static func strings(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }

    private func counts(_ items: [Count], key: String) -> JSONValue {
        .array(items.map {
            Self.object([(key, .string($0.name)), ("plays", .integer($0.plays)), ("share_percent", Self.number($0.sharePercent))])
        })
    }

    /// The compact JSON `get_taste_profile` returns.
    public func json() -> JSONValue {
        var members: [(String, JSONValue)] = [
            ("period", .string(periodUsed.toolValue)),
            ("period_requested", .string(period.toolValue)),
            ("plays_in_period", .integer(playsInPeriod)),
            ("total_plays", .integer(totalPlays)),
            ("plays_by_source", Self.object([("in_app", .integer(appPlays)), ("spotify", .integer(spotifyPlays)),
                                             ("youtube_music", .integer(youTubeMusicPlays))])),
            ("unique_artists", .integer(uniqueArtists)),
            ("weights_in_use", Self.object([("spotify", Self.number(ListeningHistoryWeights.spotify, places: 2)),
                                            ("in_app", Self.number(ListeningHistoryWeights.spotify, places: 2)),
                                            ("youtube_music", Self.number(ListeningHistoryWeights.youTubeMusic, places: 2))])),
            ("confidence", Self.object([("level", .string(confidence.rawValue)), ("plays", .integer(playsInPeriod)),
                                        ("note", .string(confidenceNote))])),
        ]
        if firstPlayMs > 0 { members.append(("history_starts", .string(LocalDate(epochDay: firstPlayMs / 86_400_000).description))) }
        members.append(("top_artists", .array(topArtists.map { artist in
            var entry: [(String, JSONValue)] = [("name", .string(artist.name)), ("plays", .integer(artist.plays)),
                                                ("share_percent", Self.number(artist.sharePercent))]
            if artist.sessions > 0 {
                entry.append(("completions", .integer(artist.completions)))
                entry.append(("early_skips", .integer(artist.earlySkips)))
                entry.append(("sessions_with_known_outcome", .integer(artist.sessions)))
            }
            return Self.object(entry)
        })))
        members.append(("top_tracks", .array(topTracks.map { track in
            var entry: [(String, JSONValue)] = [("title", .string(track.title)), ("artist", .string(track.artist)),
                                                ("plays", .integer(track.plays)), ("share_percent", Self.number(track.sharePercent))]
            if let id = track.songId { entry.append(("song_id", .string(id))) }
            return Self.object(entry)
        })))
        if !recentPlays.isEmpty {
            members.append(("recent_plays", .array(recentPlays.map {
                Self.object([("title", .string($0.title)), ("artist", .string($0.artist))])
            })))
        }
        if sessionsWithKnownOutcome > 0 {
            members.append(("completions_and_skips", Self.object([
                ("sessions_with_known_outcome", .integer(sessionsWithKnownOutcome)),
                ("completions", .integer(completions)), ("early_skips", .integer(earlySkips)),
                ("completion_rate_percent", Self.number(Double(completions) * 100.0 / Double(sessionsWithKnownOutcome))),
                ("early_skip_rate_percent", Self.number(Double(earlySkips) * 100.0 / Double(sessionsWithKnownOutcome))),
                ("note", .string("Imported plays with a known outcome in the period, plus the app's learned sessions (all time)."))])))
        }
        if !skippedArtists.isEmpty {
            members.append(("artists_often_skipped", .array(skippedArtists.map {
                Self.object([("name", .string($0.name)), ("early_skips", .integer($0.earlySkips)),
                             ("sessions", .integer($0.sessions)), ("skip_rate_percent", Self.number($0.skipRate * 100.0))])
            })))
        }
        if !genres.isEmpty {
            members.append(("genres", counts(genres, key: "name")))
            members.append(("genre_coverage_percent", Self.number(genreCoveragePercent)))
        }
        if !decades.isEmpty { members.append(("eras", counts(decades, key: "decade"))) }
        if let pattern {
            members.append(("listening_pattern", Self.object([
                ("based_on_plays", .integer(pattern.basisPlays)),
                ("time_of_day_percent", .array(pattern.timeOfDay.map {
                    Self.object([("part", .string($0.name)), ("share_percent", Self.number($0.sharePercent))])
                })),
                ("weekdays_percent", Self.number(pattern.weekdayPlaysPercent)),
                ("weekends_percent", Self.number(pattern.weekendPlaysPercent)),
                ("peak_hour", .integer(pattern.peakHour)), ("busiest_weekday", .string(pattern.busiestWeekday))])))
        }
        if !spotifyTopArtists.isEmpty || !spotifyTopTracks.isEmpty || followedArtistCount > 0 {
            var spotify: [(String, JSONValue)] = []
            for (range, names) in spotifyTopArtists { spotify.append(("top_artists_" + range, Self.strings(names))) }
            if !spotifyTopTracks.isEmpty {
                spotify.append(("top_tracks_medium_term", .array(spotifyTopTracks.map {
                    Self.object([("title", .string($0.title)), ("artist", .string($0.artist))])
                })))
            }
            if !spotifyGenres.isEmpty { spotify.append(("genres_of_top_artists", Self.strings(spotifyGenres))) }
            if followedArtistCount > 0 {
                spotify.append(("followed_artists", .integer(followedArtistCount)))
                spotify.append(("followed_artists_sample", Self.strings(followedArtistsSample)))
            }
            members.append(("spotify", Self.object(spotify)))
        }
        members.append(("taste_adjustments", .array(adjustments.map { line in
            var entry: [(String, JSONValue)] = [
                ("id", .string(line.id)), ("action", .string(line.action)), ("target_type", .string(line.targetType)),
                ("target", .string(line.target)),
            ]
            if line.strength > 0 { entry.append(("strength", .integer(line.strength))) }
            entry.append(("reason", .string(line.reason)))
            entry.append(("set_by", .string(line.setBy)))
            entry.append(("age_days", .integer(line.ageDays)))
            if let days = line.expiresInDays { entry.append(("expires_in_days", .integer(days))) }
            return Self.object(entry)
        })))
        members.append(("not_available", Self.strings(notAvailable)))
        return Self.object(members)
    }

    // MARK: Digest (the stable context block)

    /// The short, code-built lines of the context Taizo gets every conversation: top 15 artists, top genres, the last 10
    /// plays, skip-heavy artists, the active adjustments and the confidence.
    public func digestLines() -> [String] {
        var lines: [String] = []
        let periodLabel = periodUsed == .allTime ? "all time" : periodUsed.toolValue.replacingOccurrences(of: "_", with: " ")
        lines.append("Taste digest (\(periodLabel), \(playsInPeriod) plays; \(totalPlays) in all: \(appPlays) in app, "
            + "\(spotifyPlays) Spotify, \(youTubeMusicPlays) YouTube Music). Confidence: \(confidence.rawValue).")
        if !topArtists.isEmpty {
            lines.append("Top artists: " + topArtists.map { "\($0.name) (\($0.plays))" }.joined(separator: ", "))
        }
        if !genres.isEmpty {
            lines.append("Top genres: " + genres.prefix(8).map { "\($0.name) (\($0.plays))" }.joined(separator: ", "))
        } else if !spotifyGenres.isEmpty {
            lines.append("Genres of Spotify top artists: " + spotifyGenres.prefix(8).joined(separator: ", "))
        }
        if !recentPlays.isEmpty {
            lines.append("Last \(recentPlays.count) plays: " + recentPlays.map { "\($0.title) — \($0.artist)" }.joined(separator: "; "))
        }
        if !skippedArtists.isEmpty {
            lines.append("Often skipped: " + skippedArtists.prefix(8).map { "\($0.name) (\($0.earlySkips)/\($0.sessions))" }.joined(separator: ", "))
        }
        if !adjustments.isEmpty {
            lines.append("Taste changes in force:")
            lines += adjustments.prefix(25).map { line in
                "- \(line.action) \(line.targetType) \(line.target)" + (line.strength > 0 ? " x\(line.strength)" : "")
                    + " [\(line.id)] (\(line.setBy), \(line.ageDays) d ago" + (line.reason.isEmpty ? "" : ": \(line.reason)") + ")"
            }
        }
        if confidence == .empty || confidence == .low { lines.append(confidenceNote) }
        return lines
    }
}
