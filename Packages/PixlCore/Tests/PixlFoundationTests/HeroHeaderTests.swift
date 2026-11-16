import Testing
@testable import PixlFoundation

@Suite struct HeroHeaderTests {
    @Test func portraitPhoneGetsTheMockupProportion() {
        // 390 pt wide → a little taller than square (the mockup's 360 pt plus room for the status bar).
        #expect(HeroHeader.height(width: 390, viewportHeight: 844) == 424)
        #expect(HeroHeader.height(width: 430, viewportHeight: 932) == 467)
    }

    @Test func landscapeAndTinyViewportsAreClamped() {
        // Landscape: capped at 60 % of the viewport, but never below the minimum.
        #expect(HeroHeader.height(width: 844, viewportHeight: 390) == 300)
        // A large screen: the cap wins over width / aspect.
        #expect(HeroHeader.height(width: 1024, viewportHeight: 1366) == 820)
        // Unknown viewport: the natural height.
        #expect(HeroHeader.height(width: 390, viewportHeight: 0) == 424)
        // Degenerate width.
        #expect(HeroHeader.height(width: 0, viewportHeight: 844) == 300)
    }

    @Test func overlayIsPinnedToTheHeroBottom() {
        #expect(HeroHeader.overlayTop(heroHeight: 424, overlayHeight: 180) == 244)
        // A block taller than the hero starts at the top.
        #expect(HeroHeader.overlayTop(heroHeight: 300, overlayHeight: 420) == 0)
    }

    @Test func titleCollapsesWhileItPassesUnderTheBar() {
        // Title 92 pt tall at 244, bar bottom at 115 (59 safe area + 56): starts at 244 - 115 - 48 = 81, done when the
        // title's bottom (336) reaches the bar (scrolled 221).
        let window = HeroHeader.titleCollapse(titleTop: 244, titleHeight: 92, barBottom: 115)
        #expect(window.start == 81)
        #expect(window.start + window.distance == 221)
    }

    @Test func titleCollapseNeverStartsAboveThePage() {
        // A title already near the bar: the window starts at the top and still ends when it is under the bar.
        let window = HeroHeader.titleCollapse(titleTop: 100, titleHeight: 46, barBottom: 115)
        #expect(window.start == 0)
        #expect(window.distance == 31)
        // A title already under the bar: a 1 pt window (collapses at once).
        let under = HeroHeader.titleCollapse(titleTop: 20, titleHeight: 40, barBottom: 115)
        #expect(under.start == 0)
        #expect(under.distance == 1)
    }

    @Test func scrollEffectStretchesOnPullAndTrailsOnScroll() {
        #expect(HeroHeader.scrollEffect(minY: 0, height: 424) == .init(scale: 1, offset: 0))
        // Pulled down 106 pt: grows by exactly the pull from its bottom edge.
        let pulled = HeroHeader.scrollEffect(minY: 106, height: 424)
        #expect(pulled.scale == 1.25)
        #expect(pulled.offset == 0)
        // Scrolled up 100 pt: trails by 30 %.
        #expect(HeroHeader.scrollEffect(minY: -100, height: 424) == .init(scale: 1, offset: 30))
        // Parallax is clamped; bad input is inert.
        #expect(HeroHeader.scrollEffect(minY: -100, height: 424, parallax: 2).offset == 100)
        #expect(HeroHeader.scrollEffect(minY: .nan, height: 424) == .init(scale: 1, offset: 0))
        #expect(HeroHeader.scrollEffect(minY: 50, height: 0) == .init(scale: 1, offset: 0))
    }

    @Test func summaryUsesTheAppsWording() {
        #expect(HeroHeader.summary(songs: 12, albums: 3) == "12 Songs · 3 Albums")
        #expect(HeroHeader.summary(songs: 1, albums: 1) == "1 Song · 1 Album")
        #expect(HeroHeader.summary(songs: 4, albums: 0) == "4 Songs")
        #expect(HeroHeader.summary(songs: -2, albums: 0) == "0 Songs")
    }

    @Test func playsAreShortAndSingularAware() {
        #expect(HeroHeader.plays(0) == nil)
        #expect(HeroHeader.plays(1) == "1 play")
        #expect(HeroHeader.plays(12) == "12 plays")
        #expect(HeroHeader.plays(1_234) == "1.2K plays")
        #expect(HeroHeader.compact(999) == "999")
        #expect(HeroHeader.compact(1_000) == "1K")
        #expect(HeroHeader.compact(12_345) == "12K")
        // Exact in integers (2.3 × 10 is 22.999… in floating point).
        #expect(HeroHeader.compact(2_300_000) == "2.3M")
        #expect(HeroHeader.compact(2_800_000_000) == "2.8B")
        #expect(HeroHeader.compact(-1_500) == "-1.5K")
    }
}
