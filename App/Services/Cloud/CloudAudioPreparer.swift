import AVFoundation
import CoreMedia
import Foundation
import PixlNet

/// The file one Cloud Studio job uploads (design §1 step 1, §7.1 `CloudAudioPreparer`).
nonisolated struct CloudPreparedAudio: Sendable, Hashable {
    /// `Application Support/CloudStudio/uploads/<jobKey>.<ext>`.
    var fileURL: URL
    /// `m4a` (an AAC-LC source passed through unchanged), `flac` (everything else, decoded on the phone), or `wav`
    /// when this iOS can't encode FLAC.
    var ext: String
    var bytes: Int64
    /// Lower-case hex SHA-256 of the uploaded bytes.
    var sha256: String
    var durationMs: Int64
    /// The phone's own decode of the uploaded file: sample frames per channel at `sampleRate` (44.1 kHz stereo, the
    /// worker's processing format), for the import's priming check (§7.5, R13).
    var frames: Int64
    var sampleRate: Double
    /// The source's own bytes were uploaded (copy or passthrough export), not a decode.
    var passthrough: Bool
    /// The source was HE-AAC, below 32 kHz, or muxed video (YouTube itag 139 / 18): shown on the queue row.
    var lowQuality = false
}

/// Prepares a song for upload, off the main actor (design §1 step 1, §7.1):
/// - an AAC-LC `.m4a`/`.mp4` with exactly one audio track and no video is uploaded as it is (copied into the app's
///   container: a background upload is read by the system's transfer daemon, which can't open files outside it);
/// - an `ipod-library://` AAC-LC item goes through a passthrough export (protected items never reach here);
/// - everything else — HE-AAC (itag 139), muxed video (itag 18), MP3, Opus, WAV, ALAC, FLAC — is decoded with
///   `AVAssetReader`, the decoder the player uses, to 44.1 kHz stereo and written as 16-bit FLAC with `AVAudioFile`.
///   The worker then sees exactly the samples the phone plays: no encoder-delay mismatch with ffmpeg, and no lossy
///   encode stacked on another (R13).
/// The SHA-256, the duration and the decoded frame count are recorded for the job input and the import check.
nonisolated enum CloudAudioPreparer {
    nonisolated struct Failure: LocalizedError, Sendable, Equatable {
        let message: String
        /// The source itself can't be read: writing it in another format won't help.
        var isDecodeFailure: Bool

        init(message: String, isDecodeFailure: Bool = false) {
            self.message = message
            self.isDecodeFailure = isDecodeFailure
        }

        static func decode(_ message: String) -> Failure { Failure(message: message, isDecodeFailure: true) }

        var errorDescription: String? { message }
    }

    /// How a source is prepared.
    nonisolated enum Route: Sendable, Equatable {
        /// Copy the file unchanged (`m4a`).
        case copy
        /// `AVAssetExportSession` passthrough to `m4a` (music-library items).
        case exportPassthrough
        /// Decode and write FLAC.
        case decode
    }

    /// The worker's processing format: the decode and the frame count use it, so `frames` is directly comparable
    /// with the manifest's `decodedSamples` and the result's `samples`.
    static let sampleRate: Double = 44_100
    static let channels = 2
    /// Containers an AAC-LC source may be copied from unchanged (raw ADTS `.aac` is decoded instead).
    static let passthroughExtensions: Set<String> = ["m4a", "mp4", "m4b"]
    /// AAC below this core rate may be HE-AAC with implicit SBR signalling, which decoders treat differently: decode.
    static let minimumPassthroughSampleRate: Double = 32_000

    // MARK: Files

    /// `Application Support/CloudStudio/uploads` (created, and `CloudStudio` excluded from backups).
    static func uploadsDirectory() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw Failure(message: "No Application Support folder")
        }
        var root = base.appendingPathComponent("CloudStudio", isDirectory: true)
        let uploads = root.appendingPathComponent("uploads", isDirectory: true)
        try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        return uploads
    }

    /// `uploads/<jobKey>.<ext>`, or nil for a malformed job key (never a path outside the folder).
    static func uploadURL(jobKey: String, ext: String) throws -> URL? {
        guard CloudKeys.isValidJobKey(jobKey), CloudKeys.inputExtensions.contains(ext) else { return nil }
        return try uploadsDirectory().appendingPathComponent("\(jobKey).\(ext)")
    }

    /// `uploadURL`, throwing for a malformed job key.
    private static func outputURL(jobKey: String, ext: String) throws -> URL {
        guard let url = try uploadURL(jobKey: jobKey, ext: ext) else { throw Failure(message: "Bad job key") }
        return url
    }

    /// Deletes a job's prepared file(s), whatever their extension.
    static func removeUpload(jobKey: String) {
        guard CloudKeys.isValidJobKey(jobKey), let directory = try? uploadsDirectory() else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(jobKey + ".") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Bytes held by prepared uploads (Settings › Cloud processing).
    static func uploadsBytes() -> Int64 {
        guard let directory = try? uploadsDirectory() else { return 0 }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.reduce(0) { sum, name in
            let size = (try? directory.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + Int64(size)
        }
    }

    // MARK: Decision

    /// Copy, export or decode (pure, unit-tested).
    static func route(isLibraryItem: Bool, fileExtension: String, audioTrackCount: Int, videoTrackCount: Int,
                      formatID: AudioFormatID?, sourceSampleRate: Double?) -> Route {
        guard audioTrackCount == 1, videoTrackCount == 0, formatID == kAudioFormatMPEG4AAC,
              let rate = sourceSampleRate, rate >= minimumPassthroughSampleRate else { return .decode }
        if isLibraryItem { return .exportPassthrough }
        return passthroughExtensions.contains(fileExtension.lowercased()) ? .copy : .decode
    }

    // MARK: Prepare

    /// Prepares `source` (a file URL or an `ipod-library://` URL) as job `jobKey`'s upload. Replaces an earlier
    /// prepared file of the same job. `@concurrent`: never runs on the caller's actor.
    @concurrent
    static func prepare(source: URL, jobKey: String) async throws -> CloudPreparedAudio {
        guard CloudKeys.isValidJobKey(jobKey) else { throw Failure(message: "Bad job key") }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let asset = AVURLAsset(url: source)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = audioTracks.first else { throw Failure(message: "No audio track found in this song") }
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        var formatID: AudioFormatID?
        var sourceRate: Double?
        if let descriptions = try? await track.load(.formatDescriptions), let description = descriptions.first,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
            formatID = basic.pointee.mFormatID
            sourceRate = basic.pointee.mSampleRate
        }
        let isLibraryItem = source.scheme?.lowercased() == "ipod-library"
        let route = route(isLibraryItem: isLibraryItem, fileExtension: source.pathExtension,
                          audioTrackCount: audioTracks.count, videoTrackCount: videoTracks.count,
                          formatID: formatID, sourceSampleRate: sourceRate)
        removeUpload(jobKey: jobKey)

        var output: URL
        var passthrough = false
        var frames: Int64 = 0
        switch route {
        case .copy:
            output = try outputURL(jobKey: jobKey, ext: "m4a")
            try FileManager.default.copyItem(at: source, to: output)
            passthrough = true
        case .exportPassthrough:
            output = try outputURL(jobKey: jobKey, ext: "m4a")
            do {
                try await exportPassthrough(asset, to: output)
                passthrough = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Some library items refuse a passthrough export: decode them instead.
                try? FileManager.default.removeItem(at: output)
                (output, frames) = try await decodeToLossless(asset, track: track, jobKey: jobKey)
            }
        case .decode:
            (output, frames) = try await decodeToLossless(asset, track: track, jobKey: jobKey)
        }

        do {
            if passthrough {
                // The phone's own decode of exactly the bytes being uploaded.
                frames = try await countFrames(of: output)
            }
            guard frames > 0 else { throw Failure(message: "This song decoded to no audio") }
            let durationMs = frames * 1000 / Int64(sampleRate)
            if durationMs > CloudLimits.maxDurationMs { throw Failure(message: "This song is longer than 15 minutes") }
            let bytes = Int64((try output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard bytes > 0 else { throw Failure(message: "The prepared file is empty") }
            if bytes > CloudLimits.maxInputBytes {
                throw Failure(message: "The prepared file is \(bytes / 1_048_576) MB, over the cloud worker's "
                    + "\(CloudLimits.maxInputBytes / 1_048_576) MB limit")
            }
            try Task.checkCancellation()
            let sha256 = try ModelManager.sha256Hex(of: output)
            let heAAC = formatID == kAudioFormatMPEG4AAC_HE || formatID == kAudioFormatMPEG4AAC_HE_V2
            let lowQuality = heAAC || (sourceRate ?? sampleRate) < minimumPassthroughSampleRate || !videoTracks.isEmpty
            return CloudPreparedAudio(fileURL: output, ext: output.pathExtension.lowercased(), bytes: bytes, sha256: sha256,
                                      durationMs: durationMs, frames: frames, sampleRate: sampleRate,
                                      passthrough: passthrough, lowQuality: lowQuality)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    // MARK: Steps

    private static func exportPassthrough(_ asset: AVURLAsset, to output: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw Failure(message: "No passthrough export for this song")
        }
        try await session.export(to: output, as: .m4a)
    }

    /// Decodes to 44.1 kHz stereo and writes 16-bit FLAC; if this iOS can't encode FLAC, FLAC without the bit-depth
    /// hint, then 16-bit WAV (the worker accepts both). Returns the file and its frame count.
    private static func decodeToLossless(_ asset: AVURLAsset, track: AVAssetTrack,
                                         jobKey: String) async throws -> (URL, Int64) {
        let flacHinted: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitDepthHintKey: 16,
        ]
        let flacPlain: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        let wav: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        var lastError: (any Error)?
        for (ext, settings) in [("flac", flacHinted), ("flac", flacPlain), ("wav", wav)] {
            let output = try outputURL(jobKey: jobKey, ext: ext)
            try? FileManager.default.removeItem(at: output)
            do {
                let frames = try decode(asset, track: track, writingTo: output, settings: settings)
                return (output, frames)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: output)
                throw CancellationError()
            } catch let failure as Failure where failure.isDecodeFailure {
                // The source itself can't be read: another container won't help.
                try? FileManager.default.removeItem(at: output)
                throw failure
            } catch {
                try? FileManager.default.removeItem(at: output)
                lastError = error
            }
        }
        throw Failure(message: "Couldn't write the song for upload (\(lastError?.localizedDescription ?? "unknown error"))")
    }

    /// One decode pass: interleaved float32 from the reader, deinterleaved into the file's processing format.
    private static func decode(_ asset: AVURLAsset, track: AVAssetTrack, writingTo output: URL,
                               settings: [String: Any]) throws -> Int64 {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw Failure.decode("Couldn't open this song (\(error.localizedDescription))")
        }
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: pcmReadSettings)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw Failure.decode("This song's audio can't be decoded") }
        reader.add(readerOutput)
        guard reader.startReading() else {
            throw Failure.decode("Couldn't decode this song (\(reader.error?.localizedDescription ?? "unknown error"))")
        }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let frames: Int64
        do {
            // The file is finished (and closed) when it is released at the end of this scope.
            let file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            let format = file.processingFormat
            guard format.channelCount == AVAudioChannelCount(channels) else {
                throw Failure(message: "Unexpected channel layout")
            }
            let capacity = 16_384
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity)),
                  let destination = buffer.floatChannelData else {
                throw Failure(message: "No audio buffer")
            }
            var scratch = [Float](repeating: 0, count: capacity * channels)
            var written: Int64 = 0
            let maximumFrames = (CloudLimits.maxDurationMs / 1000 + 5) * Int64(sampleRate)
            while let sample = readerOutput.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                // The buffer's own sample count: its block can be larger than the samples it holds (the last one
                // is padded), and copying by byte length wrote that padding into the upload (CI caught 1,332 frames).
                let totalFrames = min(CMSampleBufferGetNumSamples(sample),
                                      CMBlockBufferGetDataLength(block) / (MemoryLayout<Float>.size * channels))
                var frameOffset = 0
                while frameOffset < totalFrames {
                    let chunk = min(totalFrames - frameOffset, capacity)
                    let status = scratch.withUnsafeMutableBytes { raw in
                        CMBlockBufferCopyDataBytes(block, atOffset: frameOffset * channels * MemoryLayout<Float>.size,
                                                   dataLength: chunk * channels * MemoryLayout<Float>.size,
                                                   destination: raw.baseAddress!)
                    }
                    guard status == kCMBlockBufferNoErr else { throw Failure.decode("Audio decoding failed") }
                    let left = destination[0], right = destination[1]
                    for f in 0..<chunk {
                        left[f] = scratch[f * 2]
                        right[f] = scratch[f * 2 + 1]
                    }
                    buffer.frameLength = AVAudioFrameCount(chunk)
                    try file.write(from: buffer)
                    written += Int64(chunk)
                    frameOffset += chunk
                }
                if written > maximumFrames { throw Failure.decode("This song is longer than 15 minutes") }
            }
            frames = written
        }
        if reader.status == .failed {
            throw Failure.decode("Audio decoding stopped (\(reader.error?.localizedDescription ?? "unknown error"))")
        }
        return frames
    }

    /// The decoded length of a file at 44.1 kHz stereo, counted without keeping the samples.
    @concurrent
    static func countFrames(of url: URL) async throws -> Int64 {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw Failure.decode("No audio track found in the prepared file")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcmReadSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.decode("The prepared file can't be decoded") }
        reader.add(output)
        guard reader.startReading() else {
            throw Failure.decode("Couldn't decode the prepared file (\(reader.error?.localizedDescription ?? "unknown error"))")
        }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var frames: Int64 = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            frames += Int64(CMSampleBufferGetNumSamples(sample))
        }
        if reader.status == .failed {
            throw Failure.decode("Decoding the prepared file stopped (\(reader.error?.localizedDescription ?? "unknown error"))")
        }
        return frames
    }

    /// Interleaved float32 at 44.1 kHz stereo (`AudioPCMReader`'s settings).
    private static var pcmReadSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
    }
}
