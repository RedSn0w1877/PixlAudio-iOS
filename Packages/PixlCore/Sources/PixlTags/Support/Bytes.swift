// Byte helpers shared by the ID3v2, FLAC and MP4 code. Every reader copies only the metadata region it needs into a
// `[UInt8]` (never the audio payload) and works on plain integer offsets, so nothing depends on `Data` slice indices.

import Foundation

/// Errors thrown by the tag readers and writers.
public enum TagError: Error, Sendable, Equatable {
    /// The data ended before a structure was complete.
    case truncated(String)
    /// A structure is malformed.
    case invalid(String)
    /// The container or structure is valid but not handled here.
    case unsupported(String)
}

extension Data {
    /// The bytes in `range` (offsets relative to the data's start) as an array.
    @inlinable
    func bytes(_ range: Range<Int>) -> [UInt8] {
        let lower = Swift.max(0, Swift.min(range.lowerBound, count))
        let upper = Swift.max(lower, Swift.min(range.upperBound, count))
        return [UInt8](self[(startIndex + lower)..<(startIndex + upper)])
    }

    /// The byte at offset `i` relative to the data's start.
    @inlinable
    func byte(at i: Int) -> UInt8 { self[startIndex + i] }

    /// A copy of the bytes in `range` (offsets relative to the data's start) as `Data` with zero-based indices.
    @inlinable
    func subdata(offsets range: Range<Int>) -> Data {
        let lower = Swift.max(0, Swift.min(range.lowerBound, count))
        let upper = Swift.max(lower, Swift.min(range.upperBound, count))
        return Data(self[(startIndex + lower)..<(startIndex + upper)])
    }
}

/// Big-endian and syncsafe integer reading/writing on byte arrays.
enum ByteIO {
    @inlinable
    static func uint16BE(_ b: [UInt8], _ i: Int) -> UInt16 {
        guard i >= 0, i + 2 <= b.count else { return 0 }
        return UInt16(b[i]) << 8 | UInt16(b[i + 1])
    }

    @inlinable
    static func int16BE(_ b: [UInt8], _ i: Int) -> Int16 { Int16(bitPattern: uint16BE(b, i)) }

    @inlinable
    static func uint24BE(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i >= 0, i + 3 <= b.count else { return 0 }
        return UInt32(b[i]) << 16 | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2])
    }

    @inlinable
    static func uint32BE(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i >= 0, i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    @inlinable
    static func uint32LE(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i >= 0, i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    @inlinable
    static func uint64BE(_ b: [UInt8], _ i: Int) -> UInt64 {
        guard i >= 0, i + 8 <= b.count else { return 0 }
        return UInt64(uint32BE(b, i)) << 32 | UInt64(uint32BE(b, i + 4))
    }

    /// A 4-byte syncsafe integer (7 bits per byte). Like TagLib's `SynchData::toUInt`, bytes with the high bit set
    /// mean buggy software wrote a plain integer, which is then read as one.
    static func syncsafe(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i >= 0, i + 4 <= b.count else { return 0 }
        if b[i..<(i + 4)].contains(where: { $0 & 0x80 != 0 }) { return uint32BE(b, i) }
        return UInt32(b[i]) << 21 | UInt32(b[i + 1]) << 14 | UInt32(b[i + 2]) << 7 | UInt32(b[i + 3])
    }

    /// Whether the 4 bytes at `i` are a valid syncsafe integer.
    static func isSyncsafe(_ b: [UInt8], _ i: Int) -> Bool {
        guard i >= 0, i + 4 <= b.count else { return false }
        return !b[i..<(i + 4)].contains(where: { $0 & 0x80 != 0 })
    }

    static func appendUInt16BE(_ v: UInt16, to out: inout [UInt8]) {
        out.append(UInt8(v >> 8)); out.append(UInt8(v & 0xFF))
    }

    static func appendUInt24BE(_ v: UInt32, to out: inout [UInt8]) {
        out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8((v >> 8) & 0xFF)); out.append(UInt8(v & 0xFF))
    }

    static func appendUInt32BE(_ v: UInt32, to out: inout [UInt8]) {
        out.append(UInt8(v >> 24)); out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF)); out.append(UInt8(v & 0xFF))
    }

    static func appendUInt32LE(_ v: UInt32, to out: inout [UInt8]) {
        out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8(v >> 24))
    }

    static func appendSyncsafe(_ v: UInt32, to out: inout [UInt8]) {
        out.append(UInt8((v >> 21) & 0x7F)); out.append(UInt8((v >> 14) & 0x7F))
        out.append(UInt8((v >> 7) & 0x7F)); out.append(UInt8(v & 0x7F))
    }

    /// ASCII bytes of `s` (non-ASCII scalars become `?`).
    static func ascii(_ s: String) -> [UInt8] {
        s.unicodeScalars.map { $0.isASCII ? UInt8($0.value) : UInt8(ascii: "?") }
    }

    /// Whether `b[i..<i+pattern.count]` equals `pattern`.
    static func matches(_ b: [UInt8], _ i: Int, _ pattern: [UInt8]) -> Bool {
        guard i >= 0, i + pattern.count <= b.count else { return false }
        for k in 0..<pattern.count where b[i + k] != pattern[k] { return false }
        return true
    }

    /// TagLib `ByteVector::find(pattern, offset, byteAlign)`: the first match at `offset + n·byteAlign`.
    static func find(_ b: [UInt8], _ pattern: [UInt8], from offset: Int, byteAlign: Int = 1,
                     end: Int? = nil) -> Int? {
        let limit = end ?? b.count
        guard !pattern.isEmpty, offset >= 0, byteAlign > 0 else { return nil }
        var i = offset
        while i + pattern.count <= limit {
            if matches(b, i, pattern) { return i }
            i += byteAlign
        }
        return nil
    }

    /// TagLib `ByteVectorList::split(v, pattern, byteAlign, max)`.
    static func split(_ v: ArraySlice<UInt8>, _ pattern: [UInt8], byteAlign: Int, max: Int = 0) -> [ArraySlice<UInt8>] {
        let bytes = [UInt8](v)
        var result: [ArraySlice<UInt8>] = []
        var previous = 0
        var offset = find(bytes, pattern, from: 0, byteAlign: byteAlign)
        while let o = offset, max == 0 || max > result.count + 1 {
            result.append(bytes[previous..<o])
            previous = o + pattern.count
            offset = find(bytes, pattern, from: o + pattern.count, byteAlign: byteAlign)
        }
        if previous < bytes.count { result.append(bytes[previous..<bytes.count]) }
        return result
    }
}

/// ID3v2 unsynchronisation (`FF 00` → `FF`), TagLib's `SynchData::decode`.
enum Unsynchronisation {
    static func decode(_ data: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var i = data.startIndex
        let end = data.endIndex
        while i < end - 1 {
            out.append(data[i])
            i += 1
            if data[i - 1] == 0xFF && data[i] == 0x00 { i += 1 }
        }
        if i < end { out.append(data[i]) }
        return out
    }

    /// Unsynchronises `data`: inserts `00` after every `FF` that is followed by `00` or a byte ≥ `E0`, and after a
    /// trailing `FF`. Used by tests to build unsynchronised tags (the writers never unsynchronise, like TagLib).
    static func encode(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count + data.count / 16)
        for (i, b) in data.enumerated() {
            out.append(b)
            if b == 0xFF {
                let next: UInt8? = i + 1 < data.count ? data[i + 1] : nil
                if next == nil || next! == 0x00 || next! >= 0xE0 { out.append(0x00) }
            }
        }
        return out
    }
}
