// CPU reference of the lyrics artwork background (`presentation/lyrics/background/`): the colour grade
// (`LyricsBackgroundGrade` in `LyricsBackgroundShader.kt`), the per-pixel steps of the AGSL shader (twist, sprite
// mapping, premultiplied composite, grade, overlays, dither), the sprite geometry and box blur of
// `ArtworkSpriteBaker.kt`, and the motion/crossfade clock of `LyricsArtworkBackground.kt` (`BackgroundAnimator`).
// The iOS Metal shader is checked against these functions; the baker can use `SpriteBlur` or Core Image.

import Foundation
import PixlFoundation

/// The background colour grade, in gamma-encoded sRGB, clamped only at the very end:
/// 1. saturation 2.75 around Rec.709 luma, 2. contrast 1.9 around mid-grey, 3. brightness ×0.7;
/// then (after the clamp) black at 50 % and white at 5 % on top.
public enum LyricsBackgroundGrade {
    public static let saturation: Float = 2.75
    public static let contrast: Float = 1.9
    public static let brightness: Float = 0.7

    public static let lumaR: Float = 0.2125
    public static let lumaG: Float = 0.7154
    public static let lumaB: Float = 0.0721

    /// Black overlay alpha, applied after the clamp.
    public static let blackOverlay: Float = 0.5
    /// White overlay alpha, applied after the black one.
    public static let whiteOverlay: Float = 0.05
    /// Graded mean luma above which the art counts as "bright" (§1.2).
    public static let brightArtLuma: Float = 0.6
    /// Black scrim drawn over the background when the art is bright (§1.2).
    public static let brightArtScrim: Float = 0.35

    /// Saturation → contrast → brightness collapsed into one 4×5 row-major colour matrix (offsets on the 0–255 scale,
    /// `android.graphics.ColorMatrix` layout). Every RGB row sums to 1.33 and the offset is −0.315 × 255. The overlays
    /// are deliberately not folded in: the clamp has to happen between the grade and the overlays.
    public static let gradeMatrix: [Float] = {
        let gain = contrast * brightness
        let offset = brightness * 0.5 * (1 - contrast) * 255
        let weights = [lumaR, lumaG, lumaB]
        var m = [Float](repeating: 0, count: 20)
        for row in 0..<3 {
            for col in 0..<3 {
                let identity: Float = row == col ? saturation : 0
                m[row * 5 + col] = gain * (identity + (1 - saturation) * weights[col])
            }
            m[row * 5 + 3] = 0
            m[row * 5 + 4] = offset
        }
        m[18] = 1 // alpha passes through
        return m
    }()

    /// The three-step reference grade on 0…1 sRGB components, clamped only at the end.
    public static func gradeReference(_ r: Float, _ g: Float, _ b: Float) -> (r: Float, g: Float, b: Float) {
        let luma = r * lumaR + g * lumaG + b * lumaB
        var rr = luma + (r - luma) * saturation
        var gg = luma + (g - luma) * saturation
        var bb = luma + (b - luma) * saturation
        rr = (rr - 0.5) * contrast + 0.5
        gg = (gg - 0.5) * contrast + 0.5
        bb = (bb - 0.5) * contrast + 0.5
        return ((rr * brightness).coerced(in: 0, 1), (gg * brightness).coerced(in: 0, 1), (bb * brightness).coerced(in: 0, 1))
    }

    /// Rec.709 luma of the graded (pre-overlay) colour, for the bright-art check.
    public static func gradedLuma(_ r: Float, _ g: Float, _ b: Float) -> Float {
        let c = gradeReference(r, g, b)
        return c.r * lumaR + c.g * lumaG + c.b * lumaB
    }

    /// Applies `gradeMatrix` to 0–255 components and clamps to 0…255 (`ColorMatrixColorFilter`).
    public static func applyMatrix(_ r: Float, _ g: Float, _ b: Float, _ a: Float) -> (r: Float, g: Float, b: Float, a: Float) {
        let m = gradeMatrix
        func row(_ k: Int) -> Float {
            (m[k * 5] * r + m[k * 5 + 1] * g + m[k * 5 + 2] * b + m[k * 5 + 3] * a + m[k * 5 + 4]).coerced(in: 0, 255)
        }
        return (row(0), row(1), row(2), row(3))
    }

    /// Mean graded luma of an ARGB (`0xAARRGGBB`) image, as `ArtworkSpriteBaker.meanGradedLuma` measures it on the
    /// blurred base sprite (alpha ignored, sum in Double).
    public static func meanGradedLuma(argb pixels: [UInt32]) -> Float {
        if pixels.isEmpty { return 0 }
        var sum = 0.0
        for c in pixels {
            let r = Float((c >> 16) & 0xFF) / 255
            let g = Float((c >> 8) & 0xFF) / 255
            let b = Float(c & 0xFF) / 255
            sum += Double(gradedLuma(r, g, b))
        }
        return Float(sum / Double(pixels.count))
    }

    /// Whether a graded mean luma counts as bright art.
    public static func isBright(meanLuma: Float) -> Bool { meanLuma > brightArtLuma }

    // MARK: Shader steps (per pixel, float, as in the AGSL)

    /// Step 1: twist around the centre — rotate `d = p − size/2` by `angle·((R − |d|)/R)²` when `|d| < R`.
    public static func twist(x: Float, y: Float, width: Float, height: Float, angle: Float = LyricsBackgroundShaderParams.twistAngle,
                             radius: Float) -> (x: Float, y: Float) {
        let cx = width * 0.5
        let cy = height * 0.5
        var dx = x - cx
        var dy = y - cy
        let dist = (dx * dx + dy * dy).squareRoot()
        if dist < radius {
            let k = (radius - dist) / radius
            let a = angle * k * k
            let cs = Float(Foundation.cos(Double(a)))
            let sn = Float(Foundation.sin(Double(a)))
            let nx = dx * cs - dy * sn
            let ny = dx * sn + dy * cs
            dx = nx
            dy = ny
        }
        return (cx + dx, cy + dy)
    }

    /// `toSprite`: maps a (twisted) screen point to sprite texels (texture centred on the origin) with the sprite's
    /// uniform `xf = (s·cosθ, s·sinθ, centreX, centreY)`.
    public static func toSprite(_ xf: SIMD4<Float>, x: Float, y: Float) -> (x: Float, y: Float) {
        let dx = x - xf.z
        let dy = y - xf.w
        return (xf.x * dx + xf.y * dy, xf.x * dy - xf.y * dx)
    }

    /// Premultiplied "over": `top + under·(1 − top.a)`.
    public static func blendOver(_ top: SIMD4<Float>, _ under: SIMD4<Float>) -> SIMD4<Float> {
        top + under * (1 - top.w)
    }

    /// Steps 3–5 for one pixel: un-premultiply the composite, grade (clamp at the end), black then white overlay, the
    /// bright-art scrim, interleaved-gradient dither, then premultiply by the crossfade `alpha`. Returns premultiplied
    /// RGBA in 0…1 (RGB may leave 0…1 by the dither, as on the GPU before storage).
    public static func shadePixel(composite col: SIMD4<Float>, pixelX: Float, pixelY: Float, scrim: Float,
                                  alpha: Float) -> SIMD4<Float> {
        let a = Swift.max(col.w, 0.0001)
        var r = col.x / a
        var g = col.y / a
        var b = col.z / a
        let luma = r * lumaR + g * lumaG + b * lumaB
        r = luma + (r - luma) * saturation
        g = luma + (g - luma) * saturation
        b = luma + (b - luma) * saturation
        r = ((r - 0.5) * contrast + 0.5) * brightness
        g = ((g - 0.5) * contrast + 0.5) * brightness
        b = ((b - 0.5) * contrast + 0.5) * brightness
        r = r.coerced(in: 0, 1)
        g = g.coerced(in: 0, 1)
        b = b.coerced(in: 0, 1)
        let overlaid = overlays(r, g, b, scrim: scrim)
        let d = (interleavedGradientNoise(x: pixelX, y: pixelY) - 0.5) / 255
        return SIMD4((overlaid.r + d) * alpha, (overlaid.g + d) * alpha, (overlaid.b + d) * alpha, alpha)
    }

    /// Step 4: black at 50 %, then white at 5 %, then the bright-art scrim (0 or 0.35).
    public static func overlays(_ r: Float, _ g: Float, _ b: Float, scrim: Float) -> (r: Float, g: Float, b: Float) {
        func one(_ v: Float) -> Float {
            var x = v * (1 - blackOverlay)
            x = x * (1 - whiteOverlay) + whiteOverlay
            return x * (1 - scrim)
        }
        return (one(r), one(g), one(b))
    }

    /// Interleaved-gradient noise (public domain): `fract(52.9829189 · fract(dot(p, (0.06711056, 0.00583715))))`.
    public static func interleavedGradientNoise(x: Float, y: Float) -> Float {
        func fract(_ v: Float) -> Float { v - v.rounded(.down) }
        return fract(52.9829189 * fract(x * 0.06711056 + y * 0.00583715))
    }
}

/// Uniform constants of the background shader (`LyricsBackgroundShader`).
public enum LyricsBackgroundShaderParams {
    public static let twistAngle: Float = -3.25
    /// Twist radius as a fraction of the short side.
    public static let twistRadiusFraction: Float = 1.0

    public static func twistRadius(width: Float, height: Float) -> Float {
        twistRadiusFraction * Swift.min(width, height)
    }
}

/// Sprite geometry of the baked artwork (`ArtworkSpriteBaker`).
public enum ArtworkSprites {
    /// Decoded art resolution, in texels.
    public static let artTexels = 96
    /// Screen-space blur σ as a fraction of the view's short side.
    public static let screenBlurFraction: Float = 0.09
    /// Art size of sprites 1–3 as a fraction of the long side; sprite 0 uses the diagonal.
    public static let spriteFractions: [Float] = [0, 0.80, 0.50, 0.25]

    /// On-screen size of the art region of sprite `k`: the diagonal for sprite 0 (covers the view at any rotation),
    /// else a fraction of the long side.
    public static func spriteArtSize(_ k: Int, width: Float, height: Float) -> Float {
        k == 0 ? (width * width + height * height).squareRoot() : spriteFractions[k] * ComposeBezier.javaMax(width, height)
    }

    /// Short/long side ratio in percent (10…100) — the only view metric the bake depends on.
    public static func aspectBucket(width: Int, height: Int) -> Int {
        let longSide = Swift.max(width, height)
        if longSide <= 0 { return 50 }
        let shortSide = Swift.max(Swift.min(width, height), 1)
        return Int(KotlinMath.roundToInt(Float(shortSide) * 100 / Float(longSide))).coerced(in: 10, 100)
    }

    /// Blur σ in texels for sprite `k`: `0.09 × (S / S_k) × 96`, where `S / S_k` depends only on the aspect ratio.
    public static func sigmaTexels(_ k: Int, aspectBucket: Int) -> Float {
        let ratio = Float(aspectBucket) / 100
        let shortOverSprite = k == 0 ? ratio / (1 + ratio * ratio).squareRoot() : ratio / spriteFractions[k]
        return screenBlurFraction * shortOverSprite * Float(artTexels)
    }

    /// Transparent padding (texels) around sprites 1–3: `ceil(3σ)`; sprite 0 is opaque and unpadded.
    public static func padTexels(_ k: Int, aspectBucket: Int) -> Int {
        k == 0 ? 0 : Int(KotlinMath.toInt((3 * sigmaTexels(k, aspectBucket: aspectBucket)).rounded(.up)))
    }
}

/// CPU blur for the tiny sprites: three box passes per axis approximate a Gaussian (box widths from the classic
/// "boxes for Gauss" fit), in premultiplied alpha so transparent padding doesn't bleed dark fringes.
public enum SpriteBlur {

    /// Box radii (one per pass) whose combined variance best matches σ². Radius 0 means "skip this pass".
    public static func boxRadiiForGaussian(_ sigma: Float, passes: Int = 3) -> [Int] {
        if sigma < 0.5 { return [Int](repeating: 0, count: passes) }
        let s2 = sigma * sigma
        let wIdeal = (12 * s2 / Float(passes) + 1).squareRoot()
        var wl = Int(KotlinMath.toInt(wIdeal.rounded(.down)))
        if wl % 2 == 0 { wl -= 1 }
        if wl < 1 { wl = 1 }
        let wu = wl + 2
        let p = Float(passes)
        let w = Float(wl)
        let mIdeal = (12 * s2 - p * w * w - 4 * p * w - 3 * p) / (-4 * w - 4)
        let m = Int(KotlinMath.roundToInt(mIdeal))
        return (0..<passes).map { i in ((i < m ? wl : wu) - 1) / 2 }
    }

    /// Places `art` (unpremultiplied ARGB, `artSize`²) centred on a transparent `(artSize + 2·pad)`² canvas, blurs it
    /// by `sigma` texels and returns unpremultiplied ARGB. When `opaque`, alpha is forced to 1 (art over black) and
    /// edges mirror, matching the MIRROR tile mode the base sprite is drawn with.
    public static func bakeSprite(art: [UInt32], artSize: Int, pad: Int, sigma: Float, opaque: Bool) -> [UInt32] {
        let size = artSize + 2 * pad
        let n = size * size
        var a = [Float](repeating: 0, count: n)
        var r = a
        var g = a
        var b = a
        for y in 0..<artSize {
            for x in 0..<artSize {
                let c = art[y * artSize + x]
                let srcA = Float(c >> 24) / 255
                let i = (y + pad) * size + (x + pad)
                a[i] = opaque ? 1 : srcA
                r[i] = Float((c >> 16) & 0xFF) / 255 * srcA
                g[i] = Float((c >> 8) & 0xFF) / 255 * srcA
                b[i] = Float(c & 0xFF) / 255 * srcA
            }
        }

        let radii = boxRadiiForGaussian(sigma)
        var line = [Float](repeating: 0, count: size)
        func blurPlane(_ plane: inout [Float]) {
            for radius in radii where radius > 0 {
                for y in 0..<size { boxPass(&plane, start: y * size, stride: 1, n: size, radius: radius, mirror: opaque, line: &line) }
                for x in 0..<size { boxPass(&plane, start: x, stride: size, n: size, radius: radius, mirror: opaque, line: &line) }
            }
        }
        if !opaque { blurPlane(&a) }
        blurPlane(&r)
        blurPlane(&g)
        blurPlane(&b)

        var out = [UInt32](repeating: 0, count: n)
        for i in 0..<n {
            let alpha = a[i].coerced(in: 0, 1)
            if alpha <= 1 / 512 { continue }
            let inv = 1 / alpha
            let ai = UInt32(Int(KotlinMath.roundToInt(alpha * 255)).coerced(in: 0, 255))
            let ri = UInt32(Int(KotlinMath.roundToInt(r[i] * inv * 255)).coerced(in: 0, 255))
            let gi = UInt32(Int(KotlinMath.roundToInt(g[i] * inv * 255)).coerced(in: 0, 255))
            let bi = UInt32(Int(KotlinMath.roundToInt(b[i] * inv * 255)).coerced(in: 0, 255))
            out[i] = (ai << 24) | (ri << 16) | (gi << 8) | bi
        }
        return out
    }

    /// One running-sum box pass over the `n` samples at `data[start + i·stride]`. Out-of-range samples are 0
    /// (transparent padding) or mirrored.
    static func boxPass(_ data: inout [Float], start: Int, stride: Int, n: Int, radius: Int, mirror: Bool,
                        line: inout [Float]) {
        for i in 0..<n { line[i] = data[start + i * stride] }
        let inv = 1 / Float(2 * radius + 1)
        var sum: Float = 0
        for j in -radius...radius { sum += sample(line, n, j, mirror) }
        for i in 0..<n {
            data[start + i * stride] = sum * inv
            sum += sample(line, n, i + radius + 1, mirror) - sample(line, n, i - radius, mirror)
        }
    }

    static func sample(_ line: [Float], _ n: Int, _ j: Int, _ mirror: Bool) -> Float {
        if j >= 0 && j < n { return line[j] }
        if !mirror { return 0 }
        let period = 2 * n
        let m = ((j % period) + period) % period
        return line[m >= n ? period - 1 - m : m]
    }
}

/// The background's motion and crossfade clock (`BackgroundAnimator`), generic over the identity of a baked sprite
/// set (e.g. the artwork key). Integrate every frame with `step`; draw with `phases`, `fade` and the set alphas.
public struct LyricsBackgroundMotion<SetID: Hashable & Sendable>: Sendable {
    /// Track-change crossfade (Apple: +0.02 alpha per 33 ms tick ≈ 1.7 s, linear).
    public static var crossfadeMs: Float { 1_700 }
    /// Redraw at 30 fps at most.
    public static var frameIntervalNanos: Int64 { 33_333_333 }
    /// Slack so a 60 Hz display lands on every 2nd frame rather than every 3rd.
    public static var frameSlackNanos: Int64 { 2_000_000 }
    /// Rotation rates in rad/s: Apple's per-33 ms increments × 30 (spec §2.2).
    public static var rotationRates: [Float] { [0.09, -0.24, -0.18, 0.12] }
    /// Reduced motion: every sprite turns at 0.03 rad/s and nothing orbits.
    public static var reducedMotionRate: Float { 0.03 }
    /// Orbit angle = rotation × 0.75, so phases wrap at 8π where rotation and orbit both repeat.
    public static var orbitFactor: Float { 0.75 }
    public static var phaseWrap: Double { Double.pi * 8 }
    /// Period of the no-art flowing gradient clock.
    public static var flowingGradientPeriodSeconds: Float { 50 }

    /// The set fading in (or shown). nil = no art.
    public private(set) var current: SetID?
    /// The set fading out, only during a crossfade.
    public private(set) var previous: SetID?
    /// False until it is known whether the track has art.
    public private(set) var resolved: Bool
    public let reducedMotion: Bool

    private var phaseAccum: [Double] = [0, 0, 0, 0]
    private var timeAccum: Double = 0
    private var pendingFade: Float = 1
    private let rates: [Float]

    public init(initial: SetID?, reducedMotion: Bool) {
        current = initial
        previous = nil
        resolved = initial != nil
        self.reducedMotion = reducedMotion
        rates = Self.rotationRates.map { r in reducedMotion ? Self.reducedMotionRate * (r < 0 ? -1 : 1) : r }
    }

    /// Rotation phase (rad) of each sprite, added to its random initial angle.
    public var phases: [Float] { phaseAccum.map { Float($0) } }
    /// Motion time in seconds (drives the no-art gradient).
    public var elapsedSeconds: Float { Float(timeAccum) }
    /// Crossfade progress 0…1.
    public var fade: Float { pendingFade }
    public var fadeDone: Bool { pendingFade >= 1 }

    /// Starts a crossfade to `next` (nil = no art). No-op if `next` is already the target.
    public mutating func show(_ next: SetID?) {
        if resolved && next == current { return }
        // Mid-fade: keep whichever set is contributing more as the outgoing one.
        let outgoing = (previous != nil && pendingFade < 0.5) ? previous : current
        if outgoing == next {
            previous = nil
            pendingFade = 1
        } else {
            previous = outgoing
            pendingFade = (outgoing == nil && next == nil) ? 1 : 0
        }
        current = next
        resolved = true
    }

    public mutating func step(dtSeconds: Float, motion: Bool) {
        if motion {
            for k in 0..<4 {
                phaseAccum[k] = (phaseAccum[k] + Double(rates[k] * dtSeconds)).truncatingRemainder(dividingBy: Self.phaseWrap)
            }
            timeAccum = (timeAccum + Double(dtSeconds)).truncatingRemainder(dividingBy: Double(Self.flowingGradientPeriodSeconds))
        }
        if pendingFade < 1 {
            pendingFade = (pendingFade + dtSeconds * 1000 / Self.crossfadeMs).coerced(atMost: 1)
        }
        if fadeDone && previous != nil { previous = nil }
    }

    public mutating func finishFade() {
        pendingFade = 1
        previous = nil
    }

    /// Alphas of the current and previous sets: previous at 1 under current at `fade` is a linear crossfade; with no
    /// incoming art the previous set fades out.
    public var setAlphas: (current: Float, previous: Float) {
        let f = pendingFade
        let currentAlpha: Float = current != nil ? f : 0
        let previousAlpha: Float
        if previous == nil {
            previousAlpha = 0
        } else if current != nil {
            previousAlpha = 1
        } else {
            previousAlpha = 1 - f
        }
        return (currentAlpha, previousAlpha)
    }

    /// Per-sprite placement (`computeGeometry`): centre, rotation and on-screen art size, for a set's random initial
    /// angles at the current phases.
    public func geometry(initialAngles: [Float], width w: Float, height h: Float)
        -> [(centerX: Float, centerY: Float, angle: Float, size: Float)] {
        let phases = self.phases
        return (0..<4).map { k in
            let theta = initialAngles[k] + phases[k]
            let orbit = Self.orbitFactor * (reducedMotion ? initialAngles[k] : theta)
            let cx: Float
            let cy: Float
            switch k {
            case 0:
                cx = w / 2
                cy = h / 2
            case 1:
                cx = w / 2.5
                cy = h / 2.5
            case 2:
                cx = w / 2 + 0.25 * w * LyricsKotlinFloat.cos(orbit)
                cy = h / 2 + 0.25 * w * LyricsKotlinFloat.sin(orbit)
            default:
                cx = w / 2 + 0.05 * w + 0.25 * w * LyricsKotlinFloat.cos(orbit)
                cy = h / 2 + 0.25 * w * LyricsKotlinFloat.sin(orbit)
            }
            return (cx, cy, theta, ArtworkSprites.spriteArtSize(k, width: w, height: h))
        }
    }

    /// The shader's per-sprite uniform `xf = (s·cosθ, s·sinθ, centreX, centreY)` with `s = 96 / artSize` texels/px.
    public func shaderUniforms(initialAngles: [Float], width: Float, height: Float) -> [SIMD4<Float>] {
        geometry(initialAngles: initialAngles, width: width, height: height).map { g in
            let s = Float(ArtworkSprites.artTexels) / g.size
            return SIMD4(s * LyricsKotlinFloat.cos(g.angle), s * LyricsKotlinFloat.sin(g.angle), g.centerX, g.centerY)
        }
    }
}
