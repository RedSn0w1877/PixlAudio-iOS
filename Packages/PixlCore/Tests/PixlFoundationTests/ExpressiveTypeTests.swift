import Testing
@testable import PixlFoundation

@Suite struct ExpressiveTypeTests {
    // MARK: Stops

    @Test func widthStopsStepAndClamp() {
        #expect(TypeWidthStop.expanded.narrowed(by: 1) == .standard)
        #expect(TypeWidthStop.expanded.narrowed(by: 9) == .compressed)
        #expect(TypeWidthStop.condensed.narrowed(by: -1) == .standard)
        #expect(TypeWidthStop.expanded.narrowed(by: 3, within: .condensed ... .expanded) == .condensed)
        #expect(TypeWidthStop.compressed < .expanded)
    }

    @Test func weightStopsStepAndClamp() {
        #expect(TypeWeightStop.black.lightened(by: 2) == .bold)
        #expect(TypeWeightStop.thin.lightened(by: 5) == .ultraLight)
        #expect(TypeWeightStop.bold.lightened(by: -9) == .black)
        #expect(TypeWeightStop.heavy.lightened(by: 4, within: .semibold ... .black) == .semibold)
    }

    // MARK: Fit by width

    /// SF Pro-like advances: each stop narrower than the next.
    private static let ratios: [TypeWidthStop: Double] = [.compressed: 0.72, .condensed: 0.84, .standard: 1,
                                                          .expanded: 1.18]

    private func measurer(line: Double, word: Double, log: Box? = nil) -> (TypeWidthStop) -> WidthFit.Measurement {
        { stop in
            log?.stops.append(stop)
            let ratio = Self.ratios[stop] ?? 1
            return WidthFit.Measurement(line: line * ratio, longestWord: word * ratio)
        }
    }

    final class Box { var stops: [TypeWidthStop] = [] }

    @Test func shortTitleStaysExpandedAndMeasuresOnce() {
        let log = Box()
        let stop = WidthFit.widestFitting(available: 300, lines: 1, measure: measurer(line: 200, word: 120, log: log))
        #expect(stop == .expanded)
        #expect(log.stops == [.expanded])
    }

    @Test func longTitleStepsDownUntilItFits() {
        // 300 pt standard: expanded 354 (no), standard 300 (yes).
        #expect(WidthFit.widestFitting(available: 300, lines: 1, measure: measurer(line: 300, word: 100)) == .standard)
        // 400 pt standard: condensed 336 (no), compressed 288 (yes).
        let log = Box()
        let stop = WidthFit.widestFitting(available: 300, lines: 1, measure: measurer(line: 400, word: 100, log: log))
        #expect(stop == .compressed)
        #expect(log.stops == [.expanded, .standard, .condensed, .compressed])
    }

    @Test func nothingFitsFallsBackToNarrowestOfRange() {
        #expect(WidthFit.widestFitting(available: 100, lines: 1, measure: measurer(line: 900, word: 900)) == .compressed)
        #expect(WidthFit.widestFitting(available: 100, lines: 1, range: .condensed ... .expanded,
                                       measure: measurer(line: 900, word: 900)) == .condensed)
    }

    @Test func rangeCapsTheWidestStop() {
        let log = Box()
        let stop = WidthFit.widestFitting(available: 300, lines: 1, range: .compressed ... .standard,
                                          measure: measurer(line: 100, word: 50, log: log))
        #expect(stop == .standard)
        #expect(log.stops == [.standard])
    }

    @Test func multiLineNeedsTheLongestWordOnOneLineAndRoomForBreaks() {
        // Two lines of 300: the line may use 0.88 × 600 = 528; the longest word must fit 300.
        #expect(WidthFit.fits(.init(line: 520, longestWord: 280), available: 300, lines: 2))
        #expect(!WidthFit.fits(.init(line: 540, longestWord: 280), available: 300, lines: 2))
        #expect(!WidthFit.fits(.init(line: 320, longestWord: 310), available: 300, lines: 2))
        // A long single word steps down even when two lines would hold the total.
        #expect(WidthFit.widestFitting(available: 300, lines: 2, measure: measurer(line: 300, word: 300)) == .standard)
    }

    @Test func zeroWidthNeverFits() {
        #expect(!WidthFit.fits(.init(line: 0, longestWord: 0), available: 0, lines: 1))
    }

    // MARK: Collapse stops

    @Test func collapseStopsFollowEqualBands() {
        var stops = CollapseStops(count: 3, hysteresis: 0)
        #expect(stops.update(fraction: 0.2) == nil)
        #expect(stops.update(fraction: 0.34) == 1)
        #expect(stops.update(fraction: 0.6) == nil)
        #expect(stops.update(fraction: 1) == 2)
        #expect(stops.update(fraction: 0) == 0)
    }

    @Test func hysteresisHoldsAStopOnItsEdge() {
        var stops = CollapseStops(count: 3, hysteresis: 0.05)
        // Edge into stop 1 at 1/3: needs 0.3833.
        #expect(stops.update(fraction: 0.35) == nil)
        #expect(stops.update(fraction: 0.39) == 1)
        // Wobbling back just under the edge keeps stop 1 …
        #expect(stops.update(fraction: 0.31) == nil)
        #expect(stops.index == 1)
        // … until it is clearly below it.
        #expect(stops.update(fraction: 0.28) == 0)
    }

    @Test func aFastJumpLandsOnTheFurthestClearedStop() {
        var stops = CollapseStops(count: 4, hysteresis: 0.05)
        // Bands at 0.25 / 0.5 / 0.75. 0.78 is in band 3 but only 0.03 past its edge: stop 2.
        #expect(stops.update(fraction: 0.78) == 2)
        #expect(stops.update(fraction: 1) == 3)
        // Straight back to the top.
        #expect(stops.update(fraction: 0) == 0)
    }

    @Test func collapseStopsClampInputsAndConfiguration() {
        var stops = CollapseStops(count: 2, hysteresis: 0.9)
        #expect(stops.hysteresis < 0.25)
        #expect(stops.update(fraction: 7) == 1)
        #expect(stops.update(fraction: -3) == 0)
        var single = CollapseStops(count: 0)
        #expect(single.count == 1)
        #expect(single.update(fraction: 1) == nil)
        stops.reset(fraction: 0.9)
        #expect(stops.index == 1)
    }

    // MARK: Scroll collapse

    @Test func scrollFractionClampsAndQuantizes() {
        #expect(ScrollCollapse.fraction(offset: -40, distance: 200) == 0)
        #expect(ScrollCollapse.fraction(offset: 500, distance: 200) == 1)
        #expect(abs(ScrollCollapse.fraction(offset: 102.4, distance: 200) - 0.51) < 1e-9)
        #expect(abs(ScrollCollapse.fraction(offset: 100.6, distance: 200) - 0.5) < 1e-9)
        #expect(abs(ScrollCollapse.fraction(offset: 150, start: 100, distance: 100, quantum: 0.25) - 0.5) < 1e-9)
        #expect(ScrollCollapse.fraction(offset: 10, start: 20, distance: 0) == 0)
        #expect(ScrollCollapse.fraction(offset: 20, start: 20, distance: 0) == 1)
    }

    @Test func lerpInterpolates() {
        #expect(ScrollCollapse.lerp(46, 17, 0) == 46)
        #expect(ScrollCollapse.lerp(46, 17, 1) == 17)
        #expect(ScrollCollapse.lerp(0, 10, 0.5) == 5)
    }
}
