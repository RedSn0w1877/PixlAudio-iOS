import Foundation
import PixlLibrary
import PixlModel

// Pure Home / Recently Played / Stats helpers ported from the Android presentation layer. Nothing here touches
// SwiftUI or the stores, so AppTests cover it directly (AppTests/HomeLogicTests.swift).

/// What the greeting card shows: a short headline and a one-line subtitle about the moment (never a statistic).
nonisolated struct HomeGreeting: Sendable, Equatable {
    var headline: String
    var subtitle: String
}

/// What the summary at the top of Home may say about the listener (PixlLibrary `HomeSummary` owns the words).
typealias HomeGreetingFacts = HomeSummaryFacts

/// The two AI texts of the greeting card: the once-a-day headline and the on-demand insight.
nonisolated enum HomeGreetingKind: Sendable, Equatable {
    case headline, insight
}

/// One row of the recently played lists (Android `RecentlyPlayedSongUiModel`).
nonisolated struct RecentlyPlayedItem: Sendable, Equatable, Identifiable {
    var song: Song
    var lastPlayedTimestamp: Int64
    var id: String { song.id }
}

/// The clock Home and Stats read: wall time and time zone. UI tests pin both so screenshots are deterministic.
nonisolated struct HomeClock: Sendable {
    var fixedNowMs: Int64?
    var timeZone: TimeZone

    func nowMs() -> Int64 { fixedNowMs ?? Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    static let live = HomeClock(fixedNowMs: nil, timeZone: .current)
    /// Thursday 2026-09-10, 18:30 UTC (an evening, mid-week: the week chart has a few days of listening).
    static let uiTest = HomeClock(fixedNowMs: 1_789_065_000_000, timeZone: TimeZone(identifier: "UTC") ?? .current)
}

nonisolated enum HomeLogic {
    // MARK: Home summary (owner decision 2026-10-26: short, contextual, never a statistic; the words are PixlLibrary's)

    /// `dayPhase()`: morning 5–10, afternoon 11–16, evening 17–21, else night.
    static func dayPhase(hour: Int) -> String { HomeSummary.dayPhase(hour: hour) }

    /// What the card says before there is anything to say.
    static let defaultSubtitle = HomeSummary.invitation

    /// The greeting card's two lines for these facts.
    static func greeting(_ facts: HomeSummaryFacts) -> HomeGreeting {
        HomeGreeting(headline: HomeSummary.headline(facts), subtitle: HomeSummary.subtitle(facts))
    }

    /// The facts about the listener's day, from the library and the plays (off the main actor with the rest of Home's
    /// computation). "Unknown Genre" is skipped; imported listening names the favourite artist while the app's own
    /// history is still thin.
    static func summaryFacts(nowMs: Int64, timeZone: TimeZone, songs: [Song], events: [PlaybackEvent],
                             allTime: PlaybackStatsSummary?, importedTopArtist: String?) -> HomeSummaryFacts {
        let zone = ZoneClock(timeZone)
        let today = zone.localDate(at: nowMs).epochDay
        var facts = HomeSummaryFacts(hour: zone.localHour(at: nowMs), weekday: HomeSummary.weekday(epochDay: today),
                                     epochDay: today, hasLibrary: !songs.isEmpty)
        guard !songs.isEmpty else { return facts }
        facts.topArtist = allTime?.topArtists.first?.artist ?? importedTopArtist
        facts.topGenre = topGenre(allTime)
        // The most recent play that is still in the library.
        let byId = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let last = events.filter({ $0.timestamp <= nowMs && byId[$0.songId] != nil }).max(by: { $0.timestamp < $1.timestamp }),
           let song = byId[last.songId] {
            facts.lastPlayedTitle = song.title
            facts.lastPlayedArtist = song.displayArtist
            facts.lastPlayedMinutesAgo = Int(max(nowMs - last.timestamp, 0) / 60_000)
        }
        facts.streakDays = HomeSummary.streakDays(playDays: Set(events.map { zone.localDate(at: max($0.timestamp, 0)).epochDay }),
                                                  today: today)
        // The newest song, when it really is new.
        if let newest = songs.max(by: { $0.dateAdded < $1.dateAdded }),
           HomeSummary.isFresh(dateAdded: newest.dateAdded, nowMs: nowMs) {
            facts.freshSongTitle = newest.title
            facts.freshSongArtist = newest.displayArtist
        }
        return facts
    }

    static func topGenre(_ summary: PlaybackStatsSummary?) -> String? {
        summary?.topGenres.first { $0.genre != PlaybackStats.unknownGenreLabel }?.genre
    }

    // MARK: AI summary (the assistant half)

    /// The headline prompt: the context of the moment, no totals, and a rule against counting aloud.
    static func greetingPrompt(_ facts: HomeGreetingFacts) -> String { HomeSummary.headlinePrompt(facts) }

    /// The expanded insight's prompt: the same context, two short sentences.
    static func insightPrompt(_ facts: HomeGreetingFacts) -> String { HomeSummary.insightPrompt(facts) }

    /// An assistant's headline: one short line, cut on a word boundary, never statistic phrasing; nil when nothing
    /// usable is left (the local headline stays).
    static func cleanGreeting(_ text: String, limit: Int = HomeSummary.headlineHardLimit) -> String? {
        HomeSummary.clean(text, limit: limit)
    }

    /// An assistant's insight: a few short sentences, cut on a word boundary, never statistic phrasing.
    static func cleanInsight(_ text: String) -> String? {
        HomeSummary.clean(text, limit: HomeSummary.insightLimit, singleLine: false)
    }

    // MARK: Recently played (Android presentation/model/RecentlyPlayedSongUi.kt)

    /// `StatsTimeRange?.resolveBounds`: range start (nil = all time) and now.
    static func recentBounds(_ range: StatsTimeRange?, nowMs: Int64, timeZone: TimeZone) -> (start: Int64?, end: Int64) {
        let now = max(nowMs, 0)
        let zone = ZoneClock(timeZone)
        let today = zone.localDate(at: now)
        switch range {
        case .day: return (zone.startOfDay(today), now)
        case .week: return (zone.startOfDay(today.mondayOfWeek), now)
        case .month: return (zone.startOfDay(LocalDate(year: today.year, month: today.month, day: 1)), now)
        case .year: return (zone.startOfDay(LocalDate(year: today.year, month: 1, day: 1)), now)
        case .all, nil: return (nil, now)
        }
    }

    /// History newest first, ties by song id (Kotlin `compareByDescending { timestamp }.thenBy { songId }`).
    private static func sortedHistory(_ history: [PlaybackHistoryEntry]) -> [PlaybackHistoryEntry] {
        history.sorted { a, b in
            if a.timestamp != b.timestamp { return a.timestamp > b.timestamp }
            return a.songId.utf16.lexicographicallyPrecedes(b.songId.utf16)
        }
    }

    /// `collectRecentlyPlayedSongIds`: distinct song ids, most recent first, within `range`.
    static func collectRecentlyPlayedSongIds(history: [PlaybackHistoryEntry], range: StatsTimeRange? = nil,
                                             nowMs: Int64, timeZone: TimeZone, maxItems: Int = .max) -> [String] {
        guard maxItems > 0, !history.isEmpty else { return [] }
        let bounds = recentBounds(range, nowMs: nowMs, timeZone: timeZone)
        var seen = Set<String>()
        var ordered: [String] = []
        for entry in sortedHistory(history) {
            if ordered.count >= maxItems { break }
            let ts = max(entry.timestamp, 0)
            if ts > bounds.end { continue }
            if let start = bounds.start, ts < start { continue }
            if seen.insert(entry.songId).inserted { ordered.append(entry.songId) }
        }
        return ordered
    }

    /// `mapRecentlyPlayedSongs`: one item per song (its latest play) for songs still in the library.
    static func mapRecentlyPlayed(history: [PlaybackHistoryEntry], songsById: [String: Song],
                                  range: StatsTimeRange? = nil, nowMs: Int64, timeZone: TimeZone,
                                  maxItems: Int = .max) -> [RecentlyPlayedItem] {
        guard maxItems > 0, !history.isEmpty, !songsById.isEmpty else { return [] }
        let ids = Set(collectRecentlyPlayedSongIds(history: history, range: range, nowMs: nowMs, timeZone: timeZone,
                                                   maxItems: maxItems))
        guard !ids.isEmpty else { return [] }
        let bounds = recentBounds(range, nowMs: nowMs, timeZone: timeZone)
        var seen = Set<String>()
        var result: [RecentlyPlayedItem] = []
        for entry in sortedHistory(history) {
            if result.count >= maxItems { break }
            let ts = max(entry.timestamp, 0)
            if ts > bounds.end { continue }
            if let start = bounds.start, ts < start { continue }
            guard seen.insert(entry.songId).inserted, ids.contains(entry.songId),
                  let song = songsById[entry.songId] else { continue }
            result.append(RecentlyPlayedItem(song: song, lastPlayedTimestamp: ts))
        }
        return result
    }

    // MARK: Recently Played screen groups (Android RecentlyPlayedScreen `groupRecentlyPlayedSongs`)

    /// Consecutive plays sharing a bucket: the hour (Today range) or the day ("Today", "Yesterday", a date).
    nonisolated struct TimestampGroup: Sendable, Equatable, Identifiable {
        var key: String
        var label: String
        var isHourBucket: Bool
        var items: [RecentlyPlayedItem]
        var id: String { key }
    }

    static func timestampGroups(_ items: [RecentlyPlayedItem], range: StatsTimeRange, nowMs: Int64,
                                timeZone: TimeZone, use24Hour: Bool, locale: Locale = .current) -> [TimestampGroup] {
        guard !items.isEmpty else { return [] }
        let zone = ZoneClock(timeZone)
        func formatter(_ pattern: String) -> DateFormatter {
            let f = DateFormatter()
            f.locale = locale
            f.timeZone = timeZone
            f.dateFormat = pattern
            return f
        }
        let hourFormatter = formatter(use24Hour ? "HH:mm" : "h a")
        let yearFormatter = formatter("MMM d, yyyy")
        let dayFormatter = formatter("EEE, MMM d")
        let today = zone.localDate(at: max(nowMs, 0))
        let sorted = items.sorted { $0.lastPlayedTimestamp > $1.lastPlayedTimestamp }

        func bucket(_ timestamp: Int64) -> (key: String, label: String, isHour: Bool) {
            let ts = max(timestamp, 0)
            if range == .day {
                let local = zone.localMs(at: ts)
                let hourStart = ts - (local % 3_600_000)
                return ("\(hourStart)", hourFormatter.string(from: Date(timeIntervalSince1970: Double(hourStart) / 1000)), true)
            }
            let date = zone.localDate(at: ts)
            let label: String
            if date == today {
                label = "Today"
            } else if date == today.plusDays(-1) {
                label = "Yesterday"
            } else {
                let instant = Date(timeIntervalSince1970: Double(ts) / 1000)
                label = (range == .year || range == .all ? yearFormatter : dayFormatter).string(from: instant)
            }
            return (date.description, label, false)
        }

        var groups: [TimestampGroup] = []
        for item in sorted {
            let b = bucket(item.lastPlayedTimestamp)
            if let last = groups.last, last.key == b.key {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append(TimestampGroup(key: b.key, label: b.label, isHourBucket: b.isHour, items: [item]))
            }
        }
        return groups
    }

    // MARK: Home recently played pills (Android RecentlyPlayedSection)

    static let pillHeight: CGFloat = 58
    static let pillSpacing: CGFloat = 8
    static let pillsLimit = 10
    static let pillsPerColumn = 3
    static let recentlyPlayedMinSongs = 4
    static let pillArtSize: CGFloat = 38
    static let pillWidthSteps: [CGFloat] = [148, 166, 184, 202, 220]

    /// `resolveRecentlyPlayedPillWidth`: wider pills for longer text.
    static func pillWidth(title: String, artist: String) -> CGFloat {
        let titleLength = Float(title.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count)
        let artistLength = Float(artist.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count)
        let weighted = titleLength + artistLength * 0.55
        let step: Int
        switch weighted {
        case ..<18: step = 0
        case ..<28: step = 1
        case ..<40: step = 2
        case ..<54: step = 3
        default: step = 4
        }
        return pillWidthSteps[min(max(step, 0), pillWidthSteps.count - 1)]
    }

    /// `resolveRecentlyPlayedRowTargets`: how many pills each of the three rows takes.
    static func pillRowTargets(_ total: Int) -> [Int] {
        let base = total / pillsPerColumn
        let remainder = total % pillsPerColumn
        return [base + (remainder > 0 ? 1 : 0), base + (remainder > 1 ? 1 : 0), base]
    }

    /// `buildRecentlyPlayedPillRows`: column-major fill of three staggered rows, with each row's content width.
    static func pillRows<Item>(_ items: [Item], width: (Item) -> CGFloat, startPadding: CGFloat,
                               endPadding: CGFloat) -> [(cells: [(item: Item, width: CGFloat)], contentWidth: CGFloat)] {
        var rows: [[(item: Item, width: CGFloat)]] = Array(repeating: [], count: pillsPerColumn)
        var widths: [CGFloat] = Array(repeating: 0, count: pillsPerColumn)
        let targets = pillRowTargets(items.count)
        var index = 0
        for column in 0..<(targets.first ?? 0) {
            for row in 0..<pillsPerColumn {
                if index >= items.count { break }
                if column >= targets[row] { continue }
                let item = items[index]
                index += 1
                let cellWidth = width(item)
                let spacingBefore: CGFloat = rows[row].isEmpty ? 0 : pillSpacing
                rows[row].append((item, cellWidth))
                widths[row] += spacingBefore + cellWidth
            }
        }
        return rows.enumerated().map { ($0.element, widths[$0.offset] + startPadding + endPadding) }
    }

    // MARK: Durations (Android utils/Formats.kt)

    /// `formatListeningDurationLong`: "1 h 05 m", "3 h", "36 m", "12 s".
    static func listeningDurationLong(_ ms: Int64) -> String {
        let totalMinutes = ms / 60_000
        let hours = totalMinutes / 60, minutes = totalMinutes % 60, seconds = (ms / 1000) % 60
        if hours > 0 && minutes > 0 { return "\(hours) h \(twoDigits(minutes)) m" }
        if hours > 0 { return "\(hours) h" }
        if minutes > 0 { return "\(minutes) m" }
        return "\(seconds) s"
    }

    /// `formatListeningDurationCompact`: "1h 05m", "3h", "36m", "12s".
    static func listeningDurationCompact(_ ms: Int64) -> String {
        let totalMinutes = ms / 60_000
        let hours = totalMinutes / 60, minutes = totalMinutes % 60, seconds = (ms / 1000) % 60
        if hours > 0 && minutes > 0 { return "\(hours)h \(twoDigits(minutes))m" }
        if hours > 0 { return "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    /// `formatDuration`: "mm:ss" or "hh:mm:ss"; "00:00" for zero.
    static func clockDuration(_ ms: Int64) -> String {
        guard ms > 0 else { return "00:00" }
        let total = ms / 1000
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0 ? "\(twoDigits(hours)):\(twoDigits(minutes)):\(twoDigits(seconds))"
            : "\(twoDigits(minutes)):\(twoDigits(seconds))"
    }

    /// `daily_mix_songs_dot_duration` (plural): "1 Song • 03:20" / "24 Songs • 1:20:00".
    static func songsDotDuration(count: Int, durationMs: Int64) -> String {
        "\(count) \(count == 1 ? "Song" : "Songs") • \(clockDuration(durationMs))"
    }

    private static func twoDigits(_ value: Int64) -> String { value < 10 ? "0\(value)" : "\(value)" }

    // MARK: Timeline labels (Android StatsScreen / StatsOverviewCard)

    /// Whether the user's locale uses a 24-hour clock (Android `DateFormat.is24HourFormat`).
    static var uses24HourClock: Bool {
        !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")
    }

    /// `convertHourLabel`: "7am" / "7:00 PM" / "19:00" / "7" → "07:00" (24 h) or "7 AM" (12 h); else unchanged.
    static func convertHourLabel(_ raw: String, use24Hour: Bool) -> String {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func format(_ hour24: Int) -> String {
            if use24Hour { return hour24 < 10 ? "0\(hour24):00" : "\(hour24):00" }
            let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
            return "\(hour12) \(hour24 < 12 ? "AM" : "PM")"
        }
        let lower = label.lowercased()
        if lower.hasSuffix("am") || lower.hasSuffix("pm") {
            let isPm = lower.hasSuffix("pm")
            let body = lower.dropLast(2).trimmingCharacters(in: .whitespaces)
            let parts = body.split(separator: ":", omittingEmptySubsequences: false)
            let minutesOK = parts.count == 1 || (parts.count == 2 && parts[1].count == 2 && Int(parts[1]) != nil)
            if let first = parts.first, (1...2).contains(first.count), let hour12 = Int(first), minutesOK {
                let hour24 = isPm && hour12 != 12 ? hour12 + 12 : (!isPm && hour12 == 12 ? 0 : hour12)
                return format(hour24)
            }
            return label
        }
        let parts = label.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2, let hour = Int(parts[0]),
           Int(parts[1]) != nil {
            return format(hour)
        }
        if let bare = Int(label), (0...23).contains(bare) { return format(bare) }
        return label
    }

    /// `formatTimelineLabelForRange`.
    static func timelineLabel(_ raw: String, range: StatsTimeRange, blank: String = "—", use24Hour: Bool) -> String {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty { return blank }
        switch range {
        case .day: return convertHourLabel(label, use24Hour: use24Hour)
        case .year: return String(label.prefix(3))
        default: return label
        }
    }

    /// `ArtistAvatar` initials: first letters of the first two words, upper-cased; "?" when none.
    static func initials(_ name: String) -> String {
        let letters = name.split(separator: " ").filter { !$0.allSatisfy(\.isWhitespace) }.prefix(2)
            .compactMap { $0.first.map { String($0).uppercased() } }
        return letters.isEmpty ? "?" : letters.joined()
    }
}
