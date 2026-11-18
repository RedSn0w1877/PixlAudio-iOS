// The canonical text form the brain's records and golden vectors use (docs/brain-spec.md, 10.4): JSON with keys in
// a fixed order, no whitespace, Int64 values as decimal strings, doubles as 16-hex-digit bit patterns, and every
// character outside printable ASCII escaped as `\uXXXX` (UTF-16 units), so the bytes are the same whatever wrote
// them. A transliteration of the Android `:brain` module's `BrainJson.kt`.
//
// A writer and a small reader; no platform JSON library.

/// The brain's canonical JSON.
public enum BrainJson {
    static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    /// Builds one canonical JSON value. Keys are written in the order they are added.
    public struct Writer {
        private var out: [UInt8] = []
        private var needComma = false

        public init() { out.reserveCapacity(256) }

        /// The text written so far.
        public var text: String { String(decoding: out, as: UTF8.self) }

        private mutating func sep() {
            if needComma { out.append(0x2C) }
            needComma = true
        }

        private mutating func key(_ name: String) {
            sep()
            quote(name)
            out.append(0x3A)
        }

        private mutating func ascii(_ s: String) { out.append(contentsOf: s.utf8) }

        public mutating func beginObject() { sep(); out.append(0x7B); needComma = false }
        public mutating func beginObject(_ name: String) { key(name); out.append(0x7B); needComma = false }
        public mutating func endObject() { out.append(0x7D); needComma = true }
        public mutating func beginArray() { sep(); out.append(0x5B); needComma = false }
        public mutating func beginArray(_ name: String) { key(name); out.append(0x5B); needComma = false }
        public mutating func endArray() { out.append(0x5D); needComma = true }

        public mutating func int(_ name: String, _ value: Int32) { key(name); ascii(String(value)) }
        public mutating func int(_ name: String, _ value: Int) { key(name); ascii(String(value)) }
        public mutating func bool(_ name: String, _ value: Bool) { key(name); ascii(value ? "true" : "false") }
        public mutating func nullValue(_ name: String) { key(name); ascii("null") }

        /// An Int64 as a decimal string.
        public mutating func long(_ name: String, _ value: Int64) { key(name); quotedAscii(String(value)) }

        /// A double as its 16-hex-digit bit pattern.
        public mutating func double(_ name: String, _ value: Double) { key(name); quotedAscii(BrainJson.hex64(value.bitPattern)) }

        public mutating func string(_ name: String, _ value: String) { key(name); quote(value) }

        /// A value that is already canonical JSON (an encoded event, a nested object).
        public mutating func raw(_ name: String, _ json: String) { key(name); ascii(json) }
        public mutating func rawItem(_ json: String) { sep(); ascii(json) }

        public mutating func intItem(_ value: Int32) { sep(); ascii(String(value)) }
        public mutating func intItem(_ value: Int) { sep(); ascii(String(value)) }
        public mutating func longItem(_ value: Int64) { sep(); quotedAscii(String(value)) }
        public mutating func doubleItem(_ value: Double) { sep(); quotedAscii(BrainJson.hex64(value.bitPattern)) }
        public mutating func stringItem(_ value: String) { sep(); quote(value) }

        public mutating func longs(_ name: String, _ values: [Int64]) {
            beginArray(name)
            for v in values { longItem(v) }
            endArray()
        }

        public mutating func ints(_ name: String, _ values: [Int32]) {
            beginArray(name)
            for v in values { intItem(v) }
            endArray()
        }

        private mutating func quotedAscii(_ s: String) {
            out.append(0x22)
            out.append(contentsOf: s.utf8)
            out.append(0x22)
        }

        private mutating func quote(_ s: String) {
            out.append(0x22)
            for unit in s.utf16 {
                let c = UInt32(unit)
                if c == 0x22 {
                    out.append(0x5C); out.append(0x22)
                } else if c == 0x5C {
                    out.append(0x5C); out.append(0x5C)
                } else if c >= 0x20 && c <= 0x7E {
                    out.append(UInt8(c))
                } else {
                    out.append(0x5C); out.append(0x75)
                    out.append(BrainJson.hexDigits[Int((c >> 12) & 15)])
                    out.append(BrainJson.hexDigits[Int((c >> 8) & 15)])
                    out.append(BrainJson.hexDigits[Int((c >> 4) & 15)])
                    out.append(BrainJson.hexDigits[Int(c & 15)])
                }
            }
            out.append(0x22)
        }
    }

    public static func hex64(_ bits: UInt64) -> String {
        var chars = [UInt8](repeating: 0x30, count: 16)
        for i in 0..<16 { chars[i] = hexDigits[Int((bits >> UInt64((15 - i) * 4)) & 15)] }
        return String(decoding: chars, as: UTF8.self)
    }

    /// The value of a hexadecimal text; nil when a character is not a hex digit.
    public static func parseHex64(_ text: String) -> UInt64? {
        var v: UInt64 = 0
        for b in text.utf8 {
            guard let d = hexValue(UInt16(b)) else { return nil }
            v = (v << 4) | UInt64(d)
        }
        return v
    }

    static func hexValue(_ unit: UInt16) -> UInt16? {
        if unit >= 0x30 && unit <= 0x39 { return unit - 48 }
        if unit >= 0x61 && unit <= 0x66 { return unit - 87 }
        if unit >= 0x41 && unit <= 0x46 { return unit - 55 }
        return nil
    }

    public static func doubleOfHex(_ text: String) -> Double? { parseHex64(text).map { Double(bitPattern: $0) } }

    // MARK: Reader

    /// One parsed JSON value. A bare integer is `.long`; an Int64 written as a decimal string stays a `.string`.
    public enum Value: Sendable {
        case object([BrainKey: Value])
        case array([Value])
        case string(String)
        case long(Int64)
        case bool(Bool)
        case null

        /// The member `name` of an object; nil for anything else or when it is missing.
        public subscript(_ name: String) -> Value? {
            if case .object(let members) = self { return members[BrainKey(name)] }
            return nil
        }

        public var stringValue: String? {
            if case .string(let s) = self { return s }
            return nil
        }

        public var arrayValue: [Value]? {
            if case .array(let a) = self { return a }
            return nil
        }

        public var boolValue: Bool? {
            if case .bool(let b) = self { return b }
            return nil
        }

        /// A bare integer.
        public var bareLong: Int64? {
            if case .long(let v) = self { return v }
            return nil
        }

        /// An Int64 in either form: the canonical decimal string, or a bare integer.
        public var longValue: Int64? {
            switch self {
            case .string(let s): return Int64(s)
            case .long(let v): return v
            default: return nil
            }
        }

        /// A double written as its 16-hex-digit bit pattern.
        public var doubleValue: Double? {
            if case .string(let s) = self { return BrainJson.doubleOfHex(s) }
            return nil
        }

        public var isNull: Bool {
            if case .null = self { return true }
            return false
        }
    }

    public struct ParseError: Error, Sendable {
        public let message: String
    }

    /// Parses one JSON value. Bare numbers with a fraction or exponent are not part of the canonical form and are
    /// rejected.
    public static func parse(_ text: String) throws -> Value {
        var p = Parser(Array(text.utf16))
        p.skipSpace()
        let v = try p.value()
        p.skipSpace()
        if p.pos != p.s.count { throw ParseError(message: "trailing text at \(p.pos)") }
        return v
    }

    private struct Parser {
        let s: [UInt16]
        var pos = 0

        init(_ s: [UInt16]) { self.s = s }

        mutating func skipSpace() {
            while pos < s.count && (s[pos] == 0x20 || s[pos] == 0x0A || s[pos] == 0x0D || s[pos] == 0x09) { pos += 1 }
        }

        private func at(_ i: Int) throws -> UInt16 {
            if i >= s.count { throw ParseError(message: "unexpected end") }
            return s[i]
        }

        mutating func value() throws -> Value {
            let c = try at(pos)
            switch c {
            case 0x7B: return try obj()
            case 0x5B: return try arr()
            case 0x22: return .string(try str())
            case 0x74: try lit("true"); return .bool(true)
            case 0x66: try lit("false"); return .bool(false)
            case 0x6E: try lit("null"); return .null
            default:
                if c == 0x2D || (c >= 0x30 && c <= 0x39) { return .long(try num()) }
                throw ParseError(message: "bad value at \(pos)")
            }
        }

        private mutating func lit(_ word: String) throws {
            for unit in word.utf16 {
                if try at(pos) != unit { throw ParseError(message: "bad literal at \(pos)") }
                pos += 1
            }
        }

        private mutating func num() throws -> Int64 {
            let start = pos
            if s[pos] == 0x2D { pos += 1 }
            while pos < s.count && s[pos] >= 0x30 && s[pos] <= 0x39 { pos += 1 }
            guard let v = Int64(String(decoding: s[start..<pos], as: UTF16.self)) else {
                throw ParseError(message: "bad number at \(start)")
            }
            return v
        }

        private mutating func str() throws -> String {
            pos += 1 // opening quote
            var out: [UInt16] = []
            while true {
                let c = try at(pos)
                pos += 1
                if c == 0x22 { break }
                if c != 0x5C { out.append(c); continue }
                let e = try at(pos)
                pos += 1
                switch e {
                case 0x22: out.append(0x22)
                case 0x5C: out.append(0x5C)
                case 0x2F: out.append(0x2F)
                case 0x6E: out.append(0x0A)
                case 0x74: out.append(0x09)
                case 0x72: out.append(0x0D)
                case 0x62: out.append(0x08)
                case 0x66: out.append(0x0C)
                case 0x75:
                    var unit: UInt16 = 0
                    for _ in 0..<4 {
                        guard let d = BrainJson.hexValue(try at(pos)) else { throw ParseError(message: "bad hex at \(pos)") }
                        unit = (unit << 4) | d
                        pos += 1
                    }
                    out.append(unit)
                default: throw ParseError(message: "bad escape at \(pos)")
                }
            }
            return String(decoding: out, as: UTF16.self)
        }

        private mutating func obj() throws -> Value {
            pos += 1
            var out: [BrainKey: Value] = [:]
            skipSpace()
            if try at(pos) == 0x7D { pos += 1; return .object(out) }
            while true {
                skipSpace()
                if try at(pos) != 0x22 { throw ParseError(message: "expected a key at \(pos)") }
                let k = try str()
                skipSpace()
                if try at(pos) != 0x3A { throw ParseError(message: "expected : at \(pos)") }
                pos += 1
                skipSpace()
                out[BrainKey(k)] = try value()
                skipSpace()
                let c = try at(pos)
                pos += 1
                if c == 0x7D { break }
                if c != 0x2C { throw ParseError(message: "expected , at \(pos)") }
            }
            return .object(out)
        }

        private mutating func arr() throws -> Value {
            pos += 1
            var out: [Value] = []
            skipSpace()
            if try at(pos) == 0x5D { pos += 1; return .array(out) }
            while true {
                skipSpace()
                out.append(try value())
                skipSpace()
                let c = try at(pos)
                pos += 1
                if c == 0x5D { break }
                if c != 0x2C { throw ParseError(message: "expected , at \(pos)") }
            }
            return .array(out)
        }
    }
}
