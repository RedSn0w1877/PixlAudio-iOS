import Testing
import PixlModel
@testable import PixlAudioCore

@Suite struct MusicHapticsPolicyTests {
    private func conditions(enabled: Bool = true, supports: Bool = true, playing: Bool = true, foreground: Bool = true,
                            lowPower: Bool = false, thermal: ThermalLevel = .nominal, safeMode: Bool = false,
                            call: Bool = false, route: MusicHapticsRoute = .local) -> MusicHapticsConditions {
        MusicHapticsConditions(isEnabled: enabled, deviceSupportsHaptics: supports, isPlaying: playing,
                               isForeground: foreground, lowPowerMode: lowPower, thermal: thermal, safeMode: safeMode,
                               inPhoneCall: call, route: route)
    }

    @Test func runsWhenEnabledPlayingAndInFront() {
        #expect(MusicHapticsPolicy.shouldRun(conditions()))
        #expect(MusicHapticsPolicy.status(conditions()) == .on)
    }

    @Test func offByDefaultSwitch() {
        #expect(!MusicHapticsPolicy.shouldRun(conditions(enabled: false)))
        #expect(MusicHapticsPolicy.status(conditions(enabled: false)) == .off)
    }

    @Test func pausedOrBackgroundedStopsTheEngineButStaysOn() {
        #expect(!MusicHapticsPolicy.shouldRun(conditions(playing: false)))
        #expect(!MusicHapticsPolicy.shouldRun(conditions(foreground: false)))
        #expect(MusicHapticsPolicy.status(conditions(playing: false, foreground: false)) == .on)
    }

    @Test func eachBlockerStopsItWithItsReason() {
        let cases: [(MusicHapticsConditions, MusicHapticsStatus.Reason)] = [
            (conditions(supports: false), .noHaptics),
            (conditions(lowPower: true), .lowPowerMode),
            (conditions(thermal: .serious), .hot),
            (conditions(thermal: .critical), .hot),
            (conditions(safeMode: true), .safeMode),
            (conditions(call: true), .phoneCall),
            (conditions(route: .remote), .remoteOutput),
        ]
        for (c, reason) in cases {
            #expect(!MusicHapticsPolicy.shouldRun(c))
            #expect(MusicHapticsPolicy.status(c) == .notAvailable(reason))
        }
        #expect(MusicHapticsPolicy.shouldRun(conditions(thermal: .fair)))
    }

    @Test func aDeviceWithoutHapticsIsNotAvailableEvenWhenSwitchedOff() {
        #expect(MusicHapticsPolicy.status(conditions(enabled: false, supports: false)) == .notAvailable(.noHaptics))
        #expect(MusicHapticsStatus.notAvailable(.noHaptics).title == "Not available")
    }

    @Test func strengthIsClamped() {
        #expect(MusicHapticsMapper.clampedStrength(5) == 20)
        #expect(MusicHapticsMapper.clampedStrength(999) == 200)
        #expect(MusicHapticsMapper.clampedStrength(100) == 100)
    }

    @Test func modesChooseWhichOnsetsBecomeTaps() {
        let kick = HapticOnset(kind: .kick, strength: 1, frame: 0)
        let snare = HapticOnset(kind: .snare, strength: 1, frame: 0)
        for mode in MusicHapticsMode.allCases { #expect(MusicHapticsMapper.tap(for: kick, mode: mode, strengthPercent: 100) != nil) }
        #expect(MusicHapticsMapper.tap(for: snare, mode: .everything, strengthPercent: 100) != nil)
        #expect(MusicHapticsMapper.tap(for: snare, mode: .beat, strengthPercent: 100) != nil)
        #expect(MusicHapticsMapper.tap(for: snare, mode: .bass, strengthPercent: 100) == nil)
    }

    @Test func snaresAreCrisperThanKicks() {
        let kick = MusicHapticsMapper.tap(for: HapticOnset(kind: .kick, strength: 0.8, frame: 0), mode: .everything, strengthPercent: 100)!
        let snare = MusicHapticsMapper.tap(for: HapticOnset(kind: .snare, strength: 0.8, frame: 0), mode: .everything, strengthPercent: 100)!
        #expect(snare.sharpness > kick.sharpness)
        #expect(kick.shape == .tap)
    }

    @Test func strengthScalesIntensityAndNeverExceedsOne() {
        let onset = HapticOnset(kind: .kick, strength: 0.6, frame: 0)
        let soft = MusicHapticsMapper.tap(for: onset, mode: .beat, strengthPercent: 20)!
        let normal = MusicHapticsMapper.tap(for: onset, mode: .beat, strengthPercent: 100)!
        let strong = MusicHapticsMapper.tap(for: onset, mode: .beat, strengthPercent: 200)!
        #expect(soft.intensity < normal.intensity && normal.intensity < strong.intensity)
        #expect(strong.intensity <= 1)
        let hardHit = MusicHapticsMapper.tap(for: HapticOnset(kind: .kick, strength: 1, frame: 0), mode: .beat, strengthPercent: 200)!
        #expect(hardHit.intensity == 1)
    }

    @Test func rumbleOnlyInEverythingAndBass() {
        #expect(MusicHapticsMapper.rumble(bassLevel: 0.8, mode: .beat, strengthPercent: 100) == nil)
        let everything = MusicHapticsMapper.rumble(bassLevel: 0.8, mode: .everything, strengthPercent: 100)
        let bass = MusicHapticsMapper.rumble(bassLevel: 0.8, mode: .bass, strengthPercent: 100)
        #expect(everything != nil && everything == bass)
        #expect(everything!.shape == .rumble)
        #expect(MusicHapticsMapper.rumble(bassLevel: 0.01, mode: .bass, strengthPercent: 100) == nil)
        #expect(MusicHapticsMapper.rumble(bassLevel: 1, mode: .bass, strengthPercent: 200)!.intensity <= 0.75)
    }

    @Test func rateLimiterAllowsAtMostTwentyFivePerSecond() {
        var limiter = HapticRateLimiter(maxPerSecond: 25)
        var allowed = 0
        var t = 0.0
        while t < 1 {
            if limiter.allow(at: t) { allowed += 1 }
            t += 0.005 // 200 events a second offered
        }
        #expect(allowed >= 24 && allowed <= 26)
        let later = limiter.allow(at: 5)
        #expect(later)
        limiter.reset()
        let afterReset = limiter.allow(at: 5.001)
        #expect(afterReset)
    }
}
