import Foundation
import Testing
import PixlModel
@testable import PixlAudioCore

/// Swift tests for the ReplayGain port (Android has no unit test for ReplayGainManager/ReplayGainProcessor; the
/// parser and gain maths are also checked against the JVM in `AudioGoldenTests`).
@Suite("ReplayGain")
struct ReplayGainTests {
    @Test func parsesTagStrings() {
        #expect(ReplayGain.parseGainString("-6.54 dB") == -6.54)
        #expect(ReplayGain.parseGainString("+3.21 dB") == 3.21)
        #expect(ReplayGain.parseGainString(" -6.54DB ") == -6.54)
        #expect(ReplayGain.parseGainString("-6.54") == -6.54)
        #expect(ReplayGain.parseGainString("\u{00A0}-3 dB\u{3000}") == -3)
        #expect(ReplayGain.parseGainString("-6,54 dB") == nil)
        #expect(ReplayGain.parseGainString("dB") == nil)
        #expect(ReplayGain.parseGainString("") == nil)
        #expect(ReplayGain.parseGainString("1.5f") == 1.5)
        #expect(ReplayGain.parseGainString("0x1p3") == 8)
        #expect(ReplayGain.parseGainString("NaN")?.isNaN == true)
        #expect(ReplayGain.parseGainString("-Infinity") == -.infinity)
        #expect(ReplayGain.parseGainString("nan") == nil)
        #expect(ReplayGain.parseGainString("dbdb5") == 5)
    }

    @Test func readsValuesFromATagMap() {
        let tags = ["replaygain_track_gain": ["-7.10 dB"], "REPLAYGAIN_ALBUM_GAIN": ["-8.20 dB", "ignored"]]
        #expect(ReplayGain.values(fromTags: tags) == ReplayGainValues(trackGainDb: -7.1, albumGainDb: -8.2))
        #expect(ReplayGain.values(fromTags: ["TITLE": ["x"]]) == nil)
        // The upper-case spelling wins over a case variant, whatever the dictionary order.
        let mixed = ["replaygain_track_gain": ["-1 dB"], "REPLAYGAIN_TRACK_GAIN": ["-4 dB"], "Replaygain_Track_Gain": ["-9 dB"]]
        #expect(ReplayGain.values(fromTags: mixed)?.trackGainDb == -4)
        // The _DB variant is the second choice.
        #expect(ReplayGain.values(fromTags: ["REPLAYGAIN_TRACK_GAIN_DB": ["-2"]])?.trackGainDb == -2)
        // An empty value list falls through to the next key…
        #expect(ReplayGain.values(fromTags: ["REPLAYGAIN_TRACK_GAIN": [], "REPLAYGAIN_TRACK_GAIN_DB": ["-2"]])?.trackGainDb == -2)
        // …but an unparsable first value decides (Android returns its null without trying later keys).
        #expect(ReplayGain.values(fromTags: ["REPLAYGAIN_TRACK_GAIN": ["loud"], "REPLAYGAIN_TRACK_GAIN_DB": ["-2"]]) == nil)
    }

    @Test func r128GainsAreConvertedFromQ78() {
        #expect(ReplayGain.parseR128Gain("-1536") == -1)   // −6 dB vs −23 LUFS = −1 dB vs −18 LUFS
        #expect(ReplayGain.parseR128Gain("0") == 5)
        #expect(ReplayGain.parseR128Gain(" 256 ") == 6)
        #expect(ReplayGain.parseR128Gain("1.5") == nil)
        #expect(ReplayGain.parseR128Gain("40000") == nil)
        #expect(ReplayGain.values(fromTags: ["R128_TRACK_GAIN": ["-1536"]])?.trackGainDb == -1)
        #expect(ReplayGain.values(fromTags: ["REPLAYGAIN_TRACK_GAIN": ["-3 dB"], "R128_TRACK_GAIN": ["-1536"]])?.trackGainDb == -3)
    }

    @Test func gainToVolume() {
        #expect(abs(ReplayGain.gainDbToVolume(-6.0206) - 0.5) < 1e-4)
        #expect(ReplayGain.gainDbToVolume(0) == 1)
        #expect(ReplayGain.gainDbToVolume(20) == 2)
        #expect(abs(ReplayGain.gainDbToVolume(-10, preAmpDb: 4) - ReplayGain.gainDbToVolume(-6)) < 1e-6)
        #expect(ReplayGain.gainDbToVolume(-.infinity) == 0)
        #expect(ReplayGain.gainDbToVolume(.nan).isNaN)
    }

    @Test func volumeMultiplierFallsBack() {
        let both = ReplayGainValues(trackGainDb: -6.0206, albumGainDb: -12.0412)
        #expect(abs(ReplayGain.volumeMultiplier(both) - 0.5) < 1e-4)
        #expect(abs(ReplayGain.volumeMultiplier(both, useAlbumGain: true) - 0.25) < 1e-4)
        let albumOnly = ReplayGainValues(albumGainDb: -12.0412)
        #expect(abs(ReplayGain.volumeMultiplier(albumOnly) - 0.25) < 1e-4)
        let trackOnly = ReplayGainValues(trackGainDb: -6.0206)
        #expect(abs(ReplayGain.volumeMultiplier(trackOnly, useAlbumGain: true) - 0.5) < 1e-4)
        #expect(ReplayGain.volumeMultiplier(nil) == 1)
        #expect(ReplayGain.volumeMultiplier(ReplayGainValues()) == 1)
    }

    // MARK: ReplayGainProcessor bookkeeping

    @Test func disabledRestoresTheUserVolume() {
        var c = ReplayGainVolumeController()
        c.captureUserVolume(0.6)
        let r = c.beginApply(mediaId: "a", hasFilePath: true, transitionRunning: false)
        #expect(r.immediateVolume == 0.6 && !r.needsTagRead)
        #expect(c.expectedVolume == 0.6)
        // The echo is ignored, a real change is the user's.
        c.onPlayerVolumeChanged(0.6, transitionRunning: false)
        #expect(c.userSelectedVolume == 0.6 && c.expectedVolume == nil)
        c.onPlayerVolumeChanged(0.3, transitionRunning: false)
        #expect(c.userSelectedVolume == 0.3)
        c.onPlayerVolumeChanged(0.9, transitionRunning: true)
        #expect(c.userSelectedVolume == 0.3)
    }

    @Test func applyReadsTagsAndDropsStaleResults() {
        var c = ReplayGainVolumeController(enabled: true)
        let first = c.beginApply(mediaId: "a", hasFilePath: true, transitionRunning: false)
        #expect(first.needsTagRead && first.immediateVolume == nil)
        let second = c.beginApply(mediaId: "b", hasFilePath: true, transitionRunning: false)
        let values = ReplayGainValues(trackGainDb: -6.0206)
        let v92 = c.completeApply(first, mediaId: "a", currentMediaId: "b", values: values, transitionRunning: false)
        #expect(v92 == nil)
        // The current item changed under the request.
        let v94 = c.completeApply(second, mediaId: "b", currentMediaId: "c", values: values, transitionRunning: false)
        #expect(v94 == nil)
        let third = c.beginApply(mediaId: "b", hasFilePath: true, transitionRunning: false)
        let volume = c.completeApply(third, mediaId: "b", currentMediaId: "b", values: values, transitionRunning: false)
        #expect(volume.map { abs($0 - 0.5) < 1e-4 } == true)
        #expect(c.lastMediaId == "b")
        // Next track: the last volume is applied at once while its tags are read.
        let next = c.beginApply(mediaId: "c", hasFilePath: true, transitionRunning: false)
        #expect(next.immediateVolume == c.lastAppliedVolume)
        // Boosts are capped at the player's 0…1.
        let loud = c.completeApply(next, mediaId: "c", currentMediaId: "c", values: ReplayGainValues(trackGainDb: 6), transitionRunning: false)
        #expect(loud == 1)
    }

    @Test func streamsKeepTheUserVolume() {
        var c = ReplayGainVolumeController(enabled: true)
        c.captureUserVolume(0.8)
        let r = c.beginApply(mediaId: "yt:1", hasFilePath: false, transitionRunning: false)
        #expect(r.immediateVolume == 0.8 && !r.needsTagRead)
        let v112 = c.beginApply(mediaId: nil, hasFilePath: true, transitionRunning: false)
        #expect(v112.immediateVolume == nil)
    }

    @Test func crossfadeHoldsTheVolumeUntilTheTransitionEnds() {
        var c = ReplayGainVolumeController(enabled: true)
        c.prepareForTransition(cachedValues: ReplayGainValues(trackGainDb: -6.0206))
        #expect(c.incomingTrackVolume.map { abs($0 - 0.5) < 1e-4 } == true)
        let r = c.beginApply(mediaId: "b", hasFilePath: true, transitionRunning: true)
        #expect(r.immediateVolume == nil)
        let v121 = c.completeApply(r, mediaId: "b", currentMediaId: "b", values: ReplayGainValues(trackGainDb: -12.0412),
                                transitionRunning: true)
        #expect(v121 == nil)
        #expect(c.pendingVolume.map { abs($0 - 0.25) < 1e-4 } == true)
        #expect(c.incomingTrackVolume == c.pendingVolume)
        guard case .setVolume(let v) = c.onTransitionFinished() else { Issue.record("expected a volume"); return }
        #expect(abs(v - 0.25) < 1e-4 && c.lastAppliedVolume == v && c.pendingVolume == nil)
        let v127 = c.onTransitionFinished()
        #expect(v127 == .recompute)
        c.enabled = false
        c.captureUserVolume(0.4)
        let v130 = c.onTransitionFinished()
        #expect(v130 == .setVolume(0.4))
    }

    @Test func metadataChangesOnlyRecomputeForANewTrack() {
        var c = ReplayGainVolumeController(enabled: true)
        let r = c.beginApply(mediaId: "a", hasFilePath: true, transitionRunning: false)
        _ = c.completeApply(r, mediaId: "a", currentMediaId: "a", values: ReplayGainValues(trackGainDb: 0), transitionRunning: false)
        let v137 = c.onMediaMetadataChanged(currentMediaId: "a", transitionRunning: false)
        #expect(v137 == .reapply(1))
        let v138 = c.onMediaMetadataChanged(currentMediaId: "a", transitionRunning: true)
        #expect(v138 == .reapply(nil))
        let v139 = c.onMediaMetadataChanged(currentMediaId: "b", transitionRunning: false)
        #expect(v139 == .recompute)
        let v140 = c.onMediaMetadataChanged(currentMediaId: nil, transitionRunning: false)
        #expect(v140 == .ignore)
    }

    // MARK: Tap stage and limiter

    @Test func stageKeepsAndroidParityUnlessBoostIsAllowed() {
        let parity = ReplayGainStage()
        #expect(parity.effectiveGain(for: 1.8) == 1)
        #expect(parity.effectiveGain(for: 0.5) == 0.5)
        #expect(parity.effectiveGain(for: .nan) == 1)
        let boost = ReplayGainStage(allowBoost: true)
        #expect(boost.effectiveGain(for: 1.8) == 1.8)
        #expect(boost.effectiveGain(for: 3) == 2)
    }

    @Test func stageRampsAndLimits() {
        var stage = ReplayGainStage(allowBoost: true)
        var samples = [Float](repeating: 0.9, count: 64)
        samples.withUnsafeMutableBufferPointer { stage.process($0.baseAddress!, frames: 32, channels: 2, volume: 2) }
        #expect(stage.currentGain == 2)
        #expect(samples.allSatisfy { $0 <= 1 })
        #expect(samples[0] < samples[63]) // ramped up from 1
        var quiet = [Float](repeating: 0.25, count: 8)
        var parity = ReplayGainStage(initialGain: 0.5)
        quiet.withUnsafeMutableBufferPointer { parity.process($0.baseAddress!, frames: 8, channels: 1, volume: 0.5) }
        #expect(quiet.allSatisfy { $0 == 0.125 })
    }

    @Test func softLimiterIsTransparentBelowTheKneeAndBounded() {
        #expect(SoftLimiter.limit(0.5) == 0.5)
        #expect(SoftLimiter.limit(-0.8) == -0.8)
        #expect(SoftLimiter.limit(.nan) == 0)
        var previous: Float = 0
        for i in 0...400 {
            let x = Float(i) / 100
            let y = SoftLimiter.limit(x)
            #expect(y >= previous && y <= 1)
            #expect(SoftLimiter.limit(-x) == -y)
            previous = y
        }
        #expect(SoftLimiter.limit(1e9) <= 1)
        #expect(SoftLimiter.limit(1.5, threshold: 1) == 1)
    }
}
