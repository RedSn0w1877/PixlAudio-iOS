import Foundation
import PixlModel
import Testing
@testable import PixlAudioCore

/// Port of `TaisLyricsPersistenceTest` (alignment-state and save-precondition cases) plus the pure parts of
/// `TaisWav2Vec2Aligner` / `TaisLyricsAligner.forceAlign`, and the iOS-only fixed windows and `LyricsDoc` output.
@Suite("LyricAlignment")
struct LyricAlignmentTests {
    // MARK: Vocabulary and target

    @Test func vocabularyMatchesAndroidJson() {
        #expect(Wav2Vec2Vocabulary.size == 32)
        #expect(Wav2Vec2Vocabulary.id(for: "E") == 5)
        #expect(Wav2Vec2Vocabulary.id(for: "'") == 27)
        #expect(Wav2Vec2Vocabulary.id(for: "Z") == 31)
        #expect(Wav2Vec2Vocabulary.id(for: "|") == 4)
        #expect(Wav2Vec2Vocabulary.id(for: "a") == nil)
    }

    @Test func extendedTargetInterleavesBlanksAndWordBoundaries() {
        let target = CtcTarget(words: ["Hi", "yo"])
        // H=11 I=10 |=4 Y=22 O=8
        #expect(target.tokenIds == [0, 11, 0, 10, 0, 4, 0, 22, 0, 8, 0])
        #expect(target.wordStateRanges == [1...3, 7...9])
    }

    @Test func wordsWithoutAlignableCharactersGetNoRangeAndNoBoundary() {
        let target = CtcTarget(words: ["42", "don't", "—", "café"])
        // DON'T then | then CAF (é drops its combining mark only when decomposed; precomposed É is dropped).
        #expect(target.wordStateRanges[0] == nil)
        #expect(target.wordStateRanges[2] == nil)
        #expect(target.wordStateRanges[1] == 1...9)
        let symbols = stride(from: 1, to: target.tokenIds.count, by: 2).map { target.tokenIds[$0] }
        #expect(symbols == [14, 8, 9, 27, 6, 4, 19, 7, 20])
    }

    @Test func decomposedAccentsKeepTheirBaseLetter() {
        let target = CtcTarget(words: ["cafe\u{301}"])
        let symbols = stride(from: 1, to: target.tokenIds.count, by: 2).map { target.tokenIds[$0] }
        #expect(symbols == [19, 7, 20, 5])
    }

    // MARK: Timings and evidence

    @Test func timingsComeFromFirstAndLastSymbolFrames() throws {
        let words = ["hi", "?", "yo"]
        let target = CtcTarget(words: words)
        // Frames: blank×5, H at 5, I at 6–7, blank, | at 12, Y at 15, O at 16–18, blank tail.
        var path = [Int](repeating: 0, count: 25)
        for t in 5..<6 { path[t] = 1 }
        for t in 6..<8 { path[t] = 3 }
        for t in 8..<12 { path[t] = 4 }
        path[12] = 5
        for t in 13..<15 { path[t] = 6 }
        path[15] = 7
        for t in 16..<19 { path[t] = 9 }
        for t in 19..<25 { path[t] = 10 }
        let timings = CtcWordTimings.timings(path: path, target: target, words: words)
        #expect(timings == [AlignedWordTiming(word: "hi", startMs: 100, endMs: 140),
                            AlignedWordTiming(word: "?", startMs: 140, endMs: 140),
                            AlignedWordTiming(word: "yo", startMs: 300, endMs: 360)])
    }

    @Test func evidenceIsTheMeanPeakProbabilityPerWord() {
        let target = CtcTarget(words: ["ab"])  // A=7 B=24 → states 1 and 3
        let path = [0, 1, 1, 2, 3, 4]
        let probabilities: [Int: Float] = [7: 0.9, 24: 0.5]
        let evidence = CtcWordTimings.evidence(path: path, target: target) { _, token in
            log(probabilities[token] ?? 0.01)
        }
        #expect(evidence.count == 1)
        #expect(abs(evidence[0] - 0.7) < 1e-5)
    }

    @Test func frameToMsIsTwentyMsPerFrame() {
        #expect(CtcWordTimings.frameToMs(0) == 0)
        #expect(CtcWordTimings.frameToMs(499) == 9980)
    }

    // MARK: Fixed windows (iOS Core ML input)

    @Test func fixedWindowsCoverEveryFrameOnceWithFullInputs() {
        let input = 160_000
        let inputFrames = CtcAlignmentCore.frameCount(samples: input)
        #expect(inputFrames == 499)
        for samples in [400, 5_000, 159_999, 160_000, 160_400, 320_000, 1_234_567, 3_840_000] {
            let windows = CtcAlignmentCore.fixedWindows(sampleCount: samples, inputSamples: input)
            let total = CtcAlignmentCore.frameCount(samples: samples)
            let kept = windows.flatMap { Array($0.firstFrame..<$0.endFrame) }
            #expect(kept == Array(0..<total))
            for w in windows {
                #expect(w.inputStartSample % CtcAlignmentCore.strideSamples == 0)
                #expect(w.inputStartSample >= 0)
                #expect(w.inputEndSample <= samples)
                #expect(w.inputEndSample - w.inputStartSample <= input)
                #expect(w.localFirstFrame >= 0)
                #expect(w.localFirstFrame + w.keptFrames <= inputFrames)
                // Every frame's receptive field is real audio whenever the song fills a window: at most the 240
                // samples after the last frame's field (499 frames read 159 760 samples) are padding.
                if samples >= input { #expect(w.inputEndSample - w.inputStartSample >= 159_760) }
            }
        }
    }

    @Test func fixedWindowsKeepContextAwayFromTheEdges() {
        let samples = 3_840_000
        let total = CtcAlignmentCore.frameCount(samples: samples)
        let context = CtcAlignmentCore.fixedContextFrames
        for w in CtcAlignmentCore.fixedWindows(sampleCount: samples, inputSamples: 160_000) {
            #expect(w.localFirstFrame >= min(context, w.firstFrame))
            #expect(499 - (w.localFirstFrame + w.keptFrames) >= min(context, total - w.endFrame))
        }
        #expect(CtcAlignmentCore.fixedWindows(sampleCount: 399, inputSamples: 160_000).isEmpty)
    }

    // MARK: Alignment state (TaisLyricsPersistenceTest)

    @Test func partialWordTimingsRemainEligibleForRetry() {
        let lyrics = Lyrics(synced: [SyncedLine(time: 1000, line: "One", words: [SyncedWord(time: 1000, word: "One")]),
                                     SyncedLine(time: 2000, line: "Two")])
        guard case .lineSyncedOnly = TaisLyricsAlignment.alignmentState(for: lyrics) else {
            Issue.record("expected line-synced")
            return
        }
    }

    @Test func failedZeroTimeOutputIsNotMistakenForCompletedSync() {
        let lyrics = Lyrics(synced: [SyncedLine(time: 0, line: "One two", words: [SyncedWord(time: 0, word: "One"),
                                                                                 SyncedWord(time: 0, word: "two")])])
        guard case .lineSyncedOnly = TaisLyricsAlignment.alignmentState(for: lyrics) else {
            Issue.record("expected line-synced")
            return
        }
    }

    @Test func instrumentalBreakDoesNotInvalidateRealWordSync() {
        let lyrics = Lyrics(synced: [SyncedLine(time: 1000, line: "One", words: [SyncedWord(time: 1000, word: "One")]),
                                     SyncedLine(time: 2000, line: "")])
        #expect(TaisLyricsAlignment.alignmentState(for: lyrics) == .wordSynced)
    }

    @Test func explicitResyncKeepsRepeatedTextAndDropsBadAnchors() {
        let lyrics = Lyrics(plain: ["stale text"], synced: [
            SyncedLine(time: 90000, line: "Repeat", words: [SyncedWord(time: 90000, word: "Repeat")]),
            SyncedLine(time: 95000, line: "Repeat", words: [SyncedWord(time: 95000, word: "Repeat")]),
        ])
        #expect(TaisLyricsAlignment.alignmentState(for: lyrics) == .wordSynced)
        #expect(TaisLyricsAlignment.alignmentState(for: lyrics, forceResync: true) == .plainTextOnly(["Repeat", "Repeat"]))
    }

    @Test func explicitResyncOfLineLyricsIgnoresExistingAnchors() {
        #expect(TaisLyricsAlignment.alignmentState(for: Lyrics(synced: [SyncedLine(time: 99999, line: "Hello")]),
                                                   forceResync: true) == .plainTextOnly(["Hello"]))
    }

    @Test func resyncWithoutTextIsSkipped() {
        #expect(TaisLyricsAlignment.alignmentState(for: nil, forceResync: true) == .noLyrics)
        #expect(TaisLyricsAlignment.alignmentState(for: Lyrics(plain: [" "]), forceResync: true) == .noLyrics)
        #expect(TaisLyricsAlignment.alignmentState(for: nil) == .noLyrics)
        #expect(TaisLyricsAlignment.alignmentState(for: Lyrics(plain: ["a"])) == .plainTextOnly(["a"]))
    }

    @Test func unusableReplacementNeverPassesTheSaveCheck() {
        let invalid: [[SyncedLine]] = [
            [],
            [SyncedLine(time: 0, line: "Hello", words: [SyncedWord(time: 0, word: "Hello")])],
            [SyncedLine(time: 1000, line: "Hello world", words: [SyncedWord(time: 1000, word: "Hello"),
                                                                 SyncedWord(time: 500, word: "world")])],
        ]
        for lines in invalid {
            #expect(throws: TaisLyricsAlignment.Failure.noUsableTiming) { try TaisLyricsAlignment.validateForSave(lines) }
        }
        let valid = [SyncedLine(time: 1000, line: "Hello world", words: [SyncedWord(time: 1000, word: "Hello"),
                                                                         SyncedWord(time: 1500, word: "world")])]
        #expect(throws: Never.self) { try TaisLyricsAlignment.validateForSave(valid) }
    }

    // MARK: Assembly (forceAlign)

    @Test func targetWordsSplitOnAsciiWhitespaceAndSkipBlankLines() {
        let words = TaisLyricsAlignment.targetWords(lines: ["Hello  world", "", "\u{00A0}", "again\tand again"])
        #expect(words.map(\.word) == ["Hello", "world", "again", "and", "again"])
        #expect(words.map(\.lineIndex) == [0, 0, 3, 3, 3])
    }

    @Test func assembleBuildsLinesAndCarriesTimeOverSpacers() throws {
        let lines = ["Hello world", "", "Again"]
        let targets = TaisLyricsAlignment.targetWords(lines: lines)
        let timings = [AlignedWordTiming(word: "Hello", startMs: 1000, endMs: 1300),
                       AlignedWordTiming(word: "world", startMs: 1500, endMs: 1900),
                       AlignedWordTiming(word: "Again", startMs: 4000, endMs: 4400)]
        let out = try TaisLyricsAlignment.assemble(lines: lines, targetWords: targets, timings: timings,
                                                   totalDurationMs: 10_000)
        #expect(out.map(\.time) == [1000, 1500, 4000])
        #expect(out[1].words == nil)
        #expect(out[0].words?.map(\.time) == [1000, 1500])
        #expect(out[2].line == "Again")
    }

    @Test func assembleRejectsIncompleteAndInconsistentTimings() {
        let lines = ["a b"]
        let targets = TaisLyricsAlignment.targetWords(lines: lines)
        #expect(throws: TaisLyricsAlignment.Failure.incomplete) {
            try TaisLyricsAlignment.assemble(lines: lines, targetWords: targets,
                                             timings: [AlignedWordTiming(word: "a", startMs: 10, endMs: 20)],
                                             totalDurationMs: 100)
        }
        #expect(throws: TaisLyricsAlignment.Failure.incomplete) {
            try TaisLyricsAlignment.assemble(lines: lines, targetWords: targets,
                                             timings: [AlignedWordTiming(word: "a", startMs: 0, endMs: 0),
                                                       AlignedWordTiming(word: "b", startMs: 0, endMs: 0)],
                                             totalDurationMs: 100)
        }
        #expect(throws: TaisLyricsAlignment.Failure.inconsistent) {
            try TaisLyricsAlignment.assemble(lines: lines, targetWords: targets,
                                             timings: [AlignedWordTiming(word: "a", startMs: 50, endMs: 60),
                                                       AlignedWordTiming(word: "b", startMs: 40, endMs: 45)],
                                             totalDurationMs: 100)
        }
        #expect(throws: TaisLyricsAlignment.Failure.inconsistent) {
            try TaisLyricsAlignment.assemble(lines: lines, targetWords: targets,
                                             timings: [AlignedWordTiming(word: "a", startMs: 50, endMs: 60),
                                                       AlignedWordTiming(word: "b", startMs: 140, endMs: 145)],
                                             totalDurationMs: 100)
        }
    }

    // MARK: LyricsDoc output

    @Test func lyricsDocIsValidAndMarkedAsTais() throws {
        let lines = [
            SyncedLine(time: 1000, line: "Hello  world", words: [SyncedWord(time: 1000, word: "Hello", endTime: 1300),
                                                                 SyncedWord(time: 1500, word: "world", endTime: 1900)]),
            SyncedLine(time: 1900, line: ""),
            SyncedLine(time: 1950, line: "Same start", words: [SyncedWord(time: 1950, word: "Same", endTime: 1950),
                                                               SyncedWord(time: 1950, word: "start", endTime: 2600)]),
        ]
        let doc = TaisLyricsAlignment.lyricsDoc(lines: lines, totalDurationMs: 2700, title: "T", artist: "A")
        #expect(LyricsDocCodec.isValid(doc))
        #expect(doc.metadata.source == "tais")
        #expect(doc.lines.count == 2)
        #expect(doc.lines[0].text == "Hello world")
        #expect(doc.lines[0].syllables.map(\.text) == ["Hello ", "world"])
        #expect(doc.lines[0].syllables.map(\.startMs) == [1000, 1500])
        // "Hello" ends where "world" starts; "world" (last in its line) is capped at the next line's start.
        #expect(doc.lines[0].syllables.map(\.durationMs) == [500, 420])
        #expect(doc.lines[1].syllables.map(\.durationMs) == [1, 670])
        // Round trip through the codec keeps it.
        let decoded = try #require(LyricsDocCodec.decode(LyricsDocCodec.encode(doc)))
        #expect(decoded == doc)
    }

    @Test func lastWordGetsAMinimumLengthButNeverPassesTheSong() {
        let lines = [SyncedLine(time: 9950, line: "End", words: [SyncedWord(time: 9950, word: "End", endTime: 9960)])]
        let doc = TaisLyricsAlignment.lyricsDoc(lines: lines, totalDurationMs: 10_000)
        #expect(LyricsDocCodec.isValid(doc))
        #expect(doc.lines[0].syllables[0].durationMs == 50)
        let early = [SyncedLine(time: 100, line: "Hi", words: [SyncedWord(time: 100, word: "Hi", endTime: 120)])]
        #expect(TaisLyricsAlignment.lyricsDoc(lines: early, totalDurationMs: 10_000).lines[0].syllables[0].durationMs == 120)
    }
}
