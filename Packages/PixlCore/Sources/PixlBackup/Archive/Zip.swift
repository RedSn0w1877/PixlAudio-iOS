// ZIP reading (central directory, stored + DEFLATE entries, data descriptors) and writing (stored entries).
//
// Android's BackupWriter streams a ZIP with `java.util.zip.ZipOutputStream` after the 4-byte "PXPL" magic:
// DEFLATED entries, general-purpose bit 3 (sizes in a data descriptor after the data) and bit 11 (UTF-8 names).
// Offsets inside that archive count from the start of the ZIP, not of the file, so callers hand this reader the
// bytes after the magic. The reader prefers the central directory; when there is none (a truncated file) it falls
// back to walking local headers the way `ZipInputStream` does. ZIP64, encryption and methods other than
// stored/deflate are rejected.

/// Why a ZIP archive could not be read.
public enum ZipError: Error, Sendable, Equatable, CustomStringConvertible {
    case notZip
    case truncated
    case corrupt(String)
    case unsupported(String)
    case entryTooLarge(name: String, limit: Int)
    case crcMismatch(String)
    case inflate(name: String, error: InflateError)

    public var description: String {
        switch self {
        case .notZip: return "Not a ZIP archive"
        case .truncated: return "ZIP archive is truncated"
        case .corrupt(let why): return "ZIP archive is corrupt: \(why)"
        case .unsupported(let why): return "Unsupported ZIP feature: \(why)"
        case .entryTooLarge(let name, let limit): return "ZIP entry '\(name)' expands beyond \(limit) bytes"
        case .crcMismatch(let name): return "invalid entry CRC (\(name))"
        case .inflate(let name, let error): return "ZIP entry '\(name)': \(error.description)"
        }
    }
}

/// One entry of a ZIP archive.
public struct ZipEntry: Sendable, Hashable {
    public var name: String
    /// 0 = stored, 8 = deflate.
    public var method: UInt16
    public var flags: UInt16
    public var crc32: UInt32
    public var compressedSize: Int
    public var uncompressedSize: Int
    /// Offset of the local file header from the start of the ZIP.
    public var localHeaderOffset: Int
    /// For entries found by walking local headers: where the data starts and whether sizes were known up front.
    var dataOffset: Int?
}

/// A parsed ZIP archive over an in-memory byte array.
public struct ZipArchive: Sendable {
    public let bytes: [UInt8]
    /// Entries in central-directory order (local-header order for the fallback walk).
    public let entries: [ZipEntry]
    /// True when the entries came from the central directory.
    public let hasCentralDirectory: Bool

    /// Upper bound on the number of entries (a `.pxpl` has at most 13).
    public static let maxEntries = 10_000

    /// How far the local-header walk may inflate one data-descriptor entry just to find where it ends: above every
    /// `.pxpl` limit (a module is at most 16 M characters, up to 48 MB of UTF-8), far below what a zip bomb asks for.
    public static let defaultMaxWalkEntryOutput = 64 * 1024 * 1024

    /// - Parameter maxWalkEntryOutput: the inflate bound for an entry whose sizes follow its data, used only when
    ///   the archive has no central directory (the fallback walk runs before any caller-side limit applies).
    public init(bytes: [UInt8], maxWalkEntryOutput: Int = ZipArchive.defaultMaxWalkEntryOutput) throws(ZipError) {
        self.bytes = bytes
        if let eocd = Self.findEndOfCentralDirectory(bytes) {
            self.entries = try Self.readCentralDirectory(bytes, eocd: eocd)
            self.hasCentralDirectory = true
        } else {
            guard bytes.count >= 4, Self.u32(bytes, 0) == 0x0403_4B50 else { throw .notZip }
            self.entries = try Self.walkLocalHeaders(bytes, maxEntryOutput: maxWalkEntryOutput)
            self.hasCentralDirectory = false
        }
    }

    /// The first entry with this exact name (like `ZipInputStream`, which stops at the first match).
    public func entry(named name: String) -> ZipEntry? {
        entries.first { $0.name.utf8.elementsEqual(name.utf8) }
    }

    /// The uncompressed bytes of an entry, checked against its CRC-32. `maxSize` bounds the output.
    public func data(for entry: ZipEntry, maxSize: Int = .max) throws(ZipError) -> [UInt8] {
        if entry.flags & 1 != 0 { throw .unsupported("encrypted entry '\(entry.name)'") }
        let start: Int
        if let known = entry.dataOffset {
            start = known
        } else {
            let p = entry.localHeaderOffset
            guard p >= 0, p + 30 <= bytes.count else { throw .truncated }
            guard Self.u32(bytes, p) == 0x0403_4B50 else { throw .corrupt("bad local header for '\(entry.name)'") }
            let nameLength = Int(Self.u16(bytes, p + 26))
            let extraLength = Int(Self.u16(bytes, p + 28))
            start = p + 30 + nameLength + extraLength
        }
        guard start <= bytes.count else { throw .truncated }
        let output: [UInt8]
        switch entry.method {
        case 0:
            if entry.uncompressedSize > maxSize { throw .entryTooLarge(name: entry.name, limit: maxSize) }
            guard start + entry.compressedSize <= bytes.count else { throw .truncated }
            output = Array(bytes[start..<(start + entry.compressedSize)])
        case 8:
            do {
                output = try Inflate.inflate(bytes, from: start, maxOutput: maxSize, expectedSize: entry.uncompressedSize).output
            } catch .outputLimitExceeded {
                throw .entryTooLarge(name: entry.name, limit: maxSize)
            } catch {
                throw .inflate(name: entry.name, error: error)
            }
            if hasCentralDirectory, output.count != entry.uncompressedSize {
                throw .corrupt("invalid entry size for '\(entry.name)' (expected \(entry.uncompressedSize) but got \(output.count) bytes)")
            }
        default:
            throw .unsupported("compression method \(entry.method) for '\(entry.name)'")
        }
        if CRC32.checksum(output) != entry.crc32 { throw .crcMismatch(entry.name) }
        return output
    }

    // MARK: Central directory

    static func findEndOfCentralDirectory(_ b: [UInt8]) -> Int? {
        guard b.count >= 22 else { return nil }
        let lowest = max(0, b.count - 22 - 65_535)
        var p = b.count - 22
        while p >= lowest {
            if b[p] == 0x50, b[p + 1] == 0x4B, b[p + 2] == 0x05, b[p + 3] == 0x06 {
                let commentLength = Int(u16(b, p + 20))
                if p + 22 + commentLength == b.count { return p }
            }
            p -= 1
        }
        return nil
    }

    static func readCentralDirectory(_ b: [UInt8], eocd: Int) throws(ZipError) -> [ZipEntry] {
        let total = Int(u16(b, eocd + 10))
        let size = Int(u32(b, eocd + 12))
        let offset = Int(u32(b, eocd + 16))
        if total == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF { throw .unsupported("ZIP64") }
        if total > maxEntries { throw .corrupt("too many entries (\(total))") }
        guard offset + size <= eocd else { throw .corrupt("central directory out of range") }
        var entries: [ZipEntry] = []
        entries.reserveCapacity(total)
        var p = offset
        for _ in 0..<total {
            guard p + 46 <= b.count else { throw .truncated }
            guard u32(b, p) == 0x0201_4B50 else { throw .corrupt("bad central directory header") }
            let flags = u16(b, p + 8)
            let method = u16(b, p + 10)
            let crc = u32(b, p + 16)
            let compressed = u32(b, p + 20)
            let uncompressed = u32(b, p + 24)
            let nameLength = Int(u16(b, p + 28))
            let extraLength = Int(u16(b, p + 30))
            let commentLength = Int(u16(b, p + 32))
            let localOffset = u32(b, p + 42)
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                throw .unsupported("ZIP64")
            }
            guard p + 46 + nameLength + extraLength + commentLength <= b.count else { throw .truncated }
            let name = decodeName(b[(p + 46)..<(p + 46 + nameLength)], utf8: flags & 0x800 != 0)
            entries.append(ZipEntry(name: name, method: method, flags: flags, crc32: crc, compressedSize: Int(compressed),
                                    uncompressedSize: Int(uncompressed), localHeaderOffset: Int(localOffset), dataOffset: nil))
            p += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    // MARK: Local-header walk (ZipInputStream-style)

    static func walkLocalHeaders(_ b: [UInt8],
                                 maxEntryOutput: Int = ZipArchive.defaultMaxWalkEntryOutput) throws(ZipError) -> [ZipEntry] {
        var entries: [ZipEntry] = []
        var p = 0
        while p + 4 <= b.count, u32(b, p) == 0x0403_4B50 {
            guard p + 30 <= b.count else { throw .truncated }
            if entries.count >= maxEntries { throw .corrupt("too many entries") }
            let flags = u16(b, p + 6)
            let method = u16(b, p + 8)
            var crc = u32(b, p + 14)
            var compressed = Int(u32(b, p + 18))
            var uncompressed = Int(u32(b, p + 22))
            let nameLength = Int(u16(b, p + 26))
            let extraLength = Int(u16(b, p + 28))
            let dataStart = p + 30 + nameLength + extraLength
            guard dataStart <= b.count else { throw .truncated }
            let name = decodeName(b[(p + 30)..<(p + 30 + nameLength)], utf8: flags & 0x800 != 0)
            var next: Int
            if flags & 8 != 0 {
                // Sizes follow the data; only a DEFLATE stream knows where its data ends.
                guard method == 8 else { throw .unsupported("only DEFLATED entries can have EXT descriptor") }
                let result: Inflate.Result
                do {
                    result = try Inflate.inflate(b, from: dataStart, maxOutput: maxEntryOutput)
                } catch .outputLimitExceeded {
                    throw .entryTooLarge(name: name, limit: maxEntryOutput)
                } catch {
                    throw .inflate(name: name, error: error)
                }
                var q = dataStart + result.consumed
                if q + 4 <= b.count, u32(b, q) == 0x0807_4B50 { q += 4 }
                guard q + 12 <= b.count else { throw .truncated }
                crc = u32(b, q)
                compressed = Int(u32(b, q + 4))
                uncompressed = Int(u32(b, q + 8))
                next = q + 12
            } else {
                next = dataStart + compressed
                guard next <= b.count else { throw .truncated }
            }
            entries.append(ZipEntry(name: name, method: method, flags: flags & ~8, crc32: crc, compressedSize: compressed,
                                    uncompressedSize: uncompressed, localHeaderOffset: p, dataOffset: dataStart))
            p = next
        }
        return entries
    }

    /// Names are UTF-8 (bit 11) or CP437; ASCII names, the only ones a backup writes, read the same either way.
    static func decodeName(_ bytes: ArraySlice<UInt8>, utf8: Bool) -> String {
        if utf8 || bytes.allSatisfy({ $0 < 0x80 }) { return String(decoding: bytes, as: UTF8.self) }
        return String(String.UnicodeScalarView(bytes.map { cp437($0) }))
    }

    static func cp437(_ b: UInt8) -> Unicode.Scalar {
        if b < 0x80 { return Unicode.Scalar(b) }
        let high: [UInt16] = [
            0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7, 0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5,
            0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9, 0x00FF, 0x00D6, 0x00DC, 0x00A2, 0x00A3, 0x00A5, 0x20A7, 0x0192,
            0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA, 0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
            0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556, 0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
            0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F, 0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
            0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B, 0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
            0x03B1, 0x00DF, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4, 0x03A6, 0x0398, 0x03A9, 0x03B4, 0x221E, 0x03C6, 0x03B5, 0x2229,
            0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248, 0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0,
        ]
        return Unicode.Scalar(high[Int(b) - 0x80]) ?? "\u{FFFD}"
    }

    @inline(__always) static func u16(_ b: [UInt8], _ p: Int) -> UInt16 { UInt16(b[p]) | UInt16(b[p + 1]) << 8 }

    @inline(__always) static func u32(_ b: [UInt8], _ p: Int) -> UInt32 {
        UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24
    }
}

/// Writes a ZIP archive of stored entries (local headers carry the sizes and CRC, no data descriptors), which
/// `ZipInputStream` and every other reader accept.
public struct ZipWriter: Sendable {
    private var out: [UInt8] = []
    private var central: [UInt8] = []
    private var count = 0
    /// DOS time/date written for every entry (default 1980-01-01 00:00, the DOS epoch).
    public var dosTime: UInt16 = 0
    public var dosDate: UInt16 = 0x21

    public init() {}

    public mutating func addStored(name: String, data: [UInt8]) {
        let nameBytes = Array(name.utf8)
        let crc = CRC32.checksum(data)
        let offset = UInt32(out.count)
        let ascii = nameBytes.allSatisfy { $0 < 0x80 }
        let flags: UInt16 = ascii ? 0 : 0x800
        // Local file header.
        put32(&out, 0x0403_4B50)
        put16(&out, 10) // version needed: 1.0 (stored)
        put16(&out, flags)
        put16(&out, 0) // stored
        put16(&out, dosTime)
        put16(&out, dosDate)
        put32(&out, crc)
        put32(&out, UInt32(data.count))
        put32(&out, UInt32(data.count))
        put16(&out, UInt16(nameBytes.count))
        put16(&out, 0)
        out.append(contentsOf: nameBytes)
        out.append(contentsOf: data)
        // Central directory record.
        put32(&central, 0x0201_4B50)
        put16(&central, 20) // version made by: 2.0, MS-DOS
        put16(&central, 10)
        put16(&central, flags)
        put16(&central, 0)
        put16(&central, dosTime)
        put16(&central, dosDate)
        put32(&central, crc)
        put32(&central, UInt32(data.count))
        put32(&central, UInt32(data.count))
        put16(&central, UInt16(nameBytes.count))
        put16(&central, 0) // extra
        put16(&central, 0) // comment
        put16(&central, 0) // disk
        put16(&central, 0) // internal attributes
        put32(&central, 0) // external attributes
        put32(&central, offset)
        central.append(contentsOf: nameBytes)
        count += 1
    }

    /// The finished archive.
    public func finish() -> [UInt8] {
        var bytes = out
        let centralOffset = UInt32(bytes.count)
        bytes.append(contentsOf: central)
        put32(&bytes, 0x0605_4B50)
        put16(&bytes, 0)
        put16(&bytes, 0)
        put16(&bytes, UInt16(count))
        put16(&bytes, UInt16(count))
        put32(&bytes, UInt32(central.count))
        put32(&bytes, centralOffset)
        put16(&bytes, 0)
        return bytes
    }

    private func put16(_ b: inout [UInt8], _ v: UInt16) {
        b.append(UInt8(truncatingIfNeeded: v))
        b.append(UInt8(truncatingIfNeeded: v >> 8))
    }

    private func put32(_ b: inout [UInt8], _ v: UInt32) {
        b.append(UInt8(truncatingIfNeeded: v))
        b.append(UInt8(truncatingIfNeeded: v >> 8))
        b.append(UInt8(truncatingIfNeeded: v >> 16))
        b.append(UInt8(truncatingIfNeeded: v >> 24))
    }
}
