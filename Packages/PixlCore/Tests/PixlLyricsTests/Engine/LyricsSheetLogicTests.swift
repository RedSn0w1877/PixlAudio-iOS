import Foundation
import Testing
import PixlModel
@testable import PixlLyrics

/// Port of `presentation/components/LyricsSheetLogicTest.kt` (the 10 line-helper cases; the two
/// `lyricsChromeColors` cases test Material colour roles and have no iOS counterpart).
@Suite("Lyrics sheet line helpers")
struct LyricsSheetLogicTests {

    @Test func sanitizeSyncedWords_removesLeadingTags_preventsOverlap() {
        let sanitized = LyricsSheetLogic.sanitizeSyncedWords([
            SyncedWord(time: 0, word: "v1:"), SyncedWord(time: 120, word: "Hello"), SyncedWord(time: 240, word: "world"),
        ])
        #expect(sanitized.map(\.word) == ["Hello", "world"])
        #expect(sanitized.map(\.time) == [120, 240])
        #expect(sanitized.allSatisfy { $0.startsNewWord })
    }

    @Test func sanitizeLyricLineText_stripsLrcTimestampTags() {
        let raw = "[00:26.42][01:12.34] Three in the morning, I ain't slept all weekend"
        #expect(LyricsSheetLogic.sanitizeLyricLineText(raw) == "Three in the morning, I ain't slept all weekend")
    }

    @Test func resolveLineEndTimeMs_extendsPastNextLineWhenLastWordStartsLater() {
        let line = SyncedLine(time: 1_000, line: "abc", words: [
            SyncedWord(time: 1_000, word: "a"), SyncedWord(time: 1_600, word: "b"), SyncedWord(time: 2_000, word: "c"),
        ])
        #expect(LyricsSheetLogic.resolveLineEndTimeMs(line, nextLineStartMs: 2_000) == 2_001)
    }

    @Test func sanitizeSyncedWords_promotesFirstVisibleWordAfterLeadingMarker() {
        let sanitized = LyricsSheetLogic.sanitizeSyncedWords([
            SyncedWord(time: 1000, word: "v1:"), SyncedWord(time: 1200, word: "fall", startsNewWord: false),
        ])
        #expect(sanitized.count == 1)
        #expect(sanitized[0].word == "fall")
        #expect(sanitized[0].startsNewWord)
    }

    @Test func clusterSyncedWords_keepsSyllablesInsideSameWord() {
        let clusters = LyricsSheetLogic.clusterSyncedWords([
            SyncedWord(time: 1000, word: "to", startsNewWord: true),
            SyncedWord(time: 1100, word: "geth", startsNewWord: false),
            SyncedWord(time: 1200, word: "er", startsNewWord: false),
            SyncedWord(time: 1500, word: "now", startsNewWord: true),
        ])
        #expect(clusters.count == 2)
        #expect(clusters[0].words.map(\.word) == ["to", "geth", "er"])
        #expect(clusters[1].words.map(\.word) == ["now"])
        #expect(clusters[0].startIndex == 0)
        #expect(clusters[1].startIndex == 3)
    }

    @Test func resolveSeekPositionMs_subtractsPositiveLyricsOffset() {
        #expect(LyricsSheetLogic.resolveSeekPositionMs(lineTimeMs: 12_000, lyricsSyncOffsetMs: 750) == 11_250)
    }

    @Test func resolveSeekPositionMs_addsNegativeLyricsOffset() {
        #expect(LyricsSheetLogic.resolveSeekPositionMs(lineTimeMs: 12_000, lyricsSyncOffsetMs: -750) == 12_750)
    }

    @Test func resolveSeekPositionMs_clampsToZeroWhenOffsetWouldGoNegative() {
        #expect(LyricsSheetLogic.resolveSeekPositionMs(lineTimeMs: 300, lyricsSyncOffsetMs: 750) == 0)
    }

    @Test func explicitLineEndWinsOverNextLineStart() {
        let lines = [
            SyncedLine(time: 1000, line: "Lead", endTime: 3000),
            SyncedLine(time: 1500, line: "Echo", endTime: 2200, voiceRole: "background"),
            SyncedLine(time: 4000, line: "Next", endTime: 5000),
        ]
        #expect(LyricsSheetLogic.resolveLineEndTimeMs(lines[0], nextLineStartMs: 1500) == 3000)
    }

    @Test func syllablesStayTogetherWhileCjkFragmentsCanWrap() {
        let latin = [SyncedWord(time: 0, word: "Hel", startsNewWord: true), SyncedWord(time: 100, word: "lo", startsNewWord: false),
                     SyncedWord(time: 200, word: "there", startsNewWord: true)]
        #expect(LyricsSheetLogic.clusterSyncedWords(latin).map(\.words.count) == [2, 1])
        let cjk = [SyncedWord(time: 0, word: "你", startsNewWord: true), SyncedWord(time: 100, word: "好", startsNewWord: false),
                   SyncedWord(time: 200, word: "世", startsNewWord: false), SyncedWord(time: 300, word: "界", startsNewWord: false)]
        let clusters = LyricsSheetLogic.clusterSyncedWords(cjk)
        #expect(clusters.map(\.words.count) == [1, 1, 1, 1])
        #expect(clusters.dropFirst().allSatisfy { !$0.words[0].startsNewWord })
    }

    // MARK: Swift-only: the hand-written regex replacements

    @Test func timestampTagEdgeCases() {
        #expect(LyricsSheetLogic.stripLrcTimestamps("[1:23]x[12:345]y[1:23.4567]z[1:23:45] end") == "x[12:345]y[1:23.4567]z end")
        #expect(LyricsSheetLogic.stripLrcTimestamps("[00:01]") == "")
        #expect(LyricsSheetLogic.stripLrcTimestamps("") == "")
        #expect(LyricsSheetLogic.stripLrcTimestamps("text [00:10.00] mid") == "text  mid")
        #expect(LyricsSheetLogic.stripLrcTimestamps("[１:23]x") == "[１:23]x", "Java \\d is ASCII only")
    }

    @Test func voiceTagEdgeCases() {
        #expect(LyricsSheetLogic.sanitizeLyricLineText("V23:\t  Hi") == "Hi")
        #expect(LyricsSheetLogic.sanitizeLyricLineText("v: no") == "v: no")
        #expect(LyricsSheetLogic.sanitizeLyricLineText("vv1: no") == "vv1: no")
        #expect(LyricsSheetLogic.sanitizeLyricLineText("  [00:01.00]  v2:  spaced  ") == "spaced  ")
    }
}

/// Port of `presentation/lyrics/LyricsClockTest.kt` (3 cases).
@Suite("LyricsClock")
struct LyricsClockTests {
    let frame: Int64 = 8_333_333

    @Test func resumeAfterIdle_isNotASeek_whenRebased() {
        var pos: Int64 = 10_000
        var clock = LyricsClock()
        clock.tick(frameNanos: 0, positionMs: pos)
        // Paused and idle for 30 s of wall-clock time, then play resumes from the same spot.
        clock.rebase()
        clock.isPlaying = true
        do { let result = clock.tick(frameNanos: 30_000_000_000, positionMs: pos); #expect(!result) }
        do { let result = clock.consumeSeek(); #expect(!result) }
        pos += 8
        do { let result = clock.tick(frameNanos: 30_000_000_000 + frame, positionMs: pos); #expect(!result) }
        #expect(clock.currentMs == 10_008)
    }

    @Test func resumeAfterIdle_withoutRebase_readsAsASeek() {
        var clock = LyricsClock()
        clock.tick(frameNanos: 0, positionMs: 10_000)
        clock.isPlaying = true
        do { let result = clock.tick(frameNanos: 30_000_000_000, positionMs: 10_000); #expect(result) }
    }

    @Test func peek_readsPositionPlusOffset_withoutPublishing() {
        // Android's `peekMs()` reads the providers without publishing; here the caller owns the position, so the
        // equivalent is: a new position + offset is only published by the next tick.
        var clock = LyricsClock()
        clock.tick(frameNanos: 0, positionMs: 5_000, offsetMs: 250)
        let peek: Int64 = 9_000 + 250
        #expect(peek == 9_250)
        #expect(clock.currentMs == 5_250)
    }

    // MARK: Swift-only

    @Test func speedScalesThePrediction() {
        var clock = LyricsClock()
        clock.isPlaying = true
        clock.playbackSpeed = 0.5
        clock.tick(frameNanos: 0, positionMs: 0)
        do { let result = clock.tick(frameNanos: 3_000_000_000, positionMs: 1_500); #expect(!result, "half speed: 3 s of frames = 1.5 s of song") }
        do { let result = clock.tick(frameNanos: 6_000_000_000, positionMs: 4_500 + 1); #expect(result, "1.5 s ahead of the prediction is a seek") }
        #expect(clock.seekCount == 1)
    }

    @Test func markSeekAndReset() {
        var clock = LyricsClock()
        clock.tick(frameNanos: 0, positionMs: 100)
        clock.markSeek()
        do { let result = clock.consumeSeek(); #expect(result) }
        clock.reset()
        do { let result = clock.tick(frameNanos: 99_000_000_000, positionMs: 50_000); #expect(!result, "after reset the next tick adopts the position") }
        #expect(clock.currentMs == 50_000)
    }
}

/// Port of `presentation/lyrics/LyricsScriptShapingTest.kt` (3 cases) through the renderer wrappers.
@Suite("Lyrics script shaping")
struct LyricsScriptShapingTests {
    @Test func latinCjkAndHebrew_useSeparatePieces() {
        #expect(!LyricsRenderMetrics.needsShapedPieces("Never gonna give you up"))
        #expect(!LyricsRenderMetrics.needsShapedPieces("Ça plane pour moi, ñandú"))
        #expect(!LyricsRenderMetrics.needsShapedPieces("夜に駆ける 君の手を"))
        #expect(!LyricsRenderMetrics.needsShapedPieces("사랑해 오늘도"))
        #expect(!LyricsRenderMetrics.needsShapedPieces("Привет, мир"))
        #expect(!LyricsRenderMetrics.needsShapedPieces("שלום עולם"))
    }

    @Test func joiningAndClusteringScripts_drawShaped() {
        #expect(LyricsRenderMetrics.needsShapedPieces("حبيبي يا نور العين"))
        #expect(LyricsRenderMetrics.needsShapedPieces("दिल से रे"))
        #expect(LyricsRenderMetrics.needsShapedPieces("ভালোবাসি"))
        #expect(LyricsRenderMetrics.needsShapedPieces("ក្ដី"))
        #expect(LyricsRenderMetrics.needsShapedPieces("Baby, حبيبي, tonight"))
        #expect(LyricsRenderMetrics.needsShapedPieces("ﻻ"))
    }

    @Test func rtlDetection_followsFirstStrongCharacter() {
        #expect(LyricsRenderMetrics.isRtlText("  «حبيبي» baby"))
        #expect(LyricsRenderMetrics.isRtlText("שלום"))
        #expect(!LyricsRenderMetrics.isRtlText("baby حبيبي"))
        #expect(!LyricsRenderMetrics.isRtlText("123 ..."))
    }
}
