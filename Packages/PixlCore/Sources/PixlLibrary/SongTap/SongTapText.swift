// Text handling for a beamed song (Song Tap): strict UTF-8, the characters a beam may never carry, and the one
// `sanitize` function the sender uses to make text fit and the receiver uses to prove it already does.
// A line-by-line transliteration of the Android `:songtap` module's `SongTapText.kt`; both must give the same
// result for the same text (golden files in Tests/PixlLibraryTests/Fixtures/songtap).
//
// Everything works on Unicode code points held in an `[Int]`, never on a platform string type. The core is
// standard-library Swift only (SongTapPurityTests).

/// Text rules of a beam.
public enum SongTapText {
    /// Characters that become one ordinary space (and runs of spaces collapse to one).
    static func isSpaceLike(_ cp: Int) -> Bool {
        switch cp {
        case 0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return cp >= 0x2000 && cp <= 0x200A
        }
    }

    /// Characters that are removed: controls, zero width, bidirectional marks, tags, noncharacters.
    public static func isStripped(_ cp: Int) -> Bool {
        if cp < 0x20 { return true }
        if cp >= 0x7F && cp <= 0x9F { return true }
        if cp == 0xAD || cp == 0x061C || cp == 0x180E { return true }
        if cp >= 0x200B && cp <= 0x200F { return true }
        if cp >= 0x202A && cp <= 0x202E { return true }
        if cp >= 0x2060 && cp <= 0x206F { return true }
        if cp == 0xFEFF { return true }
        if cp >= 0xFFF9 && cp <= 0xFFFC { return true }
        if cp >= 0xFDD0 && cp <= 0xFDEF { return true }
        if cp == 0xFFFE || cp == 0xFFFF { return true }
        if cp >= 0xE0000 && cp <= 0xE007F { return true }
        if cp >= 0xD800 && cp <= 0xDFFF { return true }
        if cp > 0x10FFFF { return true }
        return false
    }

    /// UTF-8 length of one code point.
    public static func utf8Length(_ cp: Int) -> Int {
        if cp < 0x80 { return 1 }
        if cp < 0x800 { return 2 }
        if cp < 0x10000 { return 3 }
        return 4
    }

    public static func utf8Length(_ cps: [Int]) -> Int {
        var n = 0
        for cp in cps { n += utf8Length(cp) }
        return n
    }

    public static func encodeUtf8(_ cps: [Int]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(utf8Length(cps))
        for cp in cps {
            if cp < 0x80 {
                out.append(UInt8(truncatingIfNeeded: cp))
            } else if cp < 0x800 {
                out.append(UInt8(truncatingIfNeeded: 0xC0 | (cp >> 6)))
                out.append(UInt8(truncatingIfNeeded: 0x80 | (cp & 0x3F)))
            } else if cp < 0x10000 {
                out.append(UInt8(truncatingIfNeeded: 0xE0 | (cp >> 12)))
                out.append(UInt8(truncatingIfNeeded: 0x80 | ((cp >> 6) & 0x3F)))
                out.append(UInt8(truncatingIfNeeded: 0x80 | (cp & 0x3F)))
            } else {
                out.append(UInt8(truncatingIfNeeded: 0xF0 | (cp >> 18)))
                out.append(UInt8(truncatingIfNeeded: 0x80 | ((cp >> 12) & 0x3F)))
                out.append(UInt8(truncatingIfNeeded: 0x80 | ((cp >> 6) & 0x3F)))
                out.append(UInt8(truncatingIfNeeded: 0x80 | (cp & 0x3F)))
            }
        }
        return out
    }

    /// Strict UTF-8: no overlong forms, no surrogates, nothing above U+10FFFF, no truncated sequence.
    /// Nil when `bytes` from `from` until `to` is not valid.
    public static func decodeUtf8(_ bytes: [UInt8], from: Int = 0, to: Int? = nil) -> [Int]? {
        let end = to ?? bytes.count
        var out: [Int] = []
        out.reserveCapacity(max(end - from, 0))
        var i = from
        while i < end {
            let b0 = Int(bytes[i])
            let cp: Int
            let len: Int
            if b0 < 0x80 {
                cp = b0; len = 1
            } else if b0 >= 0xC2 && b0 <= 0xDF {
                cp = b0 & 0x1F; len = 2
            } else if b0 >= 0xE0 && b0 <= 0xEF {
                cp = b0 & 0x0F; len = 3
            } else if b0 >= 0xF0 && b0 <= 0xF4 {
                cp = b0 & 0x07; len = 4
            } else {
                return nil
            }
            if i + len > end { return nil }
            var value = cp
            if len > 1 {
                for k in 1..<len {
                    let b = Int(bytes[i + k])
                    if b & 0xC0 != 0x80 { return nil }
                    value = (value << 6) | (b & 0x3F)
                }
            }
            if len == 3 && value < 0x800 { return nil }
            if len == 4 && (value < 0x10000 || value > 0x10FFFF) { return nil }
            if value >= 0xD800 && value <= 0xDFFF { return nil }
            out.append(value)
            i += len
        }
        return out
    }

    /// The code points (Unicode scalars) of a Swift string.
    public static func toCodePoints(_ s: String) -> [Int] {
        var out: [Int] = []
        out.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars { out.append(Int(scalar.value)) }
        return out
    }

    /// A string of the code points; one that is not a scalar value becomes U+FFFD.
    public static func fromCodePoints(_ cps: [Int]) -> String {
        var view = String.UnicodeScalarView()
        for cp in cps {
            if cp >= 0, cp <= 0x10FFFF, let scalar = Unicode.Scalar(UInt32(cp)) {
                view.append(scalar)
            } else {
                view.append(Unicode.Scalar(0xFFFD as UInt32)!)
            }
        }
        return String(view)
    }

    /// Makes `raw` fit a beam: stripped characters removed, space-like characters turned into one space, leading and
    /// trailing spaces dropped, then cut at a code point boundary so the UTF-8 form is at most `maxBytes`.
    /// Idempotent: `sanitize(sanitize(x)) == sanitize(x)`.
    public static func sanitize(_ raw: [Int], maxBytes: Int) -> [Int] {
        var out: [Int] = []
        out.reserveCapacity(raw.count)
        var bytes = 0
        var pendingSpace = false
        for cp in raw {
            if isSpaceLike(cp) {
                if !out.isEmpty { pendingSpace = true }
                continue
            }
            if isStripped(cp) { continue }
            let add = utf8Length(cp) + (pendingSpace ? 1 : 0)
            if bytes + add > maxBytes { break }
            if pendingSpace { out.append(0x20); bytes += 1; pendingSpace = false }
            out.append(cp)
            bytes += utf8Length(cp)
        }
        return out
    }

    public static func sanitize(_ raw: String, maxBytes: Int) -> String {
        fromCodePoints(sanitize(toCodePoints(raw), maxBytes: maxBytes))
    }

    /// True when `cps` is non-empty, fits `maxBytes` and is already what `sanitize` would return.
    public static func isClean(_ cps: [Int], maxBytes: Int) -> Bool {
        if cps.isEmpty || utf8Length(cps) > maxBytes { return false }
        return sanitize(cps, maxBytes: maxBytes) == cps
    }
}
