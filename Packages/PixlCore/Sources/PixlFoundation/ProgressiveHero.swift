// Pure geometry of the new UI's full-bleed heroes (`ProgressiveBlurHero` in the app, used by the player first; the
// artist and playlist pages share it) and of the mini player's progress ring.
//
// A hero is artwork that fills the top of a screen edge to edge: sharp at the top, progressively blurred from about
// halfway down, then melting into the page background under the title and controls. It is drawn as
//   1. the sharp artwork, unmasked, cut by a plain rectangle at `blurEnd` (where the copy above it is opaque),
//   2. ONE pre-blurred copy of it (blurred once, off the main thread, at a small size) masked by `blurMeltMask`
//      (the blur ramp times the melt at the bottom),
//   3. a veil of the page colour (`veilMeltMask`) so text over the blurred part stays legible.
// No live blur, no per-frame work, and no mask over the sharp layer (on the full player that is the live, swiping
// carousel): the masks are built once into static gradients and only the static layers carry them.
//
// The ramps follow smoothstep rather than a straight line. A linear cross-fade between a sharp and a blurred copy reads
// as a double exposure in the middle; smoothstep spends less of the band at the half-and-half point, so the change
// reads as the image going soft rather than as two pictures on top of each other.

import Foundation

public enum ProgressiveHero {
    /// A gradient stop: `location` down the hero (0 top … 1 bottom) and the mask's `opacity` there.
    public struct Stop: Sendable, Equatable {
        public var location: Double
        public var opacity: Double

        public init(location: Double, opacity: Double) {
            self.location = location
            self.opacity = opacity
        }
    }

    /// Where each layer changes, as fractions of the hero's height.
    public struct Profile: Sendable, Equatable {
        /// The blurred copy starts to show here (sharp above).
        public var blurStart: Double
        /// …and covers the sharp art fully from here.
        public var blurEnd: Double
        /// The whole hero starts melting into the page here and is gone at the bottom edge.
        public var meltStart: Double
        /// How strongly the page colour veils the hero's bottom (0 none … 1 opaque).
        public var veilOpacity: Double

        public init(blurStart: Double, blurEnd: Double, meltStart: Double, veilOpacity: Double) {
            self.blurStart = blurStart
            self.blurEnd = blurEnd
            self.meltStart = meltStart
            self.veilOpacity = veilOpacity
        }

        /// Now playing (owner, 2026-11-16: "sharp at the top, then progressively blurred from about halfway down so it
        /// melts into the background under the title and controls"). Fractions of the player's hero (`playerLayout`:
        /// about three quarters of the screen, so the blur starts near the screen's middle, is fully in by the title,
        /// and melts away under the title and the seek bar).
        public static let player = Profile(blurStart: 0.62, blurEnd: 0.82, meltStart: 0.86, veilOpacity: 0.6)
        /// Artist and playlist headers: the name sits lower on the art, so the blur arrives a little earlier and the
        /// veil is a little stronger.
        public static let header = Profile(blurStart: 0.36, blurEnd: 0.72, meltStart: 0.78, veilOpacity: 0.55)
    }

    /// Hermite smoothstep of `x` between `edge0` and `edge1` (0 below, 1 above). Equal edges step at the edge.
    public static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Mask stops that hold `from` until `start`, ease along smoothstep to `to` at `end`, and hold `to` after it.
    /// Locations are clamped to 0…1 and kept increasing (start ≤ end); `samples` stops (at least 2) describe the ease.
    /// The first stop is always at 0 and the last at 1, so the gradient covers the whole hero.
    public static func ramp(start: Double, end: Double, from: Double = 0, to: Double = 1, samples: Int = 6) -> [Stop] {
        let s = min(max(start, 0), 1)
        let e = min(max(end, s), 1)
        let count = max(samples, 2)
        var stops: [Stop] = []
        if s > 0 { stops.append(Stop(location: 0, opacity: from)) }
        for i in 0 ..< count {
            // The last sample lands exactly on `end` (no rounding short of it).
            let location = i == count - 1 ? e : s + (e - s) * Double(i) / Double(count - 1)
            let eased = smoothstep(s, e, location)
            stops.append(Stop(location: location, opacity: from + (to - from) * eased))
        }
        if e < 1 { stops.append(Stop(location: 1, opacity: to)) }
        // A zero-width band (start == end) gives repeated locations; keep the first of each.
        var unique: [Stop] = []
        for stop in stops where unique.last.map({ stop.location > $0.location }) ?? true {
            unique.append(stop)
        }
        return unique
    }

    /// The blurred copy's mask: clear over the sharp top, opaque from `blurEnd`.
    public static func blurMask(_ profile: Profile, samples: Int = 6) -> [Stop] {
        ramp(start: profile.blurStart, end: profile.blurEnd, samples: samples)
    }

    /// The page-colour veil: none at the top, `veilOpacity` at the bottom, rising with the blur.
    public static func veilMask(_ profile: Profile, samples: Int = 6) -> [Stop] {
        ramp(start: profile.blurStart, end: 1, from: 0, to: min(max(profile.veilOpacity, 0), 1), samples: samples)
    }

    /// The melt: opaque down to `meltStart`, clear at the bottom edge.
    public static func meltMask(_ profile: Profile, samples: Int = 6) -> [Stop] {
        ramp(start: profile.meltStart, end: 1, from: 1, to: 0, samples: samples)
    }

    /// The blurred copy's whole mask: the blur ramp times the melt, so the copy is the only masked layer (the sharp art
    /// under it is cut at `blurEnd`, where this is opaque).
    public static func blurMeltMask(_ profile: Profile, samples: Int = 6) -> [Stop] {
        product(blurMask(profile, samples: samples), meltMask(profile, samples: samples))
    }

    /// The veil's opacities with the melt folded in.
    public static func veilMeltMask(_ profile: Profile, samples: Int = 6) -> [Stop] {
        product(veilMask(profile, samples: samples), meltMask(profile, samples: samples))
    }

    /// Two masks multiplied: a stop at every location of either, each mask read there as its gradient draws it
    /// (linear between its stops).
    public static func product(_ a: [Stop], _ b: [Stop]) -> [Stop] {
        let locations = Set(a.map(\.location) + b.map(\.location)).sorted()
        return locations.map { Stop(location: $0, opacity: value(a, at: $0) * value(b, at: $0)) }
    }

    /// A mask's opacity at `location`, linear between its stops and held beyond its ends (1 for no stops).
    public static func value(_ stops: [Stop], at location: Double) -> Double {
        guard let first = stops.first, let last = stops.last else { return 1 }
        if location <= first.location { return first.opacity }
        if location >= last.location { return last.opacity }
        for (lower, upper) in zip(stops, stops.dropFirst()) where location <= upper.location {
            let span = upper.location - lower.location
            guard span > 0 else { return upper.opacity }
            return lower.opacity + (upper.opacity - lower.opacity) * (location - lower.location) / span
        }
        return last.opacity
    }

    /// The full player's hero, in points.
    public struct Layout: Sendable, Equatable {
        /// From the screen's top to where the hero has melted away.
        public var heroHeight: Double
        /// The sharp art's height (cut where the blurred copy is opaque, `blurEnd`).
        public var sharpHeight: Double

        public init(heroHeight: Double, sharpHeight: Double) {
            self.heroHeight = heroHeight
            self.sharpHeight = sharpHeight
        }
    }

    /// Sizes the full player's hero to the screen rather than to the cover: tall enough that the blurred copy is fully
    /// in where the title starts (`titleClearance`: from the title's top to the screen's bottom edge), so the title,
    /// the seek bar and the top of the controls sit over its blurred, veiled, melting part. Never shorter than the
    /// width nor taller than the screen. Unknown screen height: 1.6 × the width (about three quarters of a phone).
    /// The sharp art fills `width × sharpHeight` (a square cover is scaled to fill it, so a little of its sides is cut).
    public static func playerLayout(width: Double, screenHeight: Double, titleClearance: Double,
                                    profile: Profile = .player) -> Layout {
        guard width > 0 else { return Layout(heroHeight: 0, sharpHeight: 0) }
        let blurEnd = min(max(profile.blurEnd, 0.05), 1)
        var hero = width * 1.6
        if screenHeight > 0 {
            let titleTop = screenHeight - max(titleClearance, 0)
            hero = min(max(titleTop / blurEnd, width), screenHeight)
        }
        hero = hero.rounded()
        return Layout(heroHeight: hero, sharpHeight: (hero * blurEnd).rounded(.up))
    }

    /// Where the blurred copy's square sits so it lines up with the sharp art, which is a square cover scaled to fill
    /// `width × sharpHeight` (a square at the larger side, centred). When the square ends above the hero's bottom
    /// (the player: the sharp part is shorter than the hero), a mirrored copy continues it below, seamless at the
    /// join because both edges are the same blurred row.
    public struct CopyLayout: Sendable, Equatable {
        public var side: Double
        /// The square's top (≤ 0 when it overflows the sharp part's top).
        public var top: Double
        public var mirrors: Bool

        public init(side: Double, top: Double, mirrors: Bool) {
            self.side = side
            self.top = top
            self.mirrors = mirrors
        }
    }

    public static func copyLayout(width: Double, sharpHeight: Double, heroHeight: Double) -> CopyLayout {
        let side = max(width, sharpHeight, 0)
        let top = (sharpHeight - side) / 2
        return CopyLayout(side: side, top: top, mirrors: top + side < heroHeight)
    }
}

/// The mini player's progress ring around its play button (new UI, 2026-11-16: the progress is a thin circle around
/// play / pause, not a line on the pill's edge). Position is never observable state: the ring samples the playback
/// clock on a timeline, and this decides how often.
public enum ProgressRing {
    /// Seconds between redraws so the arc's end moves about `step` points per tick: a 3-minute song on a 44 pt ring
    /// (138 pt round) ticks about every 1.3 s, a 30-second clip every 0.25 s. Clamped to `range`; an unknown duration
    /// or a degenerate ring ticks at the slowest rate.
    public static func tickInterval(durationMs: Int64, diameter: Double, step: Double = 1,
                                    range: ClosedRange<Double> = 0.25 ... 2) -> Double {
        let circumference = Double.pi * diameter
        guard durationMs > 0, circumference > 0, step > 0 else { return range.upperBound }
        let secondsPerPoint = Double(durationMs) / 1000 / circumference
        return min(max(secondsPerPoint * step, range.lowerBound), range.upperBound)
    }

    /// The fraction drawn: clamped to 0…1 and snapped to `steps` per turn, so ticks that wouldn't move the arc by a
    /// visible amount draw the same value.
    public static func drawnFraction(_ fraction: Double, steps: Int = 360) -> Double {
        guard fraction.isFinite else { return 0 }
        let clamped = min(max(fraction, 0), 1)
        guard steps > 0 else { return clamped }
        return (clamped * Double(steps)).rounded(.down) / Double(steps)
    }
}
