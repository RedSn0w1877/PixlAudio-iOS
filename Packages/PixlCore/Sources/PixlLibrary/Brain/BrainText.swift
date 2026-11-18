// Text folding and title cleaning of the music brain (docs/brain-spec.md, 10.5). A line-by-line transliteration of
// the Android `:brain` module's `BrainText.kt`; both must give the same result for the same text.
//
// No regular expression, no locale or ICU API, no `String` comparison: text is handled as Unicode scalar values on
// the way in and as folded strings compared by their UTF-8 bytes afterwards. The tables are compiled in
// (`FoldTable`, `TitleRules`); nothing is opened at run time.
//
// Kotlin walks UTF-16 units and Swift walks scalars. They agree because every table key, bracket and dash is in the
// Basic Multilingual Plane and a scalar above it passes through unchanged on both sides. A lone surrogate (a space
// in Kotlin) cannot occur in a Swift string.

/// Text folding and title cleaning.
public enum BrainText {
    // Bits of `versionFlags`, in the order of the spec.
    public static let flagLive: Int32 = 1
    public static let flagRemix: Int32 = 1 << 1
    public static let flagAcoustic: Int32 = 1 << 2
    public static let flagInstrumental: Int32 = 1 << 3
    public static let flagRemaster: Int32 = 1 << 4
    public static let flagCover: Int32 = 1 << 5
    public static let flagKaraoke: Int32 = 1 << 6
    public static let flagSpedUp: Int32 = 1 << 7
    public static let flagSlowed: Int32 = 1 << 8
    public static let flagReRecorded: Int32 = 1 << 9

    /// A cleaned title: the folded title and the version flags its dropped segments set.
    public struct CleanTitle: Sendable {
        public let title: String
        public let versionFlags: Int32

        public init(title: String, versionFlags: Int32) {
            self.title = title
            self.versionFlags = versionFlags
        }

        /// The flags that make two titles different recordings: all of them except "remaster" (3.1).
        public var identityFlags: Int32 { versionFlags & ~BrainText.flagRemaster }
    }

    /// Index of `unit` in `FoldTable.keys`, or -1. Binary search over the keys compared as numbers.
    static func rowOf(_ unit: UInt32) -> Int {
        let keys = FoldTable.keys
        var lo = 0
        var hi = keys.count - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let k = UInt32(keys[mid])
            if k < unit { lo = mid + 1 } else if k > unit { hi = mid - 1 } else { return mid }
        }
        return -1
    }

    /// Folds `s` for comparison: ASCII lower-cased, diacritics removed (Vietnamese included, composed or
    /// decomposed), punctuation to a space, runs of spaces collapsed, trimmed. Scripts without a rule (Hangul, kana,
    /// CJK, Thai, ...) pass through unchanged.
    public static func fold(_ s: String) -> String {
        fold(scalars: s.unicodeScalars)
    }

    static func fold<Scalars: Sequence>(scalars: Scalars) -> String where Scalars.Element == Unicode.Scalar {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        let space = Unicode.Scalar(0x20 as UInt8)
        for scalar in scalars {
            let code = scalar.value
            if code < 0x80 {
                var mapped: UInt8 = 0
                if code >= 0x61 && code <= 0x7A {
                    mapped = UInt8(code)
                } else if code >= 0x30 && code <= 0x39 {
                    mapped = UInt8(code)
                } else if code >= 0x41 && code <= 0x5A {
                    mapped = UInt8(code + 32)
                }
                if mapped == 0 {
                    pendingSpace = true
                } else {
                    if pendingSpace && !out.isEmpty { out.append(space) }
                    pendingSpace = false
                    out.append(Unicode.Scalar(mapped))
                }
                continue
            }
            if code > 0xFFFF {
                // A supplementary scalar: no rule, unchanged.
                if pendingSpace && !out.isEmpty { out.append(space) }
                pendingSpace = false
                out.append(scalar)
                continue
            }
            let row = rowOf(code)
            if row < 0 {
                if pendingSpace && !out.isEmpty { out.append(space) }
                pendingSpace = false
                out.append(scalar)
                continue
            }
            let from = Int(FoldTable.offsets[row])
            let to = Int(FoldTable.offsets[row + 1])
            var k = from
            while k < to {
                let r = FoldTable.values[k]
                if r == 0x20 {
                    pendingSpace = true
                } else {
                    if pendingSpace && !out.isEmpty { out.append(space) }
                    pendingSpace = false
                    // Table values are checked at generation time: BMP scalars, never a surrogate.
                    if let replacement = Unicode.Scalar(UInt32(r)) { out.append(replacement) }
                }
                k += 1
            }
        }
        return String(out)
    }

    static func isOpener(_ c: Unicode.Scalar) -> Bool {
        c.value == 0x28 || c.value == 0x5B || c.value == 0xFF08 || c.value == 0xFF3B
    }

    static func isCloser(_ c: Unicode.Scalar) -> Bool {
        c.value == 0x29 || c.value == 0x5D || c.value == 0xFF09 || c.value == 0xFF3D
    }

    static func isDash(_ c: Unicode.Scalar) -> Bool {
        c.value == 0x2D || c.value == 0x2013 || c.value == 0x2014
    }

    /// Index of the closer that ends the group opened at `open`, counting nested groups; -1 if it never closes.
    static func matchingCloser(_ raw: [Unicode.Scalar], _ open: Int) -> Int {
        var depth = 0
        var i = open
        while i < raw.count {
            let c = raw[i]
            if isOpener(c) {
                depth += 1
            } else if isCloser(c) {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return -1
    }

    /// True when `tokens` contains the tokens of `sequence` in a row.
    static func containsTokens(_ tokens: [String], _ sequence: [String]) -> Bool {
        if sequence.isEmpty || sequence.count > tokens.count { return false }
        var start = 0
        while start + sequence.count <= tokens.count {
            var k = 0
            while k < sequence.count && BrainKey.sameBytes(tokens[start + k], sequence[k]) { k += 1 }
            if k == sequence.count { return true }
            start += 1
        }
        return false
    }

    static func startsWithTokens(_ tokens: [String], _ sequence: [String]) -> Bool {
        if sequence.isEmpty || sequence.count > tokens.count { return false }
        var k = 0
        while k < sequence.count && BrainKey.sameBytes(tokens[k], sequence[k]) { k += 1 }
        return k == sequence.count
    }

    /// The single-space separated tokens of a folded string.
    static func splitTokens(_ folded: String) -> [String] {
        if folded.isEmpty { return [] }
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            if scalar.value == 0x20 {
                if !current.isEmpty { tokens.append(String(current)) }
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { tokens.append(String(current)) }
        return tokens
    }

    static let flagSequences: [[String]] = TitleRules.flagTokens.map(splitTokens)
    static let neutralPrefixes: [[String]] = TitleRules.neutralPrefix.map(splitTokens)
    static let neutralEquals: [[String]] = TitleRules.neutralEquals.map(splitTokens)

    // The verdict on one segment: a positive value is the flag bits to set (the segment is dropped), `segmentNeutral`
    // drops it without a flag, `segmentKeep` leaves it in the title.
    static let segmentNeutral: Int32 = 0
    static let segmentKeep: Int32 = -1

    static func classify<Segment: Sequence>(_ segment: Segment) -> Int32 where Segment.Element == Unicode.Scalar {
        let tokens = splitTokens(fold(scalars: segment))
        if tokens.isEmpty { return segmentNeutral }
        var flags: Int32 = 0
        let sequences = flagSequences
        for r in sequences.indices where containsTokens(tokens, sequences[r]) {
            flags |= 1 << TitleRules.flagBits[r]
        }
        if flags != 0 { return flags }
        for prefix in neutralPrefixes where startsWithTokens(tokens, prefix) { return segmentNeutral }
        for whole in neutralEquals where whole.count == tokens.count && startsWithTokens(tokens, whole) {
            return segmentNeutral
        }
        return segmentKeep
    }

    /// Splits a raw title into the song's own name and its version flags.
    ///
    /// Segments are each `( ... )` and `[ ... ]` group (also full-width) and the text after the last `" - "`
    /// (hyphen, en dash or em dash, a space on both sides). A segment that names a version ("Live",
    /// "Remastered 2011", "Taylor's Version") is dropped and sets its flag (every flag it matches, as on Android); one
    /// that is only packaging ("feat. X", "Radio Edit") is dropped; anything else stays ("(Part 2)").
    public static func cleanTitle(_ rawText: String) -> CleanTitle {
        let raw = Array(rawText.unicodeScalars)
        let space = Unicode.Scalar(0x20 as UInt8)
        var head: [Unicode.Scalar] = []
        head.reserveCapacity(raw.count)
        var kept: [Unicode.Scalar] = []
        var flags: Int32 = 0
        var i = 0
        while i < raw.count {
            let c = raw[i]
            if isOpener(c) {
                let close = matchingCloser(raw, i)
                if close > i {
                    let verdict = classify(raw[(i + 1)..<close])
                    if verdict == segmentKeep {
                        kept.append(space)
                        kept.append(contentsOf: raw[(i + 1)..<close])
                    } else {
                        flags |= verdict
                    }
                    head.append(space)
                    i = close + 1
                    continue
                }
            }
            head.append(c)
            i += 1
        }

        // The text after the last " - " of what is left.
        var cut = -1
        var k = head.count - 2
        while k >= 1 {
            if isDash(head[k]) && head[k - 1] == space && head[k + 1] == space {
                cut = k
                break
            }
            k -= 1
        }
        var headText = head[...]
        if cut >= 0 {
            let verdict = classify(head[(cut + 1)...])
            if verdict != segmentKeep {
                flags |= verdict
                headText = head[..<cut]
            }
        }

        var title = fold(scalars: Array(headText) + kept)
        if title.isEmpty { title = fold(scalars: raw) }
        return CleanTitle(title: title, versionFlags: flags)
    }

    /// Kotlin's `String.isBlank()` with a fixed list, so no Unicode table of the platform is asked: true when every
    /// scalar is a space separator, a line or paragraph separator, or one of the ASCII control whitespaces.
    public static func isBlank(_ s: String) -> Bool {
        for scalar in s.unicodeScalars where !isWhitespace(scalar.value) { return false }
        return true
    }

    static func isWhitespace(_ v: UInt32) -> Bool {
        if v <= 0x20 { return v == 0x20 || (v >= 0x09 && v <= 0x0D) || (v >= 0x1C && v <= 0x1F) }
        if v == 0xA0 || v == 0x1680 || v == 0x202F || v == 0x205F || v == 0x3000 { return true }
        return (v >= 0x2000 && v <= 0x200A) || v == 0x2028 || v == 0x2029
    }

    /// Kotlin's `String.trim()` with the same fixed list.
    public static func trim(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        var from = 0
        var to = scalars.count
        while from < to && isWhitespace(scalars[from].value) { from += 1 }
        while to > from && isWhitespace(scalars[to - 1].value) { to -= 1 }
        if from == 0 && to == scalars.count { return s }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars[from..<to])
        return String(out)
    }
}
