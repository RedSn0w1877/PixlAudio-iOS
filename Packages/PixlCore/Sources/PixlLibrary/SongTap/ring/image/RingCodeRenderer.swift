import Foundation

// Draws a ring code into a grayscale picture the way a camera's Y plane records it (a port of the Android `RingCodeRenderer.kt`):
// at any rotation, tilt (perspective), blur, noise, contrast, glare patches, smudges and clutter. Floating point, so it lives
// in `ring/image`. It is a test helper and the Developer mode preview's drawing: the app draws the real code with SwiftUI Canvas.
// The same parameters and seeds give the same picture as Android up to the last bit of the maths library, which is why the
// round-trip sweeps (not golden files) are the acceptance tests of the image side.

/// A grayscale picture as a camera's Y plane records it, plus the "orangeness" map a chroma plane gives (255 where the start
/// dot's colour is, 0 elsewhere). `luma` is row-major, one byte per pixel.
public struct LumaImage: Sendable {
    public let width: Int
    public let height: Int
    public var luma: [UInt8]
    public var orange: [UInt8]

    public init(width: Int, height: Int, luma: [UInt8], orange: [UInt8]) {
        self.width = width
        self.height = height
        self.luma = luma
        self.orange = orange
    }
}

/// A bright patch (screen glare): adds up to `gain` luma at its centre, Gaussian falloff, an ellipse of radii `rx`, `ry` pixels turned by `angle`.
public struct Glare: Sendable {
    public var cx: Double
    public var cy: Double
    public var rx: Double
    public var ry: Double
    public var angle: Double
    public var gain: Double

    public init(cx: Double, cy: Double, rx: Double, ry: Double, angle: Double, gain: Double) {
        self.cx = cx; self.cy = cy; self.rx = rx; self.ry = ry; self.angle = angle; self.gain = gain
    }
}

/// A smudge on the lens or the screen: inside `radius` pixels of (`cx`, `cy`) the picture fades to `luma` by `alpha` (soft edge of 10 percent of the radius).
public struct Smudge: Sendable {
    public var cx: Double
    public var cy: Double
    public var radius: Double
    public var luma: Int
    public var alpha: Double

    public init(cx: Double, cy: Double, radius: Double, luma: Int, alpha: Double) {
        self.cx = cx; self.cy = cy; self.radius = radius; self.luma = luma; self.alpha = alpha
    }
}

public enum ArtMode: CaseIterable, Sendable { case texture, dark, light, stripes, orangeTexture }

/// How a test (or the Developer mode preview) wants a code drawn. Angles are radians. The plate is drawn `plateHalfPx` pixels
/// from its centre to its edge before tilt; tilt turns it about an axis through its centre (`tiltAxisRad` says which way) and
/// `camDistance` (in plate half-sizes) sets how strong the perspective is.
public struct RenderParams: Sendable {
    public var width = 360
    public var height = 360
    public var centerX: Double
    public var centerY: Double
    public var plateHalfPx = 130.0
    public var rotationRad = 0.0
    public var tiltRad = 0.0
    public var tiltAxisRad = 0.0
    public var camDistance = 6.0
    public var blurSigmaPx = 0.0
    public var noiseSigma = 0.0
    public var noiseSeed: Int64 = 1
    public var glares: [Glare] = []
    public var smudges: [Smudge] = []
    public var dotLuma = 58
    public var plateLuma = 238
    public var markerLuma = 105
    public var backgroundLuma = 120
    public var clutter = false
    public var artMode: ArtMode = .texture
    public var artSeed = 7
    public var supersample = 2
    /// Multiplies every luma value around 128 (a flat, low-contrast camera when below 1).
    public var contrast = 1.0
    /// Draws the start dot (a test can leave it out).
    public var marker = true

    public init(width: Int = 360, height: Int = 360, centerX: Double? = nil, centerY: Double? = nil, plateHalfPx: Double = 130.0,
                rotationRad: Double = 0.0, tiltRad: Double = 0.0, tiltAxisRad: Double = 0.0, camDistance: Double = 6.0,
                blurSigmaPx: Double = 0.0, noiseSigma: Double = 0.0, noiseSeed: Int64 = 1, glares: [Glare] = [], smudges: [Smudge] = [],
                dotLuma: Int = 58, plateLuma: Int = 238, markerLuma: Int = 105, backgroundLuma: Int = 120, clutter: Bool = false,
                artMode: ArtMode = .texture, artSeed: Int = 7, supersample: Int = 2, contrast: Double = 1.0, marker: Bool = true) {
        self.width = width
        self.height = height
        self.centerX = centerX ?? Double(width) / 2.0
        self.centerY = centerY ?? Double(height) / 2.0
        self.plateHalfPx = plateHalfPx
        self.rotationRad = rotationRad
        self.tiltRad = tiltRad
        self.tiltAxisRad = tiltAxisRad
        self.camDistance = camDistance
        self.blurSigmaPx = blurSigmaPx
        self.noiseSigma = noiseSigma
        self.noiseSeed = noiseSeed
        self.glares = glares
        self.smudges = smudges
        self.dotLuma = dotLuma
        self.plateLuma = plateLuma
        self.markerLuma = markerLuma
        self.backgroundLuma = backgroundLuma
        self.clutter = clutter
        self.artMode = artMode
        self.artSeed = artSeed
        self.supersample = supersample
        self.contrast = contrast
        self.marker = marker
    }
}

/// A rendered code and the matrix that placed it: `plateToImage` takes plate coordinates in permille (x right, y down, centre 0,0) to pixels.
public struct Rendered: Sendable {
    public let image: LumaImage
    public let plateToImage: [Double]
}

public enum RingCodeRenderer {

    /// The 3x3 homography (row major) from plate permille to pixels.
    public static func homography(_ p: RenderParams) -> [Double] {
        let cr = cos(p.rotationRad)
        let sr = sin(p.rotationRad)
        let ax = cos(p.tiltAxisRad)
        let ay = sin(p.tiltAxisRad)
        let ct = cos(p.tiltRad)
        let st = sin(p.tiltRad)
        // P = Rz * (x, y); tilt about axis a: P'.x = P.x ct + ax (a.P)(1-ct), P'.y = P.y ct + ay (a.P)(1-ct), P'.z = (ax P.y - ay P.x) st
        let rx = [cr, -sr, sr, cr] // [m11 m12; m21 m22] of Rz
        var b = [[Double]](repeating: [0, 0], count: 3)
        for j in 0...1 {
            let px = rx[0 * 2 + j]
            let py = rx[1 * 2 + j]
            let dot = ax * px + ay * py
            b[0][j] = px * ct + ax * dot * (1 - ct)
            b[1][j] = py * ct + ay * dot * (1 - ct)
            b[2][j] = (ax * py - ay * px) * st
        }
        let s = p.plateHalfPx / 1000.0
        let c1 = b[2][0] / p.camDistance / 1000.0
        let c2 = b[2][1] / p.camDistance / 1000.0
        return [
            p.centerX * c1 + s * b[0][0], p.centerX * c2 + s * b[0][1], p.centerX,
            p.centerY * c1 + s * b[1][0], p.centerY * c2 + s * b[1][1], p.centerY,
            c1, c2, 1.0,
        ]
    }

    public static func invert(_ h: [Double]) -> [Double] {
        let a = h[0], b = h[1], c = h[2]
        let d = h[3], e = h[4], f = h[5]
        let g = h[6], hh = h[7], i = h[8]
        let det = a * (e * i - f * hh) - b * (d * i - f * g) + c * (d * hh - e * g)
        let inv = 1.0 / det
        return [
            (e * i - f * hh) * inv, (c * hh - b * i) * inv, (b * f - c * e) * inv,
            (f * g - d * i) * inv, (a * i - c * g) * inv, (c * d - a * f) * inv,
            (d * hh - e * g) * inv, (b * g - a * hh) * inv, (a * e - b * d) * inv,
        ]
    }

    // MARK: Procedural art and clutter

    /// Int32 wrap-around arithmetic like the JVM's Int, so the same seed gives the same texture on both platforms.
    private static func hash(_ x: Int, _ y: Int, _ seed: Int) -> Double {
        let xi = Int32(truncatingIfNeeded: x), yi = Int32(truncatingIfNeeded: y), si = Int32(truncatingIfNeeded: seed)
        var h: Int32 = xi &* 374_761_393 &+ yi &* 668_265_263 &+ si &* 1_274_126_177
        h = (h ^ Int32(bitPattern: UInt32(bitPattern: h) >> 13)) &* 1_274_126_177
        h = h ^ Int32(bitPattern: UInt32(bitPattern: h) >> 16)
        return Double(h & 0xFFFF) / 65535.0
    }

    private static func valueNoise(_ x: Double, _ y: Double, _ seed: Int) -> Double {
        let x0 = ringInt(floor(x))
        let y0 = ringInt(floor(y))
        let fx = x - Double(x0)
        let fy = y - Double(y0)
        let sx = fx * fx * (3 - 2 * fx)
        let sy = fy * fy * (3 - 2 * fy)
        let a = hash(x0, y0, seed)
        let b = hash(x0 + 1, y0, seed)
        let c = hash(x0, y0 + 1, seed)
        let d = hash(x0 + 1, y0 + 1, seed)
        return (a + (b - a) * sx) * (1 - sy) + (c + (d - c) * sx) * sy
    }

    private struct Scene {
        let p: RenderParams
        let bits: [UInt8]
        var orange = 0.0
        private let bigR2 = Double(RingCodeLayout.bigRadius * RingCodeLayout.bigRadius)
        private let smallR2 = Double(RingCodeLayout.smallRadius * RingCodeLayout.smallRadius)
        private let markerR2 = Double(RingCodeLayout.markerRadius * RingCodeLayout.markerRadius)

        init(p: RenderParams, bits: [UInt8]) {
            self.p = p
            self.bits = bits
        }

        mutating func luma(_ qx: Double, _ qy: Double) -> Double {
            orange = 0.0
            let r = (qx * qx + qy * qy).squareRoot()
            if !insidePlate(qx, qy) { return outside(qx, qy) }
            if r < Double(RingCodeLayout.artRadius) { return art(qx, qy) }
            if r < Double(RingCodeLayout.bezelInner) { return Double(p.plateLuma) } // the light gap around the art
            if r < Double(RingCodeLayout.bezelOuter) { return Double(p.dotLuma) }
            if p.marker {
                let mdx = qx
                let mdy = qy + Double(RingCodeLayout.markerRadiusAt)
                if mdx * mdx + mdy * mdy <= markerR2 { orange = 1.0; return Double(p.markerLuma) }
            }
            // rings
            var ring = -1
            var best = 1e9
            for k in 0..<5 {
                let d = abs(r - Double(RingCodeLayout.ringRadius[k]))
                if d < best { best = d; ring = k }
            }
            if best <= Double(RingCodeLayout.bigRadius + 1) {
                let n = RingCodeLayout.ringSlots[ring]
                var ang = atan2(qx, -qy) // clockwise from 12 o'clock
                if ang < 0 { ang += 2 * Double.pi }
                let idx = ringInt((ang / (2 * Double.pi) * Double(n)) + 0.5) % n
                let a = Double(idx) * 2 * Double.pi / Double(n)
                let cx = Double(RingCodeLayout.ringRadius[ring]) * sin(a)
                let cy = -Double(RingCodeLayout.ringRadius[ring]) * cos(a)
                let dx = qx - cx
                let dy = qy - cy
                let d2 = dx * dx + dy * dy
                let big = bits[RingCodeLayout.slotOf(ring: ring, index: idx)] != 0
                if d2 <= (big ? bigR2 : smallR2) { return Double(p.dotLuma) }
            }
            return Double(p.plateLuma)
        }

        private func insidePlate(_ qx: Double, _ qy: Double) -> Bool {
            let lim = 1000.0 - Double(RingCodeLayout.plateCorner)
            let dx = max(abs(qx) - lim, 0.0)
            let dy = max(abs(qy) - lim, 0.0)
            return dx * dx + dy * dy <= Double(RingCodeLayout.plateCorner) * Double(RingCodeLayout.plateCorner)
        }

        private mutating func art(_ qx: Double, _ qy: Double) -> Double {
            switch p.artMode {
            case .dark: return 25.0
            case .light: return 245.0
            case .stripes: return (ringInt(floor(qx / 45.0)) + ringInt(floor(qy / 45.0))) & 1 == 0 ? 30.0 : 225.0
            case .texture: return 20.0 + 215.0 * RingCodeRenderer.valueNoise(qx / 80.0, qy / 80.0, p.artSeed)
            case .orangeTexture:
                let v = RingCodeRenderer.valueNoise(qx / 80.0, qy / 80.0, p.artSeed)
                orange = v > 0.5 ? 1.0 : 0.0
                return 20.0 + 215.0 * v
            }
        }

        private func outside(_ qx: Double, _ qy: Double) -> Double {
            var v = Double(p.backgroundLuma) + 18.0 * sin(qx / 600.0) * cos(qy / 700.0)
            if p.clutter {
                // dark book-spine bars and a few round objects around the plate, in the plate's plane
                for k in 0..<7 {
                    let cx = (RingCodeRenderer.hash(k, 1, 91) * 2.0 - 1.0) * 2600.0
                    let cy = (RingCodeRenderer.hash(k, 2, 91) * 2.0 - 1.0) * 2600.0
                    let w = 90.0 + RingCodeRenderer.hash(k, 3, 91) * 400.0
                    let hh = 90.0 + RingCodeRenderer.hash(k, 4, 91) * 400.0
                    if abs(cx) < 1250.0 && abs(cy) < 1250.0 { continue }
                    if abs(qx - cx) < w && abs(qy - cy) < hh { v = 35.0 + 30.0 * RingCodeRenderer.hash(k, 5, 91) }
                }
            }
            return v
        }
    }

    // MARK: Blur

    private static func boxBlurPass(_ src: [Float], _ dst: inout [Float], _ w: Int, _ h: Int, _ radius: Int, _ horizontal: Bool) {
        if radius <= 0 { dst = src; return }
        let n = horizontal ? w : h
        let lines = horizontal ? h : w
        let window = Float(2 * radius + 1)
        @inline(__always) func at(_ line: Int, _ i: Int) -> Float {
            let j = i < 0 ? 0 : (i >= n ? n - 1 : i)
            return horizontal ? src[line * w + j] : src[j * w + line]
        }
        for line in 0..<lines {
            var acc: Float = 0
            for i in -radius...radius { acc += at(line, i) }
            for i in 0..<n {
                let v = acc / window
                if horizontal { dst[line * w + i] = v } else { dst[i * w + line] = v }
                acc += at(line, i + radius + 1) - at(line, i - radius)
            }
        }
    }

    /// Gaussian-like blur: three box passes each way.
    public static func blur(_ values: inout [Float], _ w: Int, _ h: Int, _ sigma: Double) {
        if sigma <= 0.05 { return }
        let box = (12.0 * sigma * sigma / 3.0 + 1.0).squareRoot()
        let radius = max(0, ringInt((box - 1.0) / 2.0 + 0.5))
        var tmp = [Float](repeating: 0, count: values.count)
        for _ in 0..<3 {
            boxBlurPass(values, &tmp, w, h, radius, true)
            boxBlurPass(tmp, &values, w, h, radius, false)
        }
    }

    // MARK: Render

    public static func render(_ bits: [UInt8], _ p: RenderParams) -> Rendered {
        precondition(bits.count == RingCodeLayout.slots, "200 slot bits")
        let w = p.width
        let h = p.height
        let hom = homography(p)
        let inv = invert(hom)
        var scene = Scene(p: p, bits: bits)
        let ss = max(1, p.supersample)
        var img = [Float](repeating: 0, count: w * h)
        var orange = [UInt8](repeating: 0, count: w * h)
        let inv2 = 1.0 / Double(ss * ss)
        let bg = Double(p.backgroundLuma)
        for y in 0..<h {
            for x in 0..<w {
                var acc = 0.0
                var orangeAcc = 0.0
                for sy in 0..<ss {
                    for sx in 0..<ss {
                        let px = Double(x) + (Double(sx) + 0.5) / Double(ss)
                        let py = Double(y) + (Double(sy) + 0.5) / Double(ss)
                        let wq = inv[6] * px + inv[7] * py + inv[8]
                        let qx = (inv[0] * px + inv[1] * py + inv[2]) / wq
                        let qy = (inv[3] * px + inv[4] * py + inv[5]) / wq
                        acc += wq <= 0.0 ? bg : scene.luma(qx, qy)
                        orangeAcc += scene.orange
                    }
                }
                img[y * w + x] = Float(acc * inv2)
                orange[y * w + x] = UInt8(min(255, max(0, ringInt(orangeAcc * inv2 * 255.0 + 0.5))))
            }
        }
        // smudges (a physical overlay), then glare (light added before the lens blurs it)
        for s in p.smudges {
            let soft = max(1.0, s.radius * 0.10)
            let x0 = max(0, ringInt(s.cx - s.radius - soft))
            let x1 = min(w - 1, ringInt(s.cx + s.radius + soft))
            let y0 = max(0, ringInt(s.cy - s.radius - soft))
            let y1 = min(h - 1, ringInt(s.cy + s.radius + soft))
            if x0 > x1 || y0 > y1 { continue }
            for y in y0...y1 {
                for x in x0...x1 {
                    let dx = Double(x) + 0.5 - s.cx
                    let dy = Double(y) + 0.5 - s.cy
                    let d = (dx * dx + dy * dy).squareRoot()
                    let k = min(1.0, max(0.0, (s.radius + soft - d) / (2 * soft))) * s.alpha
                    if k > 0.0 {
                        let i = y * w + x
                        img[i] = Float(Double(img[i]) * (1 - k) + Double(s.luma) * k)
                        // Kotlin's Byte is signed: keep its arithmetic, so the map is the same as Android's (a quirk, only a tie-breaker)
                        let signed = Double(Int8(bitPattern: orange[i]))
                        orange[i] = UInt8(bitPattern: Int8(truncatingIfNeeded: ringInt(signed * (1 - k))))
                    }
                }
            }
        }
        for g in p.glares {
            let ca = cos(g.angle)
            let sa = sin(g.angle)
            let reach = 3.0 * max(g.rx, g.ry)
            let x0 = max(0, ringInt(g.cx - reach))
            let x1 = min(w - 1, ringInt(g.cx + reach))
            let y0 = max(0, ringInt(g.cy - reach))
            let y1 = min(h - 1, ringInt(g.cy + reach))
            if x0 > x1 || y0 > y1 { continue }
            for y in y0...y1 {
                for x in x0...x1 {
                    let dx = Double(x) + 0.5 - g.cx
                    let dy = Double(y) + 0.5 - g.cy
                    let u = (dx * ca + dy * sa) / g.rx
                    let v = (-dx * sa + dy * ca) / g.ry
                    img[y * w + x] += Float(g.gain * exp(-(u * u + v * v) / 2.0))
                }
            }
        }
        blur(&img, w, h, p.blurSigmaPx)
        var state = UInt64(bitPattern: p.noiseSeed) &* 0x9E37_79B9_7F4A_7C15 &+ 12345
        func nextUniform() -> Double {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z = z ^ (z >> 31)
            return Double(z >> 11) / 9007199254740992.0
        }
        var out = [UInt8](repeating: 0, count: w * h)
        let root3 = 3.0.squareRoot()
        for i in 0..<(w * h) {
            var v = Double(img[i])
            v = 128.0 + (v - 128.0) * p.contrast
            if p.noiseSigma > 0.0 {
                v += p.noiseSigma * (nextUniform() + nextUniform() + nextUniform() + nextUniform() - 2.0) * root3
            }
            out[i] = UInt8(min(255, max(0, ringInt(v))))
        }
        return Rendered(image: LumaImage(width: w, height: h, luma: out, orange: orange), plateToImage: hom)
    }

    /// A smudge sized to cover about `fraction` of the 200 data slots: a disc centred on a slot, grown until it covers that many.
    public static func smudgeCovering(_ bits: [UInt8], _ p: RenderParams, centerSlot: Int, fraction: Double, luma: Int, alpha: Double = 1.0) -> Smudge {
        let hom = homography(p)
        func slotPx(_ slot: Int) -> (Double, Double) {
            let ring = RingCodeLayout.ringOf(slot)
            let a = Double(RingCodeLayout.angleMicroTurns(slot)) / 1_000_000.0 * 2 * Double.pi
            let qx = Double(RingCodeLayout.ringRadius[ring]) * sin(a)
            let qy = -Double(RingCodeLayout.ringRadius[ring]) * cos(a)
            let wq = hom[6] * qx + hom[7] * qy + hom[8]
            return ((hom[0] * qx + hom[1] * qy + hom[2]) / wq, (hom[3] * qx + hom[4] * qy + hom[5]) / wq)
        }
        let c = slotPx(centerSlot)
        var dists = [Double](repeating: 0, count: RingCodeLayout.slots)
        for i in 0..<RingCodeLayout.slots {
            let s = slotPx(i)
            dists[i] = ((s.0 - c.0) * (s.0 - c.0) + (s.1 - c.1) * (s.1 - c.1)).squareRoot()
        }
        dists.sort()
        let k = max(1, ringInt(fraction * Double(RingCodeLayout.slots)))
        let radius = dists[min(k, dists.count - 1)] - 1.0
        return Smudge(cx: c.0, cy: c.1, radius: max(4.0, radius), luma: luma, alpha: alpha)
    }
}
