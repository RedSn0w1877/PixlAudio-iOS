import PixlLyrics
import PixlModel
import XCTest
@testable import PixlAudio

/// Stage 9: the demo lyrics the screenshots rely on, the karaoke piece table, the driver and the service's storage.
@MainActor
final class LyricsFeatureTests: XCTestCase {
    func testDemoWordsHaveEmphasisAndAnInterlude() throws {
        let lyrics = try XCTUnwrap(LyricsDemoContent.lyrics(.words))
        let prepared = try XCTUnwrap(PreparedLyricsBuilder.build(lyrics))
        XCTAssertTrue(prepared.hasWordTiming)
        let higher = try XCTUnwrap(prepared.lines.first { $0.text == "Take me higher" })
        XCTAssertTrue(higher.syllables?.last?.emphasis ?? false, "\"higher\" (2.4 s, explicit end) glows")
        let interludes = prepared.rows.filter(\.isInterlude)
        XCTAssertTrue(interludes.contains { row in
            if case .interlude(let start, let end, _) = row {
                return start <= LyricsDemoContent.interludeMs && LyricsDemoContent.interludeMs < end
            }
            return false
        })
        // Mid-line freeze lands inside line 10's words.
        let line10 = prepared.lines[10]
        XCTAssertTrue(line10.startMs < LyricsDemoContent.midLineMs && LyricsDemoContent.midLineMs < line10.endMs)
    }

    func testDemoDuetGroupsBackgroundVocals() throws {
        let prepared = try XCTUnwrap(PreparedLyricsBuilder.build(try XCTUnwrap(LyricsDemoContent.lyrics(.duet))))
        XCTAssertTrue(prepared.hasDuet)
        XCTAssertTrue(prepared.lines.contains { $0.isGroupedBackground })
    }

    func testPieceTableCoversEverySyllableAndKeepsTheText() throws {
        let prepared = try XCTUnwrap(PreparedLyricsBuilder.build(try XCTUnwrap(LyricsDemoContent.lyrics(.words))))
        for line in prepared.lines where line.hasWordTiming {
            let table = KaraokePieceTable(line: line)
            XCTAssertEqual(table.segments.map(\.text).joined(), line.text)
            XCTAssertEqual(table.syllableCount, line.syllables?.count)
            let timed = Set(table.segments.map(\.piece).filter { $0 >= 0 })
            XCTAssertEqual(timed.count, table.syllable.count, "every piece appears in the text")
        }
        let higher = try XCTUnwrap(prepared.lines.first { $0.text == "Take me higher" })
        let table = KaraokePieceTable(line: higher)
        XCTAssertEqual(table.emphasis.filter { $0 }.count, 6, "one piece per grapheme of \"higher\"")
    }

    func testEmphasisPeaksNearTheScreenshotTime() throws {
        let prepared = try XCTUnwrap(PreparedLyricsBuilder.build(try XCTUnwrap(LyricsDemoContent.lyrics(.words))))
        let higher = try XCTUnwrap(prepared.lines.first { $0.text == "Take me higher" })
        let table = KaraokePieceTable(line: higher)
        let middle = try XCTUnwrap(table.emphasis.indices.first { table.emphasis[$0] && table.graphemeIndex[$0] == 3 })
        let frame = table.frame(middle, tMs: LyricsDemoContent.emphasisPeakMs, activeness: 1, em: 34, background: false,
                                reducedMotion: false, highContrast: false, sweepLeft: 0, sweepRight: 100, fade: 20)
        XCTAssertGreaterThan(frame.scale, 1.05)
        XCTAssertGreaterThan(frame.glowAlpha, 0.1)
    }

    func testDriverBuildsOneStatePerRow() throws {
        let prepared = try XCTUnwrap(PreparedLyricsBuilder.build(try XCTUnwrap(LyricsDemoContent.lyrics(.words))))
        let driver = LyricsDriver()
        driver.setLyrics(prepared, animateIn: true)
        XCTAssertEqual(driver.rows.count, prepared.rows.count)
    }

    func testLaunchOptionsParse() {
        let options = LyricsLaunchOptions(arguments: ["-lyricsDemo", "duet", "-lyricsFreezeMs", "42300", "-lyricsBrightArt"])
        XCTAssertEqual(options.demo, .duet)
        XCTAssertEqual(options.freezeMs, 42_300)
        XCTAssertTrue(options.brightArt)
        XCTAssertFalse(options.highContrast)
    }

    func testOffsetsRoundTripPerSong() {
        let suite = "lyrics.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = LyricsViewPreferences(defaults: defaults)
        preferences.setOffset(-300, for: "a")
        preferences.setOffset(500, for: "b")
        XCTAssertEqual(preferences.offset(for: "a"), -300)
        XCTAssertEqual(preferences.offset(for: "b"), 500)
        preferences.setOffset(0, for: "a")
        XCTAssertEqual(preferences.offset(for: "a"), 0)
    }

    func testServiceStoresAndResetsLyrics() async throws {
        let container = try PersistenceActor.makeContainer(inMemory: true)
        let persistence = PersistenceActor(modelContainer: container)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let service = LyricsService(persistence: persistence, cacheDirectory: cache)
        let song = try XCTUnwrap(DemoLibrary.songs.first)
        let saved = await service.save(song: song, rawContent: "[00:01.00]Hello\n[00:03.00]World", source: "manual")
        XCTAssertEqual(saved?.lyrics.synced?.count, 2)
        let loaded = await service.lyrics(for: song, preference: .embeddedFirst, allowOnline: false)
        XCTAssertEqual(loaded?.lyrics.synced?.map(\.line), ["Hello", "World"])
        await service.reset(song: song)
        let stored = await service.storedLyricsAsync(for: song)
        XCTAssertNil(stored)
    }

    func testJapaneseRomanizationUsesTheTokenizer() {
        let romaji = AppleCJKRomanization().romanizeJapanese("こんにちは")
        XCTAssertNotNil(romaji)
        XCTAssertTrue(romaji?.hasPrefix("kon") == true, romaji ?? "nil")
        XCTAssertEqual(AppleCJKRomanization().pinyinReading(for: "中"), "zhong")
    }
}
