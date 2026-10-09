import PixlLibrary
import PixlModel
import XCTest
@testable import PixlAudio

/// Stage 7b: the Home / Recently Played / Stats logic ported from Android's presentation layer
/// (HomeGreetingStateHolder, RecentlyPlayedSongUi.kt, RecentlyPlayedSection, Formats.kt, StatsScreen helpers)
/// and the Home state holder over the demo library.
@MainActor
final class HomeLogicTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// Thursday 2026-09-10 18:30 UTC (HomeClock.uiTest).
    private let now: Int64 = 1_789_065_000_000
    private let day: Int64 = 86_400_000

    // MARK: Greeting

    func testDayPhasesMatchAndroid() {
        XCTAssertEqual(HomeLogic.dayPhase(hour: 5), "morning")
        XCTAssertEqual(HomeLogic.dayPhase(hour: 10), "morning")
        XCTAssertEqual(HomeLogic.dayPhase(hour: 11), "afternoon")
        XCTAssertEqual(HomeLogic.dayPhase(hour: 16), "afternoon")
        XCTAssertEqual(HomeLogic.dayPhase(hour: 17), "evening")
        XCTAssertEqual(HomeLogic.dayPhase(hour: 21), "evening")
        XCTAssertEqual(HomeLogic.dayPhase(hour: 22), "night")
        XCTAssertEqual(HomeLogic.dayPhase(hour: 4), "night")
    }

    func testLocalHeadlinePrefersArtistThenGenre() {
        XCTAssertEqual(HomeLogic.localHeadline(hour: 19, topArtist: "Luma Vale", topGenre: "Indie"),
                       "Good evening — ready for more Luma Vale?")
        XCTAssertEqual(HomeLogic.localHeadline(hour: 8, topArtist: nil, topGenre: "Indie"),
                       "Good morning — in the mood for some Indie?")
        XCTAssertEqual(HomeLogic.localHeadline(hour: 2, topArtist: nil, topGenre: nil),
                       "Still up? — let's find something to play.")
    }

    func testStatsSubtitleBranches() {
        XCTAssertEqual(HomeLogic.statsSubtitle(librarySize: 490, totalPlayCount: 200, topGenre: nil),
                       "200 plays across 490 songs in your library")
        XCTAssertEqual(HomeLogic.statsSubtitle(librarySize: 490, totalPlayCount: 12, topGenre: "Rock"),
                       "12 plays logged · mostly Rock lately")
        XCTAssertEqual(HomeLogic.statsSubtitle(librarySize: 3, totalPlayCount: 0, topGenre: nil),
                       "3 songs in your library, ready to explore")
        XCTAssertEqual(HomeLogic.statsSubtitle(librarySize: 0, totalPlayCount: 0, topGenre: nil),
                       HomeLogic.defaultSubtitle)
    }

    func testExpandedFallback() {
        XCTAssertEqual(HomeLogic.expandedFallback(librarySize: 24, totalPlayCount: 7, topArtist: "Mira Okafor", topGenre: nil),
                       "You've logged 7 plays across 24 songs in your library. Mira Okafor has been getting the most plays.")
    }

    // MARK: Formats

    func testListeningDurations() {
        XCTAssertEqual(HomeLogic.listeningDurationLong(36 * 60_000), "36 m")
        XCTAssertEqual(HomeLogic.listeningDurationLong(65 * 60_000), "1 h 05 m")
        XCTAssertEqual(HomeLogic.listeningDurationLong(120 * 60_000), "2 h")
        XCTAssertEqual(HomeLogic.listeningDurationLong(12_000), "12 s")
        XCTAssertEqual(HomeLogic.listeningDurationCompact(12 * 60_000), "12m")
        XCTAssertEqual(HomeLogic.listeningDurationCompact(61 * 60_000), "1h 01m")
        XCTAssertEqual(HomeLogic.listeningDurationCompact(0), "0s")
    }

    func testClockDurationAndSongsLine() {
        XCTAssertEqual(HomeLogic.clockDuration(0), "00:00")
        XCTAssertEqual(HomeLogic.clockDuration(214_000), "03:34")
        XCTAssertEqual(HomeLogic.clockDuration(3_723_000), "01:02:03")
        XCTAssertEqual(HomeLogic.songsDotDuration(count: 1, durationMs: 200_000), "1 Song • 03:20")
        XCTAssertEqual(HomeLogic.songsDotDuration(count: 24, durationMs: 200_000), "24 Songs • 03:20")
    }

    func testHourLabels() {
        XCTAssertEqual(HomeLogic.convertHourLabel("7am", use24Hour: true), "07:00")
        XCTAssertEqual(HomeLogic.convertHourLabel("7 PM", use24Hour: true), "19:00")
        XCTAssertEqual(HomeLogic.convertHourLabel("12am", use24Hour: true), "00:00")
        XCTAssertEqual(HomeLogic.convertHourLabel("12pm", use24Hour: false), "12 PM")
        XCTAssertEqual(HomeLogic.convertHourLabel("7:00 am", use24Hour: false), "7 AM")
        XCTAssertEqual(HomeLogic.convertHourLabel("19:00", use24Hour: false), "7 PM")
        XCTAssertEqual(HomeLogic.convertHourLabel("4", use24Hour: true), "04:00")
        XCTAssertEqual(HomeLogic.convertHourLabel("Mon", use24Hour: true), "Mon")
        XCTAssertEqual(HomeLogic.timelineLabel("September", range: .year, use24Hour: true), "Sep")
        XCTAssertEqual(HomeLogic.timelineLabel("  ", range: .week, use24Hour: true), "—")
    }

    func testInitials() {
        XCTAssertEqual(HomeLogic.initials("Luma Vale"), "LV")
        XCTAssertEqual(HomeLogic.initials("aurelio & the tides"), "A&")
        XCTAssertEqual(HomeLogic.initials("  "), "?")
    }

    // MARK: Recently played pills

    func testPillWidthSteps() {
        XCTAssertEqual(HomeLogic.pillWidth(title: "Stay", artist: "Kid"), 148)
        XCTAssertEqual(HomeLogic.pillWidth(title: "Golden Hour Loop", artist: "Aurelio"), 166)
        XCTAssertEqual(HomeLogic.pillWidth(title: String(repeating: "x", count: 60), artist: ""), 220)
    }

    func testPillRowsFillColumnMajor() {
        XCTAssertEqual(HomeLogic.pillRowTargets(10), [4, 3, 3])
        XCTAssertEqual(HomeLogic.pillRowTargets(4), [2, 1, 1])
        let rows = HomeLogic.pillRows(Array(0..<5), width: { _ in 100 }, startPadding: 8, endPadding: 24)
        let items: [[Int]] = rows.map { row in row.cells.map { $0.item } }
        XCTAssertEqual(items, [[0, 3], [1, 4], [2]])
        let twoCells: CGFloat = 240 // 8 + 100 + 8 + 100 + 24
        let oneCell: CGFloat = 132 // 8 + 100 + 24
        XCTAssertEqual(rows.map(\.contentWidth), [twoCells, twoCells, oneCell])
    }

    // MARK: Recently played mapping

    private func song(_ id: String) -> Song {
        Song(id: id, title: "Song \(id)", artist: "Artist", artistId: 1, artists: [], album: "Album", albumId: 1,
             albumArtist: nil, path: "/\(id).m4a", contentUriString: "demo://\(id)", albumArtUriString: nil,
             duration: 200_000, mimeType: nil, bitrate: nil, sampleRate: nil)
    }

    func testRecentlyPlayedDedupesNewestFirstWithinRange() {
        // PlaybackHistoryEntry has no public initialiser: build it the way the app does, from events.
        let plays: [(String, Int64)] = [("a", now - 1_000), ("b", now - 2_000), ("a", now - 3_000), ("c", now - 8 * day),
                                        ("gone", now - 4_000), ("future", now + 60_000)]
        let history = PlaybackStats.playbackHistory(plays.map { PlaybackEvent(songId: $0.0, timestamp: $0.1, durationMs: 500) })
        let songs = Dictionary(uniqueKeysWithValues: ["a", "b", "c", "future"].map { ($0, song($0)) })
        XCTAssertEqual(HomeLogic.collectRecentlyPlayedSongIds(history: history, nowMs: now, timeZone: utc),
                       ["a", "b", "gone", "c"])
        let week = HomeLogic.mapRecentlyPlayed(history: history, songsById: songs, range: .week, nowMs: now, timeZone: utc)
        XCTAssertEqual(week.map(\.song.id), ["a", "b"])
        XCTAssertEqual(week.first?.lastPlayedTimestamp, now - 1_000)
        let all = HomeLogic.mapRecentlyPlayed(history: history, songsById: songs, nowMs: now, timeZone: utc, maxItems: 2)
        XCTAssertEqual(all.map(\.song.id), ["a", "b"])
    }

    func testRangeBoundsStartOnMondayAndFirstOfMonth() {
        XCTAssertEqual(HomeLogic.recentBounds(.week, nowMs: now, timeZone: utc).start, 1_788_739_200_000) // Mon 7 Sep
        XCTAssertEqual(HomeLogic.recentBounds(.month, nowMs: now, timeZone: utc).start, 1_788_220_800_000) // 1 Sep
        XCTAssertEqual(HomeLogic.recentBounds(.day, nowMs: now, timeZone: utc).start, 1_788_998_400_000)
        XCTAssertNil(HomeLogic.recentBounds(.all, nowMs: now, timeZone: utc).start)
    }

    func testTimestampGroups() {
        let items = [
            RecentlyPlayedItem(song: song("a"), lastPlayedTimestamp: now - 3_600_000),
            RecentlyPlayedItem(song: song("b"), lastPlayedTimestamp: now - 2 * 3_600_000),
            RecentlyPlayedItem(song: song("c"), lastPlayedTimestamp: now - day),
            RecentlyPlayedItem(song: song("d"), lastPlayedTimestamp: now - 3 * day),
        ]
        let groups = HomeLogic.timestampGroups(items, range: .week, nowMs: now, timeZone: utc, use24Hour: true,
                                               locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertEqual(groups.map(\.label), ["Today", "Yesterday", "Mon, Sep 7"])
        XCTAssertEqual(groups.first?.items.count, 2)
        let hours = HomeLogic.timestampGroups(items.prefix(2).map { $0 }, range: .day, nowMs: now, timeZone: utc,
                                              use24Hour: true, locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertEqual(hours.map(\.label), ["17:00", "16:00"])
        XCTAssertTrue(hours.allSatisfy(\.isHourBucket))
    }

    // MARK: Stats chart sizing

    func testTimelineChartLayout() {
        let week = TimelineChartSpec.forRange(.week, entryCount: 7)
        let fitted = week.layout(count: 7, width: 393)
        XCTAssertTrue(fitted.scrolls) // 7 > maxVisibleItems (6)
        XCTAssertEqual(fitted.itemWidth, 50)
        let day = TimelineChartSpec.forRange(.day, entryCount: 4)
        let dayLayout = day.layout(count: 4, width: 353)
        XCTAssertFalse(dayLayout.scrolls)
        XCTAssertEqual(dayLayout.itemWidth, min(max((353 - 40 - 30) / 4, 52), 72))
    }

    // MARK: Home state holder

    func testDemoHistoryIsDeterministicAndInThePast() {
        let first = DemoListeningHistory.events(songs: DemoLibrary.songs, nowMs: now)
        let second = DemoListeningHistory.events(songs: DemoLibrary.songs, nowMs: now)
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)
        XCTAssertTrue(first.allSatisfy { $0.endMillis < now })
    }

    func testHomeComputationOverTheDemoLibrary() {
        let events = DemoListeningHistory.events(songs: DemoLibrary.songs, nowMs: now)
        let result = HomeStore.compute(snapshot: DemoLibrary.snapshot, events: events, nowMs: now, timeZone: utc,
                                       savedDaily: [], savedYourMix: [])
        let content = result.content
        XCTAssertTrue(result.generatedMixes)
        XCTAssertTrue(content.greeting.headline.hasPrefix("Good evening"))
        XCTAssertFalse(content.mixes.isEmpty)
        XCTAssertLessThanOrEqual(content.mixes.count, 3)
        XCTAssertFalse(content.shelves.isEmpty)
        XCTAssertFalse(content.dailyMix.isEmpty)
        XCTAssertFalse(content.curatedYourMix.isEmpty)
        XCTAssertEqual(content.yourMix, content.curatedYourMix)
        XCTAssertEqual(content.recentlyAdded.first?.id, "demo:0") // newest dateAdded
        XCTAssertGreaterThanOrEqual(content.recentlyPlayed.count, HomeLogic.recentlyPlayedMinSongs)
        XCTAssertEqual(content.statsOverview?.range, .week)
        XCTAssertGreaterThan(content.statsOverview?.totalPlayCount ?? 0, 0)
    }

    func testSupersededComputationStopsAndAnActiveOneMatchesCompute() async {
        let events = DemoListeningHistory.events(songs: DemoLibrary.songs, nowMs: now)
        let snapshot = DemoLibrary.snapshot, zone = utc, at = now
        let active = HomeStore.computeIfActive(snapshot: snapshot, events: events, nowMs: at, timeZone: zone,
                                               savedDaily: [], savedYourMix: [])
        let plain = HomeStore.compute(snapshot: snapshot, events: events, nowMs: at, timeZone: zone, savedDaily: [],
                                      savedYourMix: [])
        XCTAssertEqual(active?.content, plain.content)
        let cancelled = Task.detached { () -> Bool in
            // Cancel this task from inside, then compute: the first stage boundary abandons the work.
            withUnsafeCurrentTask { $0?.cancel() }
            return HomeStore.computeIfActive(snapshot: snapshot, events: events, nowMs: at, timeZone: zone,
                                             savedDaily: [], savedYourMix: []) == nil
        }
        let abandoned = await cancelled.value
        XCTAssertTrue(abandoned)
    }

    func testSavedDailyMixIsKeptForTheDay() {
        let saved = Array(DemoLibrary.songs.prefix(3).map(\.id).reversed())
        let result = HomeStore.compute(snapshot: DemoLibrary.snapshot, events: [], nowMs: now, timeZone: utc,
                                       savedDaily: saved, savedYourMix: [saved[0]])
        XCTAssertFalse(result.generatedMixes)
        XCTAssertEqual(result.content.dailyMix.map(\.id), saved)
        XCTAssertEqual(result.content.curatedYourMix.map(\.id), [saved[0]])
    }

    func testEmptyLibraryFallsBackToDefaults() {
        let result = HomeStore.compute(snapshot: .empty, events: [], nowMs: now, timeZone: utc, savedDaily: [],
                                       savedYourMix: [])
        XCTAssertEqual(result.content.greeting.subtitle, HomeLogic.defaultSubtitle)
        XCTAssertTrue(result.content.yourMix.isEmpty)
        XCTAssertNil(result.content.statsOverview)
    }

    func testRecordingBumpsTheRevision() async {
        let store = ListeningHistoryStore(clock: HomeClock(fixedNowMs: now, timeZone: utc), file: nil)
        await store.ensureLoaded()
        let before = store.revision
        store.record(songId: "demo:1", durationMs: 120_000)
        XCTAssertEqual(store.revision, before + 1)
        XCTAssertEqual(store.events.last?.endMillis, now)
        store.record(songId: "  ", durationMs: 1_000)
        XCTAssertEqual(store.revision, before + 1, "blank ids are not recorded")
    }

    func testUITestStoreHasDemoHistory() {
        let store = HomeStore.make(launch: LaunchConfiguration(arguments: ["-uiTest", "-screen", "home"]))
        XCTAssertFalse(store.history.events.isEmpty)
    }
}
