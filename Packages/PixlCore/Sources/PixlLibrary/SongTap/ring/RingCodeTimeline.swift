// The Pixl ring code's motion as a pure function of time, in integers (permille, micro-radians, milliseconds), so Kotlin and
// Swift give the same number for the same millisecond (a transliteration of the Android `RingCodeTimeline.kt`). The screen
// reads one frame per draw; there is no animation state, and a frame is eleven numbers (`slotProgress` answers for one dot).
//
// Times are the screen's clock `tMs` (milliseconds since the code was shown) plus the moments the session decides: `none`
// means "has not happened".
// - `approachStartMs` / `approachEndMs`: the other phone is near (the Bluetooth detector's "near"), and it went away again.
// - `beamStartMs`: the beam began (the same moment as the plain beam's T0).
//
// Idle: the whole code sways: 1.32 rad one way in 6 s (0.22 rad/s on average, eased at both ends), back, then the other way,
// period 24 s; the artwork breathes 2 percent (period 4 s). Approach: the code tightens by 8 percent and a glow rises around
// the plate over 800 ms; if the phone goes away it relaxes over 400 ms. Beam: the dots peel off the outer ring first and
// spiral into the art, 800 ms each, staggered; the plate fades; the art pulses 10 percent, then lifts, shrinks to 0.38 and
// flies off the top; a small "done" pill fades in. Reduced motion: nothing moves, the code cross-fades into the pill in 150 ms.

public struct RingFrameBuffer: Sendable, Equatable {
    /// Rotation of the whole code (rings, outline, start dot), micro-radians, clockwise positive.
    public var codeAngle = 0
    /// Scale of the code around the centre, 1000 = normal.
    public var codeScale = 1000
    /// The soft glow around the plate, 0..700.
    public var glow = 0
    public var plateAlpha = 1000
    /// Opacity of the whole code layer (dots, outline, start dot). Each dot also fades by its own progress.
    public var codeAlpha = 1000
    public var artScale = 1000
    /// Fraction of the container height, 0 = in place, `SongTapTimeline.offTop` = clear off the top.
    public var artTranslateY = 0
    public var artAlpha = 1000
    public var pillAlpha = 0
    /// Milliseconds since the beam began, or -1 before it: ask `RingCodeTimeline.slotProgress` with it.
    public var beamMs = -1
    /// 0 idle, 1 approach, 2 beam, 3 done (the pill is showing and the code is gone).
    public var phase = 0

    public init() {}

    public func describe() -> String {
        "angle=\(codeAngle) scale=\(codeScale) glow=\(glow) plate=\(plateAlpha) code=\(codeAlpha) art=\(artScale) ty=\(artTranslateY) "
            + "artAlpha=\(artAlpha) pill=\(pillAlpha) beam=\(beamMs) phase=\(phase)"
    }
}

public enum RingCodeTimeline {
    public static let none = Int64.min

    // Idle
    public static let swayAmplitudeMicroRad: Int64 = 1_320_000
    public static let swaySegmentMs: Int64 = 6_000
    public static let swayPeriodMs: Int64 = 4 * swaySegmentMs
    public static let breathPeriodMs: Int64 = 4_000
    public static let breathRange = 20

    // Approach
    public static let approachRiseMs: Int64 = 800
    public static let approachFallMs: Int64 = 400
    public static let approachTighten = 80
    public static let glowPeak = 700

    // Beam
    public static let dotMs: Int64 = 800
    public static let ringStaggerMs: Int64 = 70
    public static let inRingSpreadMs: Int64 = 60
    public static let plateFadeStartMs: Int64 = 100
    public static let plateFadeMs: Int64 = 800
    public static let pulseStartMs: Int64 = 700
    public static let pulseUpMs: Int64 = 300
    public static let pulseDownMs: Int64 = 300
    public static let pulsePeak = 1100
    public static let liftStartMs: Int64 = 1_300
    public static let liftMs: Int64 = 700
    public static let liftEndScale = 380
    public static let artFadeStartMs: Int64 = 1_700
    public static let artFadeMs: Int64 = 300
    public static let pillStartMs: Int64 = 1_900
    public static let pillFadeMs: Int64 = 250
    public static let glowFallStartMs: Int64 = 900
    public static let glowFallMs: Int64 = 600
    public static let beamTotalMs: Int64 = pillStartMs + pillFadeMs

    public static let reducedFadeMs: Int64 = 150

    private static func progress(_ t: Int64, _ start: Int64, _ dur: Int64) -> Int { SongTapTimeline.progress(t, start, dur) }
    private static func lerp(_ a: Int, _ b: Int, _ x: Int) -> Int { SongTapTimeline.lerp(a, b, x) }
    private static func smooth(_ x: Int) -> Int { SongTapTimeline.smooth(x) }

    /// Smoothstep in parts per million, so the slow sway has no visible steps.
    private static func smoothPpm(_ x: Int64) -> Int64 { x * x / 1_000_000 * (3_000_000 - 2 * x) / 1_000_000 }

    /// The idle sway of the whole code, micro-radians: 0 -> +A -> 0 -> -A -> 0 over 24 s, each leg eased.
    public static func swayAngle(_ tMs: Int64) -> Int {
        var t = tMs % swayPeriodMs
        if t < 0 { t += swayPeriodMs }
        let leg = Int(t / swaySegmentMs)
        let e = smoothPpm((t % swaySegmentMs) * 1_000_000 / swaySegmentMs)
        let up = swayAmplitudeMicroRad * e / 1_000_000
        let down = swayAmplitudeMicroRad - up
        switch leg {
        case 0: return Int(up)
        case 1: return Int(down)
        case 2: return Int(-up)
        default: return Int(-down)
        }
    }

    /// The artwork's idle breathing, permille: 990..1010, period 4 s.
    public static func breathScale(_ tMs: Int64) -> Int {
        var t = tMs % breathPeriodMs
        if t < 0 { t += breathPeriodMs }
        let half = breathPeriodMs / 2
        let e = t < half ? smooth(Int(t * 1000 / half)) : 1000 - smooth(Int((t - half) * 1000 / half))
        return 1000 + (e - 500) * breathRange / 1000
    }

    /// How near the other phone is, 0..1000: rises over 800 ms, relaxes over 400 ms after `endMs`.
    public static func approachLevel(_ tMs: Int64, _ startMs: Int64, _ endMs: Int64) -> Int {
        if startMs == none || tMs <= startMs { return 0 }
        let rise = smooth(progress(tMs, startMs, approachRiseMs))
        if endMs == none || tMs <= endMs { return rise }
        let atEnd = smooth(progress(endMs, startMs, approachRiseMs))
        return atEnd - lerp(0, atEnd, smooth(progress(tMs, endMs, approachFallMs)))
    }

    /// When a dot starts to peel off, in ms after the beam: outer ring first, scrambled inside a ring.
    public static func slotStartMs(ring: Int, index: Int) -> Int {
        let n = RingCodeLayout.ringSlots[ring]
        let scatter = ((index * 37) % n) * Int(inRingSpreadMs) / n
        return (RingCodeLayout.rings - 1 - ring) * Int(ringStaggerMs) + scatter
    }

    /// One dot's flight into the artwork, 0 = in place, 1000 = arrived (and gone), `beamMs` since the beam began.
    public static func slotProgress(ring: Int, index: Int, beamMs: Int) -> Int {
        if beamMs < 0 { return 0 }
        return progress(Int64(beamMs), Int64(slotStartMs(ring: ring, index: index)), dotMs)
    }

    /// The start dot leaves with the first dot of the outer ring.
    public static func markerProgress(beamMs: Int) -> Int { slotProgress(ring: RingCodeLayout.rings - 1, index: 0, beamMs: beamMs) }

    /// The whole beam's length from `beamStartMs` to the pill resting, ms.
    public static func beamTotal(reducedMotion: Bool) -> Int64 { reducedMotion ? reducedFadeMs : beamTotalMs }

    public static func frame(tMs: Int64, approachStartMs: Int64, approachEndMs: Int64, beamStartMs: Int64, reducedMotion: Bool) -> RingFrameBuffer {
        var out = RingFrameBuffer()
        frameInto(tMs: tMs, approachStartMs: approachStartMs, approachEndMs: approachEndMs, beamStartMs: beamStartMs,
                  reducedMotion: reducedMotion, out: &out)
        return out
    }

    /// `frame` without the allocation: fills `out`.
    public static func frameInto(tMs: Int64, approachStartMs: Int64, approachEndMs: Int64, beamStartMs: Int64,
                                 reducedMotion: Bool, out: inout RingFrameBuffer) {
        out.codeAngle = 0; out.codeScale = 1000; out.glow = 0; out.plateAlpha = 1000; out.codeAlpha = 1000
        out.artScale = 1000; out.artTranslateY = 0; out.artAlpha = 1000; out.pillAlpha = 0; out.beamMs = -1; out.phase = 0
        let beaming = beamStartMs != none && tMs >= beamStartMs
        if reducedMotion {
            if beaming {
                let f = smooth(progress(tMs, beamStartMs, reducedFadeMs))
                out.codeAlpha = 1000 - f; out.plateAlpha = 1000 - f; out.artAlpha = 1000 - f; out.pillAlpha = f
                out.beamMs = Int(min(tMs - beamStartMs, 1_000_000))
                out.phase = f >= 1000 ? 3 : 2
            }
            return
        }
        var level = approachLevel(tMs, approachStartMs, approachEndMs)
        if !beaming {
            out.codeAngle = swayAngle(tMs)
            out.artScale = breathScale(tMs)
            out.codeScale = 1000 - approachTighten * level / 1000
            out.glow = glowPeak * level / 1000
            out.phase = level > 0 ? 1 : 0
            return
        }
        let tb = tMs - beamStartMs
        out.beamMs = Int(min(tb, 1_000_000))
        out.phase = tb >= beamTotalMs ? 3 : 2
        out.codeAngle = swayAngle(beamStartMs)
        let flare = smooth(progress(tMs, beamStartMs, 400))
        if flare > level { level = flare }
        out.codeScale = 1000 - approachTighten * level / 1000
        let fall = smooth(progress(tMs, beamStartMs + glowFallStartMs, glowFallMs))
        out.glow = lerp(glowPeak * level / 1000, 0, fall)
        out.plateAlpha = 1000 - smooth(progress(tMs, beamStartMs + plateFadeStartMs, plateFadeMs))
        // Art: pulse, then lift, shrink and fly off the top.
        let pulseUp = SongTapTimeline.easeOutCubic(progress(tMs, beamStartMs + pulseStartMs, pulseUpMs))
        let pulseDown = smooth(progress(tMs, beamStartMs + pulseStartMs + pulseUpMs, pulseDownMs))
        let pulse = lerp(1000, pulsePeak, pulseUp)
        let afterPulse = lerp(pulse, 1000, pulseDown)
        let lift = progress(tMs, beamStartMs + liftStartMs, liftMs)
        out.artScale = lift == 0 ? afterPulse : lerp(1000, liftEndScale, smooth(lift))
        out.artTranslateY = lerp(0, SongTapTimeline.offTop, SongTapTimeline.easeInCubic(lift))
        out.artAlpha = 1000 - smooth(progress(tMs, beamStartMs + artFadeStartMs, artFadeMs))
        out.pillAlpha = smooth(progress(tMs, beamStartMs + pillStartMs, pillFadeMs))
    }
}
