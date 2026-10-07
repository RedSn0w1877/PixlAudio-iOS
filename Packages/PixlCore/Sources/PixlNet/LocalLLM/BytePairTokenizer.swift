import Foundation

/// The downloadable local AI model's tokenizer (2026-10-07, local AI phase 2): byte-level BPE exactly as Hugging Face
/// `tokenizers` runs Qwen2's `tokenizer.json`, in our own Swift (no third-party code in the app).
///
/// Pipeline (the only shape `ci/ml/convert_llm.py export_tokenizer` accepts):
/// 1. **Added tokens** (`<|im_start|>`, `<|im_end|>`, `<|endoftext|>` …) are matched in the raw text first,
///    longest first, and become their ids.
/// 2. **NFC** on the rest.
/// 3. **Pre-tokenisation** with Qwen2's split pattern
///    `(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+`,
///    hand-written as a scanner over Unicode scalars (`PreTokenizer`).
/// 4. **Byte-level BPE** on each piece's UTF-8 bytes: the lowest-ranked adjacent pair merges first, every occurrence
///    left to right, until no pair has a merge.
///
/// The vocabulary comes from the model download's `qwen2_5.pxbpe` (the format is documented in `convert_llm.py`):
/// 256 byte tokens, the merges in priority order with their result ids, and the added tokens. Decoding concatenates
/// token bytes (added tokens as their UTF-8 text) and replaces invalid UTF-8 like the byte-level decoder.
public struct BytePairTokenizer: Sendable {
    public enum LoadError: Error, Equatable, Sendable {
        case badMagic
        case unsupportedVersion(UInt32)
        case truncated
        case invalid(String)
    }

    /// One added token.
    public struct AddedToken: Sendable, Equatable {
        public let id: Int
        public let text: String
        public let isSpecial: Bool
    }

    struct Merge: Sendable {
        let rank: Int32
        let result: Int32
    }

    /// The model's embedding rows (the logits' length; can exceed the highest token id).
    public let vocabularyRows: Int
    /// `tokenizer.json`'s `ignore_merges`: a piece that is itself a token skips the merges.
    public let ignoreMerges: Bool
    public let addedTokens: [AddedToken]

    let byteIds: [Int32]
    let merges: [UInt64: Merge]
    /// Token id → its bytes (decoding); empty for unused ids.
    let tokenBytes: [[UInt8]]
    /// Bytes → id, only with `ignoreMerges`.
    let idsByBytes: [[UInt8]: Int32]
    /// Added tokens, longest first (so `<|im_end|>` wins over a shorter token sharing its start).
    let addedByLength: [(scalars: [Unicode.Scalar], id: Int)]

    // MARK: Loading

    public init(data: Data) throws {
        var reader = Reader(bytes: [UInt8](data))
        guard try reader.bytes(8) == Array("PXBPE1".utf8) + [0, 0] else { throw LoadError.badMagic }
        let version = try reader.u32()
        guard version == 1 else { throw LoadError.unsupportedVersion(version) }
        let flags = try reader.u32()
        ignoreMerges = flags & 1 != 0
        vocabularyRows = Int(try reader.u32())

        var byteIds = [Int32](repeating: 0, count: 256)
        for byte in 0..<256 { byteIds[byte] = Int32(bitPattern: try reader.u32()) }

        let mergeCount = Int(try reader.u32())
        var merges: [UInt64: Merge] = [:]
        merges.reserveCapacity(mergeCount)
        var records: [(left: Int32, right: Int32, result: Int32)] = []
        records.reserveCapacity(mergeCount)
        var highest = byteIds.max() ?? 0
        for rank in 0..<mergeCount {
            let left = Int32(bitPattern: try reader.u32())
            let right = Int32(bitPattern: try reader.u32())
            let result = Int32(bitPattern: try reader.u32())
            records.append((left, right, result))
            let key = Self.pairKey(left, right)
            if merges[key] == nil { merges[key] = Merge(rank: Int32(rank), result: result) }
            highest = max(highest, result)
        }

        let addedCount = Int(try reader.u32())
        var added: [AddedToken] = []
        for _ in 0..<addedCount {
            let id = Int(try reader.u32())
            let special = try reader.u8() != 0
            let length = Int(try reader.u16())
            let text = String(decoding: try reader.bytes(length), as: UTF8.self)
            guard !text.isEmpty else { throw LoadError.invalid("empty added token") }
            added.append(AddedToken(id: id, text: text, isSpecial: special))
            highest = max(highest, Int32(id))
        }
        guard reader.isAtEnd else { throw LoadError.invalid("trailing bytes") }

        // Token bytes, built in merge order (a merge's parts always exist before it).
        var bytes = [[UInt8]](repeating: [], count: Int(highest) + 1)
        for byte in 0..<256 { bytes[Int(byteIds[byte])] = [UInt8(byte)] }
        for record in records {
            let left = bytes[Int(record.left)], right = bytes[Int(record.right)]
            guard !left.isEmpty, !right.isEmpty else { throw LoadError.invalid("merge before its parts") }
            if bytes[Int(record.result)].isEmpty { bytes[Int(record.result)] = left + right }
        }
        for token in added { bytes[token.id] = Array(token.text.utf8) }

        var byBytes: [[UInt8]: Int32] = [:]
        if ignoreMerges {
            for (id, value) in bytes.enumerated() where !value.isEmpty && byBytes[value] == nil {
                byBytes[value] = Int32(id)
            }
        }
        self.byteIds = byteIds
        self.merges = merges
        self.tokenBytes = bytes
        self.idsByBytes = byBytes
        self.addedTokens = added
        self.addedByLength = added.map { (Array($0.text.unicodeScalars), $0.id) }.sorted { $0.0.count > $1.0.count }
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    static func pairKey(_ left: Int32, _ right: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: left)) << 32 | UInt64(UInt32(bitPattern: right))
    }

    // MARK: Lookups

    /// The id of an added token (`<|im_end|>`), or of a text that is exactly one token.
    public func id(of text: String) -> Int? {
        if let added = addedTokens.first(where: { $0.text == text }) { return added.id }
        let ids = encodeOrdinary(text)
        return ids.count == 1 ? ids[0] : nil
    }

    /// The bytes a token stands for (an added token's UTF-8 text).
    public func bytes(of id: Int) -> [UInt8] {
        guard id >= 0, id < tokenBytes.count else { return [] }
        return tokenBytes[id]
    }

    // MARK: Encoding

    /// Token ids of `text`, added tokens recognised (what `tokenizer.encode(text, add_special_tokens=False)` gives).
    public func encode(_ text: String) -> [Int] {
        var ids: [Int] = []
        let scalars = Array(text.unicodeScalars)
        var segmentStart = 0
        var index = 0
        while index < scalars.count {
            if let match = addedToken(in: scalars, at: index) {
                if segmentStart < index { ids += encodeOrdinary(scalars[segmentStart..<index]) }
                ids.append(match.id)
                index += match.length
                segmentStart = index
            } else {
                index += 1
            }
        }
        if segmentStart < scalars.count { ids += encodeOrdinary(scalars[segmentStart..<scalars.count]) }
        return ids
    }

    /// Token ids of `text` with no added-token matching.
    public func encodeOrdinary(_ text: String) -> [Int] {
        let scalars = Array(text.unicodeScalars)
        return encodeOrdinary(scalars[...])
    }

    /// The number of tokens `encode` gives (prompt budgets).
    public func count(_ text: String) -> Int { encode(text).count }

    private func addedToken(in scalars: [Unicode.Scalar], at index: Int) -> (id: Int, length: Int)? {
        let first = scalars[index]
        for token in addedByLength where token.scalars.first == first && index + token.scalars.count <= scalars.count {
            var matches = true
            for offset in 1..<token.scalars.count where scalars[index + offset] != token.scalars[offset] {
                matches = false
                break
            }
            if matches { return (token.id, token.scalars.count) }
        }
        return nil
    }

    private func encodeOrdinary(_ slice: ArraySlice<Unicode.Scalar>) -> [Int] {
        guard !slice.isEmpty else { return [] }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: slice)
        let normalized = Array(Self.nfc(String(view)).unicodeScalars)
        var ids: [Int] = []
        var cache: [[UInt8]: [Int32]] = [:]
        for range in PreTokenizer.split(normalized) {
            var piece = String.UnicodeScalarView()
            piece.append(contentsOf: normalized[range])
            let bytes = Array(String(piece).utf8)
            if let cached = cache[bytes] {
                ids += cached.map(Int.init)
                continue
            }
            let merged = bpe(bytes)
            cache[bytes] = merged
            ids += merged.map(Int.init)
        }
        return ids
    }

    /// NFC (the model's normaliser).
    static func nfc(_ text: String) -> String {
        // ASCII is always NFC: skip the Foundation round trip for the common case.
        if text.utf8.allSatisfy({ $0 < 0x80 }) { return text }
        return text.precomposedStringWithCanonicalMapping
    }

    /// Byte-level BPE of one piece.
    func bpe(_ bytes: [UInt8]) -> [Int32] {
        if ignoreMerges, let id = idsByBytes[bytes] { return [id] }
        var symbols = bytes.map { byteIds[Int($0)] }
        while symbols.count > 1 {
            var bestRank = Int32.max
            var best: Merge?
            var bestLeft: Int32 = 0, bestRight: Int32 = 0
            for index in 0..<(symbols.count - 1) {
                if let merge = merges[Self.pairKey(symbols[index], symbols[index + 1])], merge.rank < bestRank {
                    bestRank = merge.rank
                    best = merge
                    bestLeft = symbols[index]
                    bestRight = symbols[index + 1]
                }
            }
            guard let merge = best else { break }
            var merged: [Int32] = []
            merged.reserveCapacity(symbols.count)
            var index = 0
            while index < symbols.count {
                if index + 1 < symbols.count, symbols[index] == bestLeft, symbols[index + 1] == bestRight {
                    merged.append(merge.result)
                    index += 2
                } else {
                    merged.append(symbols[index])
                    index += 1
                }
            }
            symbols = merged
        }
        return symbols
    }

    // MARK: Decoding

    /// The text of `ids` (added tokens included as their text); invalid UTF-8 becomes U+FFFD.
    public func decode(_ ids: [Int]) -> String {
        var bytes: [UInt8] = []
        for id in ids { bytes += self.bytes(of: id) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Reading the file

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        var isAtEnd: Bool { offset == bytes.count }

        mutating func bytes(_ count: Int) throws -> [UInt8] {
            guard count >= 0, offset + count <= bytes.count else { throw LoadError.truncated }
            defer { offset += count }
            return Array(bytes[offset..<(offset + count)])
        }

        mutating func u8() throws -> UInt8 {
            guard offset < bytes.count else { throw LoadError.truncated }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func u16() throws -> UInt16 {
            guard offset + 2 <= bytes.count else { throw LoadError.truncated }
            defer { offset += 2 }
            return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        }

        mutating func u32() throws -> UInt32 {
            guard offset + 4 <= bytes.count else { throw LoadError.truncated }
            defer { offset += 4 }
            return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        }
    }
}

/// Qwen2's pre-tokeniser split, `(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}|
/// ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+`, as Oniguruma matches it: at each position the first
/// alternative that matches wins, each alternative greedy with backtracking. `\p{L}` is the letter categories,
/// `\p{N}` the number categories, `\s` the White_Space property.
public enum PreTokenizer {
    /// The pieces of `scalars`, as ranges covering it end to end.
    public static func split(_ scalars: [Unicode.Scalar]) -> [Range<Int>] {
        var pieces: [Range<Int>] = []
        var index = 0
        while index < scalars.count {
            let end = match(scalars, at: index)
            pieces.append(index..<end)
            index = end
        }
        return pieces
    }

    /// The end of the piece starting at `i` (always past `i`).
    static func match(_ s: [Unicode.Scalar], at i: Int) -> Int {
        let n = s.count
        let c = s[i]
        // 1. Contractions, case-insensitive ('ſ' folds to 's').
        if c == "'", i + 1 < n {
            let next = lowered(s[i + 1])
            if next == "s" || next == "t" || next == "m" || next == "d" { return i + 2 }
            if i + 2 < n {
                let third = lowered(s[i + 2])
                if (next == "r" && third == "e") || (next == "v" && third == "e") || (next == "l" && third == "l") {
                    return i + 3
                }
            }
        }
        // 2. An optional non-letter, non-number, non-newline, then letters.
        if isLetter(c) {
            return letters(s, from: i + 1)
        }
        if !isNewline(c), !isNumber(c), i + 1 < n, isLetter(s[i + 1]) {
            return letters(s, from: i + 2)
        }
        // 3. One number.
        if isNumber(c) { return i + 1 }
        // 4. An optional space, symbols, then newlines.
        var j = i
        if c == " ", i + 1 < n, isSymbol(s[i + 1]) { j = i + 1 }
        if isSymbol(s[j]) {
            j += 1
            while j < n, isSymbol(s[j]) { j += 1 }
            while j < n, isNewline(s[j]) { j += 1 }
            return j
        }
        // Whitespace from here on.
        var runEnd = i
        while runEnd < n, isWhitespace(s[runEnd]) { runEnd += 1 }
        guard runEnd > i else { return i + 1 } // unreachable: every scalar is a letter, number, symbol or space
        // 5. Whitespace up to the last newline of the run.
        var lastNewline = -1
        for k in i..<runEnd where isNewline(s[k]) { lastNewline = k }
        if lastNewline >= 0 { return lastNewline + 1 }
        // 6. Whitespace not followed by a non-space: all of it at the end, else all but its last scalar.
        if runEnd == n { return runEnd }
        if runEnd - i >= 2 { return runEnd - 1 }
        // 7. The single whitespace.
        return runEnd
    }

    private static func letters(_ s: [Unicode.Scalar], from start: Int) -> Int {
        var j = start
        while j < s.count, isLetter(s[j]) { j += 1 }
        return j
    }

    private static func lowered(_ c: Unicode.Scalar) -> Character {
        if c == "\u{017F}" { return "s" }
        guard c.isASCII else { return "\u{0}" }
        return Character(String(c).lowercased())
    }

    static func isLetter(_ c: Unicode.Scalar) -> Bool {
        switch c.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }

    static func isNumber(_ c: Unicode.Scalar) -> Bool {
        switch c.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: true
        default: false
        }
    }

    static func isWhitespace(_ c: Unicode.Scalar) -> Bool { c.properties.isWhitespace }

    static func isNewline(_ c: Unicode.Scalar) -> Bool { c == "\r" || c == "\n" }

    /// `[^\s\p{L}\p{N}]`.
    static func isSymbol(_ c: Unicode.Scalar) -> Bool { !isWhitespace(c) && !isLetter(c) && !isNumber(c) }
}
