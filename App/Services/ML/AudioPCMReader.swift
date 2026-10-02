import AVFoundation
import CoreMedia
import Foundation

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
    static func read(url: URL, sampleRate: Double, channels: Int,
                     maximumSeconds: Double = 20 * 60) async throws -> [[Float]] {
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
        var interleaved: [Float] = []
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            interleaved.reserveCapacity(min(Int(duration.seconds * sampleRate) + 4096, maximumFrames) * channels)
        }
        var scratch = [Float]()
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
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
            interleaved.append(contentsOf: scratch[0..<count])
            if interleaved.count / channels > maximumFrames {
                throw Failure(message: "This song is too long to process on this device")
            }
        }
        if reader.status == .failed {
            throw Failure(message: "Audio decoding stopped (\(reader.error?.localizedDescription ?? "unknown error"))")
        }
        guard channels > 1 else { return [interleaved] }
        let frames = interleaved.count / channels
        var result = [[Float]](repeating: [Float](repeating: 0, count: frames), count: channels)
        interleaved.withUnsafeBufferPointer { source in
            for c in 0..<channels {
                result[c].withUnsafeMutableBufferPointer { destination in
                    for f in 0..<frames { destination[f] = source[f * channels + c] }
                }
            }
        }
        return result
    }
}
