import Foundation
import Testing
@testable import PixlLyrics

/// Sing's preview piece on the player side: when it may start, what happens while it plays (it runs out, a seek leaves
/// it, the whole instrumental lands) and how the way back fits before its end.
@Suite struct SingClipPolicyTests {
    // A clip of [87 s, 150 s) in a 4-minute song.
    private let start: Int64 = 87_000
    private let end: Int64 = 150_000
    private let song: Int64 = 240_000

    private func step(_ position: Int64, full: Bool = false, end: Int64? = nil) -> SingClipPolicy.Step {
        SingClipPolicy.step(positionMs: position, clipStartMs: start, clipEndMs: end ?? self.end, songDurationMs: song,
                            fullReady: full)
    }

    // MARK: Starting

    @Test func theClipStartsOnlyInsideItWithEnoughOfItLeft() {
        #expect(SingClipPolicy.canStart(positionMs: 90_000, clipStartMs: start, clipEndMs: end, songDurationMs: song))
        #expect(!SingClipPolicy.canStart(positionMs: 86_000, clipStartMs: start, clipEndMs: end, songDurationMs: song),
                "before it (a seek back)")
        // The way back starts 2 s before the end; at least 3 s of the clip must come before that.
        #expect(SingClipPolicy.canStart(positionMs: 144_999, clipStartMs: start, clipEndMs: end, songDurationMs: song))
        #expect(!SingClipPolicy.canStart(positionMs: 145_000, clipStartMs: start, clipEndMs: end, songDurationMs: song))
        #expect(!SingClipPolicy.canStart(positionMs: 160_000, clipStartMs: start, clipEndMs: end, songDurationMs: song))
    }

    @Test func aClipThatReachesTheSongsEndMayStartUntilASecondBeforeIt() {
        #expect(SingClipPolicy.reachesSongEnd(clipEndMs: 239_600, songDurationMs: song))
        #expect(!SingClipPolicy.reachesSongEnd(clipEndMs: 239_000, songDurationMs: song))
        #expect(SingClipPolicy.canStart(positionMs: 238_500, clipStartMs: 197_000, clipEndMs: song, songDurationMs: song))
        #expect(!SingClipPolicy.canStart(positionMs: 239_000, clipStartMs: 197_000, clipEndMs: song, songDurationMs: song))
    }

    // MARK: While it plays

    @Test func theClipPlaysOnInsideItsRange() {
        #expect(step(87_000) == .stay)
        #expect(step(120_000) == .stay)
        #expect(step(147_999) == .stay)
    }

    @Test func beforeItRunsOutTheSongComesBackAtAGap() {
        #expect(step(148_000) == .leaveAtGap, "2 s before the end")
        #expect(step(149_900) == .leaveAtGap)
        #expect(step(150_300) == .leaveAtGap, "a little past the end is still the end, not a seek")
    }

    @Test func aSeekOutsideTheClipBringsTheSongBackAtOnce() {
        #expect(step(30_000) == .leaveNow)
        #expect(step(86_600) == .leaveNow)
        #expect(step(86_800) == .stay, "within the tolerance of its start")
        #expect(step(200_000) == .leaveNow)
    }

    @Test func aClipThatReachesTheSongsEndPlaysToIt() {
        #expect(step(238_500, end: song) == .stay)
        #expect(step(239_900, end: song) == .stay)
        #expect(step(20_000, end: song) == .leaveNow, "a seek out of it still brings the song back")
    }

    @Test func theWholeInstrumentalAlwaysTakesOver() {
        #expect(step(120_000, full: true) == .swapToFull)
        #expect(step(149_000, full: true) == .swapToFull, "even as the clip runs out")
        #expect(step(30_000, full: true) == .swapToFull, "and after a seek out of it: it covers the whole song")
    }

    // MARK: The way back

    @Test func aGapThatEndsInTimeIsKept() {
        let planned = SingSwitchPlanner.Placement(startPlayerMs: 148_600, fadeMs: 500, reason: .nextGap)
        #expect(SingClipPolicy.fallbackPlacement(planned, earliestPlayerMs: 148_450, clipEndMs: end) == planned)
    }

    @Test func aGapTooLateGivesWayToAFadeThatStillFits() {
        let planned = SingSwitchPlanner.Placement(startPlayerMs: 149_400, fadeMs: 700, reason: .nextGap)
        let fitted = SingClipPolicy.fallbackPlacement(planned, earliestPlayerMs: 149_000, clipEndMs: end)
        #expect(fitted.startPlayerMs == 149_000)
        #expect(fitted.fadeMs == 700, "149.0 + 0.7 is before 149.9")
        let late = SingClipPolicy.fallbackPlacement(planned, earliestPlayerMs: 149_500, clipEndMs: end)
        #expect(late.startPlayerMs == 149_500)
        #expect(late.fadeMs == 400)
        let tooLate = SingClipPolicy.fallbackPlacement(planned, earliestPlayerMs: 149_800, clipEndMs: end)
        #expect(tooLate.fadeMs == SingSwitchPlanner.minFadeMs, "never under the shortest fade")
        #expect(tooLate.reason == .noGapInWindow)
    }
}
