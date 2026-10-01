// Port of the pure aggregation in `data/stats/PlaybackStatsRepository.kt`: playback events are clipped to a time
// range, merged into per-song segments and overall listening spans, then summarised (totals, top songs, artists,
// genres and albums, timeline buckets, streaks, sessions, the 5-minute day distribution and the peak day).
// Day boundaries follow the given time zone with java.time's rules (`ZoneClock`).

import Foundation
import PixlFoundation
import PixlModel

/// One listening event as stored in `playback_history.json`.
public struct PlaybackEvent: Sendable, Hashable {
    public var songId: String
    /// End of listening (ms since 1970).
    public var timestamp: Int64
    public var durationMs: Int64
    public var startTimestamp: Int64?
    public var endTimestamp: Int64?

    public init(songId: String, timestamp: Int64, durationMs: Int64, startTimestamp: Int64? = nil,
                endTimestamp: Int64? = nil) {
        self.songId = songId
        self.timestamp = timestamp
        self.durationMs = durationMs
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
    }

    /// `startMillis()`.
    public var startMillis: Int64 {
        let end = max(endTimestamp ?? timestamp, 0)
        let inferred = max(startTimestamp ?? (end &- durationMs), 0)
        return min(inferred, end)
    }

    /// `endMillis()`.
    public var endMillis: Int64 { max(max(endTimestamp ?? timestamp, 0), startMillis) }
}

/// An entry of the recently played list (`PlaybackHistoryEntry`).
public struct PlaybackHistoryEntry: Sendable, Hashable {
    public var songId: String
    public var timestamp: Int64
}

/// The Stats screen ranges (`StatsTimeRange`); raw value = Kotlin constant name.
public enum StatsTimeRange: String, Sendable, Hashable, CaseIterable {
    case day = "DAY"
    case week = "WEEK"
    case month = "MONTH"
    case year = "YEAR"
    case all = "ALL"

    public var displayName: String {
        switch self {
        case .day: "Today"
        case .week: "Week to Date"
        case .month: "Month to Date"
        case .year: "Year to Date"
        case .all: "All Time"
        }
    }
}

/// Localised labels for timeline buckets. Defaults are English (Android uses the device locale for weekday and
/// month names and the `stats_week_label` string for month buckets); day buckets are always "12am", "4am" …
public struct StatsLabels: Sendable {
    /// Short weekday name, 1 = Monday.
    public var shortWeekday: @Sendable (Int) -> String
    /// Full weekday name, 1 = Monday.
    public var fullWeekday: @Sendable (Int) -> String
    /// Short month name, 1 = January.
    public var shortMonth: @Sendable (Int) -> String
    /// Month-bucket label for week 1…4.
    public var weekOfMonth: @Sendable (Int) -> String

    public init(shortWeekday: @escaping @Sendable (Int) -> String, fullWeekday: @escaping @Sendable (Int) -> String,
                shortMonth: @escaping @Sendable (Int) -> String, weekOfMonth: @escaping @Sendable (Int) -> String) {
        self.shortWeekday = shortWeekday
        self.fullWeekday = fullWeekday
        self.shortMonth = shortMonth
        self.weekOfMonth = weekOfMonth
    }

    static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    public static let english = StatsLabels(
        shortWeekday: { String(weekdays[($0 - 1) % 7].prefix(3)) },
        fullWeekday: { weekdays[($0 - 1) % 7] },
        shortMonth: { months[($0 - 1) % 12] },
        weekOfMonth: { "Week \($0)" })
}

public struct SongPlaybackSummary: Sendable, Hashable {
    public var songId: String
    public var title: String
    public var artist: String
    public var albumArtUri: String?
    public var totalDurationMs: Int64
    public var playCount: Int
}

public struct ArtistPlaybackSummary: Sendable, Hashable {
    public var artist: String
    public var totalDurationMs: Int64
    public var playCount: Int
    public var uniqueSongs: Int
}

public struct GenrePlaybackSummary: Sendable, Hashable {
    public var genre: String
    public var totalDurationMs: Int64
    public var playCount: Int
    public var uniqueArtists: Int
}

public struct AlbumPlaybackSummary: Sendable, Hashable {
    public var album: String
    public var albumArtUri: String?
    public var totalDurationMs: Int64
    public var playCount: Int
    public var uniqueSongs: Int
}

public struct TimelineEntry: Sendable, Hashable {
    public var label: String
    public var totalDurationMs: Int64
    public var playCount: Int
}

public struct DailyListeningBucket: Sendable, Hashable {
    public var startMinute: Int
    public var endMinuteExclusive: Int
    public var totalDurationMs: Int64
}

public struct DailyListeningDay: Sendable, Hashable {
    public var date: LocalDate
    public var buckets: [DailyListeningBucket]
    public var totalDurationMs: Int64
}

public struct DayListeningDistribution: Sendable, Hashable {
    public var bucketSizeMinutes: Int
    public var buckets: [DailyListeningBucket]
    public var maxBucketDurationMs: Int64
    public var days: [DailyListeningDay]
}

public struct PlaybackStatsSummary: Sendable, Hashable {
    public var range: StatsTimeRange
    public var startTimestamp: Int64?
    public var endTimestamp: Int64
    public var totalDurationMs: Int64
    public var totalPlayCount: Int
    public var uniqueSongs: Int
    public var averageDailyDurationMs: Int64
    public var songs: [SongPlaybackSummary]
    public var topSongs: [SongPlaybackSummary]
    public var topGenres: [GenrePlaybackSummary]
    public var timeline: [TimelineEntry]
    public var topArtists: [ArtistPlaybackSummary]
    public var topAlbums: [AlbumPlaybackSummary]
    public var activeDays: Int
    public var longestStreakDays: Int
    public var totalSessions: Int
    public var averageSessionDurationMs: Int64
    public var longestSessionDurationMs: Int64
    public var averageSessionsPerDay: Double
    public var dayListeningDistribution: DayListeningDistribution?
    public var peakTimeline: TimelineEntry?
    public var peakDayLabel: String?
    public var peakDayDurationMs: Int64
}

public enum PlaybackStats {
    public static let unknownGenreLabel = "Unknown Genre"
    static let unknownArtist = "Unknown Artist"
    static let sessionGapThresholdMs: Int64 = 30 * 60_000
    /// Roughly two years of history are kept.
    public static let maxHistoryAgeMs: Int64 = 730 * 86_400_000
    static let segmentJoinToleranceMs: Int64 = 0
    static let maxSongStatsCount = 100
    public static let defaultPlaybackHistoryLimit = 500
    public static let maxPlaybackHistoryLimit = 5_000

    struct Segment {
        let songId: String
        let start: Int64
        let end: Int64
        var duration: Int64 { max(end - start, 0) }
    }

    struct Span {
        let start: Int64
        let end: Int64
        var duration: Int64 { max(end - start, 0) }
    }

    // MARK: Persistence transforms (the repository's read-modify-write steps)

    /// `sanitizeEvent`: non-negative, start ≤ end, explicit start/end, duration = end − start (a shorter stored
    /// duration wins when no start was stored).
    public static func sanitize(_ event: PlaybackEvent) -> PlaybackEvent {
        let safeDuration = max(event.durationMs, 0)
        let safeEnd = max(event.endTimestamp ?? event.timestamp, 0)
        let safeStart: Int64
        if let start = event.startTimestamp { safeStart = start.coerced(in: 0, safeEnd) }
        else if safeDuration > 0 { safeStart = max(safeEnd &- safeDuration, 0) }
        else { safeStart = safeEnd }
        let normalizedDuration = max(safeEnd - safeStart, 0)
        let finalDuration = (event.startTimestamp == nil && safeDuration >= 1 && safeDuration < normalizedDuration)
            ? safeDuration : normalizedDuration
        let finalStart = max(safeEnd - finalDuration, 0)
        return PlaybackEvent(songId: event.songId, timestamp: safeEnd, durationMs: finalDuration,
                             startTimestamp: finalStart, endTimestamp: safeEnd)
    }

    /// `recordPlayback`: the history after recording one playback (events older than two years before it are
    /// pruned). Nil for a blank song id (nothing is written).
    public static func recordingPlayback(songId: String, durationMs: Int64, timestamp: Int64,
                                         into events: [PlaybackEvent]) -> [PlaybackEvent]? {
        if songId.isKotlinBlank { return nil }
        let ts = max(timestamp, 0)
        let duration = max(durationMs, 0)
        let event = PlaybackEvent(songId: songId, timestamp: ts, durationMs: duration,
                                  startTimestamp: max(ts - duration, 0), endTimestamp: ts)
        var updated = events
        let cutoff = event.endMillis - maxHistoryAgeMs
        if cutoff > 0 { updated.removeAll { $0.endMillis < cutoff } }
        updated.append(event)
        return updated
    }

    /// `importEventsFromBackup`: sanitised, de-duplicated by song/start/end/duration, sorted by timestamp.
    public static func importingEvents(_ events: [PlaybackEvent], into existing: [PlaybackEvent],
                                       clearExisting: Bool = true) -> [PlaybackEvent] {
        ((clearExisting ? [] : existing) + events).map(sanitize)
            .kotlinDistinct { "\($0.songId):\($0.startMillis):\($0.endMillis):\($0.durationMs)" }
            .kotlinSorted { cmp($0.timestamp, $1.timestamp) }
    }

    /// `loadPlaybackHistory`: the most recent plays, newest first.
    public static func playbackHistory(_ events: [PlaybackEvent], limit: Int = defaultPlaybackHistoryLimit) -> [PlaybackHistoryEntry] {
        if limit <= 0 { return [] }
        return events.kotlinSorted { cmp($1.timestamp, $0.timestamp) }.prefix(min(limit, maxPlaybackHistoryLimit))
            .map { PlaybackHistoryEntry(songId: $0.songId, timestamp: max($0.timestamp, 0)) }
    }

    // MARK: Summary

    /// `buildSummaryFromEvents`.
    public static func buildSummary(range: StatsTimeRange, songs: [Song], nowMillis: Int64, events allEvents: [PlaybackEvent],
                                    timeZone: TimeZone = .current, labels: StatsLabels = .english) -> PlaybackStatsSummary {
        let zone = ZoneClock(timeZone)
        let (startBound, endBound) = resolveBounds(range, allEvents, nowMillis, zone)
        let lowerBound = startBound ?? Int64.min
        let filtered = allEvents.compactMap { event -> PlaybackEvent? in
            let start = event.startMillis, end = event.endMillis
            if end < lowerBound || start > endBound { return nil }
            let clippedStart = max(start, lowerBound), clippedEnd = min(end, endBound)
            let clippedDuration = max(clippedEnd - clippedStart, 0)
            if clippedDuration <= 0 { return nil }
            return PlaybackEvent(songId: event.songId, timestamp: clippedEnd, durationMs: clippedDuration,
                                 startTimestamp: clippedStart, endTimestamp: clippedEnd)
        }
        var songMap: [KotlinKey: Song] = [:]
        for song in songs { songMap[KotlinKey(song.id)] = song }

        var eventsBySong = OrderedStringMap<[PlaybackEvent]>()
        for event in filtered { eventsBySong.append(event, to: event.songId) }
        let segmentsBySong = eventsBySong.entries.map { (key: $0.key, value: mergeSongEvents($0.value)) }
        let overallSpans = mergeSpans(segmentsBySong.flatMap { $0.value.map { Span(start: $0.start, end: $0.end) } })

        let effectiveStart = startBound ?? overallSpans.map(\.start).min() ?? filtered.map(\.startMillis).min()
            ?? allEvents.map(\.startMillis).min()
        let effectiveEnd = overallSpans.map(\.end).max() ?? endBound
        let totalDuration = overallSpans.reduce(Int64(0)) { $0 &+ $1.duration }
        let totalPlays = segmentsBySong.reduce(0) { $0 + $1.value.count }
        let uniqueSongs = segmentsBySong.count

        let allSongs = segmentsBySong.compactMap { entry -> SongPlaybackSummary? in
            guard let song = songMap[KotlinKey(entry.key)] else { return nil }
            var title = song.title
            if title.isKotlinBlank {
                title = KotlinText.substringAfterLast(song.path, "/")
                if title.isKotlinBlank { return nil }
            }
            let artist = song.displayArtist.isKotlinBlank ? unknownArtist : song.displayArtist
            return SongPlaybackSummary(songId: entry.key, title: title, artist: artist, albumArtUri: song.albumArtUriString,
                                       totalDurationMs: entry.value.reduce(0) { $0 &+ $1.duration },
                                       playCount: entry.value.count)
        }.kotlinSorted { chain(cmp($1.totalDurationMs, $0.totalDurationMs), cmp($1.playCount, $0.playCount)) }
        let songSummaries = Array(allSongs.prefix(maxSongStatsCount))

        var genreGroups = OrderedStringMap<[(key: String, value: [Segment])]>()
        for entry in segmentsBySong {
            let genre = songMap[KotlinKey(entry.key)]?.genre
            let label = (genre == nil || genre!.isKotlinBlank) ? unknownGenreLabel : genre!
            genreGroups.append(entry, to: label)
        }
        let topGenres = genreGroups.entries.map { genre, grouped -> GenrePlaybackSummary in
            let flattened = grouped.flatMap(\.value)
            let artists = grouped.flatMap { statsArtistNames(songMap[KotlinKey($0.key)]) }
                .kotlinDistinct { normalizedArtistKey($0) }
            return GenrePlaybackSummary(genre: genre, totalDurationMs: flattened.reduce(0) { $0 &+ $1.duration },
                                        playCount: flattened.count, uniqueArtists: artists.count)
        }.kotlinSorted { chain(cmp($1.totalDurationMs, $0.totalDurationMs), cmp($1.playCount, $0.playCount)) }.prefix(5)

        var daySpan: Int64 = 1
        let averageDaily: Int64
        if let effectiveStart {
            let startDate = zone.localDate(at: effectiveStart), endDate = zone.localDate(at: effectiveEnd)
            daySpan = max(1, endDate.epochDay - startDate.epochDay + 1)
            averageDaily = totalDuration / daySpan
        } else {
            averageDaily = totalDuration
        }

        let daySlices = overallSpans.flatMap { sliceSpanByDay($0, zone) }
        var dayOrder: [LocalDate] = []
        var seenDays = Set<LocalDate>()
        for slice in daySlices where seenDays.insert(slice.date).inserted { dayOrder.append(slice.date) }
        let activeDays = dayOrder.count
        var longestStreak = 0, currentStreak = 0
        var lastDay: LocalDate?
        for day in dayOrder.sorted() {
            if lastDay == nil || day == lastDay!.plusDays(1) { currentStreak += 1 } else { currentStreak = 1 }
            longestStreak = max(longestStreak, currentStreak)
            lastDay = day
        }

        let sessions = listeningSessions(overallSpans)
        let totalSessions = sessions.count
        let totalSessionDuration = sessions.reduce(Int64(0)) { $0 &+ $1.totalDuration }
        let averageSession = totalSessions > 0 ? totalSessionDuration / Int64(totalSessions) : 0
        let longestSession = sessions.map(\.totalDuration).max() ?? 0
        let sessionsPerDay = daySpan > 0 ? Double(totalSessions) / Double(daySpan) : 0.0

        let buckets = timelineBuckets(range, zone, now: endBound, spans: overallSpans,
                                      fallbackStart: effectiveStart ?? endBound, labels: labels)
        let timeline = accumulateTimeline(buckets, overallSpans)

        var artistGroups = OrderedStringMap<[(songId: String, segments: [Segment])]>()
        for entry in segmentsBySong {
            for artist in statsArtistNames(songMap[KotlinKey(entry.key)]) {
                artistGroups.append((entry.key, entry.value), to: artist)
            }
        }
        let topArtists = artistGroups.entries.map { artist, songsOfArtist -> ArtistPlaybackSummary in
            let flattened = songsOfArtist.flatMap(\.segments)
            return ArtistPlaybackSummary(artist: artist, totalDurationMs: flattened.reduce(0) { $0 &+ $1.duration },
                                         playCount: flattened.count,
                                         uniqueSongs: Set(songsOfArtist.map { KotlinKey($0.songId) }).count)
        }.kotlinSorted { chain(cmp($1.totalDurationMs, $0.totalDurationMs), cmp($1.playCount, $0.playCount)) }.prefix(5)

        var albumGroups = OrderedStringMap<[(key: String, value: [Segment])]>()
        for entry in segmentsBySong {
            let album = songMap[KotlinKey(entry.key)].flatMap { $0.album.isKotlinBlank ? nil : $0.album } ?? "Unknown Album"
            albumGroups.append(entry, to: album)
        }
        let topAlbums = albumGroups.entries.map { album, grouped -> AlbumPlaybackSummary in
            let flattened = grouped.flatMap(\.value)
            let firstSong = grouped.lazy.compactMap { songMap[KotlinKey($0.key)] }.first
            return AlbumPlaybackSummary(album: album, albumArtUri: firstSong?.albumArtUriString,
                                        totalDurationMs: flattened.reduce(0) { $0 &+ $1.duration },
                                        playCount: flattened.count, uniqueSongs: grouped.count)
        }.kotlinSorted { chain(cmp($1.totalDurationMs, $0.totalDurationMs), cmp($1.playCount, $0.playCount)) }.prefix(5)

        var peakTimeline: TimelineEntry?
        for entry in timeline where entry.totalDurationMs > 0 {
            if peakTimeline == nil || peakTimeline!.totalDurationMs < entry.totalDurationMs { peakTimeline = entry }
        }

        var weekdayOrder: [Int] = []
        var weekdayTotals: [Int: Int64] = [:]
        for slice in daySlices {
            let dow = slice.date.dayOfWeek
            if weekdayTotals[dow] == nil { weekdayOrder.append(dow) }
            weekdayTotals[dow, default: 0] &+= slice.duration
        }
        var peakDay: (dow: Int, total: Int64)?
        for dow in weekdayOrder {
            let total = weekdayTotals[dow]!
            if peakDay == nil || peakDay!.total < total { peakDay = (dow, total) }
        }
        let distribution = (range == .day || range == .week)
            ? dayDistribution(spans: overallSpans, zone: zone, range: range, startBound: startBound, endBound: endBound)
            : nil

        return PlaybackStatsSummary(
            range: range, startTimestamp: startBound, endTimestamp: endBound, totalDurationMs: totalDuration,
            totalPlayCount: totalPlays, uniqueSongs: uniqueSongs, averageDailyDurationMs: averageDaily,
            songs: songSummaries, topSongs: Array(songSummaries.prefix(5)), topGenres: Array(topGenres),
            timeline: timeline, topArtists: Array(topArtists), topAlbums: Array(topAlbums), activeDays: activeDays,
            longestStreakDays: longestStreak, totalSessions: totalSessions, averageSessionDurationMs: averageSession,
            longestSessionDurationMs: longestSession, averageSessionsPerDay: sessionsPerDay,
            dayListeningDistribution: distribution, peakTimeline: peakTimeline,
            peakDayLabel: peakDay.map { labels.fullWeekday($0.dow) }, peakDayDurationMs: peakDay?.total ?? 0)
    }

    static func resolveBounds(_ range: StatsTimeRange, _ events: [PlaybackEvent], _ now: Int64,
                              _ zone: ZoneClock) -> (Int64?, Int64) {
        let today = zone.localDate(at: now)
        switch range {
        case .day: return (zone.startOfDay(today), now)
        case .week: return (zone.startOfDay(today.mondayOfWeek), now)
        case .month: return (zone.startOfDay(LocalDate(year: today.year, month: today.month, day: 1)), now)
        case .year: return (zone.startOfDay(LocalDate(year: today.year, month: 1, day: 1)), now)
        case .all: return (events.map(\.startMillis).min(), now)
        }
    }

    static func mergeSongEvents(_ events: [PlaybackEvent]) -> [Segment] {
        guard !events.isEmpty else { return [] }
        let sorted = events.kotlinSorted { cmp($0.startMillis, $1.startMillis) }
        let songId = sorted[0].songId
        var segments: [Segment] = []
        var currentStart = sorted[0].startMillis, currentEnd = sorted[0].endMillis
        for event in sorted.dropFirst() {
            let start = event.startMillis, end = event.endMillis
            if start <= currentEnd + segmentJoinToleranceMs {
                currentEnd = max(currentEnd, end)
            } else {
                segments.append(Segment(songId: songId, start: currentStart, end: currentEnd))
                currentStart = start
                currentEnd = end
            }
        }
        segments.append(Segment(songId: songId, start: currentStart, end: currentEnd))
        return segments
    }

    static func mergeSpans(_ spans: [Span]) -> [Span] {
        guard !spans.isEmpty else { return [] }
        let sorted = spans.kotlinSorted { cmp($0.start, $1.start) }
        var merged: [Span] = []
        var currentStart = sorted[0].start, currentEnd = sorted[0].end
        for span in sorted.dropFirst() {
            if span.start <= currentEnd + segmentJoinToleranceMs {
                currentEnd = max(currentEnd, span.end)
            } else {
                merged.append(Span(start: currentStart, end: currentEnd))
                currentStart = span.start
                currentEnd = span.end
            }
        }
        merged.append(Span(start: currentStart, end: currentEnd))
        return merged
    }

    /// `statsArtistNames`: the separated artists (primary first, distinct case-insensitively), else the display
    /// artist, else "Unknown Artist".
    static func statsArtistNames(_ song: Song?) -> [String] {
        guard let song else { return [unknownArtist] }
        let separated = song.artists.kotlinSorted { cmp($1.isPrimary ? 1 : 0, $0.isPrimary ? 1 : 0) }
            .map { $0.name.kotlinTrimmed() }
            .filter { !$0.isKotlinBlank }
            .kotlinDistinct { normalizedArtistKey($0) }
        if !separated.isEmpty { return separated }
        let fallback = song.displayArtist.kotlinTrimmed()
        return [fallback.isKotlinBlank ? unknownArtist : fallback]
    }

    static func normalizedArtistKey(_ s: String) -> String { KotlinText.lowercase(s.kotlinTrimmed()) }

    struct DaySlice {
        let date: LocalDate
        let duration: Int64
    }

    static func sliceSpanByDay(_ span: Span, _ zone: ZoneClock) -> [DaySlice] {
        if span.duration <= 0 { return [] }
        var slices: [DaySlice] = []
        var cursor = span.start
        while cursor < span.end {
            let date = zone.localDate(at: cursor)
            let nextDayStart = zone.startOfDay(date.plusDays(1))
            let sliceEnd = min(span.end, nextDayStart)
            let duration = max(sliceEnd - cursor, 0)
            if duration > 0 { slices.append(DaySlice(date: date, duration: duration)) }
            // Android loops forever if a zone ever moves the next midnight behind the cursor; stop instead.
            if sliceEnd <= cursor { break }
            cursor = sliceEnd
        }
        return slices
    }

    static func dayDistribution(spans: [Span], zone: ZoneClock, range: StatsTimeRange, startBound: Int64?,
                                endBound: Int64, bucketSizeMinutes: Int = 5) -> DayListeningDistribution? {
        if spans.isEmpty { return nil }
        let bucketDuration = Int64(bucketSizeMinutes) * 60_000
        let bucketCount = max(1440 / bucketSizeMinutes, 1)
        var totals = [Int64](repeating: 0, count: bucketCount)
        var totalsByDay: [LocalDate: [Int64]] = [:]
        for span in spans {
            var cursor = span.start
            while cursor < span.end {
                let day = zone.localDate(at: cursor)
                let dayStart = zone.startOfDay(day)
                var index = Int(KotlinMath.toInt((cursor - dayStart) / bucketDuration))
                if index >= bucketCount { index = bucketCount - 1 } else if index < 0 { index = 0 }
                let bucketStart = dayStart + Int64(index) * bucketDuration
                let bucketEnd = min(span.end, bucketStart + bucketDuration)
                let contribution = max(bucketEnd - cursor, 0)
                if contribution > 0 {
                    totals[index] += contribution
                    totalsByDay[day, default: [Int64](repeating: 0, count: bucketCount)][index] += contribution
                }
                cursor = bucketEnd > cursor ? bucketEnd : span.end
            }
        }
        func buckets(_ values: [Int64]) -> [DailyListeningBucket] {
            values.indices.compactMap { i in
                values[i] > 0 ? DailyListeningBucket(startMinute: i * bucketSizeMinutes,
                                                     endMinuteExclusive: (i + 1) * bucketSizeMinutes,
                                                     totalDurationMs: values[i]) : nil
            }
        }
        let overall = buckets(totals)
        if overall.isEmpty { return nil }
        let maxBucket = max(overall.map(\.totalDurationMs).max() ?? 0, 0)
        let anchor = startBound ?? spans.map(\.start).min() ?? endBound
        let daySequence: [LocalDate]
        switch range {
        case .day: daySequence = [zone.localDate(at: anchor)]
        case .week:
            let start = zone.localDate(at: anchor)
            daySequence = (0..<7).map { start.plusDays(Int64($0)) }
        default: daySequence = totalsByDay.keys.sorted()
        }
        let days = daySequence.map { date -> DailyListeningDay in
            let values = totalsByDay[date]
            return DailyListeningDay(date: date, buckets: values.map(buckets) ?? [],
                                     totalDurationMs: values?.reduce(0, &+) ?? 0)
        }
        return DayListeningDistribution(bucketSizeMinutes: bucketSizeMinutes, buckets: overall,
                                        maxBucketDurationMs: maxBucket, days: days)
    }

    struct Session {
        var start: Int64
        var end: Int64
        var totalDuration: Int64
        var playCount: Int
    }

    static func listeningSessions(_ spans: [Span]) -> [Session] {
        guard !spans.isEmpty else { return [] }
        let sorted = spans.kotlinSorted { cmp($0.start, $1.start) }
        var sessions: [Session] = []
        var current = Session(start: sorted[0].start, end: sorted[0].end, totalDuration: sorted[0].duration, playCount: 1)
        for span in sorted.dropFirst() {
            let gap = span.start - current.end
            if gap <= sessionGapThresholdMs {
                current.end = max(current.end, span.end)
                current.totalDuration += span.duration
                current.playCount += 1
            } else {
                sessions.append(current)
                current = Session(start: span.start, end: span.end, totalDuration: span.duration, playCount: 1)
            }
        }
        sessions.append(current)
        return sessions
    }

    struct TimelineBucket {
        let label: String
        let start: Int64
        let end: Int64
        let inclusiveEnd: Bool
    }

    static func accumulateTimeline(_ buckets: [TimelineBucket], _ spans: [Span]) -> [TimelineEntry] {
        if buckets.isEmpty { return [] }
        var durations = [Int64](repeating: 0, count: buckets.count)
        var counts = [Double](repeating: 0, count: buckets.count)
        for span in spans where span.duration > 0 {
            for (index, bucket) in buckets.enumerated() {
                let endExclusive = bucket.inclusiveEnd ? bucket.end + 1 : bucket.end
                let overlap = max(min(span.end, endExclusive) - max(span.start, bucket.start), 0)
                if overlap > 0 {
                    durations[index] += overlap
                    counts[index] += Double(overlap) / Double(span.duration)
                }
            }
        }
        return buckets.indices.map {
            TimelineEntry(label: buckets[$0].label, totalDurationMs: durations[$0],
                          playCount: Int(KotlinMath.roundToLong(counts[$0])))
        }
    }

    static func timelineBuckets(_ range: StatsTimeRange, _ zone: ZoneClock, now: Int64, spans: [Span],
                                fallbackStart: Int64, labels: StatsLabels) -> [TimelineBucket] {
        let today = zone.localDate(at: now)
        switch range {
        case .day:
            let dayStart = zone.startOfDay(today)
            return (0..<6).map { index in
                let start = dayStart + Int64(index) * 4 * 3_600_000
                let hour = zone.localHour(at: start)
                let label = "\(hour % 12 == 0 ? 12 : hour % 12)\(hour < 12 ? "am" : "pm")"
                return TimelineBucket(label: label, start: start, end: start + 4 * 3_600_000, inclusiveEnd: false)
            }
        case .week:
            let monday = today.mondayOfWeek
            return (0..<7).map { index in
                let day = monday.plusDays(Int64(index))
                return TimelineBucket(label: labels.shortWeekday(day.dayOfWeek), start: zone.startOfDay(day),
                                      end: zone.startOfDay(day.plusDays(1)), inclusiveEnd: false)
            }
        case .month:
            let daysInMonth = today.lengthOfMonth
            return (0..<4).compactMap { index in
                let startDay = index * 7 + 1
                if startDay > daysInMonth { return nil }
                let endDay = index == 3 ? daysInMonth : min(startDay + 6, daysInMonth)
                let start = zone.startOfDay(LocalDate(year: today.year, month: today.month, day: startDay))
                let end = zone.startOfDay(LocalDate(year: today.year, month: today.month, day: endDay).plusDays(1))
                return TimelineBucket(label: labels.weekOfMonth(index + 1), start: start, end: end, inclusiveEnd: false)
            }
        case .year:
            return (1...12).map { month in
                let first = LocalDate(year: today.year, month: month, day: 1)
                let next = month == 12 ? LocalDate(year: today.year + 1, month: 1, day: 1)
                    : LocalDate(year: today.year, month: month + 1, day: 1)
                return TimelineBucket(label: labels.shortMonth(month), start: zone.startOfDay(first),
                                      end: zone.startOfDay(next), inclusiveEnd: false)
            }
        case .all:
            let all = spans.isEmpty ? [Span(start: fallbackStart, end: fallbackStart)] : spans
            let minTimestamp = all.map(\.start).min() ?? fallbackStart
            let maxTimestamp = all.map(\.end).max() ?? now
            let startYear = zone.localDate(at: minTimestamp).year
            let endYear = zone.localDate(at: maxTimestamp).year
            if startYear > endYear { return [] }
            return (startYear...endYear).map { year in
                TimelineBucket(label: String(year), start: zone.startOfDay(LocalDate(year: year, month: 1, day: 1)),
                               end: zone.startOfDay(LocalDate(year: year + 1, month: 1, day: 1)), inclusiveEnd: false)
            }
        }
    }
}
