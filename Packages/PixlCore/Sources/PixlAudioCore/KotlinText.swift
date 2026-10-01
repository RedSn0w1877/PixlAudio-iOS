// Kotlin text semantics the ReplayGain tag parser depends on: `String.trim()` (Char.isWhitespace) and
// `String.toFloatOrNull()` (Java `Float.parseFloat` grammar). Internal to PixlAudioCore.

import Foundation

enum KotlinText {
    /// Kotlin `Char.isWhitespace()`: Java `Character.isWhitespace || Character.isSpaceChar`, i.e. the Unicode space,
    /// line and paragraph separators plus U+0009…U+000D and U+001C…U+001F. Supplementary characters never are.
    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if (0x09...0x0D).contains(v) || (0x1C...0x1F).contains(v) { return true }
        if v > 0xFFFF { return false }
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    /// Kotlin `String.trim()`.
    static func trim(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isWhitespace($0) }) else { return "" }
        let last = scalars.lastIndex(where: { !isWhitespace($0) })!
        return String(scalars[first...last])
    }

    /// Kotlin `String.toFloatOrNull()`: the `Float.parseFloat` grammar (control characters and spaces ≤ U+0020
    /// around the number, optional sign, `NaN`, `Infinity`, decimal with optional exponent, hexadecimal with a binary
    /// exponent, optional `f`/`F`/`d`/`D` suffix after a number), rounded once to the nearest Float.
    static func toFloatOrNull(_ s: String) -> Float? {
        let bytes = Array(s.utf8)
        var lo = 0
        var hi = bytes.count
        while lo < hi && bytes[lo] <= 0x20 { lo += 1 }
        while hi > lo && bytes[hi - 1] <= 0x20 { hi -= 1 }
        guard lo < hi else { return nil }
        var i = lo
        var negative = false
        if bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") {
            negative = bytes[i] == UInt8(ascii: "-")
            i += 1
        }
        let rest = bytes[i..<hi]
        if rest.elementsEqual("NaN".utf8) { return .nan }
        if rest.elementsEqual("Infinity".utf8) { return negative ? -.infinity : .infinity }

        func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
        func isHex(_ b: UInt8) -> Bool {
            isDigit(b) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)
        }
        let numberStart = i
        var numberEnd = i
        if hi - i >= 2 && bytes[i] == UInt8(ascii: "0") && (bytes[i + 1] == UInt8(ascii: "x") || bytes[i + 1] == UInt8(ascii: "X")) {
            var j = i + 2
            var digits = 0
            while j < hi && isHex(bytes[j]) { j += 1; digits += 1 }
            if j < hi && bytes[j] == UInt8(ascii: ".") {
                j += 1
                while j < hi && isHex(bytes[j]) { j += 1; digits += 1 }
            }
            guard digits > 0, j < hi, bytes[j] == UInt8(ascii: "p") || bytes[j] == UInt8(ascii: "P") else { return nil }
            j += 1
            if j < hi && (bytes[j] == UInt8(ascii: "+") || bytes[j] == UInt8(ascii: "-")) { j += 1 }
            let expStart = j
            while j < hi && isDigit(bytes[j]) { j += 1 }
            guard j > expStart else { return nil }
            numberEnd = j
        } else {
            var j = i
            var digits = 0
            while j < hi && isDigit(bytes[j]) { j += 1; digits += 1 }
            if j < hi && bytes[j] == UInt8(ascii: ".") {
                j += 1
                while j < hi && isDigit(bytes[j]) { j += 1; digits += 1 }
            }
            guard digits > 0 else { return nil }
            if j < hi && (bytes[j] == UInt8(ascii: "e") || bytes[j] == UInt8(ascii: "E")) {
                j += 1
                if j < hi && (bytes[j] == UInt8(ascii: "+") || bytes[j] == UInt8(ascii: "-")) { j += 1 }
                let expStart = j
                while j < hi && isDigit(bytes[j]) { j += 1 }
                guard j > expStart else { return nil }
            }
            numberEnd = j
        }
        var end = numberEnd
        if end < hi {
            let b = bytes[end]
            if b == UInt8(ascii: "f") || b == UInt8(ascii: "F") || b == UInt8(ascii: "d") || b == UInt8(ascii: "D") { end += 1 }
        }
        guard end == hi else { return nil }
        // Lower-cased: some platform parsers only take "0x…p…" (Swift read "0X1P-2" as 0 on Windows).
        let literal = String(decoding: bytes[numberStart..<numberEnd], as: UTF8.self).lowercased()
        guard let magnitude = parseMagnitude(literal) else { return nil }
        return negative ? -magnitude : magnitude
    }

    /// Parses an unsigned literal already checked against the grammar. The standard library rounds once and maps
    /// out-of-range values to ∞ or 0, like Java.
    private static func parseMagnitude(_ literal: String) -> Float? { Float(literal) }
}
