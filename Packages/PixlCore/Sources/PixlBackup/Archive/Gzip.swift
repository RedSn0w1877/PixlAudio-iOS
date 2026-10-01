// gzip (RFC 1952) reading and writing, with `java.util.zip.GZIPInputStream`'s rules: header CRC checked when
// FHCRC is set, CRC-32 and ISIZE trailer checked, concatenated members decoded in turn, and anything after the
// last member that does not start a valid gzip header ignored. The legacy Android backup formats (v1/v2) are
// gzip-compressed JSON.

/// Why gzip data could not be decoded.
public enum GzipError: Error, Sendable, Equatable, CustomStringConvertible {
    case notGzip
    case unsupportedMethod(UInt8)
    case corruptHeader
    case corruptTrailer
    case truncated
    case inflate(InflateError)

    public var description: String {
        switch self {
        case .notGzip: return "Not in GZIP format"
        case .unsupportedMethod(let m): return "Unsupported compression method \(m)"
        case .corruptHeader: return "Corrupt GZIP header"
        case .corruptTrailer: return "Corrupt GZIP trailer"
        case .truncated: return "Unexpected end of ZLIB input stream"
        case .inflate(let e): return e.description
        }
    }
}

public enum Gzip {
    static let ftext: UInt8 = 1, fhcrc: UInt8 = 2, fextra: UInt8 = 4, fname: UInt8 = 8, fcomment: UInt8 = 16

    /// Decompresses gzip data starting at `offset` (all members). `maxOutput` bounds the total output.
    public static func decompress(_ data: [UInt8], from offset: Int = 0, maxOutput: Int = .max) throws(GzipError) -> [UInt8] {
        var out: [UInt8] = []
        var position = offset
        var first = true
        while true {
            let headerEnd: Int
            do {
                headerEnd = try parseHeader(data, at: position)
            } catch {
                // GZIPInputStream: the first header must be valid; a broken header after a member ends the stream.
                if first { throw error }
                return out
            }
            first = false
            let result: Inflate.Result
            do {
                result = try Inflate.inflate(data, from: headerEnd, maxOutput: maxOutput - out.count)
            } catch {
                throw .inflate(error)
            }
            let trailer = headerEnd + result.consumed
            guard trailer + 8 <= data.count else { throw .truncated }
            let crc = readLE32(data, trailer)
            let size = readLE32(data, trailer + 4)
            if crc != CRC32.checksum(result.output) || size != UInt32(truncatingIfNeeded: result.output.count) {
                throw .corruptTrailer
            }
            out.append(contentsOf: result.output)
            position = trailer + 8
            // Another member only if a full header could follow (Java needs more than the 10-byte minimum).
            if data.count - position < 10 { return out }
        }
    }

    /// Returns the offset of the compressed data after a valid header at `p`.
    static func parseHeader(_ d: [UInt8], at start: Int) throws(GzipError) -> Int {
        var p = start
        guard p + 10 <= d.count else { throw p + 2 <= d.count && d[p] == 0x1F && d[p + 1] == 0x8B ? .truncated : .notGzip }
        guard d[p] == 0x1F, d[p + 1] == 0x8B else { throw .notGzip }
        guard d[p + 2] == 8 else { throw .unsupportedMethod(d[p + 2]) }
        let flags = d[p + 3]
        p += 10
        if flags & fextra != 0 {
            guard p + 2 <= d.count else { throw .truncated }
            let xlen = Int(d[p]) | Int(d[p + 1]) << 8
            p += 2 + xlen
            guard p <= d.count else { throw .truncated }
        }
        if flags & fname != 0 {
            while true {
                guard p < d.count else { throw .truncated }
                p += 1
                if d[p - 1] == 0 { break }
            }
        }
        if flags & fcomment != 0 {
            while true {
                guard p < d.count else { throw .truncated }
                p += 1
                if d[p - 1] == 0 { break }
            }
        }
        if flags & fhcrc != 0 {
            guard p + 2 <= d.count else { throw .truncated }
            let expected = UInt16(d[p]) | UInt16(d[p + 1]) << 8
            if expected != UInt16(truncatingIfNeeded: CRC32.checksum(d[start..<p])) { throw .corruptHeader }
            p += 2
        }
        return p
    }

    /// A single gzip member with stored DEFLATE blocks (header like `GZIPOutputStream`: no name, MTIME 0, OS 0).
    public static func compress(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0]
        out.append(contentsOf: StoredDeflate.encode(data))
        appendLE32(&out, CRC32.checksum(data))
        appendLE32(&out, UInt32(truncatingIfNeeded: data.count))
        return out
    }

    static func readLE32(_ d: [UInt8], _ p: Int) -> UInt32 {
        UInt32(d[p]) | UInt32(d[p + 1]) << 8 | UInt32(d[p + 2]) << 16 | UInt32(d[p + 3]) << 24
    }

    static func appendLE32(_ out: inout [UInt8], _ v: UInt32) {
        out.append(UInt8(truncatingIfNeeded: v))
        out.append(UInt8(truncatingIfNeeded: v >> 8))
        out.append(UInt8(truncatingIfNeeded: v >> 16))
        out.append(UInt8(truncatingIfNeeded: v >> 24))
    }
}
