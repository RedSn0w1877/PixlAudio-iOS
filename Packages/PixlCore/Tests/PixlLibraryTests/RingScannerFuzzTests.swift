import Foundation
import Testing
@testable import PixlLibrary

/// Garbage in, "no code" out: the scanner never traps, never reads a code out of noise, and never reads a wrong one out of a
/// damaged code (the Android `RingScannerFuzzTest`), plus the limits report (`RingScannerLimitsTest`) and the style rules
/// (`RingCodeStyleTest`).
@Suite("Pixl ring scanner fuzz, limits and style")
struct RingScannerFuzzTests {
    typealias H = RingScanHarness
    private let deg = H.deg

    private func frame(_ w: Int, _ h: Int, _ fill: (Int, Int) -> Int) -> RingFrame {
        var luma = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { luma[y * w + x] = UInt8(truncatingIfNeeded: fill(x, y)) } }
        return RingFrame(width: w, height: h, luma: luma)
    }

    @Test func randomImagesNeverDecodeAndNeverTrap() {
        let scanner = RingScanner()
        var rng = RingRng(1001)
        var decoded = 0
        var plates = 0
        var reasons: [String: Int] = [:]
        for i in 0..<160 {
            let w = 64 + rng.int(400)
            let h = 64 + rng.int(400)
            let f: RingFrame
            switch i % 8 {
            case 0: f = frame(w, h) { _, _ in rng.int(256) } // white noise
            case 1: f = frame(w, h) { x, y in ((x / 7) + (y / 7)) % 2 == 0 ? 20 : 230 } // checkerboard
            case 2: f = frame(w, h) { _, _ in 0 }
            case 3: f = frame(w, h) { _, _ in 255 }
            case 4: f = frame(w, h) { x, y in min(255, x * 255 / w + y * 90 / h) } // gradient
            case 5: // random dark discs on light
                var discs: [[Int]] = []
                for _ in 0..<(30 + rng.int(60)) { discs.append([rng.int(w), rng.int(h), 2 + rng.int(w / 6 + 4)]) }
                f = frame(w, h) { x, y in discs.contains { (x - $0[0]) * (x - $0[0]) + (y - $0[1]) * (y - $0[1]) <= $0[2] * $0[2] } ? 40 : 225 }
            case 6: // concentric rings and dots like a code, but not one
                let cx = Double(w) / 2.0
                let cy = Double(h) / 2.0
                f = frame(w, h) { x, y in
                    let r = ((Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy)).squareRoot()
                    return r < 0.2 * Double(min(w, h)) || (Int(r) / 9) % 3 == 0 && rng.int(3) == 0 ? 40 : 225
                }
            default: f = frame(w, h) { x, y in (x * y) % 97 < 40 ? 30 : 220 } // moire
            }
            switch scanner.scan(f) {
            case .decoded: decoded += 1
            case .failed(let reason): reasons[reason.code, default: 0] += 1
            }
            if scanner.diagnostics.found { plates += 1 }
        }
        print("fuzz: 160 random images, \(decoded) decoded, \(plates) looked like a plate, reasons \(reasons)")
        #expect(decoded == 0)
    }

    @Test func degenerateFramesFailCleanly() {
        let scanner = RingScanner()
        #expect(!scanner.scan(RingFrame(width: 10, height: 10, luma: [UInt8](repeating: 0, count: 100))).isDecoded)
        #expect(!scanner.scan(RingFrame(width: 100, height: 100, luma: [UInt8](repeating: 0, count: 50))).isDecoded)
        #expect(!scanner.scan(RingFrame(width: 0, height: 0, luma: [])).isDecoded)
        #expect(!scanner.scan(RingFrame(width: 64, height: 64, luma: [UInt8](repeating: 0, count: 64 * 64), hue: [0], hueWidth: 1, hueHeight: 1)).isDecoded)
        let huge = RingFrame(width: 2000, height: 1500, luma: (0..<(2000 * 1500)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        #expect(!scanner.scan(huge).isDecoded)
    }

    @Test func aDamagedCodeIsReadRightOrNotAtAll() {
        let scanner = RingScanner()
        var rng = RingRng(2002)
        var right = 0
        var failed = 0
        var wrong = 0
        for _ in 0..<80 {
            let c = H.randomCase(&rng)
            let rot = Double(rng.int(360)) * Double.pi / 180
            let tilt = Double(rng.int(25)) * Double.pi / 180
            let axis = Double(rng.int(360)) * Double.pi / 180
            let noiseSeed = rng.signedLong()
            // random smudges and glare of any size at any place: from harmless to far past what the code can repair
            var smudges: [Smudge] = []
            for _ in 0..<(1 + rng.int(5)) {
                smudges.append(Smudge(cx: 60.0 + Double(rng.int(240)), cy: 60.0 + Double(rng.int(240)), radius: 12.0 + Double(rng.int(70)),
                                      luma: rng.int(256), alpha: 0.5 + Double(rng.int(51)) / 100.0))
            }
            var glares: [Glare] = []
            for _ in 0..<rng.int(3) {
                glares.append(Glare(cx: 60.0 + Double(rng.int(240)), cy: 60.0 + Double(rng.int(240)), rx: 15.0 + Double(rng.int(60)), ry: 15.0 + Double(rng.int(60)),
                                    angle: Double(rng.int(180)) * Double.pi / 180, gain: 100.0 + Double(rng.int(200))))
            }
            let p = RenderParams(rotationRad: rot, tiltRad: tilt, tiltAxisRad: axis, blurSigmaPx: 0.6, noiseSigma: 4.0, noiseSeed: noiseSeed, glares: glares, smudges: smudges)
            let res = H.scan(scanner, c, p)
            if H.ok(res, c) { right += 1 } else if res.isDecoded { wrong += 1 } else { failed += 1 }
        }
        print("damage fuzz: 80 codes with random smudges and glare of any size: \(right) read right, \(failed) not read, \(wrong) read wrong")
        #expect(wrong == 0, "a damaged code must never read as another code")
    }

    @Test func aCodeWithWholeFramesOfGarbageInBetweenDoesNotPoisonTheAccumulator() {
        let scanner = RingScanner()
        var rng = RingRng(3003)
        let c = H.randomCase(&rng)
        var acc = RingScanAccumulator()
        var accepted = 0
        for i in 0..<12 {
            let res: RingScanResult
            if i % 2 == 0 {
                res = H.scan(scanner, c, RenderParams(rotationRad: Double(i) * 0.3, noiseSigma: 4.0, noiseSeed: Int64(i)))
            } else {
                res = scanner.scan(frame(300, 300) { _, _ in rng.int(256) })
            }
            if acc.offer(res, nowMs: Int64(i) * 80) != nil { accepted += 1 }
        }
        #expect(accepted >= 1)
    }

    // MARK: Limits (reported, with loose floors)

    private func rate(_ label: String, _ steps: [Double], trials: Int = 6, _ build: (Double, inout RingRng, Int) -> RenderParams) -> [(Double, Int)] {
        let scanner = RingScanner()
        var out: [(Double, Int)] = []
        var rng = RingRng(0x51)
        for step in steps {
            var good = 0
            for i in 0..<trials {
                let c = H.randomCase(&rng)
                let p = build(step, &rng, i)
                if H.ok(H.scan(scanner, c, p), c) { good += 1 }
            }
            out.append((step, good))
        }
        print("limit \(label): " + out.map { "\($0.0)=\($0.1)/\(trials)" }.joined(separator: "  "))
        return out
    }

    @Test func limitTilt() {
        let r = rate("tilt degrees", [30.0, 40.0, 50.0, 60.0, 70.0]) { t, rng, _ in
            RenderParams(rotationRad: Double(rng.int(360)) * deg, tiltRad: t * deg, tiltAxisRad: Double(rng.int(360)) * deg, blurSigmaPx: 0.6)
        }
        #expect((r.first { $0.0 == 30.0 }?.1 ?? 0) >= 5)
    }

    @Test func limitNoise() {
        let r = rate("noise sigma (levels of 255)", [16.0, 24.0, 32.0, 48.0, 64.0]) { n, rng, _ in
            RenderParams(rotationRad: Double(rng.int(360)) * deg, tiltRad: 15 * deg, tiltAxisRad: Double(rng.int(360)) * deg,
                         blurSigmaPx: 0.7, noiseSigma: n, noiseSeed: rng.signedLong())
        }
        #expect((r.first { $0.0 == 16.0 }?.1 ?? 0) >= 5)
    }

    @Test func limitContrast() {
        let r = rate("contrast (share of full)", [0.5, 0.35, 0.25, 0.18, 0.12]) { k, rng, _ in
            RenderParams(rotationRad: Double(rng.int(360)) * deg, tiltRad: 15 * deg, tiltAxisRad: Double(rng.int(360)) * deg,
                         blurSigmaPx: 0.6, noiseSigma: 2.0, noiseSeed: rng.signedLong(), contrast: k)
        }
        #expect((r.first { $0.0 == 0.5 }?.1 ?? 0) >= 5)
    }

    @Test func limitPlateSize() {
        let r = rate("plate width in pixels", [260.0, 200.0, 160.0, 130.0, 100.0]) { w, rng, _ in
            RenderParams(plateHalfPx: w / 2, rotationRad: Double(rng.int(360)) * deg, tiltRad: 15 * deg, tiltAxisRad: Double(rng.int(360)) * deg,
                         blurSigmaPx: 0.6, noiseSigma: 3.0, noiseSeed: rng.signedLong())
        }
        #expect((r.first { $0.0 == 260.0 }?.1 ?? 0) >= 5)
    }

    @Test func limitBlur() {
        let r = rate("blur sigma at 260 px plate", [1.0, 1.25, 1.5, 1.75, 2.0]) { b, rng, _ in
            RenderParams(rotationRad: Double(rng.int(360)) * deg, tiltRad: 10 * deg, tiltAxisRad: Double(rng.int(360)) * deg, blurSigmaPx: b)
        }
        #expect((r.first { $0.0 == 1.0 }?.1 ?? 0) >= 5)
    }

    @Test func limitSmudge() {
        let r = rate("smudge percent of slots", [20.0, 25.0, 30.0, 35.0, 40.0]) { f, rng, i in
            let rot = Double(rng.int(360)) * deg
            let axis = Double(rng.int(360)) * deg
            var inner = RingRng(UInt64(bitPattern: rng.signedLong()))
            let c0 = H.randomCase(&inner)
            let base = RenderParams(rotationRad: rot, tiltRad: 15 * deg, tiltAxisRad: axis, blurSigmaPx: 0.6)
            let s = RingCodeRenderer.smudgeCovering(c0.bits, base, centerSlot: rng.int(200), fraction: f / 100.0, luma: i % 2 == 0 ? 205 : 135)
            return RenderParams(rotationRad: base.rotationRad, tiltRad: base.tiltRad, tiltAxisRad: base.tiltAxisRad, blurSigmaPx: 0.6, smudges: [s])
        }
        #expect((r.first { $0.0 == 20.0 }?.1 ?? 0) >= 5)
    }

    // MARK: Style

    private let black: UInt32 = 0xFF00_0000
    private let white: UInt32 = 0xFFFF_FFFF

    @Test func contrastRatioFollowsWCAG() {
        #expect(abs(RingCodeStyle.contrastRatio(black, white) - 21.0) < 0.001)
        #expect(abs(RingCodeStyle.contrastRatio(white, black) - 21.0) < 0.001)
        #expect(abs(RingCodeStyle.contrastRatio(0xFF33_6699, 0xFF33_6699) - 1.0) < 1e-9)
        // WCAG's own example: #777777 on white is 4.48:1
        #expect(abs(RingCodeStyle.contrastRatio(0xFF77_7777, white) - 4.48) < 0.01)
    }

    @Test func toneIsCIELStar() {
        #expect(abs(RingCodeStyle.toneOf(black) - 0.0) < 0.01)
        #expect(abs(RingCodeStyle.toneOf(white) - 100.0) < 0.01)
        #expect(abs(RingCodeStyle.toneOf(0xFF80_8080) - 53.59) < 0.05)
    }

    @Test func aDarkDeviceColourIsKeptAsItIs() {
        let device: UInt32 = 0xFF1F_3A8A
        let p = RingCodeStyle.palette(device)
        #expect(!p.clamped)
        #expect(p.dot == device)
        #expect(p.contrast >= RingCodeStyle.minContrast)
    }

    @Test func aPaleDeviceColourIsDarkenedUntilItPassesSevenToOne() {
        for device: UInt32 in [0xFFFF_FF00, 0xFFFF_E08A, 0xFF9F_E8FF, white, 0xFFC8_F0C8] {
            let p = RingCodeStyle.palette(device)
            #expect(p.clamped, "pale colour \(String(device, radix: 16)) is clamped")
            #expect(p.contrast >= RingCodeStyle.minContrast, "contrast \(p.contrast)")
            #expect(p.dotTone >= 15.0, "tone \(p.dotTone)")
        }
    }

    @Test func everyDeviceColourGetsAToneNinetyFivePlateAndDotsAtLeastSevenToOne() {
        var rng = RingRng(5)
        var clamped = 0
        var worst = 99.0
        for _ in 0..<2000 {
            let device = UInt32(0xFF00_0000) | UInt32(rng.int(1 << 24))
            let p = RingCodeStyle.palette(device)
            if p.clamped { clamped += 1 }
            worst = min(worst, p.contrast)
            #expect(p.contrast >= RingCodeStyle.minContrast, "device \(String(device, radix: 16)) -> contrast \(p.contrast)")
            #expect(abs(p.plateTone - RingCodeStyle.plateTone) <= 1.0, "plate tone \(p.plateTone)")
            #expect(p.marker == UInt32(bitPattern: RingCodeLayout.markerArgb))
            #expect((p.dot >> 24) & 0xFF == 0xFF)
            #expect((p.plate >> 24) & 0xFF == 0xFF)
        }
        print("palette: 2000 random device colours, \(clamped) darkened, worst contrast \(worst)")
    }

    @Test func thePlateKeepsTheHueOfTheDeviceColour() {
        let plate = RingCodeStyle.palette(0xFF2E_7D32).plate // green
        let g = (plate >> 8) & 0xFF
        let r = (plate >> 16) & 0xFF
        let b = plate & 0xFF
        #expect(g >= r && g >= b, "green plate leans green: \(r) \(g) \(b)")
    }

    @Test func aTransparentDeviceColourIsReadAsOpaque() {
        let a = RingCodeStyle.palette(0x001F_3A8A)
        let b = RingCodeStyle.palette(0xFF1F_3A8A)
        #expect(a.dot == b.dot)
        #expect(a.plate == b.plate)
    }

    @Test func theDotRadiiKeepBigAtTwiceSmallAndTheStartDotIsOrange() {
        #expect(RingCodeStyle.bigToSmallRadius == Double(RingCodeStyle.bigRadius()) / Double(RingCodeStyle.smallRadius()))
        let m = UInt32(bitPattern: RingCodeLayout.markerArgb)
        let r = (m >> 16) & 0xFF
        let g = (m >> 8) & 0xFF
        let b = m & 0xFF
        #expect(r > 180 && g >= 40 && g <= 120 && b < 60, "orange: \(r) \(g) \(b)")
        #expect(RingCodeStyle.contrastRatio(m, RingCodeStyle.palette(white).plate) >= 3.0)
    }
}
