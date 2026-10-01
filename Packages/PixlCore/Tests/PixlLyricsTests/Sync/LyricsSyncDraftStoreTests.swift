// Port of the Android `data/lyrics/sync/LyricsSyncDraftStoreTest.kt` (JUnit `@TempDir` → a fresh directory under
// the system temp folder per test), plus Swift-only checks of the codec's Java float formatting.

import Foundation
import PixlFoundation
import PixlModel
import Testing
@testable import PixlLyrics

@Suite("LyricsSyncDraftStore")
struct LyricsSyncDraftStoreTests {

    func draft(_ songId: String = "content://media/42") -> SyncDraft {
        var d = LyricsTapSync.buildDraft(songId: songId, title: "Title", artist: "Artist", album: "Album",
                                         durationMs: 200_000, lyrics: nil, pasted: "Hello world\n君が好き").draft!
        d = LyricsTapSync.tap(d, rawStartMs: 1_000, speed: 0.75, offsetMs: 100).draft
        d = LyricsTapSync.tap(d, rawStartMs: 1_400, speed: 1, offsetMs: 100).draft
        d = LyricsTapSync.release(d, tokenIndex: 1, rawEndMs: 2_600, speed: 1, offsetMs: 100)
        return LyricsTapSync.setNudge(d, nudgeMs: -20)
    }

    /// A fresh, empty directory (deleted when `body` returns).
    func withTempDir(_ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pixl-drafts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }

    func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    @Test func saveThenLoadRoundTrips() async throws {
        try await withTempDir { dir in
            let store = LyricsSyncDraftStore(directory: dir)
            let original = draft()
            #expect(await store.save(original))
            #expect(await store.exists(original.songId))
            #expect(await store.load(original.songId) == original)
            #expect(await store.load("another song") == nil)
            // Only the draft itself is left behind: no temp files.
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(names == [store.fileFor(original.songId).lastPathComponent])
        }
    }

    @Test func fileNameIsAHashOfTheSongId() async throws {
        try await withTempDir { dir in
            let store = LyricsSyncDraftStore(directory: dir)
            let name = store.fileFor("content://media/42").lastPathComponent
            #expect(name.count == 45 && name.hasSuffix(".json"))
            #expect(name.utf8.prefix(40).allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }, "\(name)")
            #expect(LyricsSyncDraftStore.sha1("abc") == "a9993e364706816aba3e25717850c26c9cd0d89d")
        }
    }

    @Test func overwritingKeepsOnlyTheLatestDraft() async throws {
        try await withTempDir { dir in
            let store = LyricsSyncDraftStore(directory: dir)
            let first = draft()
            await store.save(first)
            let second = LyricsTapSync.tap(first, rawStartMs: 5_000, speed: 1, offsetMs: 100).draft
            await store.save(second)
            #expect(await store.load(first.songId) == second)
            let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(files.count == 1)
        }
    }

    @Test func corruptOrForeignFilesAreDiscarded() async throws {
        try await withTempDir { dir in
            let store = LyricsSyncDraftStore(directory: dir)
            let original = draft()
            let file = store.fileFor(original.songId)
            try write("{ not json", to: file)
            #expect(await store.load(original.songId) == nil)
            #expect(!FileManager.default.fileExists(atPath: file.path))

            // Structurally broken: the line text no longer matches its tokens.
            let encoded = LyricsSyncDraftCodec.encode(original)
            let broken = encoded.replacingOccurrences(of: "\"Hello world\"", with: "\"Goodbye world\"")
            #expect(broken != encoded)
            try write(broken, to: file)
            #expect(await store.load(original.songId) == nil)

            // A draft stored under another song's name is not handed out.
            try write(LyricsSyncDraftCodec.encode(original), to: store.fileFor("other"))
            #expect(await store.load("other") == nil)
        }
    }

    @Test func deleteAndPrune() async throws {
        try await withTempDir { dir in
            let store = LyricsSyncDraftStore(directory: dir)
            let keep = draft("keep")
            let old = draft("old")
            await store.save(keep)
            await store.save(old)
            let now = currentTimeMillis()
            let oldDate = Date(timeIntervalSince1970: Double(now - LyricsSyncDraftStore.maxAgeMs - 60_000) / 1_000)
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: store.fileFor("old").path)
            #expect(await store.pruneOlderThan(nowMs: now) == 1)
            #expect(await store.load("keep") != nil)
            #expect(await store.load("old") == nil)

            await store.delete("keep")
            #expect(await store.load("keep") == nil)
            #expect(await store.pruneOlderThan(nowMs: now) == 0)
        }
    }

    // MARK: Swift-only

    @Test func saveCreatesTheDirectoryAndPrunesStrayTempFiles() async throws {
        try await withTempDir { dir in
            let nested = dir.appendingPathComponent("a/b", isDirectory: true)
            let store = LyricsSyncDraftStore(directory: nested)
            #expect(await store.save(draft()))
            let stray = nested.appendingPathComponent("draft-1.tmp", isDirectory: false)
            try write("x", to: stray)
            let other = nested.appendingPathComponent("notes.txt", isDirectory: false)
            try write("x", to: other)
            let future = currentTimeMillis() + LyricsSyncDraftStore.maxAgeMs + 1
            #expect(await store.pruneOlderThan(nowMs: future) == 2) // the draft and the temp file, not notes.txt
            #expect(FileManager.default.fileExists(atPath: other.path))
        }
    }

    @Test func oversizedFilesAreDiscarded() async throws {
        try await withTempDir { dir in
            let store = LyricsSyncDraftStore(directory: dir)
            let file = store.fileFor("big")
            try Data(repeating: 0x20, count: Int(LyricsSyncDraftStore.maxFileBytes) + 1).write(to: file)
            #expect(await store.load("big") == nil)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func nonFiniteSpeedsAreNotSaved() async throws {
        try await withTempDir { dir in
            let store = LyricsSyncDraftStore(directory: dir)
            var d = draft()
            d.tokens[0].startSpeed = .infinity
            #expect(await store.save(d) == false)
            #expect(await store.exists(d.songId) == false)
        }
    }

    @Test func javaFloatStrings() {
        let cases: [(Float, String)] = [
            (1, "1.0"), (0.75, "0.75"), (0.5, "0.5"), (0.1, "0.1"), (100, "100.0"), (1e-3, "0.001"),
            (1e-4, "1.0E-4"), (9_999_999, "9999999.0"), (1e7, "1.0E7"), (12_345_678, "1.2345678E7"), (1e10, "1.0E10"),
            (-2.5, "-2.5"), (0, "0.0"), (-0.0, "-0.0"), (3.4028235e38, "3.4028235E38"), (Float(bitPattern: 1), "1.4E-45"),
            (123.456, "123.456"), (0.00123, "0.00123"), (.nan, "NaN"), (.infinity, "Infinity"),
        ]
        for (value, expected) in cases {
            #expect(LyricsSyncDraftCodec.javaFloatString(value) == expected, "\(value)")
        }
        for (literal, expected) in [("0.75", Float(0.75)), (" 1 ", 1), ("0.5f", 0.5), ("2D", 2), ("7.5e-1", 0.75), (".5", 0.5)] {
            #expect(LyricsSyncDraftCodec.javaParseFloat(literal) == expected, "\(literal)")
        }
        for literal in ["", "f", "1e", "abc", "1.2.3", "--1"] {
            #expect(LyricsSyncDraftCodec.javaParseFloat(literal) == nil, "\(literal)")
        }
    }
}
