// A pure-Swift raw DEFLATE decoder (RFC 1951): stored, fixed-Huffman and dynamic-Huffman blocks. Android writes
// `.pxpl` v3 archives with `ZipOutputStream` (DEFLATED entries) and the legacy v2 format with `GZIPOutputStream`,
// so reading the owner's backups needs inflate; Swift on Windows has no zlib/Compression, hence our own.
//
// Huffman codes are decoded with one lookup table per code (indexed by the next `maxLength` bits, LSB first), so
// each symbol costs one table read. Output is bounded by `maxOutput` (a zip-bomb guard the caller sets).

/// Why a DEFLATE stream could not be decoded.
public enum InflateError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The input ended before the final block finished.
    case truncated
    /// A block type of 3.
    case invalidBlockType
    /// A stored block whose LEN and NLEN disagree.
    case storedLengthMismatch
    /// An over-subscribed or incomplete code, or a code-length sequence that does not fit.
    case invalidCodeLengths
    /// A bit pattern that is not a code in the current table.
    case invalidCode
    /// A back-reference before the start of the output, or a reserved length/distance symbol.
    case invalidDistance
    /// More than `maxOutput` bytes would be produced.
    case outputLimitExceeded(Int)

    public var description: String {
        switch self {
        case .truncated: return "Unexpected end of ZLIB input stream"
        case .invalidBlockType: return "invalid block type"
        case .storedLengthMismatch: return "invalid stored block lengths"
        case .invalidCodeLengths: return "invalid code lengths set"
        case .invalidCode: return "invalid code"
        case .invalidDistance: return "invalid distance too far back"
        case .outputLimitExceeded(let limit): return "inflated data exceeds \(limit) bytes"
        }
    }
}

/// Raw DEFLATE decoding.
public enum Inflate {
    /// The result of decoding one DEFLATE stream that starts at `offset` of the input.
    public struct Result: Sendable {
        public var output: [UInt8]
        /// Bytes of input consumed, rounded up to a whole byte (the stream's end).
        public var consumed: Int
    }

    /// Decodes a complete raw DEFLATE stream.
    public static func inflate(_ input: [UInt8], maxOutput: Int = .max) throws(InflateError) -> [UInt8] {
        try inflate(input, from: 0, maxOutput: maxOutput).output
    }

    /// Decodes the DEFLATE stream starting at `offset`; trailing bytes after the final block are left alone.
    public static func inflate(_ input: [UInt8], from offset: Int, maxOutput: Int = .max,
                               expectedSize: Int? = nil) throws(InflateError) -> Result {
        var decoder = Decoder(input: input, position: offset, maxOutput: maxOutput)
        if let expectedSize, expectedSize >= 0 { decoder.output.reserveCapacity(min(expectedSize, maxOutput, 64 << 20)) }
        try decoder.run()
        return Result(output: decoder.output, consumed: decoder.bytePosition - offset)
    }

    // MARK: Tables (RFC 1951 §3.2.5)

    static let lengthBase: [UInt16] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99,
                                       115, 131, 163, 195, 227, 258]
    static let lengthExtra: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distanceBase: [UInt16] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025,
                                         1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distanceExtra: [UInt8] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
                                         12, 12, 13, 13]
    /// Order in which code-length code lengths are sent.
    static let codeLengthOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    static let fixedLiteral: Huffman = {
        var lengths = [UInt8](repeating: 8, count: 288)
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        // swiftlint:disable:next force_try
        return try! Huffman(lengths: lengths, allowIncomplete: true)
    }()

    static let fixedDistance: Huffman = {
        // 30 distance codes of 5 bits plus the two reserved ones (30, 31), which make the code complete.
        // swiftlint:disable:next force_try
        try! Huffman(lengths: [UInt8](repeating: 5, count: 32), allowIncomplete: true)
    }()

    /// A canonical Huffman code as a direct lookup table: entry = symbol << 4 | length (0 = no code).
    struct Huffman {
        let table: [UInt32]
        let maxLength: Int

        init(lengths: [UInt8], allowIncomplete: Bool) throws(InflateError) {
            var count = [Int](repeating: 0, count: 16)
            for l in lengths { count[Int(l)] += 1 }
            count[0] = 0
            var maxLength = 0
            for l in 1...15 where count[l] > 0 { maxLength = l }
            // Kraft check: over-subscribed codes are always invalid; incomplete ones only for a single code.
            var left = 1
            for l in 1...15 {
                left <<= 1
                left -= count[l]
                if left < 0 { throw .invalidCodeLengths }
            }
            // Like zlib: an incomplete literal/length or distance code is accepted only when it is a single code of
            // length 1; the code-length code must always be complete.
            if left > 0 && (!allowIncomplete || maxLength != 1) && maxLength != 0 { throw .invalidCodeLengths }
            if maxLength == 0 {
                self.table = []
                self.maxLength = 0
                return
            }
            var nextCode = [Int](repeating: 0, count: 16)
            var code = 0
            for l in 1...15 {
                code = (code + count[l - 1]) << 1
                nextCode[l] = code
            }
            var table = [UInt32](repeating: 0, count: 1 << maxLength)
            for (symbol, l8) in lengths.enumerated() where l8 > 0 {
                let l = Int(l8)
                let c = nextCode[l]
                nextCode[l] += 1
                // Reverse the code: DEFLATE packs Huffman codes MSB first into an LSB-first bit stream.
                var reversed = 0
                var v = c
                for _ in 0..<l {
                    reversed = (reversed << 1) | (v & 1)
                    v >>= 1
                }
                let entry = UInt32(symbol) << 4 | UInt32(l)
                var i = reversed
                while i < table.count {
                    table[i] = entry
                    i += 1 << l
                }
            }
            self.table = table
            self.maxLength = maxLength
        }
    }

    // MARK: Decoder

    struct Decoder {
        let input: [UInt8]
        var position: Int
        let maxOutput: Int
        var output: [UInt8] = []
        var bitBuffer: UInt64 = 0
        var bitCount = 0

        init(input: [UInt8], position: Int, maxOutput: Int) {
            self.input = input
            self.position = position
            self.maxOutput = maxOutput
        }

        /// The input position after the last whole byte the stream used.
        var bytePosition: Int { position - bitCount / 8 }

        @inline(__always)
        mutating func refill() {
            while bitCount <= 56 && position < input.count {
                bitBuffer |= UInt64(input[position]) << UInt64(bitCount)
                position += 1
                bitCount += 8
            }
        }

        @inline(__always)
        mutating func bits(_ n: Int) throws(InflateError) -> Int {
            if n == 0 { return 0 }
            if bitCount < n {
                refill()
                if bitCount < n { throw .truncated }
            }
            let v = Int(bitBuffer & ((1 << UInt64(n)) - 1))
            bitBuffer >>= UInt64(n)
            bitCount -= n
            return v
        }

        @inline(__always)
        mutating func decode(_ h: Huffman) throws(InflateError) -> Int {
            if h.maxLength == 0 { throw .invalidCode }
            if bitCount < h.maxLength { refill() }
            let index = Int(bitBuffer & ((1 << UInt64(h.maxLength)) - 1))
            let entry = h.table[index]
            let length = Int(entry & 0xF)
            if length == 0 { throw .invalidCode }
            if length > bitCount { throw .truncated }
            bitBuffer >>= UInt64(length)
            bitCount -= length
            return Int(entry >> 4)
        }

        mutating func run() throws(InflateError) {
            var final = false
            while !final {
                final = try bits(1) == 1
                switch try bits(2) {
                case 0: try stored()
                case 1: try codes(literal: Inflate.fixedLiteral, distance: Inflate.fixedDistance)
                case 2:
                    let (literal, distance) = try dynamicTables()
                    try codes(literal: literal, distance: distance)
                default: throw .invalidBlockType
                }
            }
        }

        mutating func stored() throws(InflateError) {
            // Drop to a byte boundary, then hand the buffered whole bytes back to the input.
            let drop = bitCount % 8
            bitBuffer >>= UInt64(drop)
            bitCount -= drop
            position -= bitCount / 8
            bitBuffer = 0
            bitCount = 0
            guard position + 4 <= input.count else { throw .truncated }
            let len = Int(input[position]) | Int(input[position + 1]) << 8
            let nlen = Int(input[position + 2]) | Int(input[position + 3]) << 8
            position += 4
            if len != (~nlen & 0xFFFF) { throw .storedLengthMismatch }
            guard position + len <= input.count else { throw .truncated }
            if output.count + len > maxOutput { throw .outputLimitExceeded(maxOutput) }
            output.append(contentsOf: input[position..<(position + len)])
            position += len
        }

        mutating func dynamicTables() throws(InflateError) -> (Huffman, Huffman) {
            let hlit = try bits(5) + 257
            let hdist = try bits(5) + 1
            let hclen = try bits(4) + 4
            if hlit > 286 || hdist > 30 { throw .invalidCodeLengths }
            var codeLengthLengths = [UInt8](repeating: 0, count: 19)
            for i in 0..<hclen { codeLengthLengths[Inflate.codeLengthOrder[i]] = UInt8(try bits(3)) }
            let codeLengthCode = try Huffman(lengths: codeLengthLengths, allowIncomplete: false)
            if codeLengthCode.maxLength == 0 { throw .invalidCodeLengths }
            var lengths = [UInt8](repeating: 0, count: hlit + hdist)
            var i = 0
            while i < lengths.count {
                let symbol = try decode(codeLengthCode)
                switch symbol {
                case 0...15:
                    lengths[i] = UInt8(symbol)
                    i += 1
                case 16:
                    if i == 0 { throw .invalidCodeLengths }
                    let previous = lengths[i - 1]
                    let repeatCount = 3 + (try bits(2))
                    if i + repeatCount > lengths.count { throw .invalidCodeLengths }
                    for _ in 0..<repeatCount { lengths[i] = previous; i += 1 }
                case 17:
                    let repeatCount = 3 + (try bits(3))
                    if i + repeatCount > lengths.count { throw .invalidCodeLengths }
                    i += repeatCount
                default:
                    let repeatCount = 11 + (try bits(7))
                    if i + repeatCount > lengths.count { throw .invalidCodeLengths }
                    i += repeatCount
                }
            }
            if lengths[256] == 0 { throw .invalidCodeLengths } // no end-of-block code
            let literal = try Huffman(lengths: Array(lengths[0..<hlit]), allowIncomplete: true)
            // A distance code with no symbols at all is valid (only literals follow); using it is an error.
            let distance = try Huffman(lengths: Array(lengths[hlit...]), allowIncomplete: true)
            return (literal, distance)
        }

        mutating func codes(literal: Huffman, distance: Huffman) throws(InflateError) {
            while true {
                let symbol = try decode(literal)
                if symbol < 256 {
                    if output.count >= maxOutput { throw .outputLimitExceeded(maxOutput) }
                    output.append(UInt8(symbol))
                    continue
                }
                if symbol == 256 { return }
                let li = symbol - 257
                if li >= 29 { throw .invalidDistance }
                let length = Int(Inflate.lengthBase[li]) + (try bits(Int(Inflate.lengthExtra[li])))
                let di = try decode(distance)
                if di >= 30 { throw .invalidDistance }
                let dist = Int(Inflate.distanceBase[di]) + (try bits(Int(Inflate.distanceExtra[di])))
                if dist > output.count { throw .invalidDistance }
                if output.count + length > maxOutput { throw .outputLimitExceeded(maxOutput) }
                var from = output.count - dist
                if dist >= length {
                    // Copy out first: appending a slice of `output` to itself would keep the buffer shared and
                    // copy the whole array on every back-reference.
                    let chunk = Array(output[from..<(from + length)])
                    output.append(contentsOf: chunk)
                } else {
                    for _ in 0..<length {
                        output.append(output[from])
                        from += 1
                    }
                }
            }
        }
    }
}

/// Raw DEFLATE encoding with stored blocks only (the archives PixlBackup writes are small JSON; stored entries
/// keep the writer trivial and are read by every inflater, Android's `ZipInputStream`/`GZIPInputStream` included).
public enum StoredDeflate {
    public static func encode(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count + (data.count / 65535 + 1) * 5)
        var offset = 0
        repeat {
            let len = min(65535, data.count - offset)
            let final = offset + len == data.count
            out.append(final ? 1 : 0)
            out.append(UInt8(len & 0xFF))
            out.append(UInt8(len >> 8))
            out.append(UInt8(~len & 0xFF))
            out.append(UInt8((~len >> 8) & 0xFF))
            out.append(contentsOf: data[offset..<(offset + len)])
            offset += len
        } while offset < data.count
        return out
    }
}
