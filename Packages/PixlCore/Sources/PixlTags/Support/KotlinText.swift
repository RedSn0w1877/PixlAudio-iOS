// The Kotlin/JVM string and number operations the Android metadata code relies on, with the same semantics
// (`toIntOrNull`, `toFloatOrNull`, `String.format(Locale.US, "%.2f", f)`, the ReplayGain regexes).

import Foundation
import PixlFoundation

enum KotlinText {
    /// Kotlin `String.toIntOrNull()`: optional `+`/`-`, then at least one decimal digit (`Character.digit`, so any
    /// Unicode Nd digit), no overflow.
    static func toIntOrNull<S: StringProtocol>(_ s: S) -> Int? {
        var scalars = Substring(s).unicodeScalars[...]
        guard let first = scalars.first else { return nil }
        var negative = false
        if first == "-" || first == "+" {
            negative = first == "-"
            scalars = scalars.dropFirst()
            if scalars.isEmpty { return nil }
        }
        var value: Int32 = 0
        for scalar in scalars {
            guard scalar.properties.generalCategory == .decimalNumber,
                  let digit = scalar.properties.numericValue, digit >= 0, digit <= 9 else { return nil }
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (r, o2) = negative ? m.subtractingReportingOverflow(Int32(digit)) : m.addingReportingOverflow(Int32(digit))
            if o1 || o2 { return nil }
            value = r
        }
        return Int(value)
    }

    /// Kotlin `String.toFloatOrNull()`: the Java floating-point literal grammar (`Float.parseFloat`): characters
    /// ≤ U+0020 around the literal are ignored; optional sign; `NaN`, `Infinity`, a decimal with optional exponent or
    /// a hexadecimal float; optional `f`/`F`/`d`/`D` suffix. Correctly rounded to `Float`.
    static func toFloatOrNull<S: StringProtocol>(_ raw: S) -> Float? {
        var bytes = Array(raw.utf8)[...]
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
        var text: String
        if isHex {
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
            // Swift's parser wants a lower-case "0x"; the exponent letter may be either case.
            text = "0x" + String(decoding: b.dropFirst(2), as: UTF8.self).replacingOccurrences(of: "P", with: "p")
        } else {
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
            text = String(decoding: b, as: UTF8.self)
            if text.hasPrefix(".") { text = "0" + text }
            text = text.replacingOccurrences(of: ".e", with: ".0e").replacingOccurrences(of: ".E", with: ".0E")
            if text.hasSuffix(".") { text += "0" }
        }
        if let f = Float(sign + text) { return f }
        // Out of the Float range: Java yields ±Infinity or ±0.
        if let d = Double(sign + text) { return Float(d) }
        return nil
    }

    @inline(__always) private static func isDecDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
    @inline(__always) private static func isHexDigit(_ c: UInt8) -> Bool {
        isDecDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
    }

    /// Java `String.format(Locale.US, "%.2f", value)` for a `Float` argument: the float is widened to double, its
    /// shortest decimal digits are rounded half-up at the second decimal (Java's `FormattedFloatingDecimal`), and the
    /// sign follows the value (`-0.001` → `"-0.00"`).
    static func formatFixed2(_ value: Float) -> String { formatFixed(Double(value), precision: 2) }

    static func formatFixed(_ d: Double, precision: Int) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
        let negative = d < 0 || (d == 0 && d.sign == .minus)
        var (digits, exponent) = shortestDigits(Swift.abs(d))
        // Value = 0.d1 d2 d3 … × 10^exponent. Keep `exponent + precision` digits, rounding half-up on the next one.
        let keep = exponent + precision
        if keep < 0 {
            digits = []
        } else if keep < digits.count {
            let roundUp = digits[keep] >= 5
            digits = Array(digits[0..<keep])
            if roundUp {
                var i = digits.count - 1
                while i >= 0 {
                    if digits[i] == 9 { digits[i] = 0; i -= 1 } else { digits[i] += 1; break }
                }
                if i < 0 { digits.insert(1, at: 0); exponent += 1 }
            }
        }
        // Lay the digits out around the decimal point.
        var intPart = ""
        var fracPart = ""
        for position in 0..<Swift.max(exponent, 0) {
            intPart.append(position < digits.count ? Character(String(digits[position])) : "0")
        }
        if intPart.isEmpty { intPart = "0" }
        for k in 0..<precision {
            let position = exponent + k
            if position >= 0 && position < digits.count {
                fracPart.append(Character(String(digits[position])))
            } else {
                fracPart.append("0")
            }
        }
        return (negative ? "-" : "") + intPart + (precision > 0 ? "." + fracPart : "")
    }

    /// The shortest round-trip decimal digits of a finite non-negative double and the exponent `e` such that the
    /// value is `0.d1d2… × 10^e`. Zero gives no digits.
    static func shortestDigits(_ d: Double) -> ([Int], Int) {
        if d == 0 { return ([], 0) }
        let text = "\(d)"
        var mantissa = Substring(text)
        var exp10 = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = text[..<e]
            exp10 = Int(text[text.index(after: e)...].replacingOccurrences(of: "+", with: "")) ?? 0
        }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let intDigits = parts.first.map(String.init) ?? ""
        let fracDigits = parts.count > 1 ? String(parts[1]) : ""
        var digits = (intDigits + fracDigits).compactMap { $0.wholeNumberValue }
        var exponent = intDigits.count + exp10
        while let first = digits.first, first == 0 { digits.removeFirst(); exponent -= 1 }
        while let last = digits.last, last == 0 { digits.removeLast() }
        return (digits, exponent)
    }

    /// Removes every ASCII `d`/`D` immediately followed by `b`/`B` (`replace(Regex("[dD][bB]"), "")`).
    static func removingDb(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            if i + 1 < scalars.count, scalars[i] == "d" || scalars[i] == "D", scalars[i + 1] == "b" || scalars[i + 1] == "B" {
                i += 2
                continue
            }
            out.append(scalars[i])
            i += 1
        }
        return String(out)
    }

    /// Java regex `\s`: `[ \t\n\x0B\f\r]`.
    static func isJavaRegexSpace(_ u: Unicode.Scalar) -> Bool {
        u == " " || u == "\t" || u == "\n" || u == "\u{0B}" || u == "\u{0C}" || u == "\r"
    }

    /// `replace(Regex("(?i)\\s*d\\s*b\\s*$"), "")`: drops a trailing "dB" unit with any surrounding whitespace.
    static func removingTrailingDbUnit(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        var end = scalars.count
        // `$` also matches before one final line terminator.
        var limit = end
        if limit > 0 {
            let last = scalars[limit - 1]
            if last == "\n" {
                limit -= 1
                if limit > 0, scalars[limit - 1] == "\r" { limit -= 1 }
            } else if last == "\r" || last == "\u{85}" || last == "\u{2028}" || last == "\u{2029}" {
                limit -= 1
            }
        }
        for candidateEnd in Set([end, limit]).sorted(by: >) {
            var i = candidateEnd
            while i > 0, isJavaRegexSpace(scalars[i - 1]) { i -= 1 }
            guard i > 0, scalars[i - 1] == "b" || scalars[i - 1] == "B" else { continue }
            i -= 1
            while i > 0, isJavaRegexSpace(scalars[i - 1]) { i -= 1 }
            guard i > 0, scalars[i - 1] == "d" || scalars[i - 1] == "D" else { continue }
            i -= 1
            while i > 0, isJavaRegexSpace(scalars[i - 1]) { i -= 1 }
            end = i
            var out = String.UnicodeScalarView()
            out.append(contentsOf: scalars[0..<end])
            out.append(contentsOf: scalars[candidateEnd..<scalars.count])
            return String(out)
        }
        return s
    }

    /// Kotlin `replace(',', '.')` (per character, no canonical-equivalence matching).
    static func replacingCommas(_ s: String) -> String {
        guard s.utf8.contains(UInt8(ascii: ",")) else { return s }
        return String(String.UnicodeScalarView(s.unicodeScalars.map { $0 == "," ? "." : $0 }))
    }

    /// Kotlin `substringBefore('/')`.
    static func substringBeforeSlash(_ s: String) -> String {
        guard let i = s.firstIndex(of: "/") else { return s }
        return String(s[..<i])
    }

    /// Kotlin `take(n)` (UTF-16 code units).
    static func take(_ s: String, _ n: Int) -> String {
        let units = Array(s.utf16.prefix(n))
        return String(decoding: units, as: UTF16.self)
    }

    /// Kotlin `isNullOrBlank()`.
    static func isNullOrBlank(_ s: String?) -> Bool { s?.isKotlinBlank ?? true }
}
