// Java number parsing and printing with the JVM's exact rules (the Android backup code goes through
// `Long.parseLong`, `Double.parseDouble`, `BigDecimal.longValue()` and `Float/Double.toString`).

import Foundation
import PixlFoundation

public enum JavaNumbers {
    /// `Long.parseLong` / Kotlin `toLongOrNull()`: optional `+`/`-`, then at least one decimal digit
    /// (`Character.digit`, so any Unicode Nd digit), no whitespace, no overflow.
    public static func parseLong<S: StringProtocol>(_ s: S) -> Int64? {
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
            let digit: Int64
            if scalar.value >= 0x30 && scalar.value <= 0x39 {
                digit = Int64(scalar.value - 0x30)
            } else {
                guard scalar.properties.generalCategory == .decimalNumber,
                      let n = scalar.properties.numericValue, n >= 0, n <= 9 else { return nil }
                digit = Int64(n)
            }
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (r, o2) = negative ? m.subtractingReportingOverflow(digit) : m.addingReportingOverflow(digit)
            if o1 || o2 { return nil }
            value = r
        }
        return value
    }

    /// `Integer.parseInt` / Kotlin `toIntOrNull()`.
    public static func parseInt<S: StringProtocol>(_ s: S) -> Int32? {
        guard let l = parseLong(s) else { return nil }
        return Int32(exactly: l)
    }

    /// `Double.parseDouble`: code units ≤ U+0020 trimmed; optional sign; `NaN`, `Infinity`, a decimal with an
    /// optional exponent, or a hexadecimal float (`0x1.8p3`); optional `f`/`F`/`d`/`D` suffix.
    public static func parseDouble<S: StringProtocol>(_ raw: S) -> Double? {
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
            return Double(sign + String(decoding: b, as: UTF8.self))
        }
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

    /// `new BigDecimal(literal).longValue()`: `[+-]digits[.digits][e[+-]digits]`, truncated toward zero, low 64 bits.
    public static func bigDecimalLongValue(_ literal: String) -> Int64? {
        var bytes = Array(literal.utf8)[...]
        var negative = false
        if let first = bytes.first, first == UInt8(ascii: "+") || first == UInt8(ascii: "-") {
            negative = first == UInt8(ascii: "-")
            bytes = bytes.dropFirst()
        }
        var digits: [UInt8] = []
        var fractionDigits = 0
        var seenDot = false
        while let c = bytes.first, (c >= 0x30 && c <= 0x39) || (c == UInt8(ascii: ".") && !seenDot) {
            if c == UInt8(ascii: ".") { seenDot = true } else {
                digits.append(c - 0x30)
                if seenDot { fractionDigits += 1 }
            }
            bytes = bytes.dropFirst()
        }
        guard !digits.isEmpty else { return nil }
        var exponent = 0
        if let e = bytes.first, e == UInt8(ascii: "e") || e == UInt8(ascii: "E") {
            bytes = bytes.dropFirst()
            var expNegative = false
            if let s = bytes.first, s == UInt8(ascii: "+") || s == UInt8(ascii: "-") {
                expNegative = s == UInt8(ascii: "-")
                bytes = bytes.dropFirst()
            }
            guard !bytes.isEmpty else { return nil }
            var value = 0
            for c in bytes {
                guard c >= 0x30 && c <= 0x39 else { return nil }
                value = min(value * 10 + Int(c - 0x30), 1_000_000_000)
            }
            exponent = expNegative ? -value : value
            bytes = bytes.dropFirst(bytes.count)
        }
        guard bytes.isEmpty else { return nil }
        let shift = exponent - fractionDigits
        var integerDigits = digits
        if shift >= 0 {
            // 10^64 ≡ 0 (mod 2^64): more trailing zeros cannot change the low 64 bits.
            integerDigits.append(contentsOf: repeatElement(0, count: min(shift, 64)))
        } else {
            integerDigits.removeLast(min(-shift, integerDigits.count))
        }
        var result: Int64 = 0
        for d in integerDigits { result = result &* 10 &+ Int64(d) }
        return negative ? 0 &- result : result
    }

    @inline(__always) static func isDecDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
    @inline(__always) static func isHexDigit(_ c: UInt8) -> Bool {
        isDecDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
    }
}

/// `Double.toString` / `Float.toString` (JDK 19+: the shortest decimal that rounds to the value): plain notation
/// for 10⁻³ ≤ |x| < 10⁷ with at least one fractional digit (`100.0`, `0.001`), otherwise computerised scientific
/// notation (`1.0E7`, `1.0E-4`, `3.4028235E38`). The digits come from Swift's shortest round-trip description,
/// which selects the same decimal for every normal value. (Java also considers two-digit decimals when the
/// shortest has one digit; that only changes subnormals such as `Double.MIN_VALUE`, which backups never hold.)
public enum JavaNumberText {
    public static func double(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
        if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
        return format(d.description, magnitude: abs(d) >= 1e-3 && abs(d) < 1e7)
    }

    public static func float(_ f: Float) -> String {
        if f.isNaN { return "NaN" }
        if f.isInfinite { return f < 0 ? "-Infinity" : "Infinity" }
        if f == 0 { return f.sign == .minus ? "-0.0" : "0.0" }
        return format(f.description, magnitude: abs(f) >= 1e-3 && abs(f) < 1e7)
    }

    /// Re-renders Swift's description (`123.45`, `1e-05`, `1.2345e+20`) in Java's notation.
    static func format(_ swift: String, magnitude plain: Bool) -> String {
        var text = Substring(swift)
        var negative = false
        if text.first == "-" {
            negative = true
            text = text.dropFirst()
        }
        var mantissa = text
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = text[..<e]
            exponent = Int(text[text.index(after: e)...].replacingOccurrences(of: "+", with: "")) ?? 0
        }
        // digits × 10^(pointPosition - digits.count), with leading zeros stripped.
        var digits = ""
        var pointPosition = 0
        var seenPoint = false
        for c in mantissa {
            if c == "." { seenPoint = true; continue }
            if digits.isEmpty && c == "0" {
                if seenPoint { pointPosition -= 1 }
                continue
            }
            digits.append(c)
            if !seenPoint { pointPosition += 1 }
        }
        while digits.count > 1 && digits.hasSuffix("0") { digits.removeLast() }
        if digits.isEmpty { return negative ? "-0.0" : "0.0" }
        // Scientific exponent: value = d.ddd × 10^sci.
        let sci = pointPosition + exponent - 1
        var out = negative ? "-" : ""
        let chars = Array(digits)
        if plain {
            if sci >= 0 {
                let intCount = sci + 1
                if chars.count <= intCount {
                    out += String(chars) + String(repeating: "0", count: intCount - chars.count) + ".0"
                } else {
                    out += String(chars[0..<intCount]) + "." + String(chars[intCount...])
                }
            } else {
                out += "0." + String(repeating: "0", count: -sci - 1) + String(chars)
            }
        } else {
            out += String(chars[0]) + "." + (chars.count > 1 ? String(chars[1...]) : "0") + "E" + String(sci)
        }
        return out
    }
}
