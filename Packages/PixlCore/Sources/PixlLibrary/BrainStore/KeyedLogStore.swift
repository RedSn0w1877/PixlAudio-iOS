// The music brain's storage on iOS (docs/brain-spec.md, 3.8): one append-only record file per logical table, with
// an in-memory index of where each key's newest record is, and compaction when the file exceeds twice its live
// size. Pure Swift and Foundation file calls, so it is tested on Windows. It does file I/O, which is why it lives
// in `BrainStore/`, outside the `Brain/` folder the purity test scans.
//
// File format, one record per line:
//     <key> TAB <payload> LF        the newest line for a key is its value
//     <key> LF                      a line without a TAB removes the key
// The key has `%`, TAB, LF and CR percent-escaped; the payload is one line of JSON (no raw LF). A last line that was
// cut off by a crash is dropped when the file is opened.

import Foundation

/// An append-only file of keyed records. Not thread-safe: own it from one actor.
public final class KeyedLogStore {
    struct Entry {
        /// Where the payload starts in the file.
        var offset: UInt64
        /// Payload length in bytes.
        var length: Int
        /// The whole line, newline included: what the record costs in the file.
        var lineLength: Int
    }

    public let url: URL
    private var index: [BrainKey: Entry] = [:]
    private var handle: FileHandle?
    private var fileBytes = 0
    private var liveBytes = 0
    private var opened = false
    private let compactionFloorBytes: Int
    /// How many times the file was rewritten since it was opened (tests).
    public private(set) var compactions = 0

    public init(url: URL, compactionFloorBytes: Int = 32 * 1024) {
        self.url = url
        self.compactionFloorBytes = compactionFloorBytes
    }

    deinit { try? handle?.close() }

    public var count: Int { index.count }
    public var keys: [String] { index.keys.map(\.text) }
    /// Bytes of the file, and the bytes of it that are the newest record of a key.
    public var sizes: (file: Int, live: Int) { (fileBytes, liveBytes) }

    public func contains(_ key: String) -> Bool { index[BrainKey(key)] != nil }

    // MARK: Open

    /// Reads the file once and builds the index. `visit` is called with every live record, in no particular order.
    /// A missing file is an empty store. Calling it again re-reads the file.
    public func open(_ visit: ((String, ArraySlice<UInt8>) -> Void)? = nil) {
        try? handle?.close()
        handle = nil
        index.removeAll()
        fileBytes = 0
        liveBytes = 0
        opened = true
        // Read whole, not mapped: a mapped file cannot be truncated or replaced on Windows while the mapping lives.
        let bytes = Self.readAll(url)
        if bytes.isEmpty { return }
        var lineStart = 0
        var validEnd = 0
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0A {
                index(line: bytes[lineStart..<i], at: lineStart)
                lineStart = i + 1
                validEnd = lineStart
            }
            i += 1
        }
        fileBytes = validEnd
        if validEnd < bytes.count {
            // A torn last line: cut it off, so the next append starts on a line boundary.
            if let handle = try? FileHandle(forUpdating: url) {
                try? handle.truncate(atOffset: UInt64(validEnd))
                try? handle.close()
            }
        }
        if let visit {
            for (key, entry) in index {
                let start = Int(entry.offset)
                visit(key.text, bytes[start..<(start + entry.length)])
            }
        }
    }

    private static func readAll(_ url: URL) -> [UInt8] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return [UInt8](data)
    }

    private func index(line: ArraySlice<UInt8>, at lineStart: Int) {
        let lineLength = line.count + 1
        if let tab = line.firstIndex(of: 0x09) {
            let key = BrainKey(Self.unescape(line[line.startIndex..<tab]))
            if let old = index[key] { liveBytes -= old.lineLength }
            index[key] = Entry(offset: UInt64(tab + 1), length: line.endIndex - (tab + 1), lineLength: lineLength)
            liveBytes += lineLength
        } else if !line.isEmpty {
            let key = BrainKey(Self.unescape(line))
            if let old = index.removeValue(forKey: key) { liveBytes -= old.lineLength }
        }
    }

    // MARK: Read

    /// The newest payload stored for `key`, read from the file.
    public func payload(for key: String) -> [UInt8]? {
        ensureOpened()
        guard let entry = index[BrainKey(key)] else { return nil }
        if entry.length == 0 { return [] }
        guard let handle = fileHandle() else { return nil }
        do {
            try handle.seek(toOffset: entry.offset)
            guard let data = try handle.read(upToCount: entry.length), data.count == entry.length else { return nil }
            return [UInt8](data)
        } catch {
            return nil
        }
    }

    // MARK: Write

    /// Appends one record per pair in one write. A payload with a raw line feed is refused. False when the file
    /// could not be written (the index is then unchanged).
    @discardableResult
    public func put(_ records: [(key: String, payload: [UInt8])]) -> Bool {
        ensureOpened()
        if records.isEmpty { return true }
        var buffer: [UInt8] = []
        var pending: [(key: BrainKey, entry: Entry)] = []
        pending.reserveCapacity(records.count)
        for record in records {
            if record.payload.contains(0x0A) { return false }
            let key = Self.escape(record.key)
            let lineStart = buffer.count
            buffer.append(contentsOf: key)
            buffer.append(0x09)
            let payloadStart = buffer.count
            buffer.append(contentsOf: record.payload)
            buffer.append(0x0A)
            pending.append((BrainKey(record.key),
                            Entry(offset: UInt64(fileBytes + payloadStart), length: record.payload.count,
                                  lineLength: buffer.count - lineStart)))
        }
        guard append(buffer) else { return false }
        for item in pending {
            if let old = index[item.key] { liveBytes -= old.lineLength }
            index[item.key] = item.entry
            liveBytes += item.entry.lineLength
        }
        compactIfNeeded()
        return true
    }

    @discardableResult
    public func put(_ key: String, _ payload: [UInt8]) -> Bool { put([(key: key, payload: payload)]) }

    /// Removes keys (the ones that are stored). False when the file could not be written.
    @discardableResult
    public func remove(_ keys: [String]) -> Bool {
        ensureOpened()
        var buffer: [UInt8] = []
        var removed: [BrainKey] = []
        var seen: Set<BrainKey> = []
        for key in keys {
            let brainKey = BrainKey(key)
            if index[brainKey] == nil || !seen.insert(brainKey).inserted { continue }
            buffer.append(contentsOf: Self.escape(key))
            buffer.append(0x0A)
            removed.append(brainKey)
        }
        if removed.isEmpty { return true }
        guard append(buffer) else { return false }
        for key in removed {
            if let old = index.removeValue(forKey: key) { liveBytes -= old.lineLength }
        }
        compactIfNeeded()
        return true
    }

    private func append(_ buffer: [UInt8]) -> Bool {
        guard let handle = fileHandle() else { return false }
        do {
            try handle.seek(toOffset: UInt64(fileBytes))
            try handle.write(contentsOf: Data(buffer))
            fileBytes += buffer.count
            return true
        } catch {
            return false
        }
    }

    // MARK: Compaction

    /// Rewrites the file with only the newest record of every key when it has grown past twice its live size.
    public func compactIfNeeded() {
        if fileBytes > compactionFloorBytes && fileBytes > 2 * liveBytes { compact() }
    }

    /// Rewrites the file now. The old file stays in place if the new one cannot be written.
    public func compact() {
        ensureOpened()
        var buffer: [UInt8] = []
        buffer.reserveCapacity(liveBytes)
        var rebuilt: [BrainKey: Entry] = [:]
        rebuilt.reserveCapacity(index.count)
        for key in index.keys {
            guard let payload = payload(for: key.text) else { continue }
            let lineStart = buffer.count
            buffer.append(contentsOf: Self.escape(key.text))
            buffer.append(0x09)
            let payloadStart = buffer.count
            buffer.append(contentsOf: payload)
            buffer.append(0x0A)
            rebuilt[key] = Entry(offset: UInt64(payloadStart), length: payload.count, lineLength: buffer.count - lineStart)
        }
        try? handle?.close()
        handle = nil
        do {
            try Data(buffer).write(to: url, options: .atomic)
        } catch {
            return
        }
        index = rebuilt
        fileBytes = buffer.count
        liveBytes = buffer.count
        compactions += 1
    }

    // MARK: File

    private func ensureOpened() {
        if !opened { open() }
    }

    private func fileHandle() -> FileHandle? {
        if let handle { return handle }
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard manager.createFile(atPath: url.path, contents: nil) else { return nil }
        }
        handle = try? FileHandle(forUpdating: url)
        return handle
    }

    // MARK: Key escaping

    static func escape(_ key: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(key.utf8.count)
        for byte in key.utf8 {
            switch byte {
            case 0x25: out.append(contentsOf: [0x25, 0x32, 0x35])
            case 0x09: out.append(contentsOf: [0x25, 0x30, 0x39])
            case 0x0A: out.append(contentsOf: [0x25, 0x30, 0x41])
            case 0x0D: out.append(contentsOf: [0x25, 0x30, 0x44])
            default: out.append(byte)
            }
        }
        return out
    }

    static func unescape(_ bytes: ArraySlice<UInt8>) -> String {
        guard bytes.contains(0x25) else { return String(decoding: bytes, as: UTF8.self) }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = bytes.startIndex
        while i < bytes.endIndex {
            if bytes[i] == 0x25, i + 2 < bytes.endIndex, let high = hexValue(bytes[i + 1]), let low = hexValue(bytes[i + 2]) {
                out.append(high << 4 | low)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }
}
