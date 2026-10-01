// Kotlin/JVM string and number semantics the Android lyrics parsers rely on, written out so the ports can be
// line for line without silently changing behaviour. Swift's `String` compares, searches and prefixes by grapheme
// cluster and canonical equivalence; Kotlin works on UTF-16 code units. Everything here works on Unicode scalars
// (or UTF-16 units where Kotlin indexes them) and is exact for the inputs the parsers see.
//
// Regex note: Android runs `java.util.regex` on ICU, the JVM unit tests on the JDK engine. They agree for every
// pattern the parsers use except `\b` next to non-ASCII letters (ICU: Unicode word characters; JDK 19+: ASCII
// `\w`) and `(?i)` on non-ASCII letters. These ports follow the device (ICU) where the two differ.

import Foundation
import PixlFoundation

/// Kotlin/JVM semantics shared by the lyrics parsers (internal).
enum ParseKit {

    // MARK: Character classes

    /// `Character.isISOControl`: U+0000…U+001F and U+007F…U+009F.
    @inline(__always)
    static func isISOControl(_ s: Unicode.Scalar) -> Bool {
        s.value <= 0x1F || (0x7F...0x9F).contains(s.value)
    }

    /// `Character.getType(char) == FORMAT` evaluated per UTF-16 unit: a BMP scalar of general category Cf.
    /// (A supplementary Cf code point is two surrogate units of type SURROGATE on Android, so it never matches.)
    @inline(__always)
    static func isFormatChar(_ s: Unicode.Scalar) -> Bool {
        s.value <= 0xFFFF && s.properties.generalCategory == .format
    }

    /// Java regex `\s` without UNICODE_CHARACTER_CLASS: `[ \t\n\x0B\f\r]`.
    @inline(__always)
    static func isRegexSpace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D: return true
        default: return false
        }
    }

    /// Java regex `\d`: ASCII digits only.
    @inline(__always)
    static func isAsciiDigit(_ s: Unicode.Scalar) -> Bool { s.value >= 0x30 && s.value <= 0x39 }

    /// Kotlin `Char.isWhitespace()`.
    @inline(__always)
    static func isWhitespace(_ s: Unicode.Scalar) -> Bool { TextScripts.isKotlinWhitespace(s) }

    /// Kotlin `Char.isLetterOrDigit()`: categories L* or Nd, per UTF-16 unit (BMP only).
    @inline(__always)
    static func isLetterOrDigit(_ s: Unicode.Scalar) -> Bool {
        guard s.value <= 0xFFFF else { return false }
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber:
            return true
        default: return false
        }
    }

    /// Java regex `\p{L}` (code-point aware).
    @inline(__always)
    static func isLetter(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    /// Java regex `\p{N}` (code-point aware).
    @inline(__always)
    static func isNumber(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    /// Java regex `\p{M}`.
    @inline(__always)
    static func isMark(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// A regex word character for `\b` as ICU (Android) defines it: alphabetic, marks, decimal digits, connector
    /// punctuation (`_`).
    @inline(__always)
    static func isWordChar(_ s: Unicode.Scalar) -> Bool {
        if s.properties.isAlphabetic { return true }
        switch s.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .connectorPunctuation: return true
        default: return false
        }
    }

    /// Characters `.` does not match in a Java regex without DOTALL (line terminators).
    @inline(__always)
    static func isLineTerminator(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0A, 0x0D, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    // MARK: Strings

    /// Kotlin `CharSequence.lines()`: splits on `\r\n`, `\n` and `\r`; keeps a trailing empty line.
    static func lines(_ text: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        var it = text.unicodeScalars.makeIterator()
        var pending = it.next()
        while let s = pending {
            pending = it.next()
            if s == "\n" {
                out.append(String(current)); current = String.UnicodeScalarView()
            } else if s == "\r" {
                out.append(String(current)); current = String.UnicodeScalarView()
                if pending == "\n" { pending = it.next() }
            } else {
                current.append(s)
            }
        }
        out.append(String(current))
        return out
    }

    /// Kotlin `String.trim()` (Kotlin whitespace).
    @inline(__always)
    static func trim(_ s: String) -> String { s.kotlinTrimmed() }

    /// Kotlin `isBlank()`.
    @inline(__always)
    static func isBlank(_ s: String) -> Bool { s.isKotlinBlank }

    /// Kotlin `trim(vararg chars)` / `trimStart` / `trimEnd` with a predicate.
    static func trim(_ s: String, start: Bool = true, end: Bool = true,
                     where predicate: (Unicode.Scalar) -> Bool) -> String {
        let scalars = Array(s.unicodeScalars)
        var lo = 0
        var hi = scalars.count
        if start { while lo < hi, predicate(scalars[lo]) { lo += 1 } }
        if end { while hi > lo, predicate(scalars[hi - 1]) { hi -= 1 } }
        if lo == 0 && hi == scalars.count { return s }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[lo..<hi])
        return String(view)
    }

    /// Removes the scalars matching `predicate` (Kotlin `filterNot`).
    static func filterNot(_ s: String, _ predicate: (Unicode.Scalar) -> Bool) -> String {
        var view = String.UnicodeScalarView()
        for scalar in s.unicodeScalars where !predicate(scalar) { view.append(scalar) }
        return String(view)
    }

    /// Kotlin `startsWith(prefix)` (code units, not graphemes).
    @inline(__always)
    static func hasPrefix(_ s: String, _ prefix: String) -> Bool { s.utf8.starts(with: prefix.utf8) }

    /// Kotlin `endsWith(suffix)`.
    @inline(__always)
    static func hasSuffix(_ s: String, _ suffix: String) -> Bool {
        s.utf8.count >= suffix.utf8.count && s.utf8.reversed().starts(with: suffix.utf8.reversed())
    }

    /// Kotlin `startsWith(prefix, ignoreCase = true)` for an ASCII prefix.
    static func hasPrefixIgnoringASCIICase(_ s: String, _ prefix: String) -> Bool {
        var a = s.utf8.makeIterator()
        for p in prefix.utf8 {
            guard let c = a.next(), lowerASCII(c) == lowerASCII(p) else { return false }
        }
        return true
    }

    @inline(__always)
    static func lowerASCII(_ c: UInt8) -> UInt8 { (c >= 0x41 && c <= 0x5A) ? c + 32 : c }

    /// Kotlin `contains(other)` (code-unit substring search).
    static func contains(_ s: String, _ needle: String) -> Bool { indexOf(Array(s.unicodeScalars), Array(needle.unicodeScalars), from: 0) != nil }

    /// Index of `needle` in `haystack` at or after `from` (scalar indices).
    static func indexOf(_ haystack: [Unicode.Scalar], _ needle: [Unicode.Scalar], from: Int) -> Int? {
        if needle.isEmpty { return from <= haystack.count ? from : nil }
        guard haystack.count >= needle.count else { return nil }
        var i = from
        let last = haystack.count - needle.count
        while i <= last {
            if haystack[i] == needle[0] {
                var j = 1
                while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }

    /// Kotlin `replace(old, new)` for literal strings.
    static func replacing(_ s: String, _ old: String, with new: String) -> String {
        let hay = Array(s.unicodeScalars)
        let needle = Array(old.unicodeScalars)
        guard !needle.isEmpty, var found = indexOf(hay, needle, from: 0) else { return s }
        var out = String.UnicodeScalarView()
        var start = 0
        while true {
            out.append(contentsOf: hay[start..<found])
            out.append(contentsOf: new.unicodeScalars)
            start = found + needle.count
            guard let next = indexOf(hay, needle, from: start) else { break }
            found = next
        }
        out.append(contentsOf: hay[start...])
        return String(out)
    }

    /// Kotlin `substringBefore(delimiter)`.
    static func substringBefore(_ s: String, _ delimiter: String) -> String {
        let hay = Array(s.unicodeScalars)
        guard let i = indexOf(hay, Array(delimiter.unicodeScalars), from: 0) else { return s }
        return string(hay[..<i])
    }

    /// Kotlin `substringAfter(delimiter, missingDelimiterValue)`.
    static func substringAfter(_ s: String, _ delimiter: String, missing: String) -> String {
        let hay = Array(s.unicodeScalars)
        let needle = Array(delimiter.unicodeScalars)
        guard let i = indexOf(hay, needle, from: 0) else { return missing }
        return string(hay[(i + needle.count)...])
    }

    @inline(__always)
    static func string<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// Kotlin `lowercase()` / Java `toLowerCase(Locale.ROOT)`: full Unicode lower-case mapping, including the
    /// Greek final-sigma rule Java applies (Σ → ς at the end of a word).
    static func lowercased(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        guard scalars.contains(where: { $0.value == 0x03A3 }) else { return s.lowercased() }
        var out = ""
        for (i, scalar) in scalars.enumerated() {
            if scalar.value == 0x03A3 {
                out.unicodeScalars.append(isFinalSigma(scalars, i) ? "\u{03C2}" : "\u{03C3}")
            } else {
                out += String(scalar).lowercased()
            }
        }
        return out
    }

    /// Unicode Final_Sigma: preceded by a cased letter (skipping case-ignorable) and not followed by one.
    private static func isFinalSigma(_ s: [Unicode.Scalar], _ i: Int) -> Bool {
        var j = i - 1
        while j >= 0, s[j].properties.isCaseIgnorable { j -= 1 }
        guard j >= 0, s[j].properties.isCased else { return false }
        var k = i + 1
        while k < s.count, s[k].properties.isCaseIgnorable { k += 1 }
        return !(k < s.count && s[k].properties.isCased)
    }

    // MARK: Numbers

    /// Kotlin `String.toLongOrNull()`: optional `+`/`-`, then at least one decimal digit (`Character.digit`, so
    /// any Unicode Nd digit), no overflow.
    static func toLong<S: StringProtocol>(_ s: S) -> Int64? {
        var scalars = Substring(s).unicodeScalars[...]
        guard let first = scalars.first else { return nil }
        var negative = false
        if first == "-" || first == "+" {
            negative = first == "-"
            scalars = scalars.dropFirst()
            if scalars.isEmpty { return nil }
        }
        var value: Int64 = 0
        for scalar in scalars {
            guard scalar.properties.generalCategory == .decimalNumber,
                  let digit = scalar.properties.numericValue, digit >= 0, digit <= 9 else { return nil }
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (r, o2) = negative ? m.subtractingReportingOverflow(Int64(digit)) : m.addingReportingOverflow(Int64(digit))
            if o1 || o2 { return nil }
            value = r
        }
        return value
    }

    /// Kotlin `String.toIntOrNull()`.
    static func toInt<S: StringProtocol>(_ s: S) -> Int32? {
        guard let l = toLong(s) else { return nil }
        return Int32(exactly: l)
    }

    /// Java `Double.parseDouble` (and Kotlin `toDoubleOrNull`): leading/trailing chars ≤ U+0020 ignored; optional
    /// sign; `NaN`, `Infinity`, decimal with optional exponent, or a hexadecimal float (`0x1.8p3`); optional
    /// `f`/`F`/`d`/`D` suffix. nil when the text is not a Java floating-point literal.
    static func parseDouble<S: StringProtocol>(_ raw: S) -> Double? {
        var bytes = Array(raw.utf8)[...]
        // Java trims code units <= ' '; every such unit is a single UTF-8 byte.
        while let f = bytes.first, f <= 0x20 { bytes = bytes.dropFirst() }
        while let l = bytes.last, l <= 0x20 { bytes = bytes.dropLast() }
        guard !bytes.isEmpty else { return nil }
        var sign = ""
        if bytes.first == UInt8(ascii: "+") || bytes.first == UInt8(ascii: "-") {
            if bytes.first == UInt8(ascii: "-") { sign = "-" }
            bytes = bytes.dropFirst()
        }
        let body = String(decoding: bytes, as: UTF8.self)
        if body == "NaN" { return .nan }
        if body == "Infinity" { return sign == "-" ? -.infinity : .infinity }
        var b = bytes
        if let last = b.last, [UInt8(ascii: "f"), UInt8(ascii: "F"), UInt8(ascii: "d"), UInt8(ascii: "D")].contains(last) {
            b = b.dropLast()
        }
        guard !b.isEmpty else { return nil }
        let isHex = b.count >= 2 && b.first == UInt8(ascii: "0")
            && (b[b.startIndex + 1] == UInt8(ascii: "x") || b[b.startIndex + 1] == UInt8(ascii: "X"))
        if isHex {
            // 0x HexDigits? (. HexDigits?)? [pP] sign? Digits — at least one hex digit, binary exponent required.
            var i = b.startIndex + 2
            var digits = 0
            while i < b.endIndex, isHexDigit(b[i]) { i += 1; digits += 1 }
            if i < b.endIndex, b[i] == UInt8(ascii: ".") {
                i += 1
                while i < b.endIndex, isHexDigit(b[i]) { i += 1; digits += 1 }
            }
            guard digits > 0, i < b.endIndex, b[i] == UInt8(ascii: "p") || b[i] == UInt8(ascii: "P") else { return nil }
            i += 1
            if i < b.endIndex, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
            var expDigits = 0
            while i < b.endIndex, isDecDigit(b[i]) { i += 1; expDigits += 1 }
            guard expDigits > 0, i == b.endIndex else { return nil }
            return Double(sign + String(decoding: b, as: UTF8.self))
        }
        // Digits (. Digits?)? | . Digits — then optional exponent.
        var i = b.startIndex
        var intDigits = 0
        while i < b.endIndex, isDecDigit(b[i]) { i += 1; intDigits += 1 }
        var fracDigits = 0
        if i < b.endIndex, b[i] == UInt8(ascii: ".") {
            i += 1
            while i < b.endIndex, isDecDigit(b[i]) { i += 1; fracDigits += 1 }
        }
        guard intDigits + fracDigits > 0 else { return nil }
        if i < b.endIndex, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
            i += 1
            if i < b.endIndex, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
            var expDigits = 0
            while i < b.endIndex, isDecDigit(b[i]) { i += 1; expDigits += 1 }
            guard expDigits > 0 else { return nil }
        }
        guard i == b.endIndex else { return nil }
        var text = String(decoding: b, as: UTF8.self)
        if text.hasPrefix(".") { text = "0" + text }
        if text.hasSuffix(".") { text += "0" }
        text = text.replacingOccurrences(of: ".e", with: ".0e").replacingOccurrences(of: ".E", with: ".0E")
        return Double(sign + text)
    }

    @inline(__always) private static func isDecDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
    @inline(__always) private static func isHexDigit(_ c: UInt8) -> Bool {
        isDecDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
    }

    /// Java `Math.round(double)`: nearest long, ties toward positive infinity, saturating; NaN → 0.
    static func javaRound(_ x: Double) -> Int64 {
        if x.isNaN { return 0 }
        let floor = x.rounded(.down)
        let rounded = (x - floor >= 0.5) ? floor + 1 : floor
        return KotlinMath.toLong(rounded)
    }

    /// Kotlin `Double.roundToInt()`: nil for NaN (Kotlin throws), saturating otherwise.
    static func roundToInt(_ x: Double) -> Int32? {
        if x.isNaN { return nil }
        if x > Double(Int32.max) { return .max }
        if x < Double(Int32.min) { return .min }
        return Int32(truncatingIfNeeded: javaRound(x))
    }

    /// Kotlin `Double.roundToLong()`: nil for NaN (Kotlin throws).
    static func roundToLong(_ x: Double) -> Int64? {
        if x.isNaN { return nil }
        return javaRound(x)
    }

    /// Java `String.format("%02d", n)`: zero-padded to width 2, sign included in the width.
    static func pad2<T: BinaryInteger>(_ n: T) -> String {
        if n < 0 {
            let digits = String(n.magnitude)
            return "-" + digits
        }
        let digits = String(n)
        return digits.count >= 2 ? digits : "0" + digits
    }

    /// `"%02d:%02d.%02d"` of `timeMs` (the LRC timestamp body used by every Android formatter).
    static func lrcTimestamp(_ timeMs: Int32) -> String {
        let totalSeconds = timeMs / 1000
        return pad2(totalSeconds / 60) + ":" + pad2(totalSeconds % 60) + "." + pad2((timeMs % 1000) / 10)
    }

    /// Kotlin `Long.toInt()` (wraps).
    @inline(__always)
    static func wrapToInt(_ v: Int64) -> Int { Int(Int32(truncatingIfNeeded: v)) }
}
