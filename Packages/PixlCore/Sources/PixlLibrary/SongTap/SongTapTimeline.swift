// The beam animation as a pure function of time, in integers (Song Tap): every value is a permille (1000 = 1.0) so the
// Kotlin and Swift versions give the same number for the same millisecond. The UI reads one frame per draw and applies
// it with scale, offset and opacity only; there is no animation state to keep. A transliteration of
// `SongTapTimeline.kt`.
//
// `tMs` counts from the animation start T0 (see `SongTapHandshake`). Positions are fractions of the container height: 0
// is in place, -1100 is clear off the top.
//
// Sender: the artwork lifts (scale to 920 with a shadow), shrinks to 400 and flies off the top while it fades, then comes
// back in place. Receiver: the artwork enters from the top at scale 400, settles into place and grows into a card with a
// small overshoot, then the text and the Undo chip appear; the card rests `cardRestMs` and slides away. With reduced
// motion there is no flight: the card cross-fades in `reducedFadeMs` and the haptics stay.

public struct SongTapBeamFrame: Sendable, Equatable {
    /// The glow on the screen edge, 0...500.
    public var glow: Int
    /// Artwork (sender) or the whole card group (receiver).
    public var scale: Int
    public var translateY: Int
    public var alpha: Int
    /// Sender only: the lifted artwork's shadow, 0...1000.
    public var shadow: Int
    /// Receiver only: the card behind the artwork, text, and the Undo chip.
    public var cardAlpha: Int
    public var textAlpha: Int
    public var undoAlpha: Int

    public init(_ glow: Int, _ scale: Int, _ translateY: Int, _ alpha: Int, _ shadow: Int, _ cardAlpha: Int, _ textAlpha: Int, _ undoAlpha: Int) {
        self.glow = glow
        self.scale = scale
        self.translateY = translateY
        self.alpha = alpha
        self.shadow = shadow
        self.cardAlpha = cardAlpha
        self.textAlpha = textAlpha
        self.undoAlpha = undoAlpha
    }

    public func describe() -> String {
        "glow=\(glow) scale=\(scale) ty=\(translateY) alpha=\(alpha) shadow=\(shadow) card=\(cardAlpha) text=\(textAlpha) undo=\(undoAlpha)"
    }
}

public struct SongTapTimedCue: Sendable, Equatable {
    public var tMs: Int64
    public var cue: SongTapHapticCue

    public init(tMs: Int64, cue: SongTapHapticCue) {
        self.tMs = tMs
        self.cue = cue
    }

    public func describe() -> String { "\(tMs):\(cue.code)" }
}

public enum SongTapTimeline {
    public static let liftMs: Int64 = 180
    public static let flyMs: Int64 = 420
    public static let sendReturnStartMs: Int64 = 1_000
    public static let sendReturnMs: Int64 = 500
    public static let sendTotalMs: Int64 = 1_500

    public static let receiveEnterMs: Int64 = 420
    public static let receiveSettleEndMs: Int64 = 900
    public static let receiveTextStartMs: Int64 = 700
    public static let receiveUndoStartMs: Int64 = 1_000
    public static let cardRestMs: Int64 = 6_000
    public static let slideAwayMs: Int64 = 300
    public static let receiveRestEndMs: Int64 = receiveUndoStartMs + cardRestMs
    public static let receiveTotalMs: Int64 = receiveRestEndMs + slideAwayMs

    public static let reducedFadeMs: Int64 = 150

    public static let offTop = -1_100
    private static let glowPeak = 500
    private static let glowRiseMs: Int64 = 150
    public static let glowFallEndMs: Int64 = 1_300

    // MARK: Easing, all permille in and out

    public static func progress(_ tMs: Int64, _ startMs: Int64, _ durMs: Int64) -> Int {
        if tMs <= startMs { return 0 }
        if tMs >= startMs + durMs { return 1000 }
        return Int((tMs - startMs) * 1000 / durMs)
    }

    public static func lerp(_ a: Int, _ b: Int, _ x: Int) -> Int {
        a + Int(Int64(b - a) * Int64(x) / 1000)
    }

    public static func easeOutCubic(_ x: Int) -> Int {
        let u = Int64(1000 - x)
        return 1000 - Int(u * u * u / 1_000_000)
    }

    public static func easeInCubic(_ x: Int) -> Int {
        let v = Int64(x)
        return Int(v * v * v / 1_000_000)
    }

    public static func smooth(_ x: Int) -> Int {
        let v = Int64(x)
        return Int(v * v * (3000 - 2 * v) / 1_000_000)
    }

    /// Overshoots to about 1100 near the end and settles at 1000.
    public static func easeOutBack(_ x: Int) -> Int {
        let u = Int64(x - 1000)
        return 1000 + Int(2702 * u * u * u / 1_000_000_000) + Int(1702 * u * u / 1_000_000)
    }

    private static func glow(_ tMs: Int64) -> Int {
        if tMs <= 0 { return 0 }
        if tMs < glowRiseMs { return lerp(0, glowPeak, easeOutCubic(progress(tMs, 0, glowRiseMs))) }
        return lerp(glowPeak, 0, smooth(progress(tMs, glowRiseMs, glowFallEndMs - glowRiseMs)))
    }

    // MARK: Frames

    public static func frame(role: SongTapRole, tMs: Int64, reducedMotion: Bool) -> SongTapBeamFrame {
        role == .send ? sender(tMs, reducedMotion) : receiver(tMs, reducedMotion)
    }

    public static func totalMs(role: SongTapRole, reducedMotion: Bool) -> Int64 {
        if reducedMotion && role == .send { return reducedFadeMs }
        if reducedMotion { return reducedFadeMs + cardRestMs + reducedFadeMs }
        return role == .send ? sendTotalMs : receiveTotalMs
    }

    private static func sender(_ tMs: Int64, _ reduced: Bool) -> SongTapBeamFrame {
        if reduced { return SongTapBeamFrame(0, 1000, 0, 1000, 0, 0, 0, 0) }
        let g = glow(tMs)
        if tMs <= 0 { return SongTapBeamFrame(g, 1000, 0, 1000, 0, 0, 0, 0) }
        if tMs < liftMs {
            let e = easeOutCubic(progress(tMs, 0, liftMs))
            return SongTapBeamFrame(g, lerp(1000, 920, e), 0, 1000, lerp(0, 1000, e), 0, 0, 0)
        }
        if tMs < liftMs + flyMs {
            let p = progress(tMs, liftMs, flyMs)
            let fade = smooth(progress(tMs, liftMs + flyMs / 2, flyMs / 2))
            return SongTapBeamFrame(g, lerp(920, 400, smooth(p)), lerp(0, offTop, easeInCubic(p)), lerp(1000, 0, fade), 1000, 0, 0, 0)
        }
        if tMs < sendReturnStartMs { return SongTapBeamFrame(g, 400, offTop, 0, 1000, 0, 0, 0) }
        if tMs < sendReturnStartMs + sendReturnMs {
            let e = easeOutCubic(progress(tMs, sendReturnStartMs, sendReturnMs))
            return SongTapBeamFrame(g, lerp(940, 1000, e), 0, lerp(0, 1000, e), 0, 0, 0, 0)
        }
        return SongTapBeamFrame(g, 1000, 0, 1000, 0, 0, 0, 0)
    }

    private static func receiver(_ tMs: Int64, _ reduced: Bool) -> SongTapBeamFrame {
        if reduced {
            let inFade = easeOutCubic(progress(tMs, 0, reducedFadeMs))
            let outFade = 1000 - smooth(progress(tMs, reducedFadeMs + cardRestMs, reducedFadeMs))
            let a = tMs < reducedFadeMs + cardRestMs ? inFade : outFade
            return SongTapBeamFrame(0, 1000, 0, a, 0, a, a, a)
        }
        let g = glow(tMs)
        if tMs <= 0 { return SongTapBeamFrame(g, 400, offTop, 0, 0, 0, 0, 0) }
        let enter = progress(tMs, 0, receiveEnterMs)
        let alphaIn = easeOutCubic(progress(tMs, 0, 150))
        let ty = lerp(offTop, 0, easeOutCubic(enter))
        let grow = progress(tMs, receiveEnterMs, receiveSettleEndMs - receiveEnterMs)
        let scale = tMs < receiveEnterMs ? 400 : lerp(400, 1000, easeOutBack(grow))
        let card = smooth(progress(tMs, 500, 300))
        let text = smooth(progress(tMs, receiveTextStartMs, 300))
        let undo = smooth(progress(tMs, receiveUndoStartMs, 250))
        if tMs <= receiveRestEndMs { return SongTapBeamFrame(g, scale, ty, alphaIn, 0, card, text, undo) }
        let out = progress(tMs, receiveRestEndMs, slideAwayMs)
        let slide = easeInCubic(out)
        let fade = 1000 - smooth(out)
        return SongTapBeamFrame(g, 1000, lerp(0, offTop, slide), fade, 0, min(card, fade), min(text, fade), min(undo, fade))
    }
}

/// The vibrations that go with the beam, as times from T0.
public enum SongTapHaptics {
    public static func cues(role: SongTapRole, reducedMotion: Bool) -> [SongTapTimedCue] {
        if reducedMotion { return [SongTapTimedCue(tMs: 0, cue: .success)] }
        if role == .send {
            return [
                SongTapTimedCue(tMs: SongTapTimeline.liftMs, cue: .confirm),
                SongTapTimedCue(tMs: SongTapTimeline.sendReturnStartMs + 100, cue: .success),
            ]
        }
        return [
            SongTapTimedCue(tMs: SongTapTimeline.receiveEnterMs, cue: .confirm),
            SongTapTimedCue(tMs: SongTapTimeline.receiveSettleEndMs, cue: .success),
        ]
    }
}
