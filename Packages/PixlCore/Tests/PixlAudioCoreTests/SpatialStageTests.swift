import Foundation
import Testing
import PixlModel
@testable import PixlAudioCore

/// The on-device spatial stage (cloud audio spec of 2026-11-10, section 7, tables v1.1) against the worker's golden file
/// and against a plain double-precision port of the reference `process` (`spatial/preview.py`) for inputs long enough
/// to reach the room's longest delays, plus its ramps, its limiter and its bypass.
enum SpatialStageRig {
    static func coefficients() throws -> SpatialStageCoefficients {
        SpatialStageCoefficients(try SpatialFixtures.tables())
    }

    /// Runs a stereo signal through `stage` as interleaved Float buffers of the given sizes (cycled). `target` gives
    /// the wanted profile index (or −1) for the buffer that starts at a frame.
    static func run(_ stage: SpatialStage, left: [Float], right: [Float], sizes: [Int] = [1024],
                    wetLevel: (Int) -> Float = { _ in 1 }, target: (Int) -> Int) -> (left: [Float], right: [Float]) {
        let frames = left.count
        var interleaved = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            interleaved[2 * i] = left[i]
            interleaved[2 * i + 1] = right[i]
        }
        interleaved.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var done = 0, k = 0
            while done < frames {
                let n = min(max(sizes[k % sizes.count], 1), frames - done)
                stage.begin(frames: n, target: target(done))
                stage.process(left: base + 2 * done, right: base + 2 * done + 1, stride: 2, frames: n,
                              wetLevel: wetLevel(done))
                done += n
                k += 1
            }
        }
        var outLeft = [Float](repeating: 0, count: frames), outRight = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            outLeft[i] = interleaved[2 * i]
            outRight[i] = interleaved[2 * i + 1]
        }
        return (outLeft, outRight)
    }

    /// Seeded noise in −amplitude … amplitude.
    static func noise(_ frames: Int, amplitude: Double, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<frames).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float((Double(state >> 11) / Double(1 << 53) * 2 - 1) * amplitude)
        }
    }

    static func sine(_ frames: Int, frequency: Double, amplitude: Double, sampleRate: Int, phase: Double = 0) -> [Float] {
        (0..<frames).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / Double(sampleRate) + phase)) }
    }

    /// `preview.py`'s `process`, in Double, from a zero state (no limiter): the reference for inputs of any length.
    static func reference(_ left: [Double], _ right: [Double], table: SpatialPreviewTable,
                          sampleRate: Int) -> (left: [Double], right: [Double]) {
        let n = left.count
        let low = SpatialBiquad.lowpass(sampleRate: Double(sampleRate), cutoffHz: table.xoverHz)
        let room = SpatialBiquad.highpass(sampleRate: Double(sampleRate), cutoffHz: table.roomHpHz)
        func biquad(_ x: [Double], _ c: SpatialBiquad) -> [Double] {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            return x.map { x0 in
                let y0 = c.b0 * x0 + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
                x2 = x1; x1 = x0; y2 = y1; y1 = y0
                return y0
            }
        }
        let lowL = biquad(biquad(left, low), low), lowR = biquad(biquad(right, low), low)
        let hiL = zip(left, lowL).map { $0 - $1 }, hiR = zip(right, lowR).map { $0 - $1 }
        let rmL = biquad(hiL, room), rmR = biquad(hiR, room)
        var yL = [Double](repeating: 0, count: n), yR = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var sumL = 0.0, sumR = 0.0
            for k in 0..<min(table.taps, i + 1) {
                sumL += table.direct[k] * hiL[i - k] + table.cross[k] * hiR[i - k]
                sumR += table.direct[k] * hiR[i - k] + table.cross[k] * hiL[i - k]
            }
            yL[i] = sumL
            yR[i] = sumR
        }
        for tap in table.sparseL where tap.delay < n {
            for i in tap.delay..<n { yL[i] += tap.gainFromLeft * rmL[i - tap.delay] + tap.gainFromRight * rmR[i - tap.delay] }
        }
        for tap in table.sparseR where tap.delay < n {
            for i in tap.delay..<n { yR[i] += tap.gainFromLeft * rmL[i - tap.delay] + tap.gainFromRight * rmR[i - tap.delay] }
        }
        for i in table.lowDelay..<max(n, table.lowDelay) {
            yL[i] += lowL[i - table.lowDelay]
            yR[i] += lowR[i - table.lowDelay]
        }
        return (yL.map { $0 * table.gain }, yR.map { $0 * table.gain })
    }

    static func maxDifference(_ a: [Float], _ b: [Double]) -> Double {
        zip(a, b).map { abs(Double($0) - $1) }.max() ?? 0
    }

    static func maxStep(_ x: [Float], from start: Int = 1) -> Float {
        var m: Float = 0
        for i in max(start, 1)..<x.count { m = max(m, abs(x[i] - x[i - 1])) }
        return m
    }
}

@Suite("Spatial stage: the golden file")
struct SpatialStageGoldenTests {
    /// Spec 7 and 8: every profile at both rates reproduces the reference's output within the file's tolerance, from a
    /// zero state, before the limiter.
    @Test func everyProfileAndRateReproducesTheGoldenFile() throws {
        let coefficients = try SpatialStageRig.coefficients()
        let golden = try SpatialFixtures.golden()
        let left = golden.input.left.map(Float.init), right = golden.input.right.map(Float.init)
        for profile in SpatialProfile.allCases {
            for rate in SpatialPreviewTables.sampleRates {
                let expected = try #require(golden.output(for: profile, sampleRate: rate))
                let stage = try #require(SpatialStage(coefficients: coefficients, sampleRate: Double(rate)))
                stage.limits = false
                let index = SpatialStageCoefficients.index(of: profile)
                let out = SpatialStageRig.run(stage, left: left, right: right) { _ in index }
                let errorLeft = SpatialStageRig.maxDifference(out.left, expected.left)
                let errorRight = SpatialStageRig.maxDifference(out.right, expected.right)
                #expect(errorLeft <= golden.tolerance, "\(profile.rawValue) \(rate) left off by \(errorLeft)")
                #expect(errorRight <= golden.tolerance, "\(profile.rawValue) \(rate) right off by \(errorRight)")
            }
        }
    }

    /// The tap hands the stage buffers of any size (one frame to thousands): the history carries across them, so the
    /// output does not depend on how the song is cut.
    @Test func theOutputDoesNotDependOnTheBufferSizes() throws {
        let coefficients = try SpatialStageRig.coefficients()
        let golden = try SpatialFixtures.golden()
        let left = golden.input.left.map(Float.init), right = golden.input.right.map(Float.init)
        for profile in [SpatialProfile.studio, .hall, .night] {
            for rate in SpatialPreviewTables.sampleRates {
                let expected = try #require(golden.output(for: profile, sampleRate: rate))
                let stage = try #require(SpatialStage(coefficients: coefficients, sampleRate: Double(rate)))
                stage.limits = false
                let index = SpatialStageCoefficients.index(of: profile)
                let out = SpatialStageRig.run(stage, left: left, right: right, sizes: [1, 17, 300, 513, 4, 777]) { _ in
                    index
                }
                #expect(SpatialStageRig.maxDifference(out.left, expected.left) <= golden.tolerance)
                #expect(SpatialStageRig.maxDifference(out.right, expected.right) <= golden.tolerance)
            }
        }
    }

    /// Planar channels (stride 1) give what interleaved ones (stride 2) give.
    @Test func planarChannelsMatchInterleavedOnes() throws {
        let coefficients = try SpatialStageRig.coefficients()
        let golden = try SpatialFixtures.golden()
        var left = golden.input.left.map(Float.init), right = golden.input.right.map(Float.init)
        let stage = try #require(SpatialStage(coefficients: coefficients, sampleRate: 48_000))
        stage.limits = false
        let index = SpatialStageCoefficients.index(of: .wide)
        stage.begin(frames: left.count, target: index)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                stage.process(left: l.baseAddress!, right: r.baseAddress!, stride: 1, frames: l.count)
            }
        }
        let expected = try #require(golden.output(for: .wide, sampleRate: 48_000))
        #expect(SpatialStageRig.maxDifference(left, expected.left) <= golden.tolerance)
        #expect(SpatialStageRig.maxDifference(right, expected.right) <= golden.tolerance)
    }

    /// The golden file is 1024 frames, shorter than every room's first tap but the closest: over 20 000 frames of noise
    /// (past Concert Hall's ~8600-sample tail, through the ring's wrap) the stage follows the reference too.
    @Test func longInputsFollowTheReferenceThroughTheWholeRoom() throws {
        let tables = try SpatialFixtures.tables()
        let coefficients = SpatialStageCoefficients(tables)
        let frames = 20_000
        var left = SpatialStageRig.noise(frames, amplitude: 0.25, seed: 11)
        let right = SpatialStageRig.noise(frames, amplitude: 0.25, seed: 12)
        left[0] = 0.5
        for (profile, rate) in [(SpatialProfile.hall, 48_000), (.studio, 44_100), (.surround, 48_000)] {
            let table = try #require(tables.table(for: profile, sampleRate: rate))
            let expected = SpatialStageRig.reference(left.map(Double.init), right.map(Double.init), table: table,
                                                     sampleRate: rate)
            let stage = try #require(SpatialStage(coefficients: coefficients, sampleRate: Double(rate)))
            stage.limits = false
            let index = SpatialStageCoefficients.index(of: profile)
            let out = SpatialStageRig.run(stage, left: left, right: right, sizes: [4096, 333, 1024]) { _ in index }
            #expect(SpatialStageRig.maxDifference(out.left, expected.left) <= 1e-4, "\(profile) \(rate)")
            #expect(SpatialStageRig.maxDifference(out.right, expected.right) <= 1e-4, "\(profile) \(rate)")
        }
    }

    /// A v1 table of the older shape (no `roomHpHz`) is read as "no high-pass": the room hears the whole high band.
    @Test func aTableWithoutTheRoomHighPassFeedsTheRoomTheHighBand() throws {
        var tree = try SpatialFixtures.tree()
        var profiles = try #require(tree["profiles"] as? [String: Any])
        for (name, value) in profiles {
            var rates = try #require(value as? [String: Any])
            for (rate, table) in rates {
                var table = try #require(table as? [String: Any])
                table["roomHpHz"] = nil
                rates[rate] = table
            }
            profiles[name] = rates
        }
        tree["profiles"] = profiles
        let tables = try SpatialPreviewTables.decode(SpatialFixtures.encode(tree))
        let table = try #require(tables.table(for: .intimate, sampleRate: 44_100))
        #expect(table.roomHpHz == 0)
        let frames = 6_000
        let left = SpatialStageRig.noise(frames, amplitude: 0.25, seed: 3)
        let right = SpatialStageRig.noise(frames, amplitude: 0.25, seed: 4)
        let expected = SpatialStageRig.reference(left.map(Double.init), right.map(Double.init), table: table,
                                                 sampleRate: 44_100)
        let stage = try #require(SpatialStage(coefficients: SpatialStageCoefficients(tables), sampleRate: 44_100))
        stage.limits = false
        let index = SpatialStageCoefficients.index(of: .intimate)
        let out = SpatialStageRig.run(stage, left: left, right: right) { _ in index }
        #expect(SpatialStageRig.maxDifference(out.left, expected.left) <= 1e-4)
        #expect(SpatialStageRig.maxDifference(out.right, expected.right) <= 1e-4)
        // And it is not the v1.1 sound: the high-pass matters.
        let current = SpatialStage(coefficients: try SpatialStageRig.coefficients(), sampleRate: 44_100)
        let withHighPass = try #require(current)
        withHighPass.limits = false
        let other = SpatialStageRig.run(withHighPass, left: left, right: right) { _ in index }
        #expect(SpatialStageRig.maxDifference(other.left, expected.left) > 1e-3)
    }
}

@Suite("Spatial stage: coefficients")
struct SpatialStageCoefficientsTests {
    @Test func profileIndicesFollowTheSpecsOrder() {
        #expect(SpatialStageCoefficients.profiles == SpatialProfile.allCases)
        #expect(SpatialStageCoefficients.profileCount == SpatialProfile.allCases.count)
        #expect(SpatialStageCoefficients.rateCount == SpatialPreviewTables.sampleRates.count)
        for (i, profile) in SpatialProfile.allCases.enumerated() {
            #expect(SpatialStageCoefficients.index(of: profile) == i)
        }
        #expect(SpatialStageCoefficients.rateIndex(44_100) == 0)
        #expect(SpatialStageCoefficients.rateIndex(48_000.3) == 1)
        #expect(SpatialStageCoefficients.rateIndex(96_000) == nil)
    }

    @Test func onlyFortyFourOneAndFortyEightKilohertzGetAStage() throws {
        let coefficients = try SpatialStageRig.coefficients()
        #expect(SpatialStage(coefficients: coefficients, sampleRate: 44_100) != nil)
        #expect(SpatialStage(coefficients: coefficients, sampleRate: 48_000) != nil)
        for rate in [8_000.0, 22_050, 32_000, 88_200, 96_000, 192_000, 0] {
            #expect(SpatialStage(coefficients: coefficients, sampleRate: rate) == nil, "\(rate)")
        }
    }

    @Test func theRoomRingHoldsTheLongestDelayAndAPart() throws {
        let tables = try SpatialFixtures.tables()
        let coefficients = SpatialStageCoefficients(tables)
        #expect(coefficients.maxSparseDelay == tables.maxDelay)
        #expect(coefficients.maxTaps == 192)
        #expect(coefficients.headroomDb == tables.headroomDb)
        let stage = try #require(SpatialStage(coefficients: coefficients, sampleRate: 48_000))
        let capacity = stage.ringCapacity
        #expect(capacity & (capacity - 1) == 0)
        #expect(capacity >= coefficients.maxSparseDelay + SpatialStage.chunkFrames + 1)
        #expect(capacity >= tables.ringCapacity)
    }

    @Test func theBiquadsAreTheReferencesRBJDesigns() {
        let low = SpatialBiquad.lowpass(sampleRate: 48_000, cutoffHz: 120)
        // A low-pass passes DC: (b0 + b1 + b2) / (1 + a1 + a2) = 1.
        #expect(abs((low.b0 + low.b1 + low.b2) / (1 + low.a1 + low.a2) - 1) < 1e-9)
        #expect(abs(low.b1 - 2 * low.b0) < 1e-15 && low.b2 == low.b0)
        let high = SpatialBiquad.highpass(sampleRate: 44_100, cutoffHz: 250)
        // A high-pass stops DC and passes Nyquist: (b0 - b1 + b2) / (1 - a1 + a2) = 1.
        #expect(abs(high.b0 + high.b1 + high.b2) < 1e-12)
        #expect(abs((high.b0 - high.b1 + high.b2) / (1 - high.a1 + high.a2) - 1) < 1e-9)
        #expect(SpatialBiquad.highpass(sampleRate: 44_100, cutoffHz: 0) == .identity)
        #expect(SpatialBiquad.identity.isIdentity && !high.isIdentity)
    }
}

@Suite("Spatial stage: ramps, bypass and limiter")
struct SpatialStageRampTests {
    private let rate = 48_000
    private var rampFrames: Int { Int((SpatialStage.rampSeconds * Double(rate)).rounded(.up)) }

    /// A stage that starts bypassed never touches the sound.
    @Test func aBypassedStageLeavesTheSoundUntouched() throws {
        let stage = try #require(SpatialStage(coefficients: try SpatialStageRig.coefficients(), sampleRate: 44_100))
        let left = SpatialStageRig.noise(5_000, amplitude: 0.9, seed: 5)
        let right = SpatialStageRig.noise(5_000, amplitude: 0.9, seed: 6)
        let out = SpatialStageRig.run(stage, left: left, right: right, sizes: [512, 100]) { _ in SpatialStage.bypass }
        #expect(out.left == left && out.right == right)
        #expect(!stage.isActive && !stage.isDelayed && stage.engagement == 0)
        // Anything that is not a profile index is a bypass.
        let other = try #require(SpatialStage(coefficients: try SpatialStageRig.coefficients(), sampleRate: 44_100))
        let untouched = SpatialStageRig.run(other, left: left, right: right) { _ in 6 }
        #expect(untouched.left == left)
    }

    /// The first buffer of an item jumps to its target: an item that starts with Spatial audio on is fully on from its
    /// first frame (the reference's zero state).
    @Test func theFirstBufferStartsFullyOn() throws {
        let stage = try #require(SpatialStage(coefficients: try SpatialStageRig.coefficients(), sampleRate: Double(rate)))
        let first = stage.begin(frames: 256, target: SpatialStageCoefficients.index(of: .studio))
        #expect(first.start == 1 && first.end == 1)
        #expect(stage.isActive && stage.isDelayed && stage.currentProfile == 0)
        let bypassing = stage.begin(frames: 1_920, target: SpatialStage.bypass)
        #expect(bypassing.start == 1)
        #expect(abs(bypassing.end - 0.5) < 1e-6)   // 1920 frames of a 3840-frame ramp
    }

    /// Spec 7: switching the stage on and off, and changing profile, ramps over about 80 ms and never clicks: the
    /// largest step between two output samples stays that of the steady sound. Once fully off, the sound is the input
    /// delayed by `lowDelay` (lined up with the wet sound's centre, so going off had nothing to jump over).
    @Test func engagingBypassingAndChangingProfileNeverClick() throws {
        let coefficients = try SpatialStageRig.coefficients()
        let frames = 40_000
        let left = SpatialStageRig.sine(frames, frequency: 220, amplitude: 0.4, sampleRate: rate)
        let right = SpatialStageRig.sine(frames, frequency: 330, amplitude: 0.3, sampleRate: rate, phase: 1)
        let studio = SpatialStageCoefficients.index(of: .studio), hall = SpatialStageCoefficients.index(of: .hall)
        // off → studio at 4096 → hall at 14 000 → off at 24 000 → studio at 32 000
        func target(_ frame: Int) -> Int {
            switch frame {
            case ..<4_096: SpatialStage.bypass
            case ..<14_000: studio
            case ..<24_000: hall
            case ..<32_000: SpatialStage.bypass
            default: studio
            }
        }
        let stage = try #require(SpatialStage(coefficients: coefficients, sampleRate: Double(rate)))
        let out = SpatialStageRig.run(stage, left: left, right: right, sizes: [500, 256, 1024], target: target)

        // The steady sounds' own steps: the input, and each profile fully on.
        var steady = max(SpatialStageRig.maxStep(left), SpatialStageRig.maxStep(right))
        for index in [studio, hall] {
            let fully = try #require(SpatialStage(coefficients: coefficients, sampleRate: Double(rate)))
            let wet = SpatialStageRig.run(fully, left: left, right: right) { _ in index }
            steady = max(steady, SpatialStageRig.maxStep(wet.left, from: 2_000), SpatialStageRig.maxStep(wet.right, from: 2_000))
        }
        let worst = max(SpatialStageRig.maxStep(out.left), SpatialStageRig.maxStep(out.right))
        #expect(worst <= steady * 1.25, "a step of \(worst) against the steady sound's \(steady)")

        // Off again (from 24 000 + the ramp): exactly the input, delayed by lowDelay.
        let delay = try #require(SpatialFixtures.tables().table(for: .hall, sampleRate: rate)).lowDelay
        for i in (24_000 + rampFrames + 600)..<32_000 {
            #expect(out.left[i] == left[i - delay] && out.right[i] == right[i - delay])
            if out.left[i] != left[i - delay] { break }
        }
        #expect(stage.isActive && stage.currentProfile == studio)
    }

    /// The bypass ramp takes 80 ms; a change of profile goes down and up again in about the same, one part at most
    /// later.
    @Test func theRampsTakeAboutEightyMilliseconds() throws {
        let coefficients = try SpatialStageRig.coefficients()
        let stage = try #require(SpatialStage(coefficients: coefficients, sampleRate: Double(rate)))
        let silence = [Float](repeating: 0, count: 256)
        func step(_ target: Int) { _ = SpatialStageRig.run(stage, left: silence, right: silence, sizes: [256]) { _ in target } }
        step(SpatialStage.bypass)
        let studio = SpatialStageCoefficients.index(of: .studio)
        var frames = 0
        while stage.engagement < 1 && frames < 48_000 {
            step(studio)
            frames += 256
        }
        #expect(frames >= rampFrames - 256 && frames <= rampFrames + 256, "engaged after \(frames) frames")
        let night = SpatialStageCoefficients.index(of: .night)
        frames = 0
        while stage.currentProfile != night && frames < 48_000 {
            step(night)
            frames += 256
        }
        // Down to the dry sound in 40 ms, then the swap at the next part.
        #expect(frames <= rampFrames / 2 + 2 * 256, "swapped after \(frames) frames")
        #expect(stage.engagement == 1)
    }

    /// Spec 7: while the stage is active every output sample goes through `SoftLimiter` (−1 dBFS): nothing below the
    /// threshold changes, nothing ever passes full scale.
    @Test func theLimiterGuardsEveryOutputSampleWhileActive() throws {
        let coefficients = try SpatialStageRig.coefficients()
        let frames = 12_000
        // A hot master: noise near full scale, the same on both channels (a centred, loud mix).
        let left = SpatialStageRig.noise(frames, amplitude: 1, seed: 9)
        let right = left
        let index = SpatialStageCoefficients.index(of: .surround)
        let plain = try #require(SpatialStage(coefficients: coefficients, sampleRate: 44_100))
        plain.limits = false
        let unlimited = SpatialStageRig.run(plain, left: left, right: right) { _ in index }
        let limitedStage = try #require(SpatialStage(coefficients: coefficients, sampleRate: 44_100))
        let limited = SpatialStageRig.run(limitedStage, left: left, right: right) { _ in index }
        #expect(unlimited.left.contains { abs($0) > SoftLimiter.defaultThreshold }, "the test signal never reaches the limiter")
        for i in 0..<frames {
            #expect(limited.left[i] == SoftLimiter.limit(unlimited.left[i]))
            #expect(abs(limited.left[i]) <= 1 && abs(limited.right[i]) <= 1)
            if limited.left[i] != SoftLimiter.limit(unlimited.left[i]) { break }
        }
    }

    /// The level rule's factor (spec 6.3) applies to the spatial sound only and moves across a buffer, never jumps.
    @Test func theWetLevelScalesTheSpatialSoundAndRamps() throws {
        let coefficients = try SpatialStageRig.coefficients()
        let left = SpatialStageRig.noise(4_096, amplitude: 0.2, seed: 21)
        let right = SpatialStageRig.noise(4_096, amplitude: 0.2, seed: 22)
        let index = SpatialStageCoefficients.index(of: .studio)
        let unity = try #require(SpatialStage(coefficients: coefficients, sampleRate: 44_100))
        unity.limits = false
        let one = SpatialStageRig.run(unity, left: left, right: right, sizes: [1_024]) { _ in index }
        let louder = try #require(SpatialStage(coefficients: coefficients, sampleRate: 44_100))
        louder.limits = false
        // 1 for the first buffer, 1.585 from the second on (ramped across the second).
        let raised = SpatialStageRig.run(louder, left: left, right: right, sizes: [1_024],
                                         wetLevel: { $0 == 0 ? 1 : 1.585 }) { _ in index }
        for i in 0..<1_024 { #expect(raised.left[i] == one.left[i]) }
        for i in 2_048..<4_096 { #expect(abs(raised.left[i] - 1.585 * one.left[i]) <= 1e-5) }
        // Across the second buffer the factor climbs linearly.
        let middle = 1_024 + 512
        let factor = one.left[middle] != 0 ? raised.left[middle] / one.left[middle] : 1.29
        #expect(abs(factor - (1 + 0.585 * Float(513) / 1_024)) < 0.01 || one.left[middle] == 0)
    }

    /// A seek: the stage forgets the old position (no room tail from it), keeps its ramps, and goes on as from silence.
    @Test func aResetForgetsTheSoundSoFar() throws {
        let coefficients = try SpatialStageRig.coefficients()
        let index = SpatialStageCoefficients.index(of: .hall)
        let noise = SpatialStageRig.noise(9_000, amplitude: 0.3, seed: 31)
        let stage = try #require(SpatialStage(coefficients: coefficients, sampleRate: 48_000))
        stage.limits = false
        _ = SpatialStageRig.run(stage, left: noise, right: noise) { _ in index }
        stage.reset()
        let impulse = (0..<4_000).map { $0 == 0 ? Float(0.5) : 0 }
        let after = SpatialStageRig.run(stage, left: impulse, right: impulse) { _ in index }
        let fresh = try #require(SpatialStage(coefficients: coefficients, sampleRate: 48_000))
        fresh.limits = false
        let expected = SpatialStageRig.run(fresh, left: impulse, right: impulse) { _ in index }
        #expect(after.left == expected.left && after.right == expected.right)
    }
}
