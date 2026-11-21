import Foundation
import Testing
@testable import PixlLibrary

/// The owner's two real calibration logs of 2026-11-20 (iPhone and Pixel 10 Pro, same session) as fixtures, and the detector run over
/// them: Android's `RealTraces.kt` and `RealTraceTest.kt`. The iPhone is the REFERENCE scale (offset 0); the Pixel trace is run with the
/// offset -15 the Android app adds, to prove the two platforms agree on the same physical touch.
///
/// What is REAL here: every "listed" point (time on the phone's own boot clock, raw RSSI) copied from the logs' excerpts. What is NOT:
/// the logs list only an excerpt, so the long stretches of "resting 20 to 30 cm apart" are filled with a fixed, repeating pattern that
/// stays inside the range the logs state for that stretch (iPhone -55 to -65 around -60; Pixel -40 to -48 around -44), one reading every
/// `cadenceMs` (the logs say readings arrive about every 120 to 130 ms). Where two listed points are more than `densifyOverMs` apart the
/// missing readings are filled by straight-line interpolation at the same cadence (touch and approach points only). Nothing else is invented.
enum SongTapRealTraces {
    static let cadenceMs: Int64 = 125
    static let densifyOverMs: Int64 = 200

    struct Pt: Equatable {
        var t: Int64
        var raw: Int
        init(_ t: Int64, _ raw: Int) { self.t = t; self.raw = raw }
    }

    /// Linear interpolation between listed points, one reading per `cadenceMs`; the listed points themselves are kept as they are.
    static func densify(_ points: [Pt]) -> [Pt] {
        var out: [Pt] = []
        for (i, p) in points.enumerated() {
            out.append(p)
            guard i + 1 < points.count else { continue }
            let next = points[i + 1]
            if next.t - p.t <= densifyOverMs { continue }
            var t = p.t + cadenceMs
            while next.t - t >= cadenceMs / 2 {
                let raw = p.raw + Int(Int64(next.raw - p.raw) * (t - p.t) / (next.t - p.t))
                out.append(Pt(t, raw))
                t += cadenceMs
            }
        }
        return out
    }

    static func rest(_ fromMs: Int64, _ toMs: Int64, _ cycle: [Int]) -> [Pt] {
        var out: [Pt] = []
        var t = fromMs
        var i = 0
        while t < toMs {
            out.append(Pt(t, cycle[i % cycle.count]))
            t += cadenceMs
            i += 1
        }
        return out
    }

    // iPhone (its own scale: the reference scale, offset 0)

    static let iphoneRestCycle = [-60, -57, -62, -59, -63, -58, -61, -60, -64, -56]
    static let iphoneRestBeforeTapCycle = [-64, -61, -66, -63, -67, -62, -65, -64, -68, -60]

    static let iphoneTap1Listed: [Pt] = [
        Pt(20946591, -51), Pt(20946714, -48), Pt(20946843, -47), Pt(20946969, -53), Pt(20947090, -48),
        Pt(20947480, -37), Pt(20947600, -42), Pt(20947722, -37), Pt(20947851, -35), Pt(20947990, -35),
        Pt(20948110, -36), Pt(20948362, -34), Pt(20948996, -32), Pt(20949126, -45), Pt(20949766, -61),
        Pt(20950647, -68), Pt(20951142, -76),
    ]
    static let iphoneTap1 = densify(iphoneTap1Listed)
    static let iphoneTap1JumpMs: Int64 = 20947480
    static let iphoneTap1FiredMs: Int64 = 20947990
    static let iphoneFirstTap = rest(20_941_000, 20946591, iphoneRestBeforeTapCycle) + iphoneTap1
    static let iphoneIdle = rest(20_958_500, 20_968_500, iphoneRestCycle)

    // Pixel 10 Pro (raw, its own scale: about 15 dB hotter)

    static let pixelRestCycle = [-44, -42, -46, -43, -47, -42, -45, -41, -46, -44]
    static let pixelTouch1Listed: [Pt] = [
        Pt(701272664, -42), Pt(701274390, -40), Pt(701275801, -27), Pt(701276643, -20), Pt(701277071, -19),
        Pt(701277459, -18), Pt(701278213, -44), Pt(701279799, -45),
    ]
    static let pixelTouch1 = densify(pixelTouch1Listed)
    static let pixelTouch2Listed: [Pt] = [Pt(701295763, -46), Pt(701296194, -30), Pt(701296754, -18), Pt(701297202, -24)]
    static let pixelTouch2 = densify(pixelTouch2Listed)
    static let pixelTouch1FirstRiseMs: Int64 = 701275801
    static let pixelTouch2FirstRiseMs: Int64 = 701296194
    static let pixelSession: [Pt] =
        rest(701_262_664 - 10_000, 701_272_664, pixelRestCycle) + pixelTouch1 +
        rest(701_279_799 + cadenceMs, 701_295_763, pixelRestCycle) + pixelTouch2
    static let pixelIdle = rest(701_202_002, 701_214_002, pixelRestCycle)
    static let pixelIdleConstant = rest(701_202_002, 701_214_002, [-44])

    struct Fire { var tMs: Int64; var reason: SongTapFireReason }
    struct Run { var fires: [Fire]; var near: [(Int64, Bool)]; var finalState: SongTapDetectorState }

    /// The pipeline of the app: raw + offset, then the detector with `profile`.
    static func run(_ points: [Pt], offsetDb: Int, profile: SongTapSensitivity) -> Run {
        var state = SongTapDetectorState.initial
        var fires: [Fire] = []
        var near: [(Int64, Bool)] = []
        for p in points {
            let step = SongTapDetector.step(state, SongTapRssiSample(tMs: p.t, rssi: p.raw + offsetDb), impulseMs: -1, profile: profile)
            state = step.state
            near.append((p.t, state.near))
            if step.fire != .none { fires.append(Fire(tMs: p.t, reason: step.fire)) }
        }
        return Run(fires: fires, near: near, finalState: state)
    }
}

@Suite("Song Tap real traces (the owner's calibration logs)")
struct SongTapRealTraceTests {
    typealias T = SongTapRealTraces

    @Test func iphoneTraceNormalProfileNoFireAtRestAndAFireAtTheTouchWithin600MsOfTheJump() {
        let run = T.run(T.iphoneFirstTap, offsetDb: 0, profile: .normal)
        #expect(run.fires.count == 1, "fires: \(run.fires.map { "\($0.tMs) \($0.reason.code)" })")
        guard let fire = run.fires.first else { return }
        #expect(fire.tMs >= T.iphoneTap1JumpMs, "fired at \(fire.tMs), before the jump")
        #expect(fire.tMs - T.iphoneTap1JumpMs <= 600, "fired \(fire.tMs - T.iphoneTap1JumpMs) ms after the jump")
        // The real phone fired at 20947990 (dwell); the hold or the dwell may be first here, never later than that plus a reading.
        #expect(fire.tMs <= T.iphoneTap1FiredMs + T.cadenceMs)
    }

    @Test func iphoneTraceHighProfileFiresNoLaterThanNormalNeverAtRestAndNeverInsideTheCooldown() {
        let normal = T.run(T.iphoneFirstTap, offsetDb: 0, profile: .normal)
        let run = T.run(T.iphoneFirstTap, offsetDb: 0, profile: .high)
        #expect(!run.fires.isEmpty, "fires: \(run.fires.map { "\($0.tMs) \($0.reason.code)" })")
        // HIGH is more sensitive: a 9 dB rise held 200 ms is a tap, so it may fire on the approach (-64 to about -50) as well as at the touch,
        // but never before the first listed point (the rest) and never sooner than the cooldown after its own last fire.
        #expect(run.fires.allSatisfy { $0.tMs >= 20946591 }, "fires: \(run.fires.map { "\($0.tMs) \($0.reason.code)" })")
        #expect(run.fires[0].tMs <= (normal.fires.first?.tMs ?? 0))
        for (a, b) in zip(run.fires, run.fires.dropFirst()) { #expect(b.tMs - a.tMs >= SongTapSensitivity.high.cooldownMs) }
    }

    @Test func iphoneIdleNearFlatAroundMinus60NeverFiresWithEitherProfile() {
        for p in SongTapSensitivity.allCases {
            let run = T.run(T.iphoneIdle, offsetDb: 0, profile: p)
            #expect(run.fires.isEmpty, "\(p.code): \(run.fires.map { "\($0.tMs) \($0.reason.code)" })")
            #expect(run.near.allSatisfy { $0.1 }, "resting 20 to 30 cm is inside the near gate")
            #expect(run.fires.allSatisfy { $0.reason != .hold }, "the hold level is -45, the iPhone rests at -55 to -65")
        }
    }

    @Test func pixelTraceWithOffsetMinus15HighProfileNoFireAtRestAFireWithin400MsOfTheJumpNoneInsideTheCooldown() {
        let run = T.run(T.pixelSession, offsetDb: -15, profile: .high)
        let fires = run.fires
        #expect(fires.count == 2, "fires: \(fires.map { "\($0.tMs) \($0.reason.code)" })")
        guard fires.count == 2 else { return }
        // Nothing during the ten seconds of rest or the approach before the first rise.
        #expect(fires[0].tMs >= T.pixelTouch1FirstRiseMs)
        #expect(fires[0].tMs - T.pixelTouch1FirstRiseMs <= 400, "first touch: fired \(fires[0].tMs - T.pixelTouch1FirstRiseMs) ms after the first rise")
        #expect(fires[1].tMs >= T.pixelTouch2FirstRiseMs)
        #expect(fires[1].tMs - T.pixelTouch2FirstRiseMs <= 400, "second touch: fired \(fires[1].tMs - T.pixelTouch2FirstRiseMs) ms after the first rise")
        // No re-fire inside the 1.2 s cooldown after the first fire.
        #expect(fires.dropFirst().allSatisfy { $0.tMs - fires[0].tMs >= SongTapSensitivity.high.cooldownMs })
        // Resting at -40..-48 raw is -55..-63 normalised: inside the near gate (-70) but never a tap.
        let rest = T.run(T.pixelIdle, offsetDb: -15, profile: .high)
        #expect(rest.fires.isEmpty)
        #expect(rest.near.allSatisfy { $0.1 })
    }

    @Test func pixelTraceWithOffsetMinus15NormalProfileAlsoFiresAtBothTouchesAndNotAtRest() {
        let run = T.run(T.pixelSession, offsetDb: -15, profile: .normal)
        #expect(run.fires.count == 2, "fires: \(run.fires.map { "\($0.tMs) \($0.reason.code)" })")
    }

    @Test func aPixelRestingNeverFiresTheHoldOnceItIsNormalised() {
        for p in SongTapSensitivity.allCases {
            #expect(T.run(T.pixelIdle, offsetDb: -15, profile: p).fires.isEmpty)
            #expect(T.run(T.pixelIdleConstant, offsetDb: -15, profile: p).fires.isEmpty)
        }
    }

    @Test func theSamePhysicalTouchFiresOnBothPlatformsAfterNormalising() {
        // Cross-platform parity: the iPhone's own readings and the Pixel's raw readings plus -15 are on one scale, so both phones see a touch
        // peak around -33 and rest around -60, and the detector fires on each.
        let iphone = T.iphoneFirstTap.map(\.raw)
        let pixel = T.pixelSession.map { $0.raw - 15 }
        #expect(iphone.max()! >= -37 && iphone.max()! <= -30)
        #expect(pixel.max()! >= -37 && pixel.max()! <= -30, "Pixel touching reads about -33 once normalised, was \(pixel.max()!)")
        #expect(!T.run(T.iphoneFirstTap, offsetDb: 0, profile: .high).fires.isEmpty)
        #expect(T.run(T.pixelSession, offsetDb: -15, profile: .high).fires.count == 2)
    }

    @Test func aPixelTraceWithNoOffsetShowsTheOldProblemTheHoldFiresAtRestAndTheGateIsCrossedFarAway() {
        // The owner's Pixel smoothed -44 at rest, a bit above the -45 hold level: unnormalised, it would fire at rest.
        let run = T.run(T.pixelIdleConstant, offsetDb: 0, profile: .high)
        #expect(run.fires.count == 1)
        #expect(run.fires.first?.reason == .hold)
        let cyc = T.run(T.pixelIdle, offsetDb: 0, profile: .high)
        #expect(!cyc.fires.isEmpty, "unnormalised resting Pixel fires")
        // The same pose that reads -76 on the iPhone reads about -61 raw on the Pixel, which a -70 gate counts as near with no offset.
        let apartRaw = -76 + 15
        func nearAfter(_ offset: Int) -> Bool {
            var s = SongTapDetectorState.initial
            for i in 0..<12 { s = SongTapDetector.step(s, SongTapRssiSample(tMs: Int64(i) * 125, rssi: apartRaw + offset), impulseMs: -1, profile: .high).state }
            return s.near
        }
        #expect(nearAfter(0), "without the offset the Pixel counts a phone far away as near")
        #expect(!nearAfter(-15), "with the offset it is the iPhone's -76: outside the gate")
    }

    @Test func densifyKeepsEveryListedPointAndOnlyAddsReadingsBetweenFarApartOnes() {
        let listed = T.iphoneTap1Listed
        let dense = T.iphoneTap1
        #expect(listed.allSatisfy { dense.contains($0) })
        #expect(dense.count > listed.count)
        #expect(dense.map(\.t) == dense.map(\.t).sorted())
        #expect(T.pixelTouch1Listed.allSatisfy { T.pixelTouch1.contains($0) })
        #expect(T.densify([T.Pt(0, 0)]) == [T.Pt(0, 0)])
    }
}
