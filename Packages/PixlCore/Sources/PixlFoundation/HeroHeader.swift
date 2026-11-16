// Pure geometry and text of the new UI's page heroes (the artist page first, then the playlist page): the full-bleed
// `ProgressiveBlurHero` at the top of a scrolling page, with the page's title block pinned to its blurred bottom.
//
// - `height`: how tall the hero is for a screen (a portrait phone gets a little more than a square, the mockup's
//   proportion; landscape and large screens are capped so the hero never fills the screen).
// - `titleCollapse`: the scroll window over which the hero title morphs narrower and lighter (`CollapsingTitleState`)
//   — from just before the title reaches the top bar until it has passed under it, when the bar shows its own title.
// - `scrollEffect`: the hero's overscroll stretch and its parallax, evaluated by the app in `visualEffect` (render
//   phase, no state, no re-render).
// - `summary` / `plays`: the header's and the rows' short texts.

import Foundation

public enum HeroHeader {
    /// The hero's height for a page `width` pt wide on a viewport `viewportHeight` pt tall: `width / aspect`, at most
    /// `maxViewportFraction` of the viewport and at least `minHeight` (the minimum wins on a tiny viewport, so the
    /// title block always has art behind it). Rounded to whole points so layout doesn't shimmer between widths.
    public static func height(width: Double, viewportHeight: Double, aspect: Double = 0.92,
                              maxViewportFraction: Double = 0.6, minHeight: Double = 300) -> Double {
        guard width > 0, aspect > 0 else { return minHeight }
        let natural = width / aspect
        let cap = viewportHeight > 0 ? viewportHeight * maxViewportFraction : natural
        return max(minHeight, min(natural, cap)).rounded()
    }

    /// Where the title block's top sits in the page at rest: the block is pinned to the hero's bottom edge, and a block
    /// taller than the hero (huge text sizes) makes the header grow, so the block then starts at the top.
    public static func overlayTop(heroHeight: Double, overlayHeight: Double) -> Double {
        max(0, heroHeight - overlayHeight)
    }

    /// A scroll window: the collapse runs from `start` to `start + distance` points of scroll.
    public struct CollapseWindow: Sendable, Equatable {
        public var start: Double
        public var distance: Double

        public init(start: Double, distance: Double) {
            self.start = start
            self.distance = distance
        }
    }

    /// When a hero title collapses. `titleTop` is the title's top in the page at rest, `titleHeight` its height, and
    /// `barBottom` the bottom edge of the pinned top bar (safe area included). The title starts morphing when its top is
    /// `lead` points below the bar and is fully collapsed once its bottom has gone under the bar's bottom edge — the
    /// moment the bar's own title takes over. The window never starts before the top of the page and is at least 1 pt.
    public static func titleCollapse(titleTop: Double, titleHeight: Double, barBottom: Double,
                                     lead: Double = 48) -> CollapseWindow {
        let start = titleTop - barBottom - lead
        let end = titleTop + max(0, titleHeight) - barBottom
        let clampedStart = max(0, start)
        return CollapseWindow(start: clampedStart, distance: max(1, end - clampedStart))
    }

    /// The hero's scroll response, applied in the render phase.
    public struct ScrollEffect: Sendable, Equatable {
        /// Scale about the hero's bottom edge (> 1 while pulled down past the top).
        public var scale: Double
        /// Downward offset (parallax: the hero scrolls away slower than the page).
        public var offset: Double

        public init(scale: Double, offset: Double) {
            self.scale = scale
            self.offset = offset
        }
    }

    /// `minY`: the hero's top in the scroll view's visible bounds (0 at rest, positive while the page is pulled down,
    /// negative once it scrolls up). Pulled down, the hero grows from its bottom edge by exactly the pull, so no gap
    /// opens above it; scrolled up, it trails the page by `parallax` (0 = none, 1 = pinned).
    public static func scrollEffect(minY: Double, height: Double, parallax: Double = 0.3) -> ScrollEffect {
        guard minY.isFinite, height > 0 else { return ScrollEffect(scale: 1, offset: 0) }
        if minY > 0 { return ScrollEffect(scale: 1 + minY / height, offset: 0) }
        return ScrollEffect(scale: 1, offset: -minY * min(max(parallax, 0), 1))
    }

    /// The header line under a page title: "12 Songs · 3 Albums" (the app's "N Songs" wording; a zero album count is
    /// left out, singulars are singular).
    public static func summary(songs: Int, albums: Int) -> String {
        var parts = [songs == 1 ? "1 Song" : "\(max(0, songs)) Songs"]
        if albums > 0 { parts.append(albums == 1 ? "1 Album" : "\(albums) Albums") }
        return parts.joined(separator: " · ")
    }

    /// A row's play count: "1 play", "12 plays", "1.2K plays", "3.4M plays" (one decimal under 10 of a unit, none
    /// above; a trailing ".0" is dropped). Nil for no plays.
    public static func plays(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        if count == 1 { return "1 play" }
        return "\(compact(count)) plays"
    }

    /// 999 → "999", 1_234 → "1.2K", 12_345 → "12K", 2_500_000 → "2.5M".
    public static func compact(_ value: Int) -> String {
        // Integer arithmetic: 2_300_000 / 1e6 * 10 is 22.999… in floating point and would read "2.2M".
        let units: [(threshold: Int, suffix: String)] = [(1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K")]
        guard value >= 0 else { return "-" + compact(value == .min ? .max : -value) }
        for unit in units where value >= unit.threshold {
            let whole = value / unit.threshold
            if whole >= 10 { return "\(whole)\(unit.suffix)" }
            let tenth = (value % unit.threshold) / (unit.threshold / 10)
            return (tenth == 0 ? "\(whole)" : "\(whole).\(tenth)") + unit.suffix
        }
        return "\(value)"
    }
}
