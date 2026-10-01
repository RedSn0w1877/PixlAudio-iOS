import AVFoundation
import Foundation
import PixlTags
@testable import PixlAudio

/// Audio files generated at test time (no binary fixtures in the repo). Tags are written with PixlTags, exactly as
/// the app's write-back does.
enum TestAudioFiles {
    /// A 1×1 PNG, for embedded-artwork tests.
    static let tinyPNG = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
        0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
        0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ])

    /// Silent MPEG-1 Layer III frames (128 kbit/s, 44.1 kHz, mono; zero side info decodes as silence).
    static func mpegFrames(seconds: Double) -> Data {
        let frameLength = 417  // 144 * 128000 / 44100, no padding
        let frameCount = Int((seconds * 44_100 / 1152).rounded(.up))
        var frame = [UInt8](repeating: 0, count: frameLength)
        frame[0] = 0xFF
        frame[1] = 0xFB
        frame[2] = 0x90
        frame[3] = 0xC0
        var data = Data(capacity: frameLength * frameCount)
        for _ in 0..<frameCount { data.append(contentsOf: frame) }
        return data
    }

    /// An MP3 with an ID3v2.4 tag.
    static func mp3(seconds: Double, tags: TagProperties, pictures: [TagPicture]? = nil) throws -> Data {
        try AudioTagWriter.write(TagChanges(properties: tags, pictures: pictures), to: mpegFrames(seconds: seconds)).data
    }

    /// A FLAC file with a STREAMINFO block (44.1 kHz, mono, 16 bit, `seconds` of samples) and a Vorbis comment, but
    /// no audio frames: enough for the tag reader and the STREAMINFO duration.
    static func flac(seconds: Int, tags: TagProperties) throws -> Data {
        var bytes = Array("fLaC".utf8)
        bytes += [0x80, 0x00, 0x00, 0x22]  // last block, STREAMINFO, 34 bytes
        bytes += [0x10, 0x00, 0x10, 0x00]  // min / max block size 4096
        bytes += [0, 0, 0, 0, 0, 0]  // min / max frame size unknown
        let sampleRate: UInt64 = 44_100
        let totalSamples = UInt64(seconds) * sampleRate
        let packed = sampleRate << 44 | 0 << 41 | 15 << 36 | totalSamples
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: packed >> UInt64(shift))) }
        bytes += [UInt8](repeating: 0, count: 16)  // MD5
        return try AudioTagWriter.write(TagChanges(properties: tags), to: Data(bytes)).data
    }

    /// An untagged 16-bit PCM WAV tone.
    static func wav(seconds: Int) -> Data { TestToneWriter.makeWAV(seconds: seconds) }

    /// An AAC `.m4a` written with `AVAudioFile` (silence).
    static func writeM4A(to url: URL, seconds: Int) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44_100) else {
                throw CocoaError(.fileWriteUnknown)
            }
            buffer.frameLength = 44_100
            for _ in 0..<seconds { try file.write(from: buffer) }
        }
    }

    /// Writes `data` to `relativePath` under `root`, creating folders.
    @discardableResult
    static func put(_ data: Data, at relativePath: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    /// Moves a file's modification date forward so the scanner sees it as changed.
    static func touch(_ url: URL, secondsAhead: TimeInterval = 60) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(secondsAhead)],
                                              ofItemAtPath: url.path)
    }
}
