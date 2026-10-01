import Foundation
import PixlFoundation
import PixlModel
import Testing
@testable import PixlBackup

/// The bytes of a fixture in `Fixtures/`.
func fixtureBytes(_ name: String) throws -> [UInt8] {
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    let url = try #require(Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Fixtures"))
    return Array(try Data(contentsOf: url))
}

/// A JSON-lines fixture written by `tools/android-reference/BackupGen.java`.
func goldenLines(_ name: String) throws -> [JSONValue] {
    let text = String(decoding: try fixtureBytes(name), as: UTF8.self)
    let parser = JSONParser(mode: .strict, maxDepth: 64)
    return try text.split(separator: "\n", omittingEmptySubsequences: true).map { try parser.parse(String($0)) }
}

extension JSONValue {
    var str: String { stringValue ?? "" }
    var optStr: String? { isNull ? nil : stringValue }
    var i64: Int64 { int64Value ?? 0 }
    var bool: Bool { boolValue ?? false }
    var arr: [JSONValue] { arrayValue ?? [] }
}

/// Bytes from a hex string.
func hexBytes(_ hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = hex.startIndex
    while i < hex.endIndex {
        let j = hex.index(i, offsetBy: 2)
        out.append(UInt8(hex[i..<j], radix: 16)!)
        i = j
    }
    return out
}


/// A fixed clock for manifest validation (2026-09-30).
let testNow: Int64 = 1_790_800_000_000

/// A recording module handler (Android tests use relaxed MockK mocks).
actor RecordingHandler: BackupModuleHandler {
    nonisolated let section: BackupSection
    var exportPayload = "[]"
    var snapshotPayload: String
    var restoreError: BackupError?
    var rollbackError: BackupError?
    private(set) var restored: [String] = []
    private(set) var rolledBack: [String] = []
    private(set) var snapshots = 0

    init(_ section: BackupSection, snapshot: String = "snapshot") {
        self.section = section
        self.snapshotPayload = snapshot
    }

    func failRestore(_ message: String) { restoreError = BackupError(message) }
    func failRollback(_ message: String) { rollbackError = BackupError(message) }
    func setExport(_ payload: String) { exportPayload = payload }

    func export() async throws -> String { exportPayload }
    func countEntries() async throws -> Int { 0 }
    func snapshot() async throws -> String {
        snapshots += 1
        return snapshotPayload
    }
    func restore(_ payload: String) async throws {
        if let restoreError { throw restoreError }
        restored.append(payload)
    }
    func rollback(_ snapshot: String) async throws {
        if let rollbackError { throw rollbackError }
        rolledBack.append(snapshot)
    }
}

/// Builds a `.pxpl` the way the Android writer does (manifest checksums computed), optionally tampering with the
/// manifest afterwards.
func makeBackup(_ payloads: [(String, String)], createdAt: Int64 = testNow - 86_400_000,
                tamper: ((inout BackupManifest) -> Void)? = nil) -> [UInt8] {
    let manifest = BackupManifest(schemaVersion: 3, appVersion: "test", appVersionCode: 1, createdAt: createdAt,
                                  deviceInfo: DeviceInfo())
    let bytes = BackupWriter.write(manifest: manifest, modulePayloads: payloads.map { ($0.0, $0.1) })
    guard let tamper else { return bytes }
    // Rewrite the archive with an edited manifest and the same module entries.
    let archive = try! ZipArchive(bytes: Array(bytes[4...]))
    var edited = try! BackupManifest.decode(json: String(decoding: try! archive.data(for: archive.entry(named: "manifest.json")!), as: UTF8.self))!
    tamper(&edited)
    var zip = ZipWriter()
    zip.addStored(name: "manifest.json", data: Array(edited.json.utf8))
    for entry in archive.entries where entry.name != "manifest.json" {
        zip.addStored(name: entry.name, data: try! archive.data(for: entry))
    }
    return BackupFormatDetector.pxplMagic + zip.finish()
}

/// A library resembling the owner's (the songs in the Android fixtures), under PixlAudio ids.
let fixtureLibrary: [BackupSongSummary] = [
    BackupSongSummary(id: "f:music/M83/Midnight City.flac", title: "Midnight City", artistName: "M83",
                      albumName: "Hurry Up, We're Dreaming", duration: 243_500),
    BackupSongSummary(id: "f:music/The xx/Intro.m4a", title: "Intro", artistName: "The xx", albumName: "xx", duration: 127_000),
    BackupSongSummary(id: "mp:9001", title: "Teardrop", artistName: "Massive Attack", albumName: "Mezzanine", duration: 330_200),
    BackupSongSummary(id: "f:music/Other/Song.mp3", title: "Other", artistName: "Someone", albumName: "Else", duration: 100_000),
]
