import Foundation
import PixlNet

/// The sparse disk cache behind the streaming loader (Android: ExoPlayer's SimpleCache, 1 GB auto-cache). One file
/// per video, written at the offsets the player asked for; `ByteRangeSet` records which bytes are on disk. A file
/// whose ranges cover its whole length is complete and plays straight from disk (and is what a download copies).
/// Lives in `Library/Caches/YouTube/streams`, so Settings › Offline storage can free it; least recently used files
/// go first above 1 GB.
actor StreamCache {
    nonisolated struct Meta: Codable, Sendable, Equatable {
        var contentLength: Int64
        var contentType: String
        /// The googlevideo itag the bytes came from (a re-resolution must return the same file).
        var itag: String?
        var ranges = ByteRangeSet()
        var lastAccess: Double = Date().timeIntervalSince1970
    }

    static let maxBytes: Int64 = 1_000_000_000

    let directory: URL
    private var metas: [String: Meta] = [:]
    private var handles: [String: FileHandle] = [:]

    init(directory: URL = YouTubeNetwork.cachesDirectory("streams")) {
        self.directory = directory
    }

    nonisolated func dataURL(_ videoId: String) -> URL { directory.appendingPathComponent("\(videoId).m4a") }
    nonisolated func metaURL(_ videoId: String) -> URL { directory.appendingPathComponent("\(videoId).json") }

    // MARK: Metadata

    func meta(_ videoId: String) -> Meta? {
        if let meta = metas[videoId] { return meta }
        guard let data = try? Data(contentsOf: metaURL(videoId)),
              let meta = try? JSONDecoder().decode(Meta.self, from: data),
              FileManager.default.fileExists(atPath: dataURL(videoId).path) else { return nil }
        metas[videoId] = meta
        return meta
    }

    /// Records the file's size and type. A different size or itag means another file: the old bytes go.
    func setInfo(_ videoId: String, contentLength: Int64, contentType: String, itag: String?) {
        if let existing = meta(videoId) {
            if existing.contentLength == contentLength && (existing.itag == nil || itag == nil || existing.itag == itag) {
                return
            }
            remove(videoId)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: dataURL(videoId).path) {
            FileManager.default.createFile(atPath: dataURL(videoId).path, contents: nil)
        }
        metas[videoId] = Meta(contentLength: contentLength, contentType: contentType, itag: itag)
        saveMeta(videoId)
    }

    func isComplete(_ videoId: String) -> Bool {
        guard let meta = meta(videoId) else { return false }
        return meta.ranges.isComplete(length: meta.contentLength)
    }

    /// The file to play from disk when every byte is cached.
    func completeFileURL(_ videoId: String) -> URL? {
        guard isComplete(videoId) else { return nil }
        touch(videoId)
        return dataURL(videoId)
    }

    // MARK: Bytes

    /// Contiguous cached bytes from `offset` (at most `limit`).
    func contiguousLength(_ videoId: String, from offset: Int64, limit: Int64) -> Int64 {
        meta(videoId)?.ranges.contiguousLength(from: offset, limit: limit) ?? 0
    }

    /// Where the next cached span starts after `offset` (to stop a network fetch there).
    func nextCachedStart(_ videoId: String, after offset: Int64) -> Int64? {
        meta(videoId)?.ranges.spans.first { $0.start > offset }?.start
    }

    /// The bytes of `range` when they are all cached.
    func read(_ videoId: String, _ range: Range<Int64>) -> Data? {
        guard let meta = meta(videoId), meta.ranges.contains(range), let handle = handle(videoId) else { return nil }
        do {
            try handle.seek(toOffset: UInt64(range.lowerBound))
            let data = try handle.read(upToCount: Int(range.count)) ?? Data()
            guard data.count == Int(range.count) else { return nil }
            touch(videoId)
            return data
        } catch {
            return nil
        }
    }

    /// Writes bytes at `offset` and records them.
    func write(_ videoId: String, offset: Int64, data: Data) {
        guard !data.isEmpty, var meta = meta(videoId), let handle = handle(videoId) else { return }
        let end = min(offset + Int64(data.count), meta.contentLength)
        guard end > offset else { return }
        do {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data.prefix(Int(end - offset)))
        } catch {
            return
        }
        meta.ranges.insert(offset..<end)
        meta.lastAccess = Date().timeIntervalSince1970
        metas[videoId] = meta
        saveMeta(videoId)
        if meta.ranges.isComplete(length: meta.contentLength) { closeHandle(videoId) }
    }

    /// Copies a complete file to `destination` (a download that was already fully streamed).
    func copyComplete(_ videoId: String, to destination: URL) -> Bool {
        guard isComplete(videoId) else { return false }
        closeHandle(videoId)
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? fm.copyItem(at: dataURL(videoId), to: destination)) != nil
    }

    func remove(_ videoId: String) {
        closeHandle(videoId)
        metas[videoId] = nil
        try? FileManager.default.removeItem(at: dataURL(videoId))
        try? FileManager.default.removeItem(at: metaURL(videoId))
    }

    /// Least recently used files go until the cache is under 1 GB (`keeping` is the one playing).
    func evictIfNeeded(keeping: String?) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        var entries: [(id: String, size: Int64, lastAccess: Double)] = []
        var total: Int64 = 0
        for file in files where file.pathExtension == "m4a" {
            let id = file.deletingPathExtension().lastPathComponent
            let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            total += size
            entries.append((id, size, meta(id)?.lastAccess ?? 0))
        }
        guard total > Self.maxBytes else { return }
        for entry in entries.sorted(by: { $0.lastAccess < $1.lastAccess }) where entry.id != keeping {
            remove(entry.id)
            total -= entry.size
            if total <= Self.maxBytes { break }
        }
    }

    // MARK: Private

    private func handle(_ videoId: String) -> FileHandle? {
        if let handle = handles[videoId] { return handle }
        guard let handle = try? FileHandle(forUpdating: dataURL(videoId)) else { return nil }
        handles[videoId] = handle
        return handle
    }

    private func closeHandle(_ videoId: String) {
        try? handles[videoId]?.close()
        handles[videoId] = nil
    }

    private func touch(_ videoId: String) {
        guard var meta = metas[videoId] else { return }
        let now = Date().timeIntervalSince1970
        // Persist at most once a minute for reads.
        if now - meta.lastAccess > 60 {
            meta.lastAccess = now
            metas[videoId] = meta
            saveMeta(videoId)
        }
    }

    private func saveMeta(_ videoId: String) {
        guard let meta = metas[videoId], let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: metaURL(videoId), options: .atomic)
    }
}
