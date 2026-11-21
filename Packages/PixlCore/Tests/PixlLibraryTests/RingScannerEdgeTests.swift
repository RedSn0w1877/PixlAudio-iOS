import Foundation
import Testing
@testable import PixlLibrary

/// The renderer, the scanner's edge cases, the accumulator, the fuzz and the style rules (the Android `RingScannerEdgeTest`,
/// `RingScannerFuzzTest`, `RingScannerLimitsTest` and `RingCodeStyleTest`).
@Suite("Pixl ring scanner edges")
struct RingScannerEdgeTests {
    typealias H = RingScanHarness
    private let deg = H.deg

    // MARK: The renderer

    @Test func theRendererIsDeterministic() {
        var rng = RingRng(1)
        let c = H.randomCase(&rng)
        let p = RenderParams(rotationRad: 0.7, tiltRad: 0.3, blurSigmaPx: 0.8, noiseSigma: 6.0, noiseSeed: 9)
        let a = RingCodeRenderer.render(c.bits, p).image
        let b = RingCodeRenderer.render(c.bits, p).image
        #expect(a.luma == b.luma)
        #expect(a.orange == b.orange)
    }

    @Test func bigDotsCarryFourTimesTheDarkMassOfSmallOnes() {
        let p = RenderParams(supersample: 3)
        let allBig = RingCodeRenderer.render([UInt8](repeating: 1, count: RingCodeLayout.slots), p).image
        let allSmall = RingCodeRenderer.render([UInt8](repeating: 0, count: RingCodeLayout.slots), p).image
        func dark(_ img: LumaImage) -> Int { img.luma.reduce(0) { $0 + 255 - Int($1) } }
        // the art disc, outline and start dot are the same in both, so compare what differs
        let diff = dark(allBig) - dark(allSmall)
        #expect(diff > 0)
        let perPixel = Double(p.plateLuma - p.dotLuma)
        let scale = p.plateHalfPx / 1000.0
        let bigR = Double(RingCodeLayout.bigRadius), smallR = Double(RingCodeLayout.smallRadius)
        let extraArea = Double(RingCodeLayout.slots) * Double.pi * (bigR * bigR - smallR * smallR) * scale * scale
        let expected = extraArea * perPixel
        #expect(abs(Double(diff) - expected) <= expected * 0.04, "diff \(diff) expected \(expected)")
    }

    @Test func thePlateMatrixPutsTheStartDotWhereTheGeometrySays() {
        var rng = RingRng(2)
        let c = H.randomCase(&rng)
        let p = RenderParams(rotationRad: 40 * deg, tiltRad: 20 * deg, tiltAxisRad: 70 * deg)
        let r = RingCodeRenderer.render(c.bits, p)
        let h = r.plateToImage
        let qx = 0.0
        let qy = -Double(RingCodeLayout.markerRadiusAt)
        let w = h[6] * qx + h[7] * qy + h[8]
        let px = Int((h[0] * qx + h[1] * qy + h[2]) / w)
        let py = Int((h[3] * qx + h[4] * qy + h[5]) / w)
        #expect(Int(r.image.orange[py * r.image.width + px]) > 200, "orange map at the start dot")
        let lumaOfMarker = Double(RingCodeStyle.lumaOf(UInt32(bitPattern: RingCodeLayout.markerArgb)))
        #expect(abs(lumaOfMarker - Double(p.markerLuma)) <= 6.0, "the renderer's start dot luma is the one a camera would see")
    }

    @Test func tiltSqueezesThePlate() {
        var rng = RingRng(3)
        let c = H.randomCase(&rng)
        func width(_ tilt: Double) -> Int {
            let r = RingCodeRenderer.render(c.bits, RenderParams(tiltRad: tilt, tiltAxisRad: 0.0))
            // axis 0 tilts about the x axis: the y extent shrinks
            var lo = r.image.height
            var hi = 0
            for y in 0..<r.image.height {
                for x in 0..<r.image.width where r.image.luma[y * r.image.width + x] > 220 {
                    if y < lo { lo = y }
                    if y > hi { hi = y }
                }
            }
            return hi - lo
        }
        #expect(Double(width(60 * deg)) < Double(width(0.0)) * 0.75)
    }

    @Test func aSmudgeSizedForAFractionCoversAboutThatManySlots() {
        var rng = RingRng(4)
        let c = H.randomCase(&rng)
        let p = RenderParams()
        for fraction in [0.1, 0.2] {
            let s = RingCodeRenderer.smudgeCovering(c.bits, p, centerSlot: 77, fraction: fraction, luma: 200)
            var inside = 0
            let h = RingCodeRenderer.homography(p)
            for slot in 0..<RingCodeLayout.slots {
                let ring = RingCodeLayout.ringOf(slot)
                let a = Double(RingCodeLayout.angleMicroTurns(slot)) / 1_000_000.0 * 2 * Double.pi
                let qx = Double(RingCodeLayout.ringRadius[ring]) * sin(a)
                let qy = -Double(RingCodeLayout.ringRadius[ring]) * cos(a)
                let px = h[0] * qx + h[1] * qy + h[2]
                let py = h[3] * qx + h[4] * qy + h[5]
                if (px - s.cx) * (px - s.cx) + (py - s.cy) * (py - s.cy) <= s.radius * s.radius { inside += 1 }
            }
            #expect(abs(fraction * Double(RingCodeLayout.slots) - Double(inside)) <= 4.0, "fraction \(fraction): \(inside) inside")
        }
    }

    // MARK: The scanner

    @Test func aCodeOnADeviceColourPaletteReadsDarkOrPale() {
        let scanner = RingScanner()
        var rng = RingRng(81)
        var good = 0
        var total = 0
        for _ in 0..<40 {
            let device = UInt32(0xFF00_0000) | UInt32(rng.int(1 << 24))
            let pal = RingCodeStyle.palette(device)
            let c = H.randomCase(&rng)
            let rot = Double(rng.int(360)) * deg
            let tilt = Double(rng.int(25)) * deg
            let axis = Double(rng.int(360)) * deg
            let p = RenderParams(rotationRad: rot, tiltRad: tilt, tiltAxisRad: axis, blurSigmaPx: 0.7, noiseSigma: 3.0, noiseSeed: rng.signedLong(),
                                 dotLuma: RingCodeStyle.lumaOf(pal.dot), plateLuma: RingCodeStyle.lumaOf(pal.plate), markerLuma: RingCodeStyle.lumaOf(pal.marker))
            total += 1
            if H.ok(H.scan(scanner, c, p), c) { good += 1 }
        }
        print("device-colour palettes: \(good) / \(total) read")
        #expect(good >= total - 1, "\(good) / \(total)")
    }

    @Test func lowContrastAndAFlatDimCameraStillRead() {
        let scanner = RingScanner()
        var rng = RingRng(91)
        var good = 0
        var total = 0
        for contrast in [0.5, 0.35] {
            for _ in 0..<8 {
                let c = H.randomCase(&rng)
                let rot = Double(rng.int(360)) * deg
                let tilt = Double(rng.int(20)) * deg
                let axis = Double(rng.int(360)) * deg
                let p = RenderParams(rotationRad: rot, tiltRad: tilt, tiltAxisRad: axis, blurSigmaPx: 0.6, noiseSigma: 3.0, noiseSeed: rng.signedLong(), contrast: contrast)
                total += 1
                if H.ok(H.scan(scanner, c, p), c) { good += 1 }
            }
        }
        print("low contrast (0.5 and 0.35 of full): \(good) / \(total) read")
        #expect(good >= total - 2, "\(good) / \(total)")
    }

    @Test func theStartDotCanBeHiddenAndTheCodeStillReads() {
        let scanner = RingScanner()
        var rng = RingRng(101)
        var good = 0
        for _ in 0..<24 {
            let c = H.randomCase(&rng)
            let rot = Double(rng.int(360)) * deg
            let tilt = Double(rng.int(20)) * deg
            let axis = Double(rng.int(360)) * deg
            let p = RenderParams(rotationRad: rot, tiltRad: tilt, tiltAxisRad: axis, blurSigmaPx: 0.6, marker: false)
            let res = H.scan(scanner, c, p, withHue: false)
            if H.ok(res, c) { good += 1 }
            #expect(!(res.isDecoded && !H.ok(res, c)), "never a wrong code")
        }
        print("no start dot: \(good) / 24 read")
        #expect(good >= 20, "\(good) / 24")
    }

    @Test func theOrangeHueMapIsAHintNotARequirement() {
        let scanner = RingScanner()
        var rng = RingRng(111)
        for _ in 0..<12 {
            let c = H.randomCase(&rng)
            let rot = Double(rng.int(360)) * deg
            let tilt = Double(rng.int(20)) * deg
            let axis = Double(rng.int(360)) * deg
            let p = RenderParams(rotationRad: rot, tiltRad: tilt, tiltAxisRad: axis, artMode: .orangeTexture, artSeed: rng.int(99))
            let withHue = H.scan(scanner, c, p, withHue: true)
            #expect(H.ok(withHue, c), "with the hue map: \(H.describe(withHue, scanner))")
            let without = H.scan(scanner, c, p, withHue: false)
            #expect(H.ok(without, c), "without it: \(H.describe(without, scanner))")
        }
    }

    @Test func chromaToOrangeness() {
        // the start dot (0xD9480F) is about U 75, V 205
        #expect(RingHue.orangeness(u: 75, v: 205) > 200)
        #expect(RingHue.orangeness(u: 128, v: 128) == 0)
        #expect(RingHue.orangeness(u: 200, v: 100) == 0) // blue
        #expect(RingHue.orangeness(u: 60, v: 130) == 0) // cyan-green
        #expect(RingHue.orangeness(u: 128, v: 200) == 0) // magenta-red, no U shift
    }

    @Test func diagnosticsDescribeWhatWasSeen() {
        let scanner = RingScanner()
        var rng = RingRng(121)
        let c = H.randomCase(&rng)
        let r = RingCodeRenderer.render(c.bits, RenderParams(rotationRad: 1.0, tiltRad: 0.3, blurSigmaPx: 0.8, noiseSigma: 5.0))
        var t: Int64 = 0
        let res = scanner.scan(H.frameOf(r)) { t += 1_000_000; return t }
        #expect(res.isDecoded)
        let d = scanner.diagnostics
        #expect(d.found && d.markerFound)
        #expect(d.slotConfidence.count == RingCodeLayout.slots)
        let confident = d.slotConfidence.filter { $0 >= 60 }.count
        #expect(confident >= 180, "confident slots: \(confident)")
        #expect(d.slotBits.count == RingCodeLayout.slots)
        for s in 0..<RingCodeLayout.slots { #expect(c.bits[s] == d.slotBits[s], "slot \(s)") }
        #expect(d.scanMicros > 0)
        #expect(d.scale == 1)
        // the reported plate centre is the real one
        #expect(abs(r.plateToImage[2] - d.centreX) <= 2.0)
        #expect(abs(r.plateToImage[5] - d.centreY) <= 2.0)
    }

    @Test func aBigFrameIsDownscaledAndStillReads() {
        let scanner = RingScanner()
        var rng = RingRng(131)
        let c = H.randomCase(&rng)
        let p = RenderParams(width: 1280, height: 960, centerX: 600.0, centerY: 470.0, plateHalfPx: 380.0, rotationRad: 2.0, tiltRad: 0.35, tiltAxisRad: 1.0,
                             blurSigmaPx: 2.0, noiseSigma: 4.0, noiseSeed: 5, clutter: true, supersample: 1)
        let r = RingCodeRenderer.render(c.bits, p)
        let res = scanner.scan(H.frameOf(r))
        #expect(H.ok(res, c), "\(H.describe(res, scanner))")
        #expect(scanner.diagnostics.scale == 2)
        #expect(abs(p.centerX - scanner.diagnostics.centreX) <= 3.0)
    }

    @Test func scanTimeOnThisMachine() {
        let scanner = RingScanner()
        var rng = RingRng(141)
        let c = H.randomCase(&rng)
        let small = RingCodeRenderer.render(c.bits, RenderParams(rotationRad: 1.2, tiltRad: 0.3, noiseSigma: 4.0))
        let frame = H.frameOf(small)
        for _ in 0..<3 { _ = scanner.scan(frame) }
        var times: [Int64] = []
        for _ in 0..<10 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = scanner.scan(frame)
            times.append(Int64(DispatchTime.now().uptimeNanoseconds - t0) / 1000)
        }
        times.sort()
        print("scan time (debug build, one core): 360x360 median \(times[times.count / 2]) us worst \(times.last ?? 0) us")
        #expect(times[times.count / 2] < 2_000_000, "scan far too slow: \(times[times.count / 2]) us")
    }

    // MARK: The accumulator

    private func decoded(_ id: String, _ random: Int = 7) -> RingScanResult {
        .decoded(payload: RingCodePayload(videoId: id, minuteBucket: 5, random: random), corrected: 0, erasures: 0)
    }

    private func failed() -> RingScanResult { .failed(.unreadable) }

    @Test func threeConsistentDecodesInARowAccept() {
        var acc = RingScanAccumulator()
        #expect(acc.offer(decoded("dQw4w9WgXcQ"), nowMs: 0) == nil)
        #expect(acc.offer(decoded("dQw4w9WgXcQ"), nowMs: 100) == nil)
        #expect(acc.offer(decoded("dQw4w9WgXcQ"), nowMs: 200)?.videoId == "dQw4w9WgXcQ")
    }

    @Test func aDifferentDecodeInBetweenStartsAgain() {
        var acc = RingScanAccumulator()
        _ = acc.offer(decoded("dQw4w9WgXcQ"), nowMs: 0)
        _ = acc.offer(decoded("dQw4w9WgXcQ"), nowMs: 100)
        #expect(acc.offer(decoded("aaaaaaaaaaa"), nowMs: 200) == nil) // another code: the run restarts at one
        #expect(acc.offer(decoded("dQw4w9WgXcQ"), nowMs: 300) == nil)
        #expect(acc.offer(decoded("dQw4w9WgXcQ"), nowMs: 400) == nil)
        #expect(acc.offer(decoded("dQw4w9WgXcQ"), nowMs: 500) != nil)
        // the same video with another tag is another code too
        var acc2 = RingScanAccumulator()
        _ = acc2.offer(decoded("dQw4w9WgXcQ", 1), nowMs: 0)
        _ = acc2.offer(decoded("dQw4w9WgXcQ", 1), nowMs: 10)
        #expect(acc2.offer(decoded("dQw4w9WgXcQ", 2), nowMs: 20) == nil)
    }

    @Test func aFailedFrameNeitherCountsNorBreaksTheRunButALongGapDoes() {
        var acc = RingScanAccumulator()
        _ = acc.offer(decoded("dQw4w9WgXcQ"), nowMs: 0)
        #expect(acc.offer(failed(), nowMs: 100) == nil)
        #expect(acc.offer(decoded("dQw4w9WgXcQ"), nowMs: 200) == nil)
        #expect(acc.offer(decoded("dQw4w9WgXcQ"), nowMs: 300) != nil)
        var stale = RingScanAccumulator()
        _ = stale.offer(decoded("dQw4w9WgXcQ"), nowMs: 0)
        _ = stale.offer(decoded("dQw4w9WgXcQ"), nowMs: 100)
        #expect(stale.offer(failed(), nowMs: 5_000) == nil)
        #expect(stale.offer(decoded("dQw4w9WgXcQ"), nowMs: 5_100) == nil) // the old run is gone: this is the first again
        #expect(stale.offer(decoded("dQw4w9WgXcQ"), nowMs: 5_200) == nil)
        #expect(stale.offer(decoded("dQw4w9WgXcQ"), nowMs: 5_300) != nil)
    }

    @Test func resetForgetsTheRun() {
        var acc = RingScanAccumulator()
        _ = acc.offer(decoded("dQw4w9WgXcQ"), nowMs: 0)
        _ = acc.offer(decoded("dQw4w9WgXcQ"), nowMs: 10)
        acc.reset()
        #expect(acc.offer(decoded("dQw4w9WgXcQ"), nowMs: 20) == nil)
    }

    @Test func threeRealFramesOfAMovingCameraAccept() {
        let scanner = RingScanner()
        var rng = RingRng(151)
        let c = H.randomCase(&rng)
        var acc = RingScanAccumulator()
        var accepted: RingCodePayload?
        for i in 0..<5 {
            let p = RenderParams(centerX: 175.0 + Double(i) * 3, centerY: 183.0 - Double(i) * 2,
                                 rotationRad: Double(20 + i * 9) * deg, tiltRad: Double(8 + i) * deg, tiltAxisRad: 1.0,
                                 blurSigmaPx: 0.7, noiseSigma: 5.0, noiseSeed: Int64(i))
            let res = H.scan(scanner, c, p)
            accepted = acc.offer(res, nowMs: Int64(i) * 66) ?? accepted
        }
        #expect(accepted == c.payload)
    }
}
