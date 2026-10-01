// Gson's `JsonElement` accessors (`getAsString`, `getAsDouble`, `getAsLong`, `getAsInt`, `getAsJsonObject`, …) over
// PixlFoundation's `JSONValue`, with Gson's conversions and failures, because the Android lyrics code reads provider
// JSON through Gson and its quirks decide what is accepted. Parse with `GsonJSON.parse` (PixlFoundation's kotlinx
// mode: like Gson's lenient reader it takes unquoted scalar tokens; single quotes, comments and unquoted keys —
// which Gson's lenient mode also takes — are rejected).

import Foundation
import PixlFoundation

/// A Gson accessor failure (Gson throws `IllegalStateException`, `UnsupportedOperationException`,
/// `NumberFormatException`, `ClassCastException` or a `NullPointerException` from a missing member).
struct GsonError: Error, Sendable {
    let message: String
}

enum GsonJSON {
    /// Parses a JSON document (any top-level value).
    static func parse(_ text: String) throws(GsonError) -> JSONValue {
        do {
            return try JSONParser(mode: .kotlinx, maxDepth: 512).parse(text)
        } catch {
            throw GsonError(message: error.description)
        }
    }

    /// `getAsJsonObject()`.
    static func object(_ value: JSONValue?) throws(GsonError) -> JSONObject {
        guard let value else { throw GsonError(message: "null") }
        guard case .object(let o) = value else { throw GsonError(message: "Not a JSON Object") }
        return o
    }

    /// `getAsJsonArray()`.
    static func array(_ value: JSONValue?) throws(GsonError) -> [JSONValue] {
        guard let value else { throw GsonError(message: "null") }
        guard case .array(let a) = value else { throw GsonError(message: "Not a JSON Array") }
        return a
    }

    /// `JsonObject.getAsJsonArray(member)`: nil when absent; a cast failure when present but not an array (JSON
    /// null included).
    static func optionalArray(_ object: JSONObject, _ member: String) throws(GsonError) -> [JSONValue]? {
        guard let value = object[member] else { return nil }
        guard case .array(let a) = value else { throw GsonError(message: "ClassCastException") }
        return a
    }

    /// `JsonObject.getAsJsonObject(member)`: nil when absent; a cast failure otherwise unless it is an object.
    static func optionalObject(_ object: JSONObject, _ member: String) throws(GsonError) -> JSONObject? {
        guard let value = object[member] else { return nil }
        guard case .object(let o) = value else { throw GsonError(message: "ClassCastException") }
        return o
    }

    /// `getAsString()`: strings, numbers (their literal), booleans, and a one-element array of those.
    static func string(_ value: JSONValue?) throws(GsonError) -> String {
        guard let value else { throw GsonError(message: "null") }
        switch value {
        case .string(let s): return s
        case .number(let literal): return literal
        case .bool(let b): return b ? "true" : "false"
        case .array(let items) where items.count == 1: return try string(items[0])
        default: throw GsonError(message: "Not a primitive")
        }
    }

    /// `getAsDouble()`: `Double.parseDouble` of the number literal or string.
    static func double(_ value: JSONValue?) throws(GsonError) -> Double {
        guard let value else { throw GsonError(message: "null") }
        switch value {
        case .number(let text), .string(let text):
            guard let d = ParseKit.parseDouble(text) else { throw GsonError(message: "NumberFormatException") }
            return d
        case .bool(let b):
            guard let d = ParseKit.parseDouble(b ? "true" : "false") else { throw GsonError(message: "NumberFormatException") }
            return d
        case .array(let items) where items.count == 1: return try double(items[0])
        default: throw GsonError(message: "Not a primitive")
        }
    }

    /// `getAsLong()`: numbers via `LazilyParsedNumber.longValue()` (`Long.parseLong`, else
    /// `BigDecimal(literal).longValue()` — truncating, wrapping); strings via `Long.parseLong`.
    static func long(_ value: JSONValue?) throws(GsonError) -> Int64 {
        guard let value else { throw GsonError(message: "null") }
        switch value {
        case .number(let literal):
            if let l = ParseKit.toLong(literal) { return l }
            guard let l = bigDecimalLongValue(literal) else { throw GsonError(message: "NumberFormatException") }
            return l
        case .string(let s):
            guard let l = ParseKit.toLong(s) else { throw GsonError(message: "NumberFormatException") }
            return l
        case .bool: throw GsonError(message: "NumberFormatException")
        case .array(let items) where items.count == 1: return try long(items[0])
        default: throw GsonError(message: "Not a primitive")
        }
    }

    /// `getAsInt()`: numbers keep the low 32 bits of their integer value; strings via `Integer.parseInt`.
    static func int(_ value: JSONValue?) throws(GsonError) -> Int32 {
        guard let value else { throw GsonError(message: "null") }
        switch value {
        case .number:
            return Int32(truncatingIfNeeded: try long(value))
        case .string(let s):
            guard let i = ParseKit.toInt(s) else { throw GsonError(message: "NumberFormatException") }
            return i
        case .bool: throw GsonError(message: "NumberFormatException")
        case .array(let items) where items.count == 1: return try int(items[0])
        default: throw GsonError(message: "Not a primitive")
        }
    }

    /// `new BigDecimal(literal).longValue()`: `[+-]digits[.digits][e[+-]digits]`, truncated toward zero, low 64 bits.
    static func bigDecimalLongValue(_ literal: String) -> Int64? {
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
}
