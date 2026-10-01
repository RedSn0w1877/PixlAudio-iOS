// Small Kotlin/Java text semantics the network ports rely on: `lowercase(Locale.ROOT)` (with Java's Final_Sigma
// rule), `Double.toString`, `String.substringBefore`, UTF-16 views for Kotlin `Char` maths, and the ASCII regex
// classes (`\w`, `\s`, `\d`) of java.util.regex without UNICODE_CHARACTER_CLASS.

import Foundation
import PixlFoundation

enum NetText {
    // MARK: Case

    /// Kotlin `lowercase()` / Java `toLowerCase(Locale.ROOT)`: full Unicode lower-case mapping with the Final_Sigma
    /// context rule for U+03A3.
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

    private static func isFinalSigma(_ s: [Unicode.Scalar], _ i: Int) -> Bool {
        var j = i - 1
        while j >= 0, s[j].properties.isCaseIgnorable { j -= 1 }
        guard j >= 0, s[j].properties.isCased else { return false }
        var k = i + 1
        while k < s.count, s[k].properties.isCaseIgnorable { k += 1 }
        return !(k < s.count && s[k].properties.isCased)
    }

    /// Kotlin `equals(other, ignoreCase = true)` for the ASCII-only words the ports compare ("OK", "Song", …):
    /// per-character upper- then lower-case comparison.
    static func equalsIgnoreCase(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf16), y = Array(b.utf16)
        guard x.count == y.count else { return false }
        for (c1, c2) in zip(x, y) where c1 != c2 {
            let u1 = String(utf16CodeUnits: [c1], count: 1).uppercased(), u2 = String(utf16CodeUnits: [c2], count: 1).uppercased()
            if u1 == u2 { continue }
            if u1.lowercased() == u2.lowercased() { continue }
            return false
        }
        return true
    }

    /// Kotlin `contains(other, ignoreCase = true)` (case folding by per-character lower case).
    static func containsIgnoreCase(_ haystack: String, _ needle: String) -> Bool {
        if needle.isEmpty { return true }
        return containsExact(lowercased(haystack), lowercased(needle))
    }

    /// Kotlin `startsWith(prefix, ignoreCase = true)`.
    static func hasPrefixIgnoreCase(_ s: String, _ prefix: String) -> Bool {
        let a = Array(s.utf16), p = Array(prefix.utf16)
        guard a.count >= p.count else { return false }
        return equalsIgnoreCase(String(decoding: a[0..<p.count], as: UTF16.self), prefix)
    }

    // MARK: Kotlin string helpers

    /// Kotlin `substringBefore(delimiter)` (the whole string when it is missing).
    static func substringBefore(_ s: String, _ delimiter: String) -> String {
        guard let range = s.range(of: delimiter, options: .literal) else { return s }
        return String(s[..<range.lowerBound])
    }

    /// Kotlin `take(n)` on a String (UTF-16 code units, like Kotlin `Char`s).
    static func take(_ s: String, _ n: Int) -> String {
        let units = Array(s.utf16)
        if units.count <= n { return s }
        return String(decoding: units[0..<max(0, n)], as: UTF16.self)
    }

    /// Kotlin `CharSequence.contains(other)`: exact UTF-16 substring search (no canonical equivalence).
    static func containsExact(_ haystack: String, _ needle: String) -> Bool {
        indexOf(haystack, needle) != nil
    }

    /// Kotlin `indexOf(other)` in UTF-16 code units, or nil.
    static func indexOf(_ haystack: String, _ needle: String, from start: Int = 0) -> Int? {
        indexOf(Array(haystack.utf16), Array(needle.utf16), from: start)
    }

    static func indexOf(_ h: [UInt16], _ n: [UInt16], from start: Int = 0) -> Int? {
        if n.isEmpty { return min(max(start, 0), h.count) }
        if h.count < n.count { return nil }
        var i = max(start, 0)
        while i + n.count <= h.count {
            if h[i] == n[0] {
                var k = 1
                while k < n.count && h[i + k] == n[k] { k += 1 }
                if k == n.count { return i }
            }
            i += 1
        }
        return nil
    }

    /// Kotlin `==` on Strings (UTF-16 equality, no canonical equivalence).
    static func same(_ a: String, _ b: String) -> Bool { a.utf16.elementsEqual(b.utf16) }

    /// Kotlin `removeSuffix(suffix)` (exact UTF-16).
    static func removeSuffix(_ s: String, _ suffix: String) -> String {
        let a = Array(s.utf16), b = Array(suffix.utf16)
        guard a.count >= b.count, Array(a[(a.count - b.count)...]) == b else { return s }
        return String(decoding: a[0..<(a.count - b.count)], as: UTF16.self)
    }

    /// Kotlin `removePrefix(prefix)` (exact UTF-16).
    static func removePrefix(_ s: String, _ prefix: String) -> String {
        let a = Array(s.utf16), b = Array(prefix.utf16)
        guard a.count >= b.count, Array(a[0..<b.count]) == b else { return s }
        return String(decoding: a[b.count...], as: UTF16.self)
    }

    /// Kotlin `startsWith(prefix)` (exact UTF-16).
    static func startsWith(_ s: String, _ prefix: String) -> Bool {
        let a = Array(s.utf16), b = Array(prefix.utf16)
        return a.count >= b.count && Array(a[0..<b.count]) == b
    }

    /// Kotlin `endsWith(suffix)` (exact UTF-16).
    static func endsWith(_ s: String, _ suffix: String) -> Bool {
        let a = Array(s.utf16), b = Array(suffix.utf16)
        return a.count >= b.count && Array(a[(a.count - b.count)...]) == b
    }

    /// Kotlin `String.length` (UTF-16 code units).
    static func length(_ s: String) -> Int { s.utf16.count }

    /// Kotlin `trim()`.
    static func trim(_ s: String) -> String { s.kotlinTrimmed() }

    /// Kotlin `isBlank()`.
    static func isBlank(_ s: String) -> Bool { s.isKotlinBlank }

    /// Kotlin `String.toLongOrNull()` for ASCII digits with an optional sign (no overflow).
    static func toLong(_ s: String) -> Int64? {
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
    static func toInt(_ s: String) -> Int? {
        guard let l = toLong(s), let i = Int32(exactly: l) else { return nil }
        return Int(i)
    }

    // MARK: Java regex character classes (no UNICODE_CHARACTER_CLASS)

    /// `\w`: `[a-zA-Z_0-9]`.
    static func isWordChar(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F: return true
        default: return false
        }
    }

    /// `\s`: `[ \t\n\x0B\f\r]`.
    static func isRegexSpace(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D: return true
        default: return false
        }
    }

    /// `\d`: `[0-9]`.
    static func isAsciiDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 0x30 && c.value <= 0x39 }

    /// `[a-zA-Z0-9_$]` — a JavaScript identifier character as base.js patterns spell it.
    static func isJsIdentifierChar(_ c: Unicode.Scalar) -> Bool { isWordChar(c) || c == "$" }

    /// `\p{L}` (Java: general category L*).
    static func isLetter(_ c: Unicode.Scalar) -> Bool {
        switch c.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    /// `\p{N}` (Java: general category N*).
    static func isNumber(_ c: Unicode.Scalar) -> Bool {
        switch c.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    /// `\p{M}` (Java: general category M*).
    static func isMark(_ c: Unicode.Scalar) -> Bool {
        switch c.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    // MARK: Numbers

    /// Java `Double.toString` (JDK 19+ shortest-digit form): plain decimal for 1e-3 ≤ |d| < 1e7 with at least one
    /// fractional digit, otherwise `d.dddE±n`.
    static func javaDoubleString(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
        if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
        let sign = d < 0 ? "-" : ""
        let text = "\(abs(d))"
        var mantissa = Substring(text)
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = text[..<e]
            exponent = Int(text[text.index(after: e)...].replacingOccurrences(of: "+", with: "")) ?? 0
        }
        let pieces = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let intPart = String(pieces[0])
        let fracPart = pieces.count > 1 ? String(pieces[1]) : ""
        var digits = Array(intPart + fracPart)
        var point = intPart.count + exponent
        while digits.first == "0" {
            digits.removeFirst()
            point -= 1
        }
        while digits.last == "0" { digits.removeLast() }
        if digits.isEmpty { return sign + "0.0" }
        let sciExponent = point - 1
        if sciExponent >= -3 && sciExponent < 7 {
            if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + String(digits) }
            if point >= digits.count { return sign + String(digits) + String(repeating: "0", count: point - digits.count) + ".0" }
            return sign + String(digits[0..<point]) + "." + String(digits[point...])
        }
        let tail = digits.count > 1 ? String(digits[1...]) : "0"
        return sign + String(digits[0]) + "." + tail + "E" + String(sciExponent)
    }

    /// Java `Float.toString` for the values the AI settings hold (shortest digits of the Float, Java layout).
    static func javaFloatString(_ f: Float) -> String {
        if f.isNaN { return "NaN" }
        if f.isInfinite { return f < 0 ? "-Infinity" : "Infinity" }
        // Swift's Float description is the shortest Float round-trip, as Java's (JDK 19+) is.
        guard let asDouble = Double("\(f)") else { return javaDoubleString(Double(f)) }
        return javaDoubleString(asDouble)
    }

    /// Lower-case hex of bytes.
    static func hex(_ bytes: [UInt8]) -> String {
        let digits: [Character] = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return out
    }

    /// RFC 4648 base64url without padding (`Base64.URL_SAFE | NO_PADDING | NO_WRAP`).
    static func base64URL(_ bytes: [UInt8]) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var out = ""
        var i = 0
        while i + 2 < bytes.count {
            let n = (UInt32(bytes[i]) << 16) | (UInt32(bytes[i + 1]) << 8) | UInt32(bytes[i + 2])
            out.append(alphabet[Int((n >> 18) & 63)])
            out.append(alphabet[Int((n >> 12) & 63)])
            out.append(alphabet[Int((n >> 6) & 63)])
            out.append(alphabet[Int(n & 63)])
            i += 3
        }
        let rest = bytes.count - i
        if rest == 1 {
            let n = UInt32(bytes[i]) << 16
            out.append(alphabet[Int((n >> 18) & 63)])
            out.append(alphabet[Int((n >> 12) & 63)])
        } else if rest == 2 {
            let n = (UInt32(bytes[i]) << 16) | (UInt32(bytes[i + 1]) << 8)
            out.append(alphabet[Int((n >> 18) & 63)])
            out.append(alphabet[Int((n >> 12) & 63)])
            out.append(alphabet[Int((n >> 6) & 63)])
        }
        return out
    }
}
