import Foundation
import Testing
import PixlModel
@testable import PixlAudioCore

/// Swift tests for the transition port (Android has no unit test for Envelope.kt, TransitionController or
/// TransitionRepositoryImpl; the envelope and crossfade gains are also checked against the JVM in
/// `AudioGoldenTests`).
@Suite("Transitions")
struct TransitionTests {
    // MARK: Envelope

    @Test func envelopeEndpointsAndShapes() {
        for curve in TransitionCurve.allCases {
            #expect(TransitionEnvelope.envelope(0, curve) == 0)
            #expect(TransitionEnvelope.envelope(1, curve) == 1)
            #expect(TransitionEnvelope.envelope(-3, curve) == 0)
            #expect(TransitionEnvelope.envelope(7, curve) == 1)
            #expect(TransitionEnvelope.envelope(.nan, curve).isNaN)
            var previous: Float = 0
            for i in 0...200 {
                let v = TransitionEnvelope.envelope(Float(i) / 200, curve)
                #expect(v >= previous, "\(curve) must not decrease")
                previous = v
            }
        }
        #expect(TransitionEnvelope.envelope(0.5, .linear) == 0.5)
        #expect(TransitionEnvelope.envelope(0.5, .exp) == 0.25)
        #expect(TransitionEnvelope.envelope(0.25, .log) == 0.5)
        #expect(abs(TransitionEnvelope.envelope(0.5, .sCurve) - 0.5) < 1e-7)
        // EXP starts slow, LOG starts fast.
        #expect(TransitionEnvelope.envelope(0.1, .exp) < TransitionEnvelope.envelope(0.1, .linear))
        #expect(TransitionEnvelope.envelope(0.1, .log) > TransitionEnvelope.envelope(0.1, .linear))
    }

    // MARK: Rule resolution

    static let global = TransitionSettings(mode: .overlap, durationMs: 4000, curveIn: .linear, curveOut: .linear)
    static let playlistDefault = TransitionSettings(mode: .fadeInOut, durationMs: 3000, curveIn: .exp, curveOut: .log)
    static let specific = TransitionSettings(mode: .smooth, durationMs: 8000)
    static let rules = [
        TransitionRule(id: 1, playlistId: "p1", settings: playlistDefault),
        TransitionRule(id: 2, playlistId: "p1", fromTrackId: "a", toTrackId: "b", settings: specific),
        TransitionRule(id: 3, playlistId: "p2", settings: TransitionSettings(mode: .none)),
        TransitionRule(id: 4, playlistId: "p1", fromTrackId: "a", toTrackId: nil, settings: TransitionSettings(mode: .none)),
    ]

    @Test func specificRuleBeatsPlaylistDefaultBeatsGlobal() {
        let r1 = TransitionRuleResolver.resolve(playlistId: "p1", fromTrackId: "a", toTrackId: "b", rules: Self.rules, global: Self.global)
        #expect(r1 == TransitionResolution(settings: Self.specific, source: .playlistSpecific))
        let r2 = TransitionRuleResolver.resolve(playlistId: "p1", fromTrackId: "b", toTrackId: "a", rules: Self.rules, global: Self.global)
        #expect(r2 == TransitionResolution(settings: Self.playlistDefault, source: .playlistDefault))
        let r3 = TransitionRuleResolver.resolve(playlistId: "p9", fromTrackId: "a", toTrackId: "b", rules: Self.rules, global: Self.global)
        #expect(r3 == TransitionResolution(settings: Self.global, source: .globalDefault))
        let r4 = TransitionRuleResolver.resolve(playlistId: nil, fromTrackId: "a", toTrackId: "b", rules: Self.rules, global: Self.global)
        #expect(r4.source == .globalDefault)
        // A half-specified rule (from only) matches neither the pair query nor the default query.
        let r5 = TransitionRuleResolver.resolve(playlistId: "p1", fromTrackId: "a", toTrackId: "c", rules: Self.rules, global: Self.global)
        #expect(r5.source == .playlistDefault)
    }

    // MARK: Scheduling

    @Test func skipReasons() {
        let enabled = TransitionResolution(settings: Self.global, source: .globalDefault)
        #expect(CrossfadeScheduler.skipReason(resolution: enabled, crossfadeEnabled: true) == nil)
        #expect(CrossfadeScheduler.skipReason(resolution: enabled, crossfadeEnabled: false) == .globallyDisabled)
        // Playlist rules apply even with the global toggle off.
        let playlist = TransitionResolution(settings: Self.playlistDefault, source: .playlistDefault)
        #expect(CrossfadeScheduler.skipReason(resolution: playlist, crossfadeEnabled: false) == nil)
        let none = TransitionResolution(settings: TransitionSettings(mode: .none), source: .playlistSpecific)
        #expect(CrossfadeScheduler.skipReason(resolution: none, crossfadeEnabled: true) == .disabledOrZeroDuration)
        let zero = TransitionResolution(settings: TransitionSettings(durationMs: 0), source: .playlistDefault)
        #expect(CrossfadeScheduler.skipReason(resolution: zero, crossfadeEnabled: true) == .disabledOrZeroDuration)
    }

    @Test func planClampsTheFadeToTheTrack() {
        let r = TransitionResolution(settings: TransitionSettings(durationMs: 2000), source: .globalDefault)
        #expect(CrossfadeScheduler.plan(resolution: r, crossfadeEnabled: true, trackDurationMs: 200_000)
                == .crossfade(transitionPointMs: 198_000, fadeDurationMs: 2000))
        #expect(CrossfadeScheduler.plan(resolution: r, crossfadeEnabled: true, trackDurationMs: 649) == .none(.trackTooShort))
        #expect(CrossfadeScheduler.plan(resolution: r, crossfadeEnabled: true, trackDurationMs: 650)
                == .crossfade(transitionPointMs: 150, fadeDurationMs: 500))
        #expect(CrossfadeScheduler.plan(resolution: r, crossfadeEnabled: true, trackDurationMs: 1500)
                == .crossfade(transitionPointMs: 150, fadeDurationMs: 1350))
        let short = TransitionResolution(settings: TransitionSettings(durationMs: 100), source: .globalDefault)
        #expect(CrossfadeScheduler.plan(resolution: short, crossfadeEnabled: true, trackDurationMs: 10_000)
                == .crossfade(transitionPointMs: 9500, fadeDurationMs: 500))
        #expect(CrossfadeScheduler.plan(resolution: r, crossfadeEnabled: false, trackDurationMs: 200_000) == .none(.globallyDisabled))
    }

    @Test func fireDecisionUsesTheRemainingTime() {
        #expect(CrossfadeScheduler.fireDecision(trackDurationMs: 200_000, positionMs: 198_000, fadeDurationMs: 2000) == .fire(durationMs: 2000))
        #expect(CrossfadeScheduler.fireDecision(trackDurationMs: 200_000, positionMs: 199_200, fadeDurationMs: 2000) == .fire(durationMs: 800))
        #expect(CrossfadeScheduler.fireDecision(trackDurationMs: 200_000, positionMs: 200_000, fadeDurationMs: 2000) == .tooCloseToEnd)
        #expect(CrossfadeScheduler.fireDecision(trackDurationMs: 200_000, positionMs: 250_000, fadeDurationMs: 2000) == .tooCloseToEnd)
        let s = CrossfadeScheduler.firingSettings(TransitionSettings(mode: .smooth, durationMs: 2000, curveIn: .exp), durationMs: 800)
        #expect(s == TransitionSettings(mode: .smooth, durationMs: 800, curveIn: .exp))
    }

    @Test func countdownSleepsAdaptively() {
        #expect(CrossfadeScheduler.countdownSleepMs(remainingMs: 60_000, speed: 1) == 56_000)
        #expect(CrossfadeScheduler.countdownSleepMs(remainingMs: 60_000, speed: 2) == 28_000)
        #expect(CrossfadeScheduler.countdownSleepMs(remainingMs: 60_000, speed: 0.5) == 60_000) // capped at remaining
        #expect(CrossfadeScheduler.countdownSleepMs(remainingMs: 60_000, speed: 0) == 60_000)   // speed floor 0.1
        #expect(CrossfadeScheduler.countdownSleepMs(remainingMs: 5001, speed: 1) == 1001)
        #expect(CrossfadeScheduler.countdownSleepMs(remainingMs: 5000, speed: 1) == 250)
        #expect(CrossfadeScheduler.countdownSleepMs(remainingMs: 1001, speed: 1) == 250)
        #expect(CrossfadeScheduler.countdownSleepMs(remainingMs: 1000, speed: 1) == 50)
        #expect(CrossfadeScheduler.countdownSleepMs(remainingMs: 30, speed: 1) == 30)
        #expect(CrossfadeScheduler.countdownSleepMs(remainingMs: 0, speed: 1) == 1)
        #expect(CrossfadeScheduler.countdownSleepMs(remainingMs: 7000, speed: 3) == 1000)
    }

    @Test func nextTargetFollowsTheRepeatMode() {
        #expect(CrossfadeScheduler.nextTargetIndex(currentIndex: 2, queueCount: 5, repeatMode: .off) == 3)
        #expect(CrossfadeScheduler.nextTargetIndex(currentIndex: 2, queueCount: 5, repeatMode: .one) == 2)
        #expect(CrossfadeScheduler.nextTargetIndex(currentIndex: 4, queueCount: 5, repeatMode: .off) == nil)
        #expect(CrossfadeScheduler.nextTargetIndex(currentIndex: 4, queueCount: 5, repeatMode: .all) == nil) // no wrap
        #expect(CrossfadeScheduler.nextTargetIndex(currentIndex: 4, queueCount: 5, repeatMode: .one) == 4)
        #expect(CrossfadeScheduler.nextTargetIndex(currentIndex: nil, queueCount: 5, repeatMode: .off) == nil)
        #expect(CrossfadeScheduler.nextTargetIndex(currentIndex: 0, queueCount: 0, repeatMode: .off) == nil)
    }

    @Test func suspensionsNeedEveryOwnerToResume() {
        var s = TransitionSuspensions()
        #expect(!s.isSuspended)
        let v128 = s.suspend("sync")
        #expect(v128)
        let v129 = s.suspend("sync")
        #expect(!v129)
        let v130 = s.suspend("preview")
        #expect(!v130)
        let v131 = s.resume("sync")
        #expect(!v131)
        #expect(s.isSuspended)
        let v133 = s.resume("unknown")
        #expect(!v133)
        let v134 = s.resume("preview")
        #expect(v134)
        #expect(!s.isSuspended)
        let v136 = s.resume("preview")
        #expect(!v136)
    }

    @Test func constantsMatchAndroid() {
        #expect(CrossfadeScheduler.debounceMs == 1500)
        #expect(CrossfadeScheduler.swapRescheduleDelayMs == 1000)
        #expect(CrossfadeScheduler.minFadeMs == 500)
        #expect(CrossfadeScheduler.guardWindowMs == 150)
        #expect(CrossfadeRun.stepMs == 32)
        #expect(CrossfadeRun.minimumDurationMs == 500)
    }

    // MARK: Crossfade gains

    @Test func crossfadeRunRampsBothDecks() {
        let run = CrossfadeRun(settings: TransitionSettings(durationMs: 100, curveIn: .linear, curveOut: .linear),
                               outgoingStartVolume: 0.8)
        #expect(run.durationMs == 500)
        #expect(run.gains(elapsedMs: 0) == CrossfadeGains(incoming: 0, outgoing: 0.8))
        let mid = run.gains(elapsedMs: 250, incomingTarget: 0.5)
        #expect(mid.incoming == 0.25 && abs(mid.outgoing - 0.4) < 1e-7)
        #expect(run.gains(elapsedMs: 900) == CrossfadeGains(incoming: 1, outgoing: 0))
        #expect(!run.isFinished(elapsedMs: 499) && run.isFinished(elapsedMs: 500))
        #expect(run.finalGains(incomingTarget: 0.7) == CrossfadeGains(incoming: 0.7, outgoing: 0))
        #expect(run.finalGains(incomingTarget: 1.6) == CrossfadeGains(incoming: 1, outgoing: 0))
        #expect(CrossfadeRun(settings: TransitionSettings(), outgoingStartVolume: 3).outgoingStartVolume == 1)
    }

    @Test func rampsFollowEachDecksMediaTime() {
        let run = CrossfadeRun(settings: TransitionSettings(durationMs: 2000, curveIn: .sCurve, curveOut: .exp))
        let (incoming, outgoing) = CrossfadeRamp.pair(run: run, outgoingStartTime: 178, incomingTarget: 0.9)
        #expect(incoming.gain(at: -1) == 0)
        #expect(incoming.gain(at: 0) == 0)
        #expect(abs(incoming.gain(at: 1) - 0.45) < 1e-6)
        #expect(incoming.gain(at: 5) == 0.9)
        #expect(outgoing.gain(at: 100) == 1)
        #expect(outgoing.gain(at: 179) == 0.75)
        #expect(outgoing.gain(at: 181) == 0)
        // Same values as the Android loop at the same progress.
        let gains = run.gains(elapsedMs: 1000, incomingTarget: 0.9)
        #expect(incoming.gain(at: 1) == gains.incoming)
        #expect(outgoing.gain(at: 179) == gains.outgoing)
    }

    @Test func rampApplyInterpolatesAcrossTheBuffer() {
        let ramp = CrossfadeRamp(role: .incoming, curve: .linear, startTime: 0, duration: 1, scale: 1)
        var samples = [Float](repeating: 1, count: 10) // 5 stereo frames
        samples.withUnsafeMutableBufferPointer {
            ramp.apply(to: $0.baseAddress!, frames: 5, channels: 2, firstFrameTime: 0.5, sampleRate: 8)
        }
        // Frame times 0.5 … 1.0 → gains 0.5 … 1.0 in equal steps.
        #expect(samples[0] == 0.5 && samples[1] == 0.5)
        #expect(abs(samples[4] - 0.75) < 1e-6)
        #expect(abs(samples[8] - 1) < 1e-6 && abs(samples[9] - 1) < 1e-6)
    }

    @Test func gainRampIsANoOpAtUnity() {
        var samples: [Float] = [0.3, -0.7, 0.1]
        samples.withUnsafeMutableBufferPointer { GainRamp.apply(to: $0.baseAddress!, frames: 3, channels: 1, from: 1, to: 1) }
        #expect(samples == [0.3, -0.7, 0.1])
        samples.withUnsafeMutableBufferPointer { GainRamp.apply(to: $0.baseAddress!, frames: 3, channels: 1, from: 0, to: 0) }
        #expect(samples.allSatisfy { $0 == 0 })
    }
}
