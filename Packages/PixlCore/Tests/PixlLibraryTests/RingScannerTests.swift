import Foundation
import Testing
@testable import PixlLibrary

/// The round-trip sweeps of the ring code's image side (the Android `RingScannerTest.kt`): the Swift renderer draws a code with an
/// impairment, the Swift scanner reads it. The same sweeps, seeds and floors as Android; the numbers are the acceptance tests.
/// Synthetic pictures only: a real camera will differ.
@Suite("Pixl ring scanner sweeps")
struct RingScannerTests {
    typealias H = RingScanHarness
    private let deg = H.deg

    @Test func aCleanUprightCodeReads() {
        let scanner = RingScanner()
        var rng = RingRng(11)
        let c = H.randomCase(&rng)
        let r = RingCodeRenderer.render(c.bits, RenderParams())
        let res = scanner.scan(H.frameOf(r))
        #expect(H.ok(res, c), "\(H.describe(res, scanner))")
        let d = scanner.diagnostics
        #expect(d.markerFound && d.found)
        #expect(d.matched >= 190, "matched \(d.matched)")
        #expect(d.residualPx < 0.6, "residual \(d.residualPx)")
    }

    @Test func rotationZeroTo360Degrees() {
        let scanner = RingScanner()
        var rng = RingRng(21)
        let sweep = H.Sweep("rotation every 3 degrees")
        var d = 0
        while d < 360 {
            let c = H.randomCase(&rng)
            let p = RenderParams(rotationRad: Double(d) * deg)
            sweep.record(H.scan(scanner, c, p), c, "rot \(d)", scanner)
            d += 3
        }
        sweep.report()
        #expect(sweep.good == sweep.total, "\(sweep.message)")
    }

    @Test func tiltUpTo30DegreesAboutEveryAxis() {
        let scanner = RingScanner()
        var rng = RingRng(31)
        let sweep = H.Sweep("tilt 0..30 degrees, 8 axes, random rotation")
        for tilt in [5, 10, 15, 20, 25, 30] {
            for axis in stride(from: 0, to: 360, by: 45) {
                let c = H.randomCase(&rng)
                let p = RenderParams(rotationRad: Double(rng.int(360)) * deg, tiltRad: Double(tilt) * deg, tiltAxisRad: Double(axis) * deg)
                sweep.record(H.scan(scanner, c, p), c, "tilt \(tilt) axis \(axis)", scanner)
            }
        }
        sweep.report()
        #expect(sweep.good >= sweep.total - 2, "\(sweep.message)")
    }

    @Test func blurAndNoise() {
        let scanner = RingScanner()
        var rng = RingRng(41)
        // The plate is 260 px across here: a dot is 4 to 8 px wide, the outline 3 px. Blur of 2 px is far past what a focused phone
        // camera gives at this size (reported, not asserted); the large-plate test below goes further.
        let blur = H.Sweep("blur 0.5..1.5 px at 260 px plate")
        for sigma in [0.5, 1.0, 1.5] {
            for i in 0..<12 {
                let c = H.randomCase(&rng)
                let p = RenderParams(rotationRad: Double(rng.int(360)) * deg, tiltRad: Double(rng.int(20)) * deg, tiltAxisRad: Double(rng.int(360)) * deg, blurSigmaPx: sigma)
                blur.record(H.scan(scanner, c, p), c, "blur \(sigma) #\(i)", scanner)
            }
        }
        blur.report()
        let heavy = H.Sweep("blur 2.0 px at 260 px plate (past the limit)")
        for i in 0..<10 {
            let c = H.randomCase(&rng)
            let p = RenderParams(rotationRad: Double(rng.int(360)) * deg, blurSigmaPx: 2.0)
            heavy.record(H.scan(scanner, c, p), c, "blur 2.0 #\(i)", scanner)
        }
        print(heavy.line())
        let noise = H.Sweep("noise sigma 4..16 levels")
        for sigma in [4.0, 8.0, 12.0, 16.0] {
            for i in 0..<10 {
                let c = H.randomCase(&rng)
                let p = RenderParams(rotationRad: Double(rng.int(360)) * deg, tiltRad: Double(rng.int(20)) * deg, tiltAxisRad: Double(rng.int(360)) * deg,
                                     blurSigmaPx: 0.7, noiseSigma: sigma, noiseSeed: rng.signedLong())
                noise.record(H.scan(scanner, c, p), c, "noise \(sigma) #\(i)", scanner)
            }
        }
        noise.report()
        #expect(blur.good >= blur.total - 1, "\(blur.message)")
        #expect(noise.good >= noise.total - 4, "\(noise.line())")
    }

    @Test func aLargerPlateTakesProportionallyMoreBlur() {
        let scanner = RingScanner()
        // 640 x 640 frame, plate 520 px across: the same relative blur as above, twice the pixels. A real frame is bigger still.
        var rng = RingRng(43)
        let sweep = H.Sweep("blur 1..3 px at 520 px plate")
        for sigma in [1.0, 2.0, 3.0] {
            for i in 0..<8 {
                let c = H.randomCase(&rng)
                let p = RenderParams(width: 640, height: 640, plateHalfPx: 260.0, rotationRad: Double(rng.int(360)) * deg,
                                     tiltRad: Double(rng.int(20)) * deg, tiltAxisRad: Double(rng.int(360)) * deg, blurSigmaPx: sigma)
                sweep.record(H.scan(scanner, c, p), c, "big blur \(sigma) #\(i)", scanner)
            }
        }
        sweep.report()
        #expect(sweep.good >= sweep.total - 1, "\(sweep.message)")
        // the cliff: past about 1.5 percent of the plate's half-size the thin outline ring melts away and no plate is found
        let past = H.Sweep("blur 4 px at 520 px plate (past the limit)")
        for i in 0..<6 {
            let c = H.randomCase(&rng)
            let p = RenderParams(width: 640, height: 640, plateHalfPx: 260.0, rotationRad: Double(rng.int(360)) * deg, blurSigmaPx: 4.0)
            past.record(H.scan(scanner, c, p), c, "past \(i)", scanner)
        }
        print(past.line())
    }

    @Test func smudgesOverUpTo20PercentOfTheSlots() {
        let scanner = RingScanner()
        var rng = RingRng(51)
        for fraction in [0.10, 0.15, 0.20] {
            let sweep = H.Sweep("smudge \(Int(fraction * 100)) percent of the slots")
            for i in 0..<40 {
                let c = H.randomCase(&rng)
                let base = RenderParams(rotationRad: Double(rng.int(360)) * deg, tiltRad: Double(rng.int(20)) * deg, tiltAxisRad: Double(rng.int(360)) * deg, blurSigmaPx: 0.6)
                let smudge = RingCodeRenderer.smudgeCovering(c.bits, base, centerSlot: rng.int(200), fraction: fraction, luma: i % 2 == 0 ? 205 : 135)
                let p = RenderParams(rotationRad: base.rotationRad, tiltRad: base.tiltRad, tiltAxisRad: base.tiltAxisRad, blurSigmaPx: 0.6, smudges: [smudge])
                sweep.record(H.scan(scanner, c, p), c, "smudge #\(i)", scanner)
            }
            sweep.report()
            #expect(sweep.good >= sweep.total - 2, "\(sweep.message)")
        }
    }

    @Test func glarePatches() {
        let scanner = RingScanner()
        var rng = RingRng(61)
        let sweep = H.Sweep("one to two glare patches, 25..55 px")
        for i in 0..<60 {
            let c = H.randomCase(&rng)
            var glares: [Glare] = []
            for _ in 0..<(1 + rng.int(2)) {
                let cx = 110.0 + Double(rng.int(140))
                let cy = 110.0 + Double(rng.int(140))
                let rx = 25.0 + Double(rng.int(30))
                let ry = 15.0 + Double(rng.int(30))
                let angle = Double(rng.int(180)) * deg
                let gain = 200.0 + Double(rng.int(100))
                glares.append(Glare(cx: cx, cy: cy, rx: rx, ry: ry, angle: angle, gain: gain))
            }
            let p = RenderParams(rotationRad: Double(rng.int(360)) * deg, tiltRad: Double(rng.int(20)) * deg, tiltAxisRad: Double(rng.int(360)) * deg,
                                 blurSigmaPx: 0.6, glares: glares)
            sweep.record(H.scan(scanner, c, p), c, "glare #\(i)", scanner)
        }
        sweep.report()
        #expect(sweep.good >= sweep.total * 4 / 5, "\(sweep.message)")
    }

    @Test func clutterAndEveryKindOfArtwork() {
        let scanner = RingScanner()
        var rng = RingRng(71)
        let sweep = H.Sweep("clutter + art modes + off-centre plate")
        for mode in ArtMode.allCases {
            for i in 0..<16 {
                let c = H.randomCase(&rng)
                let cx = 190.0 + Double(rng.int(100))
                let cy = 160.0 + Double(rng.int(40))
                let half = 120.0 + Double(rng.int(30))
                let rot = Double(rng.int(360)) * deg
                let tilt = Double(rng.int(25)) * deg
                let axis = Double(rng.int(360)) * deg
                let seed = rng.int(1000)
                let p = RenderParams(width: 480, height: 360, centerX: cx, centerY: cy, plateHalfPx: half, rotationRad: rot, tiltRad: tilt, tiltAxisRad: axis,
                                     blurSigmaPx: 0.6, noiseSigma: 4.0, noiseSeed: rng.signedLong(), clutter: true, artMode: mode, artSeed: seed)
                let res = H.scan(scanner, c, p, withHue: i % 2 == 0)
                sweep.record(res, c, "\(mode) #\(i)", scanner)
            }
        }
        sweep.report()
        #expect(sweep.good >= sweep.total - 4, "\(sweep.message)")
    }
}
