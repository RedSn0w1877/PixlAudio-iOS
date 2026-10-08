import CoreML
import Foundation
import PixlFoundation
import PixlModel
import PixlNet
import XCTest
@testable import PixlAudio

/// The downloadable local AI model (2026-10-07, local AI phase 2), on the simulator's Core ML:
/// - **Smoke test:** a tiny random Qwen2-shaped model made by the same conversion as the real one
///   (`ci/ml/convert_llm.py`: stateful KV cache, int4 per block of 32, the app's input/state/output contract) runs
///   through `CoreMLCausalModel` + PixlNet's `LocalLLMGenerator` and must reproduce, token for token, the greedy
///   continuation Core ML gave on the CI Mac (`local_llm_tiny.json`), from a fresh cache and from a reused prefix.
/// - **Install:** `ModelManager.install` keeps the tar's extra file (the tokenizer) beside the compiled model.
/// - **Runtime:** `LocalModelRuntime` runs requests on its queue and stops a generation when its task is cancelled.
/// - **Prompts:** the pure parts of `LocalModelPrompts`.
///
/// The real model (~1 GB) isn't downloaded here; its speed and answers can only be judged on the phone.
final class LocalModelTests: XCTestCase {
    struct Expected {
        let context: Int
        let prompt: [Int]
        let greedy: [Int]
    }

    private static func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: LocalModelTests.self).url(forResource: name, withExtension: ext),
                      "\(name).\(ext) is not bundled with the tests")
    }

    private static func expected() throws -> Expected {
        let data = try Data(contentsOf: try fixture("local_llm_tiny", "json"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let prompt = try XCTUnwrap(object["prompt"] as? [Int])
        let greedy = try XCTUnwrap(object["greedy"] as? [Int])
        let context = try XCTUnwrap(object["context"] as? Int)
        return Expected(context: context, prompt: prompt, greedy: greedy)
    }

    /// The tiny model's package, extracted from its tar into a fresh temporary directory.
    private func extractedPackage() throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("llm-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: work) }
        let members = try UstarExtractor.extract(archive: try Self.fixture("local_llm_tiny", "tar"), to: work)
        let first = try XCTUnwrap(members.first, "the tiny model's tar is empty")
        let package = String(first.split(separator: "/").first ?? "")
        XCTAssertTrue(package.hasSuffix(".mlpackage"), first)
        return work.appendingPathComponent(package, isDirectory: true)
    }

    private func compiledTinyModel() async throws -> URL {
        let compiled = try await MLModel.compileModel(at: try extractedPackage())
        addTeardownBlock { try? FileManager.default.removeItem(at: compiled) }
        return compiled
    }

    /// Argmax without any penalty: what the CI reference did.
    private static let pureGreedy = SamplingSettings(temperature: 0, topK: 1, topP: 1, repetitionPenalty: 1)

    private static func request(_ prompt: [Int], _ count: Int) -> LocalGenerationRequest {
        LocalGenerationRequest(prompt: prompt, maxNewTokens: count, sampling: pureGreedy, stopTokens: [],
                               prefillChunk: 4, minimumAnswerTokens: 1)
    }

    // MARK: Smoke test

    func testTinyModelReproducesTheCoreMLReference() async throws {
        let expected = try Self.expected()
        let model = try CoreMLCausalModel(compiledURL: try await compiledTinyModel(), computeUnits: .cpuOnly)
        XCTAssertEqual(model.contextLength, expected.context)
        XCTAssertEqual(model.vocabularySize, 256)
        let generator = LocalLLMGenerator(model: model)

        let first = try generator.generate(Self.request(expected.prompt, expected.greedy.count))
        XCTAssertEqual(first.tokens, expected.greedy, "a fresh cache")
        XCTAssertEqual(first.finish, .length)

        // The same conversation continued: the cache keeps the prompt and the first five answer tokens.
        let split = 5
        let continued = try generator.generate(Self.request(expected.prompt + Array(expected.greedy.prefix(split)),
                                                            expected.greedy.count - split))
        XCTAssertEqual(continued.reusedTokens, expected.prompt.count + split - 1)
        XCTAssertEqual(continued.tokens, Array(expected.greedy.dropFirst(split)), "a reused prefix")

        // A different prompt that shares only its first tokens, then the original again from a reset state.
        _ = try generator.generate(Self.request(Array(expected.prompt.prefix(3)) + [1, 2, 3], 4))
        model.resetState()
        generator.reset()
        let again = try generator.generate(Self.request(expected.prompt, expected.greedy.count))
        XCTAssertEqual(again.tokens, expected.greedy, "after a reset")
    }

    func testTheCausalMaskAndLogitsKeepTheirShapes() async throws {
        let model = try CoreMLCausalModel(compiledURL: try await compiledTinyModel(), computeUnits: .cpuOnly)
        var logits = [Float](repeating: .nan, count: model.vocabularySize)
        // A full query of new tokens, then a single one at the end of the context.
        try model.step(Array(0..<16)[...], past: 0, logits: &logits)
        XCTAssertTrue(logits.allSatisfy(\.isFinite))
        try model.step([7][...], past: model.contextLength - 1, logits: &logits)
        XCTAssertTrue(logits.allSatisfy(\.isFinite))
    }

    // MARK: Install and runtime

    /// The tiny model with a byte-level tokenizer file beside it, installed like the real download.
    private func installTinyModel() async throws -> ModelDescriptor {
        let package = try extractedPackage()
        let root = package.deletingLastPathComponent()
        let tokenizer = root.appendingPathComponent(ModelCatalog.LocalLLM.tokenizerFile)
        try Self.byteTokenizer().write(to: tokenizer)
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("llm-\(UUID().uuidString).tar")
        try TestTar.write(directory: root, to: archive)
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)
        let descriptor = ModelDescriptor(id: .llm, file: "test.tar", package: package.lastPathComponent,
                                         bytes: size.int64Value, sha256: try ModelManager.sha256Hex(of: archive),
                                         title: "Test", purpose: "Test", extraFiles: [ModelCatalog.LocalLLM.tokenizerFile])
        if let directory = ModelManager.directory(for: descriptor) {
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        }
        _ = try await ModelManager.install(descriptor, archive: archive)
        return descriptor
    }

    /// A tokenizer file with the 256 byte tokens only (ids = byte values), in PixlNet's format.
    private static func byteTokenizer() -> Data {
        var data = Data("PXBPE1".utf8) + Data([0, 0])
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        u32(1)
        u32(0)
        u32(256)
        for byte in 0..<256 { u32(UInt32(byte)) }
        u32(0)
        u32(0)
        return data
    }

    func testInstallKeepsTheTokenizerBesideTheModel() async throws {
        let descriptor = try await installTinyModel()
        XCTAssertTrue(ModelManager.isInstalled(descriptor))
        let tokenizer = try XCTUnwrap(ModelManager.extraFileURL(descriptor, ModelCatalog.LocalLLM.tokenizerFile))
        XCTAssertNoThrow(try BytePairTokenizer(contentsOf: tokenizer))
        let size = try XCTUnwrap(ModelManager.installedSize(descriptor))
        let compiled = try XCTUnwrap(ModelManager.compiledURL(descriptor))
        XCTAssertGreaterThan(size, ModelManager.directorySize(compiled), "the tokenizer counts towards the size")
        // Without its tokenizer the model isn't installed.
        try FileManager.default.removeItem(at: tokenizer)
        XCTAssertFalse(ModelManager.isInstalled(descriptor))
    }

    func testRuntimeGeneratesOnItsQueueAndStopsWhenCancelled() async throws {
        let descriptor = try await installTinyModel()
        let expected = try Self.expected()
        let runtime = LocalModelRuntime(descriptor: descriptor)
        let prompt = expected.prompt, count = expected.greedy.count
        let tokens = try await runtime.run { session in
            try session.generate(Self.request(prompt, count)).tokens
        }
        // The runtime prefers the GPU; the simulator's Core ML may run it on the CPU or the Mac's GPU, so only the
        // first tokens (the clearest margins) must match.
        XCTAssertEqual(tokens.count, count)
        XCTAssertEqual(tokens.first, expected.greedy.first)
        XCTAssertNotNil(runtime.lastStats)

        // A request that would never end on its own.
        let endless = Task {
            try await runtime.run { session -> Int in
                var rounds = 0
                while true {
                    _ = try session.generate(Self.request(Array(prompt.prefix(4)) + [rounds % 200], 40))
                    rounds += 1
                }
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        endless.cancel()
        do {
            _ = try await endless.value
            XCTFail("the endless request was not stopped")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        // The queue is free again.
        let after = try await runtime.run { session in session.tokenizer.encode("ab") }
        XCTAssertEqual(after, [97, 98])
    }

    func testAMissingModelIsReportedNotLoaded() async throws {
        let missing = ModelDescriptor(id: .llm, file: "none.tar", package: "None.mlpackage", bytes: 1,
                                      sha256: "not-installed", title: "None", purpose: "None",
                                      extraFiles: [ModelCatalog.LocalLLM.tokenizerFile])
        let ai = LocalModelAI(runtime: LocalModelRuntime(descriptor: missing))
        XCTAssertEqual(ai.unavailability(), .localModelMissing)
        do {
            _ = try await ai.text(instructions: "x", prompt: "y", maxTokens: 4)
            XCTFail("a missing model answered")
        } catch {
            XCTAssertEqual(error as? OnDeviceFailure, .localModelMissing)
        }
        // Token counts fall back to the estimate.
        let count = await ai.tokenCount("hello world")
        XCTAssertEqual(count, OnDeviceText.estimatedTokens("hello world"))
    }

    // MARK: Prompts

    private func song(_ id: String, title: String, artist: String, genre: String) -> Song {
        Song(id: id, title: title, artist: artist, artistId: 1, album: "\(artist) Album", albumId: 1, path: "",
             contentUriString: "", albumArtUriString: nil, duration: 200_000, genre: genre, isFavorite: false,
             mimeType: nil, bitrate: nil, sampleRate: nil)
    }

    func testTheLibraryNoteRunsOnlyForTheUsersOwnMusic() {
        let songs = [song("1", title: "Holocene", artist: "Bon Iver", genre: "Folk"),
                     song("2", title: "Motion Sickness", artist: "Phoebe Bridgers", genre: "Indie")]
        let named = LocalModelPrompts.libraryNote(for: "Tell me about Bon Iver", songs: songs)
        XCTAssertTrue(named?.contains("Artist Bon Iver") == true, named ?? "nil")
        let mine = LocalModelPrompts.libraryNote(for: "What are my top artists?", songs: songs)
        XCTAssertTrue(mine?.contains("Top artists") == true, mine ?? "nil")
        XCTAssertNil(LocalModelPrompts.libraryNote(for: "Who wrote Bohemian Rhapsody?", songs: songs))
        XCTAssertEqual(LocalModelPrompts.libraryNote(for: "what's in my library?", songs: []), "The user's library is empty.")
    }

    func testTheChatTurnCarriesTheNoteFirst() {
        XCTAssertEqual(LocalModelPrompts.chatTurn("  hi  ", note: nil), "hi")
        XCTAssertEqual(LocalModelPrompts.chatTurn("Who's my top artist?", note: "Top artists: X."),
                       "Notes from my library:\nTop artists: X.\n\nMy message: Who's my top artist?")
    }

    func testPlansKeepTheLibrarysValuesAndPicksHaveRoom() {
        let prompt = LocalModelPrompts.planPrompt("Request: rainy", genres: ["Folk", "Indie"], artists: ["Bon Iver"])
        XCTAssertEqual(prompt, "Request: rainy\nAllowed genres: Folk, Indie\nAllowed artists: Bon Iver")
        let plan = LocalModelPrompts.plan("genres: indie\nartists: bon iver, Adele\nmoods: rainy\nenergy: 2\nfamiliar: no",
                                          genres: ["Folk", "Indie"], artists: ["Bon Iver"])
        XCTAssertEqual(plan, OnDeviceCuration.Plan(genres: ["Indie"], artists: ["Bon Iver"], moods: ["rainy"], energy: 2,
                                                   familiar: false))
        // Three digits, a comma and a space per pick fit.
        XCTAssertGreaterThanOrEqual(LocalModelPrompts.pickTokens(maximum: 40), 40 * 5)
        XCTAssertTrue(LocalModelPrompts.pickPrompt("Songs:\n1. A").hasSuffix(OnDeviceCuration.textAnswerLine))
        XCTAssertEqual(LocalModelPrompts.sampling(temperature: nil), .greedy)
        XCTAssertEqual(LocalModelPrompts.pickSampling(temperature: 1.5).repetitionPenalty, 1)
        XCTAssertLessThanOrEqual(LocalModelPrompts.pickSampling(temperature: 1.5).temperature, 0.8)
    }

    func testTheMissingModelMessageNeverReadsAsANetworkProblem() {
        let message = OnDeviceFailure.localModelMissing.message
        XCTAssertTrue(OnDeviceFailure.fixed.contains(.localModelMissing))
        XCTAssertEqual(AIPlaylistController.resolveErrorMessage(message), message)
        XCTAssertTrue(OnDeviceFailure.localModelMissing.stopsCuration)
        XCTAssertTrue(message.contains("Use downloaded AI model"))
    }

    func testTheCatalogPinsTheModelAndItsTokenizer() {
        XCTAssertEqual(ModelCatalog.descriptor(.llm), ModelCatalog.llm)
        XCTAssertTrue(ModelCatalog.all.contains(ModelCatalog.llm))
        XCTAssertFalse(ModelCatalog.tais.contains(ModelCatalog.llm), "Experimental lists the studio models only")
        XCTAssertEqual(ModelCatalog.llm.extraFiles, [ModelCatalog.LocalLLM.tokenizerFile])
        XCTAssertEqual(ModelCatalog.llm.sha256.count, 64)
        XCTAssertGreaterThan(ModelCatalog.llm.bytes, 500_000_000)
    }
}

/// An uncompressed ustar writer for the tests (the app only reads tars): regular files under `directory`, sorted.
enum TestTar {
    static func write(directory: URL, to archive: URL) throws {
        let fm = FileManager.default
        var files: [(name: String, url: URL)] = []
        let base = directory.resolvingSymlinksInPath().path
        if let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                var name = url.resolvingSymlinksInPath().path
                if name.hasPrefix(base) { name.removeFirst(base.count) }
                while name.hasPrefix("/") { name.removeFirst() }
                files.append((name, url))
            }
        }
        var output = Data()
        for file in files.sorted(by: { $0.name < $1.name }) {
            let contents = try Data(contentsOf: file.url)
            output.append(header(name: file.name, size: contents.count))
            output.append(contents)
            let padding = (512 - contents.count % 512) % 512
            output.append(Data(count: padding))
        }
        output.append(Data(count: 1024))
        try output.write(to: archive)
    }

    private static func header(name: String, size: Int) -> Data {
        var block = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, at offset: Int, length: Int) {
            for (index, byte) in Array(text.utf8).prefix(length).enumerated() { block[offset + index] = byte }
        }
        precondition(name.utf8.count < 100, "name too long for this writer: \(name)")
        put(name, at: 0, length: 100)
        put("0000644", at: 100, length: 8)
        put("0000000", at: 108, length: 8)
        put("0000000", at: 116, length: 8)
        put(String(format: "%011o", size), at: 124, length: 12)
        put("00000000000", at: 136, length: 12)
        put("        ", at: 148, length: 8)
        block[156] = UInt8(ascii: "0")
        put("ustar", at: 257, length: 6)
        put("00", at: 263, length: 2)
        let checksum = block.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", checksum), at: 148, length: 6)
        block[154] = 0
        block[155] = UInt8(ascii: " ")
        return Data(block)
    }
}
