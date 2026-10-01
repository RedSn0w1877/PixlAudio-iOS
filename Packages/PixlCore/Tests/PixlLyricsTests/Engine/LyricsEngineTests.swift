import Foundation
import Testing
import PixlModel
@testable import PixlLyrics

/// Port of `presentation/lyrics/LyricsEngineTest.kt` (all 16 cases), plus Swift-only tests of the change flags the
/// display-link driver relies on.
@Suite("LyricsEngine")
final class LyricsEngineTests {
    var positionMs: Int64 = 0
    var frameNanos: Int64 = 1_000_000_000
    let engine = LyricsEngine()

    let viewport: Float = 1_000
    let anchor: Float = 250
    let rowH: Float = 50

    init() {
        engine.setConfig(LyricsEngineConfig(density: 1, blurSupported: true, blurEnabled: true, blurStrength: 1))
    }

    /// 30 lead lines, one every 2 s from 1 s: row i == line i (no interludes).
    static func lyrics() -> PreparedLyrics {
        PreparedLyricsBuilder.build(Lyrics(synced: (0..<30).map { SyncedLine(time: 1_000 + $0 * 2_000, line: "line \($0)") }))!
    }

    var playing: Bool {
        get { engine.clock.isPlaying }
        set { engine.clock.isPlaying = newValue }
    }

    func install(animateIn: Bool = false) {
        let p = Self.lyrics()
        engine.setLyrics(p, animateIn: animateIn)
        engine.setViewport(height: viewport, anchor: anchor)
        for r in p.rows.indices { engine.setRowHeight(r, rowH) }
    }

    func frame() {
        engine.step(frameNanos: frameNanos, positionMs: positionMs)
    }

    /// Advances `ms` in 16 ms frames; the player advances with it while playing.
    func advance(_ ms: Int64) {
        var left = ms
        while left > 0 {
            let d = Swift.min(16, left)
            frameNanos += d * 1_000_000
            if playing { positionMs += d }
            frame()
            left -= d
        }
    }

    @Test func firstLayout_putsTheHotLineOnTheAnchor() {
        install()
        playing = true
        positionMs = 3_100 // line 1 is hot: [2750, 5000)
        frame()
        #expect(engine.isLaidOut)
        #expect(engine.scrollTargetRow == 1)
        #expect(abs(engine.rowY[1] - anchor) <= 0.01)
        #expect(abs(engine.rowY[0] - (anchor - rowH)) <= 0.01)
        #expect(abs(engine.rowY[2] - (anchor + rowH)) <= 0.01)
        #expect(engine.rowHot[1])
        #expect(!engine.rowHot[0])
        #expect(!engine.rowHot[2])
        #expect(engine.rowActiveness[1] == 1, "a rebuild snaps activeness")
    }

    @Test func hotSet_usesTheLeadIn() {
        install()
        playing = true
        positionMs = 4_749
        frame()
        #expect(!engine.isLineHot(2))
        advance(1)
        #expect(engine.isLineHot(2), "hot at start - 250")
        #expect(engine.isLineHot(1), "line 1 still hot until its end")
        #expect(engine.scrollTargetRow == 1, "lowest-index hot lead line wins")
        advance(251)
        #expect(!engine.isLineHot(1))
        #expect(engine.scrollTargetRow == 2)
    }

    @Test func targetChange_cascadesWithStaggeredDelays() {
        install()
        playing = true
        positionMs = 3_100
        frame()
        // Jump exactly as far as the frame clock moves: normal playback, not a seek.
        let jump = 5_001 - positionMs
        frameNanos += jump * 1_000_000
        positionMs += jump
        frame()
        let start = frameNanos
        #expect(engine.scrollTargetRow == 2)
        #expect(engine.rowPendingAtNanos(0) == -1, "row 0 moves at once")
        #expect(abs(Double(engine.rowPendingAtNanos(1) - (start + 50_000_000))) <= 1e6)
        #expect(abs(Double(engine.rowPendingAtNanos(2) - (start + 100_000_000))) <= 1e6)
        // The target row (2) still adds a full 50 ms step; the 1.05 decay starts after it.
        #expect(abs(Double(engine.rowPendingAtNanos(3) - (start + 150_000_000))) <= 1e6)
        #expect(abs(Double(engine.rowPendingAtNanos(4) - (start + 197_619_000))) <= 1e6)

        let row5Before = engine.rowY[5]
        advance(20)
        #expect(engine.rowY[5] == row5Before, "row 5 has not started yet")

        advance(3_000)
        let target = engine.scrollTargetRow
        #expect(abs(engine.rowY[target] - anchor) <= 0.3)
        #expect(engine.isAtRest || playing)
    }

    @Test func seek_retargetsWithoutStagger() {
        install()
        playing = true
        positionMs = 3_100
        frame()
        frameNanos += 16_000_000
        positionMs = 21_100 // far away: a seek
        frame()
        for r in 0..<30 { #expect(engine.rowPendingAtNanos(r) == -1, "row \(r)") }
        #expect(engine.scrollTargetRow == 10)
    }

    @Test func depthBlur_distancesFromTheHotLine() {
        install()
        playing = true
        positionMs = 5_100 // only line 2 hot
        frame()
        #expect(engine.scrollTargetRow == 2)
        #expect(engine.rowSigmaTargetDp(2) == 0)
        #expect(abs(engine.rowSigmaTargetDp(1) - 2.4) <= 1e-5, "just above")
        #expect(abs(engine.rowSigmaTargetDp(0) - 3.2) <= 1e-5)
        #expect(abs(engine.rowSigmaTargetDp(3) - 1.6) <= 1e-5, "next")
        #expect(abs(engine.rowSigmaTargetDp(4) - 2.4) <= 1e-5)
        #expect(abs(engine.rowSigmaTargetDp(20) - 5.0) <= 1e-5)
    }

    @Test func api30_usesTheAlphaFalloffInsteadOfBlur() {
        engine.setConfig(LyricsEngineConfig(density: 1, blurSupported: false))
        install()
        playing = true
        positionMs = 5_100
        frame()
        advance(600)
        #expect(engine.rowBlurRadiusPx[3] == 0)
        #expect(engine.rowBlurSigma[3] == 0)
        #expect(abs(engine.rowDepthAlpha[3] - 0.94) <= 1e-3)
        #expect(engine.rowDepthAlpha[2] == 1)
    }

    @Test func scale_inactiveLinesShrinkOnlyWhilePlaying() {
        install()
        playing = true
        positionMs = 5_100
        frame()
        advance(1_000) // t = 6100: line 2 is still the only hot line
        #expect(engine.scrollTargetRow == 2)
        #expect(abs(engine.rowScale[2] - 1) <= 1e-3)
        #expect(abs(engine.rowScale[5] - LyricsEngine.inactiveScale) <= 1e-3)

        playing = false
        advance(3_000)
        #expect(abs(engine.rowScale[5] - 1) <= 1e-3)
    }

    @Test func userScroll_dragClampsRemovesBlurAndSnapsBackAfterIdle() {
        install()
        playing = false
        positionMs = 5_100
        frame()
        advance(500)
        #expect(engine.rowSigmaTargetDp(0) > 0)

        engine.onDragStart()
        engine.onDrag(-100)
        #expect(engine.scrollOffset == -100)
        #expect(engine.isUserScrolling)
        engine.onDrag(10_000) // the first line may not go below the anchor
        #expect(abs(engine.scrollOffset - 2 * rowH) <= 0.01)
        engine.onDragEnd(velocity: 0)

        advance(300)
        #expect(engine.rowSigmaTargetDp(0) == 0, "no blur while scrolling")
        #expect(engine.rowBlurRadiusPx[0] == 0)

        advance(4_000)
        #expect(engine.isUserScrolling, "still waiting before 4.5 s")
        advance(400)
        #expect(!engine.isUserScrolling, "snapped back after 4.5 s")
        #expect(engine.scrollOffset == 0)
        // The folded offset animates back with the slow spring.
        advance(3_000)
        #expect(abs(engine.rowY[2] - anchor) <= 0.3)
        #expect(engine.rowSigmaTargetDp(0) > 0)
    }

    @Test func fling_coastsAndStopsAtTheClamp() {
        install()
        playing = false
        positionMs = 5_100
        frame()
        engine.onDragStart()
        engine.onDrag(-10)
        engine.onDragEnd(velocity: -5_000)
        advance(32) // the fling starts on the first frame and has moved by the second
        let early = engine.scrollOffset
        #expect(early < -10)
        advance(3_000)
        let minOffset = 0.5 * viewport - (anchor - 2 * rowH + 30 * rowH)
        #expect(engine.scrollOffset >= minOffset - 0.01)
        #expect(engine.scrollOffset < early)
    }

    @Test func seek_endsUserScroll() {
        install()
        playing = true
        positionMs = 5_100
        frame()
        engine.onDragStart()
        engine.onDrag(-200)
        engine.onDragEnd(velocity: 0)
        advance(100)
        #expect(engine.isUserScrolling)
        frameNanos += 16_000_000
        positionMs = 40_000
        frame()
        #expect(!engine.isUserScrolling)
        #expect(engine.scrollOffset == 0)
    }

    @Test func animateIn_startsBelowAndCascadesUp() {
        install(animateIn: true)
        playing = true
        positionMs = 3_100
        frame()
        #expect(abs(engine.rowY[1] - 2 * viewport) <= 1, "starts at 2 × viewport")
        #expect(engine.isPlaced(1))
        advance(3_000)
        #expect(abs(engine.rowY[engine.scrollTargetRow] - anchor) <= 0.3)
    }

    @Test func reducedMotion_snaps() {
        engine.setConfig(LyricsEngineConfig(density: 1, reducedMotion: true))
        install()
        playing = true
        positionMs = 3_100
        frame()
        let jump = 5_001 - positionMs
        frameNanos += jump * 1_000_000
        positionMs += jump
        frame()
        #expect(abs(engine.rowY[2] - anchor) <= 0.01)
        #expect(engine.rowPendingAtNanos(5) == -1)
    }

    @Test func pausedAndSettled_isAtRest() {
        install()
        playing = false
        positionMs = 5_100
        frame()
        advance(1_000)
        #expect(engine.isAtRest)
        #expect(!engine.needsFrame)
    }

    // MARK: window-first measuring

    @Test func predictedTarget_matchesTheFirstLayoutsTarget() {
        let p = Self.lyrics()
        engine.setLyrics(p, animateIn: true)
        engine.setViewport(height: viewport, anchor: anchor)
        playing = true
        positionMs = 25_100 // line 12 hot
        #expect(engine.layoutAnchorRow == -1)
        let predicted = engine.predictScrollTargetRow(positionMs)
        for r in p.rows.indices { engine.setRowHeight(r, rowH) }
        frame()
        #expect(predicted == 12)
        #expect(engine.scrollTargetRow == predicted)
        #expect(engine.layoutAnchorRow == predicted)
    }

    @Test func estimatedHeightsOutsideTheWindow_leaveTheVisibleCascadeUnchanged() {
        let margin = LyricsEngine.snapMarginDp // density 1
        let real = (0..<30).map { Float(40 + ($0 * 37 % 60)) }
        let target = 12
        // The view's window: down past the viewport bottom (+ the anchor row), up past -margin.
        var inWindow = [Bool](repeating: false, count: 30)
        var y = anchor
        var r = target
        while r < 30 && y <= viewport + real[target] { inWindow[r] = true; y += real[r]; r += 1 }
        y = anchor
        r = target - 1
        while r >= 0 && y >= -margin { inWindow[r] = true; y -= real[r]; r -= 1 }
        #expect(!inWindow[0] && !inWindow[29], "rows are left out above and below")

        func run(_ heights: (Int) -> Float) -> LyricsEngine {
            var pos: Int64 = 25_100
            let e = LyricsEngine()
            e.clock.isPlaying = true
            e.setConfig(LyricsEngineConfig(density: 1))
            e.setLyrics(Self.lyrics(), animateIn: true)
            e.setViewport(height: viewport, anchor: anchor)
            for i in 0..<30 { e.setRowHeight(i, heights(i)) }
            var nanos: Int64 = 1_000_000_000
            e.step(frameNanos: nanos, positionMs: pos)
            // A few frames into the cascade, still on the estimates.
            for _ in 0..<20 {
                nanos += 16_000_000
                pos += 16
                e.step(frameNanos: nanos, positionMs: pos)
            }
            return e
        }
        let exact = run { real[$0] }
        let estimated = run { inWindow[$0] ? real[$0] : 55 }
        #expect(estimated.scrollTargetRow == target)
        for i in 0..<30 {
            if inWindow[i] {
                #expect(abs(exact.rowSpringY(i) - estimated.rowSpringY(i)) <= 0.001, "row \(i) y")
                #expect(exact.rowPendingAtNanos(i) == estimated.rowPendingAtNanos(i), "row \(i) delay")
            } else {
                for e in [exact, estimated] {
                    let top = e.rowSpringY(i)
                    #expect(top + real[i] < 0 || top > viewport, "row \(i) off-screen")
                }
            }
        }
    }

    // MARK: clock

    @Test func clock_monotonicGuardAndSeekDetection() {
        var pos: Int64 = 10_000
        var offset: Int64 = 0
        var c = LyricsClock()
        c.isPlaying = true
        var f: Int64 = 0
        do { let result = c.tick(frameNanos: f, positionMs: pos, offsetMs: offset); #expect(!result) }
        #expect(c.currentMs == 10_000)

        f += 16_000_000; pos = 9_960 // 40 ms backwards: jitter, rejected
        do { let result = c.tick(frameNanos: f, positionMs: pos, offsetMs: offset); #expect(!result) }
        #expect(c.currentMs == 10_000)

        f += 16_000_000; pos = 9_900 // 100 ms backwards: accepted, not a seek
        do { let result = c.tick(frameNanos: f, positionMs: pos, offsetMs: offset); #expect(!result) }
        #expect(c.currentMs == 9_900)

        f += 16_000_000; pos = 20_000
        do { let result = c.tick(frameNanos: f, positionMs: pos, offsetMs: offset); #expect(result) }
        do { let result = c.consumeSeek(); #expect(result) }
        do { let result = c.consumeSeek(); #expect(!result) }
        #expect(c.seekCount == 1)

        c.isPlaying = false
        f += 16_000_000; pos = 19_980 // paused: no guard
        c.tick(frameNanos: f, positionMs: pos, offsetMs: offset)
        #expect(c.currentMs == 19_980)

        offset = 300
        f += 16_000_000
        c.tick(frameNanos: f, positionMs: pos, offsetMs: offset)
        #expect(c.currentMs == 20_280)
    }

    @Test func clock_predictionFollowsElapsedTimeWhilePlaying() {
        var c = LyricsClock()
        c.isPlaying = true
        c.tick(frameNanos: 0, positionMs: 0)
        // 3 s of frames later the player is 3 s ahead: not a seek.
        do { let result = c.tick(frameNanos: 3_000_000_000, positionMs: 3_000); #expect(!result) }
        #expect(c.currentMs == 3_000)
    }

    // MARK: Swift-only: change flags for the display-link driver

    @Test func changeFlagsReportOnlyMovedRowsAndAccumulateUntilCleared() {
        install()
        playing = true
        positionMs = 5_100
        frame()
        #expect(engine.changes.contains(.rows))
        #expect(engine.changedRows.count == 30, "first layout positions every row")
        #expect(engine.rowChanges[2].contains(.y))
        #expect(engine.rowChanges[2].contains(.hot))
        engine.clearChanges()
        #expect(engine.changedRows.isEmpty)
        #expect(engine.changes.isEmpty)

        // Gestures between frames set flags that survive until cleared.
        engine.onDragStart()
        engine.onDrag(-30)
        #expect(engine.changes.contains(.scrollOffset))
        #expect(engine.changes.contains(.userScrolling))
        advance(16)
        #expect(engine.changes.contains(.scrollOffset), "not cleared by step")
        for r in engine.changedRows { #expect(!engine.rowChanges[r].isEmpty) }
        engine.clearChanges()
    }

    @Test func settledEngineReportsNoChanges() {
        install()
        playing = false
        positionMs = 5_100
        frame()
        advance(2_000)
        engine.clearChanges()
        advance(100)
        #expect(engine.changedRows.isEmpty)
        #expect(engine.isAtRest)
    }

    @Test func sigmaOutputIsQuantisedStrengthScaledSigma() {
        engine.setConfig(LyricsEngineConfig(density: 3, blurStrength: 1.2, blurSigmaQuantum: 0.3))
        install()
        playing = true
        positionMs = 5_100
        frame()
        advance(1_000) // σ tweens have finished
        // Row 4 is two lead rows below the hot line: 2.4 × 1.2 = 2.88 → 3.0 at a 0.3 quantum.
        #expect(abs(engine.rowBlurSigma[4] - 3.0) <= 1e-5)
        #expect(engine.rowBlurSigma[2] == 0)
        // The Android radius output stays Skia's: (2.88·3 − 0.5)/0.57735 = 14.10 → 13.5 px.
        #expect(engine.rowBlurRadiusPx[4] == 13.5)
    }

    @Test func equalModelIsIgnoredAndHitTestingUsesPublishedRows() {
        install()
        playing = true
        positionMs = 5_100
        frame()
        engine.clearChanges()
        engine.setLyrics(Self.lyrics(), animateIn: true) // equal model: no reinstall
        #expect(!engine.changes.contains(.rows))
        #expect(engine.hitRow(y: anchor + 1) == 2)
        #expect(engine.hitRow(y: anchor - 1) == 1)
        #expect(engine.hitRow(y: -10_000) == -1)
        #expect(engine.hitRow(y: anchor + 1, isMeasured: { $0 != 2 }) == -1)
    }

    @Test func emptyLyricsAreAtRest() {
        engine.setLyrics(nil, animateIn: false)
        engine.step(frameNanos: 1, positionMs: 0)
        #expect(engine.isAtRest)
        #expect(engine.rowCount == 0)
        #expect(!engine.needsFrame)
    }
}
