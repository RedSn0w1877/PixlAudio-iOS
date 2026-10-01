import Foundation
import PixlFoundation
import PixlModel
import Testing
@testable import PixlLibrary

/// Port of `data/stats/PlaybackStatsRepositoryTest.kt` (zone fixed instead of the system default) plus the
/// repository's read-modify-write transforms and the MONTH range the golden generator cannot run.
@Suite struct PlaybackStatsTests {
    let zone = TimeZone(identifier: "Europe/Berlin")!
    var clock: ZoneClock { ZoneClock(zone) }

    private func song(_ id: String, durationMs: Int64 = 5 * 60 * 1000, artist: String = "Artist",
                      artists: [ArtistRef] = [], genre: String? = nil) -> Song {
        Song(id: id, title: "Song \(id)", artist: artist, artistId: 1, artists: artists, album: "Album", albumId: 1,
             path: "/music/\(id).mp3", contentUriString: "content://media/external/audio/media/\(id)", albumArtUriString: nil,
             duration: durationMs, genre: genre, mimeType: "audio/mpeg", bitrate: 320_000, sampleRate: 44_100)
    }

    private func at(_ hour: Int, _ minute: Int = 0) -> Int64 {
        clock.startOfDay(LocalDate(year: 2026, month: 4, day: 10)) + Int64(hour) * 3_600_000 + Int64(minute) * 60_000
    }

    private func event(_ songId: String, start: Int64, duration: Int64) -> PlaybackEvent {
        PlaybackEvent(songId: songId, timestamp: start + duration, durationMs: duration, startTimestamp: start,
                      endTimestamp: start + duration)
    }

    @Test func loadSummaryExcludesEventThatOnlyTouchesTheStartBoundary() {
        let now = at(0)
        let summary = PlaybackStats.buildSummary(range: .day, songs: [song("song-1")], nowMillis: now,
                                                 events: [event("song-1", start: now - 10_000, duration: 10_000)], timeZone: zone)
        #expect(summary.totalDurationMs == 0)
        #expect(summary.totalPlayCount == 0)
    }

    @Test func loadSummaryPreservesPlaybackLongerThanTrackDuration() {
        let start = at(10), listened: Int64 = 15 * 60_000
        let summary = PlaybackStats.buildSummary(range: .day, songs: [song("song-1", durationMs: 3 * 60_000)],
                                                 nowMillis: start + listened + 1_000,
                                                 events: [event("song-1", start: start, duration: listened)], timeZone: zone)
        #expect(summary.totalDurationMs == listened)
        #expect(summary.totalPlayCount == 1)
        #expect(summary.songs.first?.totalDurationMs == listened)
    }

    @Test func loadSummaryDoesNotCountShortGapsBetweenSpansAsListenedTime() {
        let start = at(12)
        let events = [event("song-1", start: start, duration: 10_000), event("song-2", start: start + 11_000, duration: 10_000)]
        let summary = PlaybackStats.buildSummary(range: .day, songs: [song("song-1"), song("song-2")],
                                                 nowMillis: start + 22_000, events: events, timeZone: zone)
        #expect(summary.totalDurationMs == 20_000)
        #expect(summary.totalPlayCount == 2)
    }

    @Test func buildSummaryFromEventsUsesEventSpansWithoutFilesystemPersistence() {
        let start = at(9)
        let summary = PlaybackStats.buildSummary(range: .day, songs: [song("song-1")], nowMillis: start + 31_000,
                                                 events: [event("song-1", start: start, duration: 30_000)], timeZone: zone)
        #expect(summary.totalDurationMs == 30_000)
        #expect(summary.uniqueSongs == 1)
    }

    @Test func loadSummarySeparatesMultiArtistPlaybackInTopArtists() {
        let start = at(14)
        let collaboration = song("song-1", artist: "Artist A", artists: [ArtistRef(id: 1, name: "Artist A", isPrimary: true),
                                                                         ArtistRef(id: 2, name: "Artist B", isPrimary: false)])
        let summary = PlaybackStats.buildSummary(range: .day, songs: [collaboration], nowMillis: start + 61_000,
                                                 events: [event("song-1", start: start, duration: 60_000)], timeZone: zone)
        #expect(summary.topArtists.map(\.artist) == ["Artist A", "Artist B"])
        for artist in summary.topArtists {
            #expect(artist.totalDurationMs == 60_000)
            #expect(artist.playCount == 1)
            #expect(artist.uniqueSongs == 1)
        }
    }

    @Test func loadSummaryCountsSeparatedArtistsInGenreUniqueness() {
        let start = at(15)
        let collaboration = song("song-1", artist: "Artist A", artists: [ArtistRef(id: 1, name: "Artist A", isPrimary: true),
                                                                         ArtistRef(id: 2, name: "Artist B", isPrimary: false)],
                                 genre: "Pop")
        let summary = PlaybackStats.buildSummary(range: .day, songs: [collaboration], nowMillis: start + 31_000,
                                                 events: [event("song-1", start: start, duration: 30_000)], timeZone: zone)
        #expect(summary.topGenres.count == 1)
        #expect(summary.topGenres.first?.uniqueArtists == 2)
    }

    // Swift-only.

    @Test func monthRangeBucketsByWeekOfMonth() {
        let now = clock.startOfDay(LocalDate(year: 2026, month: 2, day: 28)) + 3_600_000
        let summary = PlaybackStats.buildSummary(range: .month, songs: [song("s")], nowMillis: now,
                                                 events: [event("s", start: clock.startOfDay(LocalDate(year: 2026, month: 2, day: 9)), duration: 60_000)],
                                                 timeZone: zone)
        #expect(summary.timeline.map(\.label) == ["Week 1", "Week 2", "Week 3", "Week 4"])
        #expect(summary.timeline.map(\.totalDurationMs) == [0, 60_000, 0, 0])
        #expect(summary.startTimestamp == clock.startOfDay(LocalDate(year: 2026, month: 2, day: 1)))
        #expect(summary.dayListeningDistribution == nil)
        #expect(summary.peakDayLabel == "Monday")
        var spanish = StatsLabels.english
        spanish.weekOfMonth = { "Semana \($0)" }
        #expect(PlaybackStats.buildSummary(range: .month, songs: [], nowMillis: now, events: [], timeZone: zone, labels: spanish)
            .timeline.first?.label == "Semana 1")
    }

    @Test func dayBucketsAndDistribution() {
        let now = at(23)
        let summary = PlaybackStats.buildSummary(range: .day, songs: [song("s")], nowMillis: now,
                                                 events: [event("s", start: at(8, 2), duration: 6 * 60_000)], timeZone: zone)
        #expect(summary.timeline.map(\.label) == ["12am", "4am", "8am", "12pm", "4pm", "8pm"])
        #expect(summary.timeline[2] == TimelineEntry(label: "8am", totalDurationMs: 360_000, playCount: 1))
        let buckets = summary.dayListeningDistribution!.buckets
        #expect(buckets.map(\.startMinute) == [480, 485])
        #expect(buckets.map(\.totalDurationMs) == [180_000, 180_000])
        #expect(summary.peakTimeline?.label == "8am")
        #expect(summary.totalSessions == 1)
    }

    @Test func sanitizeKeepsTheStoredDurationWhenNoStartWasStored() {
        let e = PlaybackStats.sanitize(PlaybackEvent(songId: "a", timestamp: 1000, durationMs: 100, endTimestamp: 3000))
        #expect(e == PlaybackEvent(songId: "a", timestamp: 3000, durationMs: 100, startTimestamp: 2900, endTimestamp: 3000))
        let clamped = PlaybackStats.sanitize(PlaybackEvent(songId: "a", timestamp: 1000, durationMs: 100, startTimestamp: 2000))
        #expect(clamped.durationMs == 0)
    }

    @Test func recordingPrunesHistoryOlderThanTwoYears() {
        let old = PlaybackEvent(songId: "old", timestamp: 1_000, durationMs: 10, startTimestamp: 990, endTimestamp: 1_000)
        let kept = PlaybackEvent(songId: "kept", timestamp: 2 * PlaybackStats.maxHistoryAgeMs, durationMs: 10)
        let updated = PlaybackStats.recordingPlayback(songId: "new", durationMs: 5_000,
                                                      timestamp: 2 * PlaybackStats.maxHistoryAgeMs + 10, into: [old, kept])!
        #expect(updated.map(\.songId) == ["kept", "new"])
        #expect(updated.last == PlaybackEvent(songId: "new", timestamp: 2 * PlaybackStats.maxHistoryAgeMs + 10, durationMs: 5_000,
                                              startTimestamp: 2 * PlaybackStats.maxHistoryAgeMs - 4_990,
                                              endTimestamp: 2 * PlaybackStats.maxHistoryAgeMs + 10))
        #expect(PlaybackStats.recordingPlayback(songId: "  ", durationMs: 1, timestamp: 1, into: []) == nil)
    }

    @Test func importMergesSanitisesDeduplicatesAndSorts() {
        let a = PlaybackEvent(songId: "a", timestamp: 300, durationMs: 100)
        let b = PlaybackEvent(songId: "b", timestamp: 200, durationMs: 50)
        let merged = PlaybackStats.importingEvents([a, b, a], into: [b], clearExisting: false)
        #expect(merged.map(\.songId) == ["b", "a"])
        #expect(PlaybackStats.importingEvents([a], into: [b]).map(\.songId) == ["a"])
        let history = PlaybackStats.playbackHistory([b, a, PlaybackEvent(songId: "c", timestamp: -5, durationMs: 0)], limit: 2)
        #expect(history == [PlaybackHistoryEntry(songId: "a", timestamp: 300), PlaybackHistoryEntry(songId: "b", timestamp: 200)])
        #expect(PlaybackStats.playbackHistory([a], limit: 0).isEmpty)
    }

    @Test func codecWritesGsonFormat() {
        let text = PlaybackHistoryCodec.encode([PlaybackEvent(songId: "x<y", timestamp: 2_000, durationMs: 500)])
        #expect(text == "[{\"songId\":\"x\\u003cy\",\"timestamp\":2000,\"durationMs\":500,\"startTimestamp\":1500,\"endTimestamp\":2000}]")
        #expect(PlaybackHistoryCodec.decode(text) == [PlaybackEvent(songId: "x<y", timestamp: 2_000, durationMs: 500,
                                                                    startTimestamp: 1_500, endTimestamp: 2_000)])
        #expect(PlaybackHistoryCodec.decode(utf8: Array(text.utf8)).count == 1)
        #expect(PlaybackHistoryCodec.encode([]) == "[]")
        #expect(PlaybackHistoryCodec.bigDecimalLongValue("1.5e1") == 15)
        #expect(PlaybackHistoryCodec.bigDecimalLongValue("-1e100") == 0)
        #expect(PlaybackHistoryCodec.bigDecimalLongValue("abc") == nil)
    }

    @Test func localDateMatchesJavaTime() {
        #expect(LocalDate(epochDay: 0).description == "1970-01-01")
        #expect(LocalDate(epochDay: -1).description == "1969-12-31")
        #expect(LocalDate(year: 2024, month: 2, day: 29).epochDay == 19_782)
        #expect(LocalDate(epochDay: 19_782) == LocalDate(year: 2024, month: 2, day: 29))
        #expect(LocalDate(year: 2026, month: 9, day: 30).dayOfWeek == 3)
        #expect(LocalDate(year: 2026, month: 9, day: 30).mondayOfWeek == LocalDate(year: 2026, month: 9, day: 28))
        #expect(LocalDate.parseISO("2026-02-29") == nil)
        #expect(LocalDate(year: -5, month: 1, day: 1).description == "-0005-01-01")
        #expect(LocalDate(year: 12_345, month: 1, day: 1).description == "+12345-01-01")
        for day in stride(from: Int64(-800_000), through: 800_000, by: 997) { #expect(LocalDate(epochDay: day).epochDay == day) }
    }

    @Test func startOfDayHandlesMidnightDaylightSavingGaps() throws {
        // São Paulo skipped 00:00–01:00 on 2018-11-04; java.time gives 01:00 local (03:00 UTC).
        let saoPaulo = ZoneClock(try #require(TimeZone(identifier: "America/Sao_Paulo")))
        #expect(saoPaulo.startOfDay(LocalDate(year: 2018, month: 11, day: 4)) == 1_541_300_400_000)
        #expect(saoPaulo.localDate(at: 1_541_300_400_000) == LocalDate(year: 2018, month: 11, day: 4))
        #expect(ZoneClock(TimeZone(identifier: "UTC")!).startOfDay(LocalDate(year: 2026, month: 1, day: 1)) == 1_767_225_600_000)
    }
}

/// Port of `utils/QueueUtilsTest.kt`.
@Suite struct QueueUtilsTests {
    private func buildSongs(_ count: Int) -> [Song] {
        (0..<count).map { i in
            Song(id: "song-\(i)", title: "Song \(i)", artist: "Artist", artistId: 1, album: "Album", albumId: 1,
                 path: "/tmp/song-\(i).mp3", contentUriString: "content://pixelplay/song/\(i)", albumArtUriString: nil,
                 duration: 180_000, mimeType: "audio/mpeg", bitrate: 320_000, sampleRate: 44_100)
        }
    }

    @Test func suspendingShuffleHandles10kSongsWithoutLosingItems() async {
        let songs = buildSongs(10_000)
        var random = KotlinRandom(seed: Int32(42))
        let shuffled = await QueueUtils.buildAnchoredShuffleQueue(songs, anchorIndex: 7_654, startAtZero: false, random: &random)
        #expect(shuffled.count == songs.count)
        #expect(shuffled[7_654].id == songs[7_654].id)
        #expect(Set(shuffled.map(\.id)) == Set(songs.map(\.id)))
    }

    /// Android checks a sibling coroutine runs during the shuffle; here a sibling task must make progress while a
    /// 10k shuffle (which yields every 512 steps) runs.
    @Test func suspendingShuffleYieldsForLargeQueues() async {
        let songs = buildSongs(10_000)
        let counter = Counter()
        let heartbeat = Task {
            while !Task.isCancelled {
                await counter.increment()
                await Task.yield()
            }
        }
        let before = await counter.value
        var random = KotlinRandom(seed: Int32(7))
        _ = await QueueUtils.buildAnchoredShuffleQueue(songs, anchorIndex: 4_321, startAtZero: false, random: &random)
        // Give the heartbeat a chance on a single-threaded executor too.
        for _ in 0..<100 { await Task.yield() }
        let after = await counter.value
        heartbeat.cancel()
        #expect(after > before)
    }

    @Test func suspendingShuffleStartAtZeroPlacesAnchorFirst() async {
        let songs = buildSongs(32)
        var random = KotlinRandom(seed: Int32(99))
        let shuffled = await QueueUtils.buildAnchoredShuffleQueue(songs, anchorIndex: 11, startAtZero: true, random: &random)
        #expect(shuffled.first?.id == songs[11].id)
        #expect(shuffled.count == songs.count)
        #expect(Set(shuffled.map(\.id)) == Set(songs.map(\.id)))
    }

    // Swift-only.
    @Test func smallQueuesAndClampedAnchors() {
        var random = KotlinRandom(seed: Int32(1))
        #expect(QueueUtils.buildAnchoredShuffleQueue([1], anchorIndex: 5, random: &random) == [1])
        #expect(QueueUtils.fisherYatesCopy([Int](), random: &random) == [])
        let shuffled = QueueUtils.buildAnchoredShuffleQueue(Array(0..<10), anchorIndex: 99, random: &random)
        #expect(shuffled[9] == 9)
        #expect(Set(QueueUtils.fisherYatesCopy(Array(0..<50))) == Set(0..<50))
    }
}

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
