import Accelerate
import AudioToolbox
import AVFoundation
import CoreMedia
import Darwin
import Foundation
import MediaToolbox
import PixlAudioCore
import Synchronization

/// Builds the `MTAudioProcessingTap` attached to every item (architecture §2 "Playback"): ReplayGain pre-gain (+ soft
/// limiter when boosting) → 10-band EQ + bass-boost shelf as `vDSP_biquadm` (RBJ coefficients from PixlAudioCore) with
/// the loudness pre-gain → virtualizer (stereo width) → limiter when any boost is on → mid/side instrumental fallback
/// → the crossfade gain g(t) evaluated from the item's own media time, ramped per buffer → fixed deck gain.
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
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .process(bufferList, frames: Int(numberFramesOut.pointee), timeRange: timeRange)
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

    // Equalizer.
    private var biquad: vDSP_biquadm_Setup?
    private var biquadChannels = 0
    private var loadedGeneration = -1
    /// 5 × sections × channels, vDSP's per-section/per-coefficient/per-channel layout.
    private let coefficientScratch: UnsafeMutablePointer<Double>
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
        coefficientScratch = .allocate(capacity: AudioEffectsParameters.sectionCount * 5 * Self.maxChannels)
        coefficientScratch.initialize(repeating: 0, count: AudioEffectsParameters.sectionCount * 5 * Self.maxChannels)
        localBlock = .allocate(capacity: AudioEffectsParameters.blockSize)
        localBlock.initialize(repeating: 0, count: AudioEffectsParameters.blockSize)
    }

    deinit {
        if let biquad { vDSP_biquadm_DestroySetup(biquad) }
        inputPointers.deallocate()
        outputPointers.deallocate()
        channelStarts.deallocate()
        coefficientScratch.deallocate()
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
        framesSincePrepare = 0
        currentReplayGain = effectiveReplayGain()
        currentFixedGain = item.fixedGain.load()
        rebuildBiquad()
    }

    func unprepare() {
        if let biquad { vDSP_biquadm_DestroySetup(biquad) }
        biquad = nil
        biquadChannels = 0
        loadedGeneration = -1
    }

    /// (Re)creates the vDSP setup for the current channel count from the latest coefficients.
    private func rebuildBiquad() {
        if let biquad { vDSP_biquadm_DestroySetup(biquad) }
        biquad = nil
        biquadChannels = 0
        guard channels > 0, isFloat32 else { return }
        let latest = effects.latestBlock()
        let block = blockForThisRate(latest.block)
        expandCoefficients(block)
        biquad = vDSP_biquadm_CreateSetup(coefficientScratch, vDSP_Length(AudioEffectsParameters.sectionCount),
                                          vDSP_Length(channels))
        biquadChannels = biquad == nil ? 0 : channels
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

    /// Writes the mono block's sections into vDSP's multichannel layout (section → coefficient → channel).
    @inline(__always)
    private func expandCoefficients(_ block: UnsafePointer<Double>) {
        let n = max(channels, 1)
        for s in 0..<AudioEffectsParameters.sectionCount {
            for k in 0..<5 {
                let value = block[s * 5 + k]
                let base = (s * 5 + k) * n
                for c in 0..<n { coefficientScratch[base + c] = value }
            }
        }
    }

    @inline(__always)
    private func loadTail(_ block: UnsafePointer<Double>) {
        let tail = AudioEffectsParameters.sectionCount * 5
        preGain = Float(block[tail])
        width = Float(block[tail + 1])
        needsLimiter = block[tail + 2] != 0
        let nowBypass = block[tail + 3] != 0
        if nowBypass && !bypass { tailFrames = Int(sampleRate / 2) }
        if !nowBypass && bypass, let biquad { vDSP_biquadm_ResetState(biquad) }
        bypass = nowBypass
    }

    private func effectiveReplayGain() -> Float {
        let volume = item.replayGainVolume.load()
        let v = volume.isNaN ? 1 : volume
        return effects.allowReplayGainBoost.load(ordering: .relaxed) ? min(max(v, 0), ReplayGain.maxVolume)
                                                                     : min(max(v, 0), 1)
    }

    // MARK: Process (render thread — no allocation, locks or logging)

    func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int, timeRange: CMTimeRange) {
        guard frames > 0 else { return }
        let firstTime: Double
        if timeRange.start.isValid && timeRange.start.isNumeric {
            firstTime = timeRange.start.seconds
        } else {
            firstTime = Double(framesSincePrepare) / sampleRate
        }
        framesSincePrepare += frames
        item.processedMediaTime.store(firstTime + Double(frames) / sampleRate)
        item.processedFrames.wrappingAdd(frames, ordering: .relaxed)
        item.hasProcessed.store(true, ordering: .relaxed)
        guard isFloat32, channels > 0, bindChannels(bufferList, frames: frames) else { return }

        let rmsIn = item.log != nil ? rms(frames: frames) : 0

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
                expandCoefficients(latest.block)
                if let biquad {
                    vDSP_biquadm_SetTargetsDouble(biquad, coefficientScratch, 0.25, 1e-6, 0, 0,
                                                  vDSP_Length(AudioEffectsParameters.sectionCount),
                                                  vDSP_Length(biquadChannels))
                }
            }
            loadTail(latest.block)
        }
        if !bypass || tailFrames > 0 || currentPreGain != preGain {
            applyGainRamp(from: currentPreGain, to: preGain, frames: frames)
            currentPreGain = preGain
            if let biquad, biquadChannels == channels {
                vDSP_biquadm(biquad, inputPointers, vDSP_Stride(stride), outputPointers, vDSP_Stride(stride),
                             vDSP_Length(frames))
            }
            if channels == 2 && width != 1 { applyWidth(frames: frames) }
            if needsLimiter { limit(frames: frames) }
            if bypass { tailFrames = max(tailFrames - frames, 0) }
        }

        // 3. Mid/side vocal attenuation (stereo).
        let attenuation = effects.midSideAttenuation.load()
        if channels == 2 && attenuation > 0 { applyMidSide(attenuation: min(attenuation, 1), frames: frames) }

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
        if let log = item.log {
            log.append(.init(mediaTime: firstTime, frames: frames, rmsIn: rmsIn, rmsOut: rms(frames: frames),
                             hostTime: mach_absolute_time()))
        }
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
