import Foundation
import Testing
@testable import PixlAudioCore

/// Port of `data/tais/lyrics/CtcAlignmentCoreTest` (all 8 cases) plus Swift-only checks.
@Suite("CtcAlignmentCore")
struct CtcAlignmentCoreTests {
    static func emission(_ tokens: Int...) -> [[Float]] {
        tokens.map { token in (0..<3).map { $0 == token ? -0.01 : -12 } }
    }

    @Test func longIntroAndOutroStayBlank() throws {
        let path = try #require(try CtcAlignmentCore.align(logProbs: Self.emission(0, 0, 0, 0, 1, 1, 0, 2, 0, 0),
                                                           extended: [0, 1, 0, 2, 0]))
        #expect(path.firstIndex(of: 1) == 4)
        #expect(path.firstIndex(of: 3) == 7)
        #expect(path.prefix(4).allSatisfy { $0 == 0 })
        #expect(path.suffix(2).allSatisfy { $0 == 4 })
    }

    @Test func interludeDoesNotPullNextLyricForward() throws {
        let path = try #require(try CtcAlignmentCore.align(logProbs: Self.emission(1, 0, 0, 0, 0, 2), extended: [0, 1, 0, 2, 0]))
        #expect(path.firstIndex(of: 3) == 5)
    }

    @Test func vocalsMayBeginOnTheFirstFrame() throws {
        #expect(try CtcAlignmentCore.align(logProbs: Self.emission(1), extended: [0, 1, 0]) == [1])
    }

    @Test func repeatedSymbolsRequireASeparatingBlank() throws {
        #expect(try CtcAlignmentCore.align(logProbs: Self.emission(1, 1), extended: [0, 1, 0, 1, 0]) == nil)
        let path = try CtcAlignmentCore.align(logProbs: Self.emission(1, 0, 1), extended: [0, 1, 0, 1, 0])
        #expect(path == [1, 2, 3])
    }

    @Test func overlapTrimmingCoversEveryAudioFrameExactlyOnce() {
        for samples in [400, 719, 720, 256001, 320000, 2858256] {
            let windows = CtcAlignmentCore.windows(sampleCount: samples)
            let kept = windows.flatMap { Array($0.firstFrame..<$0.endFrame) }
            #expect(kept == Array(0..<((samples - 400) / 320 + 1)))
            for w in windows {
                #expect(w.inputStartSample >= 0 && w.inputEndSample <= samples)
                #expect(w.inputStartSample % 320 == 0)
                let produced = (w.inputEndSample - w.inputStartSample - 400) / 320 + 1
                #expect(w.localFirstFrame + w.keptFrames <= produced)
                #expect(w.inputEndSample - w.inputStartSample <= 320080)
            }
        }
        #expect(CtcAlignmentCore.windows(sampleCount: 399).isEmpty)
    }

    @Test func largePathIsRejectedBeforeAllocation() {
        let logProbs = [[Float]](repeating: [0, -1], count: 10000)
        #expect(throws: CtcAlignmentError.tooLong) {
            try CtcAlignmentCore.align(logProbs: logProbs, extended: [Int](repeating: 0, count: 10001))
        }
    }

    @Test func longAlignmentCooperatesWithCancellation() {
        // emission(*IntArray(100)): 100 frames of token 0.
        let emissions = [[Float]](repeating: [-0.01, -12, -12], count: 100)
        #expect(throws: CancellationError.self) {
            try CtcAlignmentCore.align(logProbs: emissions, extended: [0, 1, 0]) { throw CancellationError() }
        }
    }

    @Test func weakAcousticMatchesAreNotAcceptedJustBecauseTimingsIncrease() {
        #expect(!CtcAlignmentCore.acceptsWordEvidence([0.1, 0.2, 0.15, 0.3]))
        #expect(!CtcAlignmentCore.acceptsWordEvidence([0.95, 0.95, 0.05, 0.05]))
        #expect(!CtcAlignmentCore.acceptsWordEvidence([.nan]))
        #expect(CtcAlignmentCore.acceptsWordEvidence([0.8, 0.7, 0.85, 0.9]))
    }

    // Swift-only.

    @Test func emptyInputsAndTooFewFramesGiveNoPath() throws {
        #expect(try CtcAlignmentCore.align(logProbs: [], extended: [0]) == nil)
        #expect(try CtcAlignmentCore.align(logProbs: Self.emission(0), extended: []) == nil)
        // 5 tokens need at least 4 frames ((11 - 1) / 2 = 5 > 4).
        #expect(try CtcAlignmentCore.align(logProbs: Self.emission(0, 1, 0, 2), extended: [0, 1, 0, 2, 0, 1, 0, 2, 0, 1, 0]) == nil)
        #expect(!CtcAlignmentCore.acceptsWordEvidence([]))
    }

    @Test func outOfRangeTokensThrowInsteadOfTrapping() {
        #expect(throws: CtcAlignmentError.invalidToken(index: 1, token: 7)) {
            try CtcAlignmentCore.align(logProbs: Self.emission(0, 1), extended: [0, 7, 0])
        }
        let flat: [Float] = [0, -1, -2, 0, -1, -2]
        #expect(throws: CtcAlignmentError.invalidToken(index: 0, token: -1)) {
            try flat.withUnsafeBufferPointer {
                try CtcAlignmentCore.align(logProbs: $0, vocabularySize: 3, extended: [-1])
            }
        }
    }

    @Test func flatBufferMatchesRows() throws {
        let rows = Self.emission(0, 0, 1, 1, 0, 2, 2, 0)
        let flat = rows.flatMap { $0 }
        let a = try CtcAlignmentCore.align(logProbs: rows, extended: [0, 1, 0, 2, 0])
        let b = try flat.withUnsafeBufferPointer {
            try CtcAlignmentCore.align(logProbs: $0, vocabularySize: 3, extended: [0, 1, 0, 2, 0])
        }
        #expect(a != nil && a == b)
    }

    @Test func windowsForAShortClipAndTheConstants() {
        #expect(CtcAlignmentCore.windows(sampleCount: 400) == [
            CtcAlignmentCore.Window(firstFrame: 0, endFrame: 1, inputStartSample: 0, inputEndSample: 400),
        ])
        #expect(CtcAlignmentCore.strideSamples == 320 && CtcAlignmentCore.receptiveSamples == 400)
        #expect(CtcAlignmentCore.maxPathCells == 67_108_864)
    }
}
