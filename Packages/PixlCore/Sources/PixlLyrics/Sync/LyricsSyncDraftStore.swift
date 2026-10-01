// Unsaved tap-sync sessions, one JSON file per song at `<directory>/{sha1(songId)}.json`, written atomically
// (temp file, fsync, replace). Port of the Android `LyricsSyncDraftStore`: same file names, same JSON
// (`LyricsSyncDraftCodec`), same 8 MiB read cap and 60-day pruning. Drafts are not backed up; they are deleted after
// a successful save or "Start over". The app passes the directory (Application Support/lyrics_sync_drafts).
//
// Works on Windows too (swift-corelibs-foundation FileManager/FileHandle), which is where the tests run locally.

import Foundation
import PixlModel

/// Reads and writes draft files. An actor, so concurrent saves and loads never interleave (Android: a `Mutex`).
public actor LyricsSyncDraftStore {
    public static let directoryName = "lyrics_sync_drafts"
    public static let maxAgeMs: Int64 = 60 * 24 * 60 * 60 * 1_000
    static let maxFileBytes: Int64 = 8 * 1024 * 1024

    public nonisolated let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The draft file for a song.
    public nonisolated func fileFor(_ songId: String) -> URL {
        directory.appendingPathComponent(Self.sha1(songId) + ".json", isDirectory: false)
    }

    /// The stored draft for `songId`, or nil. Unreadable, inconsistent or foreign drafts are deleted.
    public func load(_ songId: String) -> SyncDraft? {
        let fm = FileManager.default
        let file = fileFor(songId)
        guard Self.isFile(file) else { return nil }
        let draft: SyncDraft?
        do {
            let size = (try fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            if size > Self.maxFileBytes {
                draft = nil
            } else {
                let data = try Data(contentsOf: file)
                draft = LyricsSyncDraftCodec.decode(String(decoding: data, as: UTF8.self))
            }
        } catch {
            return nil
        }
        guard let draft, draft.songId.isIdentical(to: songId) else {
            try? fm.removeItem(at: file)
            return nil
        }
        return draft
    }

    /// Returns false when the draft could not be written (the previous file is left intact).
    @discardableResult
    public func save(_ draft: SyncDraft, nowMs: Int64 = currentTimeMillis()) -> Bool {
        let fm = FileManager.default
        if !Self.isDirectory(directory) {
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                if !Self.isDirectory(directory) { return false }
            }
        }
        guard LyricsSyncDraftCodec.isEncodable(draft) else { return false }
        let bytes = Data(LyricsSyncDraftCodec.encode(draft, nowMs: nowMs).utf8)
        let target = fileFor(draft.songId)
        let temporary = directory.appendingPathComponent("draft-\(UUID().uuidString).tmp", isDirectory: false)
        defer {
            if Self.isFile(temporary) { try? fm.removeItem(at: temporary) }
        }
        do {
            guard fm.createFile(atPath: temporary.path, contents: nil) else { return false }
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: bytes)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try Self.replace(target, with: temporary)
            return true
        } catch {
            return false
        }
    }

    /// Deletes the draft for `songId` (if any).
    public func delete(_ songId: String) {
        try? FileManager.default.removeItem(at: fileFor(songId))
    }

    public func exists(_ songId: String) -> Bool { Self.isFile(fileFor(songId)) }

    /// Deletes drafts (and stray temp files) older than `maxAgeMs`. Returns how many were removed.
    @discardableResult
    public func pruneOlderThan(maxAgeMs: Int64 = LyricsSyncDraftStore.maxAgeMs,
                               nowMs: Int64 = currentTimeMillis()) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var removed = 0
        for name in names {
            let file = directory.appendingPathComponent(name, isDirectory: false)
            guard Self.isFile(file) else { continue }
            if !name.hasSuffix(".json") && !name.hasSuffix(".tmp") { continue }
            // `File.lastModified()` is 0 when it cannot be read.
            let modified = (try? fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
                .map { Int64(($0.timeIntervalSince1970 * 1_000).rounded(.down)) } ?? 0
            if nowMs &- modified > maxAgeMs && (try? fm.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    /// Lowercase hex SHA-1 of the UTF-8 song id (the draft's file name).
    public static func sha1(_ value: String) -> String { SHA1.hexDigest(value) }

    // MARK: File helpers

    static func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Moves `temporary` over `target`, atomically where the platform allows (Android: `ATOMIC_MOVE`, falling back
    /// to a plain replacing move).
    static func replace(_ target: URL, with temporary: URL) throws {
        let fm = FileManager.default
        guard isFile(target) else {
            try fm.moveItem(at: temporary, to: target)
            return
        }
        #if os(Windows)
        // swift-corelibs-foundation has no `replaceItemAt` on Windows (it traps); the tests run there, the app never
        // does. Remove + move is the non-atomic fallback Android also uses when an atomic move is unsupported.
        try fm.removeItem(at: target)
        try fm.moveItem(at: temporary, to: target)
        #else
        do {
            _ = try fm.replaceItemAt(target, withItemAt: temporary)
        } catch {
            try fm.removeItem(at: target)
            try fm.moveItem(at: temporary, to: target)
        }
        #endif
    }
}
