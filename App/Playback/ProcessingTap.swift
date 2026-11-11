import Accelerate
import AudioToolbox
import AVFoundation
import CoreMedia
import Darwin
import Foundation
import MediaToolbox
import PixlAudioCore
import PixlModel
import Synchronization

/// Builds the `MTAudioProcessingTap` attached to every item (architecture §2 "Playback"): ReplayGain pre-gain (+ soft
/// limiter when boosting) → 10-band EQ + bass-boost shelf as `vDSP_biquadm` (RBJ coefficients from PixlAudioCore) with
/// the loudness pre-gain → virtualizer (stereo width) → limiter when any boost is on → mid/side instrumental fallback
/// → Spatial audio's on-device stage (cloud audio spec 7: the song's own audio only, while Spatial audio is active;
/// it replaces the virtualizer, which fades out along the stage's ramp, and ends in the soft limiter) → the crossfade
/// gain g(t) evaluated from the item's own media time, ramped per buffer → fixed deck gain.
///
/// The same tap works for `AVPlayerItem.audioMix` (playback) and `AVAssetReaderAudioMixOutput.audioMix` (offline:
/// the tests measure the chain that way).
nonisolated enum ProcessingTap {
    /// An audio mix carrying a new tap for `track`. Each call creates a new tap (a tap belongs to one item).
    static func makeAudioMix(for track: AVAssetTrack, effects: AudioEffectsParameters,
                             item: TapItemParameters) -> AVAudioMix? {
        guard let tap = makeTap(effects: effects, item: item) else { return nil }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    /// Creates the tap. The context is retained by the tap and released in `finalize`.
    static func makeTap(effects: AudioEffectsParameters, item: TapItemParameters) -> MTAudioProcessingTap? {
        let context = TapContext(effects: effects, item: item)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque()),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, maxFrames, format in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .prepare(maxFrames: Int(maxFrames), format: format.pointee)
            },
            unprepare: { tap in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .unprepare()
            },
            process: { tap, numberFrames, _, bufferList, numberFramesOut, flagsOut in
                var timeRange = CMTimeRange()
                let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferList, flagsOut,
                                                                &timeRange, numberFramesOut)
                guard status == noErr else {
                    numberFramesOut.pointee = 0
                    return
                }
                // Past the end the player keeps pulling (silent) buffers; they are not media.
                let endFlag = MTAudioProcessingTapFlags(truncatingIfNeeded: kMTAudioProcessingTapFlag_EndOfStream)
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .process(bufferList, frames: Int(numberFramesOut.pointee), timeRange: timeRange,
                             endOfStream: flagsOut.pointee & endFlag != 0)
            })
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        guard status == noErr, let tap else {
            // The tap never took ownership: balance the retain.
            Unmanaged.passUnretained(context).release()
            return nil
        }
        return tap
    }
}

/// The per-tap state. Everything the render thread touches is allocated in `init`/`prepare`.
nonisolated final class TapContext: @unchecked Sendable {
    static let maxChannels = 8

    let effects: AudioEffectsParameters
    let item: TapItemParameters

    // Format (set in prepare).
    private var sampleRate: Double = 44_100
    private var channels = 0
    private var interleaved = false
    private var isFloat32 = false

    // Channel pointer tables for vDSP_biquadm (strided views of the buffers).
    private let inputPointers: UnsafeMutablePointer<UnsafePointer<Float>>
    private let outputPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let channelStarts: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private var stride = 1
    private let dummy: UnsafeMutablePointer<Float>

    // Equalizer: one single-channel vDSP_biquadm setup per channel. A single-channel setup takes the mono block's
    // layout as is (section → b0 b1 b2 a1 a2), which sidesteps the multichannel coefficient interleaving: Apple's
    // documented order (section → coefficient → channel) produced unstable filters on CI.
    private let biquads: UnsafeMutablePointer<vDSP_biquadm_Setup?>
    private var biquadChannels = 0
    private var loadedGeneration = -1
    /// Mono block redesigned for this tap's sample rate when it differs from the published design rate.
    private let localBlock: UnsafeMutablePointer<Double>
    private var preGain: Float = 1
    private var currentPreGain: Float = 1
    private var width: Float = 1
    private var needsLimiter = false
    private var bypass = true
    /// Keeps the filters running briefly after the chain became bypass, so a switch-off rings out.
    private var tailFrames = 0

    // Gain stages (value carried across buffers so changes ramp without zipper noise).
    private var currentReplayGain: Float = 1
    private var currentFixedGain: Float = 1
    private var framesSincePrepare = 0
    /// Music Haptics detector (scalars only: no allocation on the render thread). Re-created in `prepare` for the rate.
    private var hapticAnalyzer = MusicHapticAnalyzer(sampleRate: 44_100)
    private var hapticAnalyzerRunning = false

    // Spatial audio (cloud audio spec 6.3, 7). Everything is set up in `prepare`.
    /// This item's on-device stage: only for the song's own audio, in stereo float at 44.1 or 48 kHz.
    private var spatialStage: SpatialStage?
    /// This item is a spatial render (`SpatialItemRole.render`): never spatialized again, never widened.
    private var isSpatialRender = false
    /// A spatial render's level factor (its headroom given back, spec 6.3 "Level"); 1 for anything else.
    private var renderLevel: Float = 1
    /// The stage's headroom as a factor (the table file's `headroomDb`).
    private var stageLevel: Float = 1
    /// Media time just past the last buffer (a jump means a seek: the stage forgets the old position).
    private var nextMediaTime: Double = -1

    init(effects: AudioEffectsParameters, item: TapItemParameters) {
        self.effects = effects
        self.item = item
        dummy = .allocate(capacity: 1)
        dummy.initialize(to: 0)
        inputPointers = .allocate(capacity: Self.maxChannels)
        outputPointers = .allocate(capacity: Self.maxChannels)
        channelStarts = .allocate(capacity: Self.maxChannels)
        inputPointers.initialize(repeating: UnsafePointer(dummy), count: Self.maxChannels)
        outputPointers.initialize(repeating: dummy, count: Self.maxChannels)
        channelStarts.initialize(repeating: dummy, count: Self.maxChannels)
        biquads = .allocate(capacity: Self.maxChannels)
        biquads.initialize(repeating: nil, count: Self.maxChannels)
        localBlock = .allocate(capacity: AudioEffectsParameters.blockSize)
        localBlock.initialize(repeating: 0, count: AudioEffectsParameters.blockSize)
    }

    deinit {
        destroyBiquads()
        biquads.deallocate()
        inputPointers.deallocate()
        outputPointers.deallocate()
        channelStarts.deallocate()
        localBlock.deallocate()
        dummy.deallocate()
    }

    // MARK: Prepare / unprepare (not the render thread: allocation allowed)

    func prepare(maxFrames: Int, format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44_100
        channels = min(Int(format.mChannelsPerFrame), Self.maxChannels)
        interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        isFloat32 = format.mFormatID == kAudioFormatLinearPCM && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
        item.sampleRate.store(sampleRate)
        hapticAnalyzer = MusicHapticAnalyzer(sampleRate: sampleRate)
        hapticAnalyzerRunning = false
        framesSincePrepare = 0
        prepareSpatial()
        currentReplayGain = effectiveReplayGain()
        currentFixedGain = item.fixedGain.load()
        rebuildBiquad()
    }

    func unprepare() {
        destroyBiquads()
        loadedGeneration = -1
    }

    private func destroyBiquads() {
        for c in 0..<Self.maxChannels {
            if let setup = biquads[c] { vDSP_biquadm_DestroySetup(setup) }
            biquads[c] = nil
        }
        biquadChannels = 0
    }

    /// (Re)creates one single-channel setup per channel from the latest coefficients.
    private func rebuildBiquad() {
        destroyBiquads()
        guard channels > 0, isFloat32 else { return }
        let latest = effects.latestBlock()
        let block = blockForThisRate(latest.block)
        var created = 0
        for c in 0..<channels {
            guard let setup = vDSP_biquadm_CreateSetup(block, vDSP_Length(AudioEffectsParameters.sectionCount), 1)
            else { break }
            biquads[c] = setup
            created += 1
        }
        if created == channels { biquadChannels = channels } else { destroyBiquads() }
        loadTail(block)
        currentPreGain = preGain
        loadedGeneration = latest.generation
    }

    /// The published block, or one redesigned for this tap's rate when it differs from the design rate. Designing
    /// allocates, so this only runs in `prepare` — buffers between a settings change and the next prepare use the
    /// published coefficients (a fraction of a semitone off at worst for 48 kHz content).
    private func blockForThisRate(_ published: UnsafePointer<Double>) -> UnsafePointer<Double> {
        let designRate = effects.designSampleRate.load()
        guard abs(designRate - sampleRate) > 0.5 else { return published }
        let parameters = EqualizerDesigner.design(effects.settings, sampleRate: sampleRate)
        AudioEffectsParameters.write(parameters, into: localBlock)
        return UnsafePointer(localBlock)
    }

    @inline(__always)
    private func loadTail(_ block: UnsafePointer<Double>) {
        let tail = AudioEffectsParameters.sectionCount * 5
        preGain = Float(block[tail])
        width = Float(block[tail + 1])
        needsLimiter = block[tail + 2] != 0
        let nowBypass = block[tail + 3] != 0
        if nowBypass && !bypass { tailFrames = Int(sampleRate / 2) }
        if !nowBypass && bypass {
            for c in 0..<biquadChannels { if let setup = biquads[c] { vDSP_biquadm_ResetState(setup) } }
        }
        bypass = nowBypass
    }

    private func effectiveReplayGain() -> Float {
        let volume = item.replayGainVolume.load()
        let v = volume.isNaN ? 1 : volume
        let gain = effects.allowReplayGainBoost.load(ordering: .relaxed) ? min(max(v, 0), ReplayGain.maxVolume)
                                                                         : min(max(v, 0), 1)
        // A spatial render plays `headroomDb` under the source: the level rule gives it back, capped at unity
        // (`SpatialLevel.playbackGain`, spec 6.3). The stage's own share is given back inside the stage (`wetLevel`).
        return renderLevel > 1 ? min(1, gain * renderLevel) : gain
    }

    /// Spatial audio's part of `prepare`: the item's role, the render's level, and the stage when the format takes it.
    private func prepareSpatial() {
        let role = item.spatialRole.load(ordering: .relaxed)
        isSpatialRender = role == SpatialItemRole.render
        nextMediaTime = -1
        let headroom = item.spatialHeadroomDb.load()
        renderLevel = isSpatialRender && headroom.isFinite && headroom > 0 ? Float(SpatialLevel.linear(db: headroom)) : 1
        guard role == SpatialItemRole.stage else {
            spatialStage = nil
            return
        }
        guard channels == 2, isFloat32, let coefficients = effects.spatial.coefficients else {
            spatialStage = nil
            item.spatialFormat.store(SpatialItemFormat.unsupported, ordering: .relaxed)
            return
        }
        if let stage = spatialStage, abs(Double(stage.sampleRate) - sampleRate) <= 0.5,
           stage.coefficients === coefficients {
            stage.reset()
        } else {
            spatialStage = SpatialStage(coefficients: coefficients, sampleRate: sampleRate)
        }
        stageLevel = Float(SpatialLevel.linear(db: max(coefficients.headroomDb, 0)))
        item.spatialFormat.store(spatialStage == nil ? SpatialItemFormat.unsupported : SpatialItemFormat.supported,
                                 ordering: .relaxed)
    }

    /// The stage's wet level for a ReplayGain gain: `min(1, gain × headroom) / gain`, so the spatial sound plays at
    /// `SpatialLevel.playbackGain(gain, headroomDb:)` while the dry sound keeps `gain` (spec 6.3 "Level").
    @inline(__always)
    private func stageWetLevel(_ gain: Float) -> Float {
        guard gain > 0, stageLevel > 1 else { return 1 }
        return min(1, gain * stageLevel) / gain
    }

    // MARK: Process (render thread — no allocation, locks or logging)

    func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int, timeRange: CMTimeRange,
                 endOfStream: Bool = false) {
        guard frames > 0 else { return }
        let firstTime: Double
        if timeRange.start.isValid && timeRange.start.isNumeric {
            firstTime = timeRange.start.seconds
        } else {
            firstTime = Double(framesSincePrepare) / sampleRate
        }
        framesSincePrepare += frames
        // Frames that are media: none beyond the item's duration (the player keeps pulling silent buffers after the
        // last frame); without a known duration, none flagged past the end of stream.
        let duration = item.mediaDuration.load()
        var mediaFrames = endOfStream && duration <= 0 ? 0 : frames
        if duration > 0 {
            let remaining = Int(((duration - firstTime) * sampleRate).rounded())
            mediaFrames = min(mediaFrames, max(remaining, 0))
        }
        if mediaFrames > 0 {
            item.processedMediaTime.store(firstTime + Double(mediaFrames) / sampleRate)
            item.processedFrames.wrappingAdd(mediaFrames, ordering: .relaxed)
        }
        item.hasProcessed.store(true, ordering: .relaxed)
        guard isFloat32, channels > 0, bindChannels(bufferList, frames: frames) else { return }

        let rmsIn = item.log != nil ? rms(frames: frames) : 0

        // Spatial audio: the stage takes this buffer's target first (the profile, or bypass), so the virtualizer it
        // replaces fades along the same ramp.
        var engagement: (start: Float, end: Float) = (0, 0)
        if let stage = spatialStage {
            if timeRange.start.isValid && timeRange.start.isNumeric {
                // A jump in media time is a seek: the room must not ring on with the old position.
                if nextMediaTime >= 0 && abs(firstTime - nextMediaTime) > 0.05 { stage.reset() }
                nextMediaTime = firstTime + Double(frames) / sampleRate
            }
            engagement = stage.begin(frames: frames, target: effects.spatial.profileIndex.load(ordering: .relaxed))
        }

        // 1. ReplayGain (+ limiter only when boosting above unity).
        let replayGain = effectiveReplayGain()
        applyGainRamp(from: currentReplayGain, to: replayGain, frames: frames)
        currentReplayGain = replayGain
        if replayGain > SoftLimiter.defaultThreshold && replayGain > 1 { limit(frames: frames) }

        // 2. Equalizer chain: loudness pre-gain, band + bass-boost biquads, width, limiter.
        let latest = effects.latestBlock()
        if latest.generation != loadedGeneration {
            loadedGeneration = latest.generation
            let designRate = effects.designSampleRate.load()
            // A different rate keeps the coefficients designed in prepare (see blockForThisRate).
            if abs(designRate - sampleRate) <= 0.5 {
                for c in 0..<biquadChannels {
                    if let setup = biquads[c] {
                        vDSP_biquadm_SetTargetsDouble(setup, latest.block, 0.25, 1e-6, 0, 0,
                                                      vDSP_Length(AudioEffectsParameters.sectionCount), 1)
                    }
                }
            }
            loadTail(latest.block)
        }
        if !bypass || tailFrames > 0 || currentPreGain != preGain {
            applyGainRamp(from: currentPreGain, to: preGain, frames: frames)
            currentPreGain = preGain
            if biquadChannels == channels {
                for c in 0..<channels {
                    if let setup = biquads[c] {
                        vDSP_biquadm(setup, inputPointers + c, vDSP_Stride(stride), outputPointers + c,
                                     vDSP_Stride(stride), vDSP_Length(frames))
                    }
                }
            }
            // The virtualizer: never on a spatial render (it would smear the binaural cues), and faded out along the
            // stage's ramp while the stage is on (spec 6.3 keeps it bypassed then).
            if channels == 2 && width != 1 && !isSpatialRender {
                if engagement.start > 0 || engagement.end > 0 {
                    applyWidth(frames: frames, from: width + (1 - width) * engagement.start,
                               to: width + (1 - width) * engagement.end)
                } else {
                    applyWidth(frames: frames)
                }
            }
            if needsLimiter { limit(frames: frames) }
            if bypass { tailFrames = max(tailFrames - frames, 0) }
        }

        // 3. Mid/side vocal attenuation (stereo).
        let attenuation = effects.midSideAttenuation.load()
        if channels == 2 && attenuation > 0 { applyMidSide(attenuation: min(attenuation, 1), frames: frames) }

        // 3½. Spatial audio's on-device stage, ending in the soft limiter while it is active (spec 7). The level rule's
        // factor rides on its wet sound.
        if let stage = spatialStage {
            stage.process(left: channelStarts[0], right: channelStarts[1], stride: stride, frames: frames,
                          wetLevel: stageWetLevel(replayGain))
            item.spatialEngagement.store(engagement.end)
        }

        // 4. Crossfade gain from this item's media time, then the deck's fixed gain.
        if let ramp = item.ramp.read() {
            let g0 = ramp.gain(at: firstTime)
            let g1 = ramp.gain(at: firstTime + Double(frames - 1) / sampleRate)
            applyGainRamp(from: g0, to: g1, frames: frames)
        }
        let fixed = item.fixedGain.load()
        applyGainRamp(from: currentFixedGain, to: fixed, frames: frames)
        currentFixedGain = fixed

        item.lastPeak.store(peak(frames: frames))
        runHapticAnalysis(frames: frames)
        if let log = item.log, mediaFrames > 0 {
            log.append(.init(mediaTime: firstTime, frames: mediaFrames, rmsIn: rmsIn, rmsOut: rms(frames: frames),
                             hostTime: mach_absolute_time()))
        }
    }

    /// Music Haptics (render thread: no allocation, locks or logging). Listens to what this tap just produced while the
    /// controller has the analysis switched on; otherwise one relaxed atomic load per buffer.
    @inline(__always)
    private func runHapticAnalysis(frames: Int) {
        let bus = effects.haptics
        guard bus.isActive.load(ordering: .relaxed) else {
            if hapticAnalyzerRunning {
                hapticAnalyzerRunning = false
                hapticAnalyzer.reset()
            }
            return
        }
        hapticAnalyzerRunning = true
        let left = UnsafePointer(channelStarts[0])
        let right: UnsafePointer<Float>? = channels > 1 ? UnsafePointer(channelStarts[1]) : nil
        hapticAnalyzer.process(left: left, right: right, stride: stride, frames: frames) { onset in
            bus.publish(onset)
        }
        bus.setBass(hapticAnalyzer.bassLevel)
    }

    /// Points the channel tables at the buffers: interleaved → `base + c` with stride = channels; planar → one
    /// buffer per channel with stride 1. False when the layout is not what `prepare` described.
    @inline(__always)
    private func bindChannels(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) -> Bool {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        if interleaved {
            guard buffers.count >= 1, let data = buffers[0].mData else { return false }
            let base = data.assumingMemoryBound(to: Float.self)
            let available = Int(buffers[0].mDataByteSize) / (MemoryLayout<Float>.size * channels)
            guard available >= frames else { return false }
            for c in 0..<channels {
                channelStarts[c] = base + c
            }
            stride = channels
        } else {
            guard buffers.count >= channels else { return false }
            for c in 0..<channels {
                guard let data = buffers[c].mData,
                      Int(buffers[c].mDataByteSize) / MemoryLayout<Float>.size >= frames else { return false }
                channelStarts[c] = data.assumingMemoryBound(to: Float.self)
            }
            stride = 1
        }
        for c in 0..<channels {
            inputPointers[c] = UnsafePointer(channelStarts[c])
            outputPointers[c] = channelStarts[c]
        }
        return true
    }

    /// Multiplies every channel by a gain moving linearly from `from` (first frame) to `to` (last frame).
    @inline(__always)
    private func applyGainRamp(from: Float, to: Float, frames: Int) {
        if from == to && from == 1 { return }
        let step = frames > 1 ? (to - from) / Float(frames - 1) : 0
        for c in 0..<channels {
            let p = channelStarts[c]
            var g = from
            var i = 0
            for _ in 0..<frames {
                p[i] *= g
                g += step
                i += stride
            }
        }
    }

    @inline(__always)
    private func limit(frames: Int) {
        for c in 0..<channels {
            let p = channelStarts[c]
            var i = 0
            for _ in 0..<frames {
                p[i] = SoftLimiter.limit(p[i])
                i += stride
            }
        }
    }

    /// `StereoWidth.process` on strided channels.
    @inline(__always)
    private func applyWidth(frames: Int) {
        let l = channelStarts[0], r = channelStarts[1]
        var i = 0
        for _ in 0..<frames {
            let mid = (l[i] + r[i]) * 0.5
            let side = (l[i] - r[i]) * 0.5 * width
            l[i] = mid + side
            r[i] = mid - side
            i += stride
        }
    }

    /// `applyWidth` with the width moving linearly from `from` (first frame) to `to` (last frame).
    @inline(__always)
    private func applyWidth(frames: Int, from: Float, to: Float) {
        if from == 1 && to == 1 { return }
        let l = channelStarts[0], r = channelStarts[1]
        let step = frames > 1 ? (to - from) / Float(frames - 1) : 0
        var w = from
        var i = 0
        for _ in 0..<frames {
            let mid = (l[i] + r[i]) * 0.5
            let side = (l[i] - r[i]) * 0.5 * w
            l[i] = mid + side
            r[i] = mid - side
            w += step
            i += stride
        }
    }

    /// `MidSideVocal.process` on strided channels (same Float operations as Android).
    @inline(__always)
    private func applyMidSide(attenuation: Float, frames: Int) {
        let l = channelStarts[0], r = channelStarts[1]
        let midGain = 1 - attenuation
        var i = 0
        for _ in 0..<frames {
            let mid = (l[i] + r[i]) * 0.5 * midGain
            let side = (l[i] - r[i]) * 0.5
            l[i] = min(max(mid + side, -1), 1)
            r[i] = min(max(mid - side, -1), 1)
            i += stride
        }
    }

    @inline(__always)
    private func rms(frames: Int) -> Float {
        var sum: Float = 0
        for c in 0..<channels {
            let p = channelStarts[c]
            var i = 0
            for _ in 0..<frames {
                sum += p[i] * p[i]
                i += stride
            }
        }
        return (sum / Float(frames * channels)).squareRoot()
    }

    @inline(__always)
    private func peak(frames: Int) -> Float {
        var m: Float = 0
        for c in 0..<channels {
            let p = channelStarts[c]
            var i = 0
            for _ in 0..<frames {
                m = max(m, abs(p[i]))
                i += stride
            }
        }
        return m
    }
}
