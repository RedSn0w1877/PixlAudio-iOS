import Testing
@testable import PixlFoundation

@Suite struct PlaybackProgressTests {
    @Test func displayDurationTrustsAgreeingPlayer() {
        #expect(PlaybackProgress.displayDuration(reportedMs: 200_500, hintMs: 200_000) == 200_500)
    }

    @Test func displayDurationTakesTheShorterWhenTheyDisagree() {
        // A stream estimate twice the song's length must not stretch the bar (the lyrics bar stopped at the middle).
        #expect(PlaybackProgress.displayDuration(reportedMs: 400_000, hintMs: 200_000) == 200_000)
        #expect(PlaybackProgress.displayDuration(reportedMs: 100_000, hintMs: 200_000) == 100_000)
    }

    @Test func displayDurationFallsBackToWhicheverIsKnown() {
        #expect(PlaybackProgress.displayDuration(reportedMs: 0, hintMs: 180_000) == 180_000)
        #expect(PlaybackProgress.displayDuration(reportedMs: 180_000, hintMs: 0) == 180_000)
        #expect(PlaybackProgress.displayDuration(reportedMs: 0, hintMs: 0) == 0)
        #expect(PlaybackProgress.displayDuration(reportedMs: -5, hintMs: -5) == 0)
    }

    @Test func fractionIsClamped() {
        #expect(PlaybackProgress.fraction(positionMs: 50, durationMs: 100) == 0.5)
        #expect(PlaybackProgress.fraction(positionMs: 150, durationMs: 100) == 1)
        #expect(PlaybackProgress.fraction(positionMs: -10, durationMs: 100) == 0)
        #expect(PlaybackProgress.fraction(positionMs: 10, durationMs: 0) == 0)
    }
}
