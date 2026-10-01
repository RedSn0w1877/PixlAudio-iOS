// A small JSON value model, parser and writer. Pure Swift (no JSONSerialization/JSONDecoder), so it behaves the
// same on Windows and Apple platforms and lets PixlCore reproduce the Android app's kotlinx.serialization output
// byte for byte (key order, escaping, explicit nulls) — which Foundation's encoder cannot promise.

import Foundation

/// An immutable JSON value. Numbers keep their literal text so callers decide how strictly to read them.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    /// A number, stored as its literal. In `.kotlinx` parsing mode any other unquoted token also lands here (as
    /// kotlinx does when it skips unknown values); typed accessors reject such tokens.
    case number(String)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    /// A number literal for an integer.
    @inlinable
    public static func integer<T: BinaryInteger>(_ value: T) -> JSONValue { .number(String(value)) }

    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var objectValue: JSONObject? { if case .object(let o) = self { return o } else { return nil } }
    public var isNull: Bool { if case .null = self { return true } else { return false } }

    /// The value as a strict JSON integer (no fraction or exponent) in the Int64 range.
    public var int64Value: Int64? {
        guard case .number(let literal) = self, JSONGrammar.isStrictInteger(literal) else { return nil }
        return Int64(literal)
    }

    /// The value as a Double, for any valid JSON number literal.
    public var doubleValue: Double? {
        guard case .number(let literal) = self, JSONGrammar.isNumber(literal) else { return nil }
        return Double(literal)
    }

    /// Member lookup for objects (last occurrence wins, like kotlinx and most parsers).
    public subscript(key: String) -> JSONValue? { objectValue?[key] }
}

/// A JSON object that keeps member order (and duplicates) as written.
public struct JSONObject: Sendable, Hashable, Sequence {
    public var members: [(key: String, value: JSONValue)]

    public init(_ members: [(key: String, value: JSONValue)] = []) { self.members = members }

    /// The last member with this key.
    public subscript(key: String) -> JSONValue? {
        for member in members.reversed() where member.key.isIdentical(to: key) { return member.value }
        return nil
    }

    /// Appends a member (use for building output in a fixed key order).
    public mutating func append(_ key: String, _ value: JSONValue) { members.append((key, value)) }

    public func makeIterator() -> IndexingIterator<[(key: String, value: JSONValue)]> { members.makeIterator() }

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        lhs.members.count == rhs.members.count
            && zip(lhs.members, rhs.members).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(members.count)
        for member in members {
            hasher.combine(member.key)
            hasher.combine(member.value)
        }
    }
}

/// A JSON syntax error with the UTF-8 byte offset where it was found.
public struct JSONParseError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public let offset: Int
    public var description: String { "JSON error at byte \(offset): \(message)" }
}

/// Parses JSON text.
public struct JSONParser: Sendable {
    public enum Mode: Sendable {
        /// RFC 8259: literals must be `true`, `false`, `null` or a valid number; control characters must be escaped.
        case strict
        /// kotlinx.serialization's default (non-lenient) `Json` reader: like strict, but any unquoted token is
        /// accepted as a value (typed readers reject bad ones later, unknown keys just skip them) and raw control
        /// characters are allowed inside strings.
        case kotlinx
    }

    public var mode: Mode
    /// Maximum nesting of arrays/objects.
    public var maxDepth: Int

    public init(mode: Mode = .strict, maxDepth: Int = 512) {
        self.mode = mode
        self.maxDepth = maxDepth
    }

    /// Parses a complete document; only whitespace may follow the value.
    public func parse(_ text: String) throws(JSONParseError) -> JSONValue {
        try Self.parse(bytes: Array(text.utf8), mode: mode, maxDepth: maxDepth)
    }

    /// Parses UTF-8 bytes.
    public func parse(utf8 data: [UInt8]) throws(JSONParseError) -> JSONValue {
        try Self.parse(bytes: data, mode: mode, maxDepth: maxDepth)
    }

    private static func parse(bytes: [UInt8], mode: Mode, maxDepth: Int) throws(JSONParseError) -> JSONValue {
        var reader = Reader(bytes: bytes, mode: mode, maxDepth: maxDepth)
        reader.skipWhitespace()
        let value = try reader.readValue(depth: 0)
        reader.skipWhitespace()
        if reader.index != reader.bytes.count { throw reader.error("Unexpected trailing content") }
        return value
    }

    private struct Reader {
        let bytes: [UInt8]
        let mode: Mode
        let maxDepth: Int
        var index = 0

        init(bytes: [UInt8], mode: Mode, maxDepth: Int) {
            self.bytes = bytes
            self.mode = mode
            self.maxDepth = maxDepth
        }

        func error(_ message: String) -> JSONParseError { JSONParseError(message: message, offset: index) }

        mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                default: return
                }
            }
        }

        mutating func readValue(depth: Int) throws(JSONParseError) -> JSONValue {
            guard index < bytes.count else { throw error("Unexpected end of input") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try readObject(depth: depth + 1)
            case UInt8(ascii: "["): return try readArray(depth: depth + 1)
            case UInt8(ascii: "\""): return .string(try readString())
            default: return try readLiteral()
            }
        }

        mutating func readObject(depth: Int) throws(JSONParseError) -> JSONValue {
            if depth > maxDepth { throw error("Nesting too deep") }
            index += 1 // {
            var object = JSONObject()
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(object)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("Expected a quoted key") }
                let key = try readString()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("Expected ':'") }
                index += 1
                skipWhitespace()
                let value = try readValue(depth: depth)
                object.append(key, value)
                skipWhitespace()
                guard index < bytes.count else { throw error("Unterminated object") }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                if bytes[index] == UInt8(ascii: "}") {
                    index += 1
                    return .object(object)
                }
                throw error("Expected ',' or '}'")
            }
        }

        mutating func readArray(depth: Int) throws(JSONParseError) -> JSONValue {
            if depth > maxDepth { throw error("Nesting too deep") }
            index += 1 // [
            var items: [JSONValue] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }
            while true {
                skipWhitespace()
                items.append(try readValue(depth: depth))
                skipWhitespace()
                guard index < bytes.count else { throw error("Unterminated array") }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                if bytes[index] == UInt8(ascii: "]") {
                    index += 1
                    return .array(items)
                }
                throw error("Expected ',' or ']'")
            }
        }

        mutating func readString() throws(JSONParseError) -> String {
            index += 1 // opening quote
            var out: [UInt8] = []
            var runStart = index
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    out.append(contentsOf: bytes[runStart..<index])
                    index += 1
                    return String(decoding: out, as: UTF8.self)
                }
                if byte == UInt8(ascii: "\\") {
                    out.append(contentsOf: bytes[runStart..<index])
                    try readEscape(into: &out)
                    runStart = index
                    continue
                }
                if byte < 0x20, mode == .strict { throw error("Unescaped control character in string") }
                index += 1
            }
            throw error("Unterminated string")
        }

        mutating func readEscape(into out: inout [UInt8]) throws(JSONParseError) {
            index += 1 // backslash
            guard index < bytes.count else { throw error("Unterminated escape") }
            let c = bytes[index]
            index += 1
            switch c {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                let unit = try readHex4()
                var scalarValue = UInt32(unit)
                if (0xD800...0xDBFF).contains(unit) {
                    // High surrogate: combine with a following \uDC00-\uDFFF escape when present.
                    if index + 5 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        let save = index
                        index += 2
                        let low = try readHex4()
                        if (0xDC00...0xDFFF).contains(low) {
                            scalarValue = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                        } else {
                            index = save
                            scalarValue = 0xFFFD
                        }
                    } else {
                        scalarValue = 0xFFFD
                    }
                } else if (0xDC00...0xDFFF).contains(unit) {
                    scalarValue = 0xFFFD // lone low surrogate: not representable in a Swift String
                }
                let scalar = Unicode.Scalar(scalarValue) ?? "\u{FFFD}"
                out.append(contentsOf: Array(String(Character(scalar)).utf8))
            default:
                index -= 1
                throw error("Invalid escape character")
            }
        }

        mutating func readHex4() throws(JSONParseError) -> UInt16 {
            guard index + 4 <= bytes.count else { throw error("Truncated \\u escape") }
            var value: UInt16 = 0
            for _ in 0..<4 {
                let c = bytes[index]
                let digit: UInt16
                switch c {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt16(c - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt16(c - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt16(c - UInt8(ascii: "A") + 10)
                default: throw error("Invalid hex digit in \\u escape")
                }
                value = value << 4 | digit
                index += 1
            }
            return value
        }

        mutating func readLiteral() throws(JSONParseError) -> JSONValue {
            let start = index
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D, UInt8(ascii: ","), UInt8(ascii: ":"), UInt8(ascii: "{"),
                     UInt8(ascii: "}"), UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "\""):
                    break
                default:
                    index += 1
                    continue
                }
                break
            }
            guard index > start else { throw error("Expected a value") }
            let token = String(decoding: bytes[start..<index], as: UTF8.self)
            switch token {
            case "null": return .null
            case "true": return .bool(true)
            case "false": return .bool(false)
            default:
                if mode == .strict, !JSONGrammar.isNumber(token) {
                    index = start
                    throw error("Invalid literal '\(token)'")
                }
                return .number(token)
            }
        }
    }
}

/// JSON number grammar checks.
public enum JSONGrammar {
    /// RFC 8259 number: `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`.
    public static func isNumber(_ literal: String) -> Bool {
        var it = Array(literal.utf8)[...]
        if it.first == UInt8(ascii: "-") { it = it.dropFirst() }
        guard let first = it.first, isDigit(first) else { return false }
        if first == UInt8(ascii: "0") {
            it = it.dropFirst()
        } else {
            while let c = it.first, isDigit(c) { it = it.dropFirst() }
        }
        if it.first == UInt8(ascii: ".") {
            it = it.dropFirst()
            guard let c = it.first, isDigit(c) else { return false }
            while let c = it.first, isDigit(c) { it = it.dropFirst() }
        }
        if let e = it.first, e == UInt8(ascii: "e") || e == UInt8(ascii: "E") {
            it = it.dropFirst()
            if let s = it.first, s == UInt8(ascii: "+") || s == UInt8(ascii: "-") { it = it.dropFirst() }
            guard let c = it.first, isDigit(c) else { return false }
            while let c = it.first, isDigit(c) { it = it.dropFirst() }
        }
        return it.isEmpty
    }

    /// A number literal with no fraction or exponent.
    public static func isStrictInteger(_ literal: String) -> Bool {
        isNumber(literal) && !literal.utf8.contains(where: { $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "e") || $0 == UInt8(ascii: "E") })
    }

    @inlinable
    static func isDigit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }
}

// MARK: - Writing

/// Writes JSON the way kotlinx.serialization's default `Json` does: compact (no whitespace), members in the given
/// order, and strings escaped with kotlinx's table — `"` `\` and C0 controls only (`\b \t \n \f \r` short forms,
/// other controls as lowercase `\u00xx`); `/`, DEL, U+2028/2029 and all non-ASCII are written raw.
public enum JSONWriter {
    public static func write(_ value: JSONValue) -> String {
        var out = ""
        write(value, into: &out)
        return out
    }

    public static func write(_ value: JSONValue, into out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let literal): out += literal
        case .string(let s): writeString(s, into: &out)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case .object(let object):
            out += "{"
            for (i, member) in object.members.enumerated() {
                if i > 0 { out += "," }
                writeString(member.key, into: &out)
                out += ":"
                write(member.value, into: &out)
            }
            out += "}"
        }
    }

    /// A quoted, kotlinx-escaped string.
    public static func writeString(_ s: String, into out: inout String) {
        out += "\""
        var scalars = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x22: scalars.append(contentsOf: "\\\"".unicodeScalars)
            case 0x5C: scalars.append(contentsOf: "\\\\".unicodeScalars)
            case 0x08: scalars.append(contentsOf: "\\b".unicodeScalars)
            case 0x09: scalars.append(contentsOf: "\\t".unicodeScalars)
            case 0x0A: scalars.append(contentsOf: "\\n".unicodeScalars)
            case 0x0C: scalars.append(contentsOf: "\\f".unicodeScalars)
            case 0x0D: scalars.append(contentsOf: "\\r".unicodeScalars)
            case 0x00..<0x20:
                let hex = String(scalar.value, radix: 16)
                scalars.append(contentsOf: ("\\u" + String(repeating: "0", count: 4 - hex.count) + hex).unicodeScalars)
            default: scalars.append(scalar)
            }
        }
        out += String(scalars)
        out += "\""
    }
}

// MARK: - kotlinx.serialization readers

/// Reads JSON values with kotlinx.serialization's (non-lenient, default `Json`) rules for primitive fields.
public enum KotlinxJSON {
    /// kotlinx `decodeLong`: an unquoted or **quoted** numeric literal (`consumeNumericLiteral`). Digits with an
    /// optional leading `-`, leading zeros allowed, an optional exponent (`e`/`E`, `+`/`-`) whose result must be a
    /// whole number in the Long range; no fraction, no `+` sign on the mantissa.
    public static func long(_ value: JSONValue) -> Int64? {
        switch value {
        case .number(let literal): return parseNumericLiteral(literal)
        case .string(let literal): return parseNumericLiteral(literal)
        default: return nil
        }
    }

    /// kotlinx `decodeInt`: `long` that must fit in 32 bits.
    public static func int(_ value: JSONValue) -> Int32? {
        guard let l = long(value), let i = Int32(exactly: l) else { return nil }
        return i
    }

    /// kotlinx `decodeString` (non-lenient): only a quoted string.
    public static func string(_ value: JSONValue) -> String? { value.stringValue }

    /// kotlinx `decodeBoolean` (non-lenient): `true`/`false` unquoted.
    public static func bool(_ value: JSONValue) -> Bool? { value.boolValue }

    /// Port of `AbstractJsonLexer.consumeNumericLiteral` applied to the token text.
    public static func parseNumericLiteral(_ literal: String) -> Int64? {
        let chars = Array(literal.utf8)
        var accumulator: Int64 = 0
        var exponentAccumulator: Int64 = 0
        var isNegative = false
        var isExponentPositive = false
        var hasExponent = false
        var current = 0
        let start = 0
        while current < chars.count {
            let ch = chars[current]
            if (ch == UInt8(ascii: "e") || ch == UInt8(ascii: "E")) && !hasExponent {
                if current == start { return nil }
                isExponentPositive = true
                hasExponent = true
                current += 1
                continue
            }
            if ch == UInt8(ascii: "-") && hasExponent {
                if current == start { return nil }
                isExponentPositive = false
                current += 1
                continue
            }
            if ch == UInt8(ascii: "+") && hasExponent {
                if current == start { return nil }
                isExponentPositive = true
                current += 1
                continue
            }
            if ch == UInt8(ascii: "-") {
                if current != start { return nil }
                isNegative = true
                current += 1
                continue
            }
            // Token boundaries never reach here (the parser split on them); a quote or space inside a quoted
            // literal ends the number in kotlinx and then fails the closing-quote check.
            guard ch >= UInt8(ascii: "0"), ch <= UInt8(ascii: "9") else { return nil }
            current += 1
            let digit = Int64(ch - UInt8(ascii: "0"))
            if hasExponent {
                exponentAccumulator = exponentAccumulator &* 10 &+ digit
                continue
            }
            accumulator = accumulator &* 10 &- digit
            if accumulator > 0 { return nil } // overflow
        }
        if current == start || (isNegative && start == current - 1) { return nil }
        if hasExponent {
            let exponent = isExponentPositive
                ? pow(10.0, Double(exponentAccumulator))
                : pow(10.0, -Double(exponentAccumulator))
            let doubleAccumulator = Double(accumulator) * exponent
            if doubleAccumulator > Double(Int64.max) || doubleAccumulator < Double(Int64.min) { return nil }
            if doubleAccumulator.rounded(.down) != doubleAccumulator { return nil }
            accumulator = KotlinMath.toLong(doubleAccumulator)
        }
        if isNegative { return accumulator }
        if accumulator != Int64.min { return -accumulator }
        return nil
    }
}
