import AVFoundation
import CoreMedia
import Foundation
import PixlModel

/// Decodes a whole song to float PCM at a fixed rate and channel count (Android `TaisLyricsAligner.decodeToMono16k`
/// and `TaisStemSeparator.decodeToStereoFloat` + `resampleTo44100`). `AVAssetReaderTrackOutput` does the decoding,
/// the channel mix-down and the sample-rate conversion (Android interpolates linearly by hand), for every format
/// AVFoundation plays — local files, `ipod-library://` items and downloaded streams.
nonisolated enum AudioPCMReader {
    nonisolated struct Failure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    /// Deinterleaved channels (`channels` arrays of equal length). Checks for cancellation between buffers.
    /// `@concurrent`: decoding a whole song never runs on the caller's actor (approachable concurrency would put a
    /// main-actor caller's call on the main thread).
    @concurrent
    static func read(url: URL, sampleRate: Double, channels: Int,
                     maximumSeconds: Double? = nil) async throws -> [[Float]] {
        // What this phone can hold: a 6-minute stereo song at 44.1 kHz is ~127 MB as Float, and the separator keeps the mix
        // and its result (3.5 GB phones: ~11 minutes of stereo, 20 minutes of 16 kHz mono).
        let maximumSeconds = maximumSeconds ?? HeavyWorkPolicy.maxDecodeSeconds(
            channels: channels, sampleRate: sampleRate, physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
        let pacer = HeavyWorkGate.shared.makePacer()
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw Failure(message: "No audio track found in this song")
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure(message: "This song's audio can't be decoded") }
        reader.add(output)
        guard reader.startReading() else {
            throw Failure(message: "Couldn't decode this song (\(reader.error?.localizedDescription ?? "unknown error"))")
        }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let maximumFrames = Int(maximumSeconds * sampleRate)
        // One array per channel, filled buffer by buffer: the whole song is never held twice (an interleaved copy plus
        // the split one was 2x the audio, ~170 MB more for a 6-minute stereo song at 44.1 kHz).
        var planes = [[Float]](repeating: [], count: channels)
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            let frames = min(Int(duration.seconds * sampleRate) + 4096, maximumFrames)
            for c in 0..<channels { planes[c].reserveCapacity(frames) }
        }
        var scratch = [Float]()
        while let buffer = output.copyNextSampleBuffer() {
            // Decoding is CPU-bound: it pauses with the rest of the heavy work and leaves the cores half the time.
            try pacer.checkpoint()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            if scratch.count < count { scratch = [Float](repeating: 0, count: count) }
            let status = scratch.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                           destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw Failure(message: "Audio decoding failed") }
            let frames = count / channels
            if channels == 1 {
                planes[0].append(contentsOf: scratch[0..<count])
            } else {
                scratch.withUnsafeBufferPointer { source in
                    for c in 0..<channels {
                        let lane = [Float](unsafeUninitializedCapacity: frames) { slot, initialized in
                            for f in 0..<frames { slot[f] = source[f * channels + c] }
                            initialized = frames
                        }
                        planes[c].append(contentsOf: lane)
                    }
                }
            }
            if planes[0].count > maximumFrames {
                throw Failure(message: "This song is too long to process on this device")
            }
        }
        if reader.status == .failed {
            throw Failure(message: "Audio decoding stopped (\(reader.error?.localizedDescription ?? "unknown error"))")
        }
        return planes
    }
}
