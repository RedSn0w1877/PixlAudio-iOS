import AVFoundation
import CoreMedia
import Foundation
import PixlModel
import XCTest
@testable import PixlAudio

/// Test audio written at test time (no fixtures): 16-bit PCM WAV files of sines and noise.
enum TestAudio {
    static let sampleRate = 44_100

    /// A stereo sine. `rightAmplitude` nil = same as left (centred).
    static func sine(frequency: Double, seconds: Double, amplitude: Double = 0.5, rightAmplitude: Double? = nil,
                     rightFrequency: Double? = nil, id3: Data? = nil, name: String = UUID().uuidString) throws -> URL {
        let frames = Int(seconds * Double(sampleRate))
        var samples = [Int16](repeating: 0, count: frames * 2)
        let twoPi = 2.0 * Double.pi
        for i in 0..<frames {
            let t = Double(i) / Double(sampleRate)
            let l = amplitude * sin(twoPi * frequency * t)
            let r = (rightAmplitude ?? amplitude) * sin(twoPi * (rightFrequency ?? frequency) * t)
            samples[2 * i] = Int16(max(-1, min(1, l)) * 32_767)
            samples[2 * i + 1] = Int16(max(-1, min(1, r)) * 32_767)
        }
        return try write(samples, channels: 2, id3: id3, name: name)
    }

    /// Stereo white noise (seeded, uncorrelated channels).
    static func noise(seconds: Double, amplitude: Double = 0.3, seed: UInt64 = 1,
                      name: String = UUID().uuidString) throws -> URL {
        let frames = Int(seconds * Double(sampleRate))
        var samples = [Int16](repeating: 0, count: frames * 2)
        var state = seed
        for i in 0..<(frames * 2) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double(state >> 11) / Double(1 << 53) * 2 - 1
            samples[i] = Int16(unit * amplitude * 32_767)
        }
        return try write(samples, channels: 2, name: name)
    }

    static func write(_ samples: [Int16], channels: Int, id3: Data? = nil, name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pixlaudio-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name).appendingPathExtension("wav")
        var data = Data(capacity: 44 + samples.count * 2)
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let id3Chunk = id3.map { 8 + $0.count + ($0.count & 1) } ?? 0
        data.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36 + samples.count * 2 + id3Chunk))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); le(UInt32(16)); le(UInt16(1)); le(UInt16(channels))
        le(UInt32(sampleRate)); le(UInt32(sampleRate * channels * 2)); le(UInt16(channels * 2)); le(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); le(UInt32(samples.count * 2))
        samples.withUnsafeBufferPointer { buffer in
            for s in buffer { le(s) }
        }
        if let id3 {
            data.append(contentsOf: Array("id3 ".utf8)); le(UInt32(id3.count))
            data.append(id3)
            if id3.count & 1 == 1 { data.append(0) }
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// An ID3v2.3 tag with one `TXXX` frame per (description, value).
    static func id3Tag(_ frames: [(String, String)]) -> Data {
        var body = Data()
        for (description, value) in frames {
            var content = Data([0])   // ISO-8859-1
            content.append(contentsOf: Array(description.utf8)); content.append(0)
            content.append(contentsOf: Array(value.utf8))
            body.append(contentsOf: Array("TXXX".utf8))
            withUnsafeBytes(of: UInt32(content.count).bigEndian) { body.append(contentsOf: $0) }
            body.append(contentsOf: [0, 0])
            body.append(content)
        }
        var tag = Data(Array("ID3".utf8) + [3, 0, 0])
        let size = body.count
        tag.append(contentsOf: [UInt8((size >> 21) & 0x7F), UInt8((size >> 14) & 0x7F),
                                UInt8((size >> 7) & 0x7F), UInt8(size & 0x7F)])
        tag.append(body)
        return tag
    }

    static func song(_ url: URL, id: String? = nil, title: String = "Test", seconds: Double) -> Song {
        Song(id: id ?? "f:test/\(url.lastPathComponent)", title: title, artist: "PixlAudio Tests", artistId: 1,
             album: "Tests", albumId: 1, path: url.path, contentUriString: url.absoluteString, albumArtUriString: nil,
             duration: Int64(seconds * 1000), mimeType: "audio/wav", bitrate: nil, sampleRate: sampleRate)
    }
}

/// Runs a file through the processing tap offline (`AVAssetReaderAudioMixOutput` with the tap's audio mix) and
/// returns the processed interleaved stereo Float samples.
enum TapOfflineRenderer {
    static func render(_ url: URL, effects: AudioEffectsParameters, item: TapItemParameters) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: TestAudio.sampleRate,
        ])
        output.audioMix = ProcessingTap.makeAudioMix(for: track, effects: effects, item: item)
        XCTAssertNotNil(output.audioMix, "tap creation failed")
        reader.add(output)
        XCTAssertTrue(reader.startReading(), "reader failed: \(String(describing: reader.error))")
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = chunk.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            XCTAssertEqual(status, noErr)
            samples += chunk
        }
        XCTAssertEqual(reader.status, .completed, "reader: \(String(describing: reader.error))")
        return samples
    }

    /// RMS of one channel (0 = left, 1 = right) of interleaved stereo over `range` (frames).
    static func rms(_ samples: [Float], channel: Int, frames range: Range<Int>) -> Double {
        var sum = 0.0
        var n = 0
        for frame in range where frame * 2 + channel < samples.count {
            let v = Double(samples[frame * 2 + channel])
            sum += v * v
            n += 1
        }
        return n > 0 ? (sum / Double(n)).squareRoot() : 0
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}
