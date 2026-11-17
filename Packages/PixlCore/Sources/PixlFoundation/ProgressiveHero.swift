// Pure geometry of the new UI's full-bleed heroes (`ProgressiveBlurHero` in the app, used by the player first; the
// artist and playlist pages share it) and of the mini player's progress ring.
//
// A hero is artwork that fills the top of a screen edge to edge: sharp at the top, progressively blurred from about
// halfway down, then melting into whatever is behind it under the title and controls. It is drawn as
//   1. the sharp artwork, unmasked, cut by a plain rectangle at `blurEnd` (where the copy above it is opaque),
//   2. ONE pre-blurred copy of it (blurred once, off the main thread, at a small size) masked by `blurMeltMask`
//      (the blur ramp times the melt at the bottom),
//   3. a veil of the page colour (`veilMeltMask`) so text over the blurred part stays legible.
// No live blur, no per-frame work, and no mask over the sharp layer (on the full player that is the live, swiping
// carousel): the masks are built once into static gradients and only the static layers carry them.
//
// Every layer lives inside the hero's frame and every mask reaches exactly 0 at the frame's bottom edge, so the hero
// as a whole dissolves into the background (2026-11-16 fix: the player's blurred copies rode below a carousel page
// that was only as tall as the sharp part and were cut there, leaving a hard edge right above the title).
//
// The ramps follow smootherstep (6t⁵ − 15t⁴ + 10t³) sampled into many stops. A linear cross-fade between a sharp and a
// blurred copy reads as a double exposure in the middle, and a ramp whose slope jumps at either end shows its ends as
// faint lines (Mach bands); smootherstep starts and ends with zero slope and zero curvature, so neither end of a band
// shows and the change reads as the image going soft rather than as two pictures on top of each other.

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

    /// Where each layer changes, as fractions of the hero's height (0 top … 1 the bottom of the hero's frame).
    public struct Profile: Sendable, Equatable {
        /// The blurred copy starts to show here (sharp above).
        public var blurStart: Double
        /// …and covers the sharp art fully from here: the sharp art is cut here, so the melt must not start before it.
        public var blurEnd: Double
        /// The whole hero starts melting into what is behind it here and is gone, every layer at 0, at the bottom edge.
        public var meltStart: Double
        /// How strongly the page colour veils the blurred part (0 none … 1 opaque): reached where the melt starts, then
        /// melting with everything else.
        public var veilOpacity: Double

        public init(blurStart: Double, blurEnd: Double, meltStart: Double, veilOpacity: Double) {
            self.blurStart = blurStart
            self.blurEnd = blurEnd
            self.meltStart = meltStart
            self.veilOpacity = veilOpacity
        }

        /// Now playing (owner, 2026-11-16: "sharp at the top, then progressively blurred from about halfway down so it
        /// melts into the background under the title and controls"). Fractions of the player's hero (`playerLayout`:
        /// the title's top lands on `blurEnd`, and the hero runs on about 200 pt below it, to the transport): the blur
        /// starts near the screen's middle, is fully in by the title, and the whole hero melts away over the last
        /// quarter (about 175 pt on a 390 × 844 phone), under the title, the seek bar and the transport.
        public static let player = Profile(blurStart: 0.54, blurEnd: 0.70, meltStart: 0.75, veilOpacity: 0.45)
        /// Artist and playlist headers: the name sits on the art's lower part, so the blur arrives earlier, over a
        /// longer band. The hero is the header's own frame; the page under it is the veil's colour.
        public static let header = Profile(blurStart: 0.36, blurEnd: 0.72, meltStart: 0.78, veilOpacity: 0.45)
    }

    /// Hermite smoothstep of `x` between `edge0` and `edge1` (0 below, 1 above). Equal edges step at the edge.
    public static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Perlin's smootherstep (6t⁵ − 15t⁴ + 10t³) of `x` between `edge0` and `edge1` (0 below, 1 above): zero slope
    /// and zero curvature at both edges, so a fade along it has no visible start or end. Equal edges step at the edge.
    public static func smootherstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * t * (t * (6 * t - 15) + 10)
    }

    /// Stops per eased band: enough that the gradient's straight segments between them don't show their corners
    /// (each band is at most a few hundred points, so about 10–20 pt per segment).
    public static let rampSamples = 16

    /// Mask stops that hold `from` until `start`, ease along smootherstep to `to` at `end`, and hold `to` after it.
    /// Locations are clamped to 0…1 and kept increasing (start ≤ end); `samples` stops (at least 2) describe the ease.
    /// The first stop is always at 0 and the last at 1, so the gradient covers the whole hero.
    public static func ramp(start: Double, end: Double, from: Double = 0, to: Double = 1,
                            samples: Int = rampSamples) -> [Stop] {
        let s = min(max(start, 0), 1)
        let e = min(max(end, s), 1)
        let count = max(samples, 2)
        var stops: [Stop] = []
        if s > 0 { stops.append(Stop(location: 0, opacity: from)) }
        for i in 0 ..< count {
            // The last sample lands exactly on `end` (no rounding short of it), and its value is exactly `to`.
            let location = i == count - 1 ? e : s + (e - s) * Double(i) / Double(count - 1)
            let eased = i == count - 1 ? 1 : smootherstep(s, e, location)
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
    public static func blurMask(_ profile: Profile, samples: Int = rampSamples) -> [Stop] {
        ramp(start: profile.blurStart, end: profile.blurEnd, samples: samples)
    }

    /// The page-colour veil: none over the sharp top, rising with the blur to `veilOpacity` where the melt starts (so
    /// with the melt folded in it only ever falls from there to the bottom).
    public static func veilMask(_ profile: Profile, samples: Int = rampSamples) -> [Stop] {
        ramp(start: profile.blurStart, end: max(profile.meltStart, profile.blurStart), from: 0,
             to: min(max(profile.veilOpacity, 0), 1), samples: samples)
    }

    /// The melt: opaque down to `meltStart`, exactly 0 at the bottom edge of the hero's frame.
    public static func meltMask(_ profile: Profile, samples: Int = rampSamples) -> [Stop] {
        ramp(start: profile.meltStart, end: 1, from: 1, to: 0, samples: samples)
    }

    /// The blurred copy's whole mask: the blur ramp times the melt, so the copy is the only masked layer (the sharp art
    /// under it is cut at `blurEnd`, where this is opaque).
    public static func blurMeltMask(_ profile: Profile, samples: Int = rampSamples) -> [Stop] {
        product(blurMask(profile, samples: samples), meltMask(profile, samples: samples))
    }

    /// The veil's opacities with the melt folded in.
    public static func veilMeltMask(_ profile: Profile, samples: Int = rampSamples) -> [Stop] {
        product(veilMask(profile, samples: samples), meltMask(profile, samples: samples))
    }

    /// The dimming scrim behind the status bar and the chrome over the sharp top: `opacity` at the top, eased to 0 at
    /// its own bottom edge (a straight two-stop fade shows where it stops).
    public static func topScrimMask(opacity: Double = 0.32, samples: Int = rampSamples) -> [Stop] {
        ramp(start: 0, end: 1, from: min(max(opacity, 0), 1), to: 0, samples: samples)
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

    /// What each layer contributes at one point down the hero, as the app stacks them: the sharp art (opaque above
    /// the clip, nothing below it), the blurred copy over it, the veil on top. Outside the hero's frame (below 1)
    /// nothing is drawn.
    public struct Layers: Sendable, Equatable {
        public var sharp: Double
        public var copy: Double
        public var veil: Double

        public init(sharp: Double, copy: Double, veil: Double) {
            self.sharp = sharp
            self.copy = copy
            self.veil = veil
        }

        /// How much of what is behind the hero it hides (1 fully, 0 the hero is gone).
        public var coverage: Double { 1 - (1 - sharp) * (1 - copy) * (1 - veil) }

        /// The composite as one channel, each layer painted in its own value over `background` (source-over): a seam
        /// in any layer shows up as a jump here.
        public func composite(sharpValue: Double, copyValue: Double, veilValue: Double, background: Double) -> Double {
            var value = background
            value = sharpValue * sharp + value * (1 - sharp)
            value = copyValue * copy + value * (1 - copy)
            return veilValue * veil + value * (1 - veil)
        }
    }

    /// The layers at `location` (a fraction of the hero; outside 0…1 is outside its frame) for a sharp part cut at
    /// `clip` (`sharpHeight / heroHeight`), reading the copy's and the veil's stops as their gradients draw them.
    public static func layers(at location: Double, clip: Double, copy: [Stop], veil: [Stop]) -> Layers {
        guard location >= 0, location <= 1 else { return Layers(sharp: 0, copy: 0, veil: 0) }
        return Layers(sharp: location < clip ? 1 : 0, copy: value(copy, at: location), veil: value(veil, at: location))
    }

    /// Swapping the blurred copy (a new source, the copy arriving over the page-colour fallback, or giving way to it),
    /// in seconds: the incoming layer fades in over `swapFade` while the outgoing one stays opaque under or over it,
    /// and only then fades out for as long. A plain cross-fade (both at once) covers only `1 − p(1 − p)` of the band
    /// where the copy is opaque — 75 % half way — so for its 0.3 s the sharp art's cut and the background below it
    /// showed through as a line.
    public static let swapFade = 0.3

    /// The incoming and outgoing layers' opacities `time` seconds into a swap (linear progress; the app eases each
    /// fade, which keeps where they start and end). At every moment one of them is opaque.
    public static func swapOpacities(at time: Double, fade: Double = swapFade) -> (incoming: Double, outgoing: Double) {
        guard fade > 0 else { return (1, 0) }
        let incoming = min(max(time / fade, 0), 1)
        let outgoing = 1 - min(max((time - fade) / fade, 0), 1)
        return (incoming, outgoing)
    }

    /// The full player's hero, in points.
    public struct Layout: Sendable, Equatable {
        /// From the screen's top to where the hero has melted away: the height of every carousel page and of every
        /// layer (nothing of the hero is drawn outside it, so nothing can be cut by a frame).
        public var heroHeight: Double
        /// The sharp art's height (cut where the blurred copy is opaque, `blurEnd`).
        public var sharpHeight: Double

        public init(heroHeight: Double, sharpHeight: Double) {
            self.heroHeight = heroHeight
            self.sharpHeight = sharpHeight
        }

        /// Where the sharp art is cut, as a fraction of the hero.
        public var clip: Double { heroHeight > 0 ? sharpHeight / heroHeight : 0 }
    }

    /// Sizes the full player's hero to the screen rather than to the cover: the blurred copy is fully in where the
    /// title starts (`titleClearance`: from the title's top to the screen's bottom edge) and the hero runs on below it
    /// (`1 − blurEnd` of it, about 200 pt on a phone) so it melts out gently under the title, the seek bar and the
    /// transport. Never shorter than the width nor taller than the screen. Unknown screen height: 1.8 × the width
    /// (about 85 % of a phone). The sharp art fills `width × sharpHeight` (a square cover is scaled to fill it, so a
    /// little of its sides is cut).
    public static func playerLayout(width: Double, screenHeight: Double, titleClearance: Double,
                                    profile: Profile = .player) -> Layout {
        guard width > 0 else { return Layout(heroHeight: 0, sharpHeight: 0) }
        let blurEnd = min(max(profile.blurEnd, 0.05), 1)
        var hero = width * 1.8
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
