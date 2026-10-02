import Foundation
import Testing
@testable import PixlFoundation

/// The model archives' tar reader, against an archive written by Python's `tarfile` (USTAR, like
/// ci/ml/common.py), plus damaged and hostile headers.
@Suite("Ustar")
struct UstarTests {
    static func fixture() throws -> URL {
        try #require(Bundle.module.url(forResource: "tiny-mlpackage", withExtension: "tar", subdirectory: "Fixtures"))
    }

    static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ustar-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func extractsPythonWrittenArchive() throws {
        let out = Self.scratch()
        defer { try? FileManager.default.removeItem(at: out) }
        var progressCalls = 0
        let members = try UstarExtractor.extract(archive: try Self.fixture(), to: out) { _ in progressCalls += 1 }
        let longDir = String(repeating: "d", count: 120)
        #expect(members == ["Tiny.mlpackage/Manifest.json", "Tiny.mlpackage/Data/com.apple.CoreML/model.mlmodel",
                            "Tiny.mlpackage/\(longDir)/w.bin"])
        let manifest = try Data(contentsOf: out.appendingPathComponent("Tiny.mlpackage/Manifest.json"))
        #expect(String(decoding: manifest, as: UTF8.self) == "{\"a\":1}")
        let model = try Data(contentsOf: out.appendingPathComponent("Tiny.mlpackage/Data/com.apple.CoreML/model.mlmodel"))
        #expect(model.count == 1300 && model.allSatisfy { $0 == UInt8(ascii: "x") })
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("Tiny.mlpackage/\(longDir)/w.bin").path))
        #expect(progressCalls == 2)
    }

    static func header(path: String, size: Int, type: UInt8 = UInt8(ascii: "0"), corruptChecksum: Bool = false) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: 512)
        for (i, b) in path.utf8.prefix(100).enumerated() { block[i] = b }
        for (i, b) in String(format: "%011o", size).utf8.enumerated() { block[124 + i] = b }
        block[156] = type
        for (i, b) in "ustar\u{0}00".utf8.enumerated() { block[257 + i] = b }
        for i in 148..<156 { block[i] = 32 }
        var sum = block.reduce(0) { $0 + Int($1) }
        if corruptChecksum { sum += 1 }
        for (i, b) in String(format: "%06o", sum).utf8.enumerated() { block[148 + i] = b }
        block[154] = 0
        return block
    }

    @Test func headerParsing() throws {
        let parsed = try #require(try UstarHeader.parse(Self.header(path: "a/b.bin", size: 1234)))
        #expect(parsed == UstarHeader(path: "a/b.bin", size: 1234, kind: .file))
        #expect(try UstarHeader.parse([UInt8](repeating: 0, count: 512)) == nil)
        #expect(throws: UstarError.badChecksum) { try UstarHeader.parse(Self.header(path: "a", size: 1, corruptChecksum: true)) }
        #expect(try UstarHeader.parse(Self.header(path: "d/", size: 0, type: UInt8(ascii: "5")))?.kind == .directory)
    }

    @Test func refusesPathsThatEscapeTheDestination() throws {
        for bad in ["../evil", "/abs", "a/../../b", "a//b", "a\\b"] { #expect(!UstarHeader.isSafe(bad)) }
        #expect(UstarHeader.isSafe("Model.mlpackage/Data/weights/weight.bin"))
        #expect(UstarHeader.isSafe("dir/"))
        let archive = Self.scratch().appendingPathExtension("tar")
        defer { try? FileManager.default.removeItem(at: archive) }
        try Data(Self.header(path: "../evil", size: 0) + [UInt8](repeating: 0, count: 1024)).write(to: archive)
        let out = Self.scratch()
        defer { try? FileManager.default.removeItem(at: out) }
        #expect(throws: UstarError.unsafePath("../evil")) { try UstarExtractor.extract(archive: archive, to: out) }
    }

    @Test func truncatedDataFails() throws {
        let archive = Self.scratch().appendingPathExtension("tar")
        defer { try? FileManager.default.removeItem(at: archive) }
        try Data(Self.header(path: "f.bin", size: 4000) + [UInt8](repeating: 7, count: 100)).write(to: archive)
        let out = Self.scratch()
        defer { try? FileManager.default.removeItem(at: out) }
        #expect(throws: UstarError.truncated) { try UstarExtractor.extract(archive: archive, to: out) }
    }

    @Test func symlinksAreRefused() throws {
        let archive = Self.scratch().appendingPathExtension("tar")
        defer { try? FileManager.default.removeItem(at: archive) }
        try Data(Self.header(path: "link", size: 0, type: UInt8(ascii: "2")) + [UInt8](repeating: 0, count: 1024)).write(to: archive)
        let out = Self.scratch()
        defer { try? FileManager.default.removeItem(at: out) }
        #expect(throws: UstarError.unsupportedEntry("link")) { try UstarExtractor.extract(archive: archive, to: out) }
    }
}
