import Foundation
import PixlAudioCore
import XCTest
@testable import PixlAudio

/// Stage 14 against the real published models (release `models-v1`, fetched over the network like the app does,
/// then verified, extracted and compiled by `ModelManager.install`): the wav2vec2 window pipeline produces one
/// normalised log-probability row per 20 ms frame, lyric alignment refuses lyrics over audio without a voice, and
/// MDX-Net renders a complete, level-safe instrumental WAV. Skipped when the release can't be reached.
final class TaisModelTests: XCTestCase {
    private func installed(_ model: ModelDescriptor) async throws -> URL {
        if let url = ModelManager.compiledURL(model), ModelManager.installedSize(model) != nil { return url }
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await URLSession.shared.download(from: model.downloadURL)
        } catch {
            throw XCTSkip("models-v1 unreachable: \(error.localizedDescription)")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw XCTSkip("models-v1 answered \(response)") }
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tar")
        try FileManager.default.moveItem(at: temporary, to: archive)
        let compiled = try await ModelManager.install(model, archive: archive)
        XCTAssertNotNil(ModelManager.installedSize(model), "the installed model is not recognised")
        return compiled
    }

    private static func tone(seconds: Double, rate: Double, frequency: Double = 220) -> [Float] {
        (0..<Int(seconds * rate)).map { Float(sin(Double($0) * 2 * .pi * frequency / rate) * 0.3) }
    }

    func testWav2Vec2EmitsANormalisedRowPerFrame() async throws {
        executionTimeAllowance = 900
        let url = try await installed(ModelCatalog.wav2vec2)
        let samples = Self.tone(seconds: 12.5, rate: 16_000)
        let progress = ProgressLog()
        let rows = try await Wav2Vec2Aligner().logProbabilities(samples: samples, modelURL: url) { done, total in
            await progress.record(done, total)
        }
        let frames = CtcAlignmentCore.frameCount(samples: samples.count)
        let vocabulary = Wav2Vec2Vocabulary.size
        XCTAssertEqual(rows.count, frames * vocabulary)
        let windows = await progress.calls
        XCTAssertEqual(windows.last?.1, CtcAlignmentCore.fixedWindows(sampleCount: samples.count,
                                                                     inputSamples: ModelCatalog.Wav2Vec2.inputSamples).count)
        var blankFrames = 0
        for frame in 0..<frames {
            let row = rows[(frame * vocabulary)..<((frame + 1) * vocabulary)]
            XCTAssertTrue(row.allSatisfy(\.isFinite), "frame \(frame) is not finite")
            let total = row.reduce(0.0) { $0 + exp(Double($1)) }
            XCTAssertEqual(total, 1, accuracy: 1e-3, "frame \(frame) is not a probability distribution")
            if row.indices.max(by: { row[$0] < row[$1] }) == row.startIndex + Wav2Vec2Vocabulary.blankId { blankFrames += 1 }
        }
        // A pure tone carries no speech: CTC's blank wins almost everywhere.
        XCTAssertGreaterThan(Double(blankFrames) / Double(frames), 0.8)
    }

    func testAlignmentRefusesLyricsOverAToneInsteadOfInventingTimings() async throws {
        executionTimeAllowance = 900
        let url = try await installed(ModelCatalog.wav2vec2)
        let samples = Self.tone(seconds: 8, rate: 16_000)
        do {
            let timings = try await Wav2Vec2Aligner().align(samples: samples, words: ["hello", "darkness", "my", "old", "friend"],
                                                            modelURL: url) { _, _ in }
            XCTAssertTrue(timings.isEmpty, "timings were produced for a tone: \(timings)")
        } catch let failure as TaisLyricsAlignment.Failure {
            XCTAssertEqual(failure, .notConfident)
        }
    }

    func testMdxRendersACompleteInstrumental() async throws {
        executionTimeAllowance = 900
        let url = try await installed(ModelCatalog.mdxnet)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mdx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("tone.wav")
        try TestToneWriter.write(to: source, seconds: 7)
        let destination = directory.appendingPathComponent("tone_instrumental.wav")
        let progress = ProgressLog()
        try await MdxStemSeparator().renderInstrumental(source: source, destination: destination, modelURL: url) { done, total in
            Task { await progress.record(done, total) }
        }
        XCTAssertTrue(InstrumentalFiles.isComplete(destination))
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)
        XCTAssertEqual(size.intValue, 44 + 7 * MdxSeparation.sampleRate * 4, "7 s of 16-bit stereo plus the header")
        let channels = try await AudioPCMReader.read(url: destination, sampleRate: Double(MdxSeparation.sampleRate), channels: 2)
        let peak = channels.flatMap { $0 }.reduce(Float(0)) { max($0, abs($1)) }
        XCTAssertLessThanOrEqual(peak, 0.99, "the peak-safe gain was not applied")
    }

    func testAWrongArchiveIsRefusedBeforeExtraction() async throws {
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tar")
        try Data(repeating: 7, count: 1024).write(to: archive)
        do {
            _ = try await ModelManager.install(ModelCatalog.mdxnet, archive: archive)
            XCTFail("a wrong archive was installed")
        } catch let error as ModelManager.ModelError {
            XCTAssertTrue(error.message.contains("wrong size"), error.message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path), "the rejected archive was kept")
    }

    func testSha256MatchesCryptoKitReference() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try ModelManager.sha256Hex(of: file),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

private actor ProgressLog {
    private(set) var calls: [(Int, Int)] = []
    func record(_ done: Int, _ total: Int) { calls.append((done, total)) }
}
