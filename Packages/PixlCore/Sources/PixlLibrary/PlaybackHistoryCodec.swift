// `playback_history.json` in Android's exact format: what `PlaybackStatsRepository` writes with Gson
// (`serializeEvents`: sanitised events, fields in declaration order, Gson's HTML-safe string escaping) and how it
// reads it back (`parseEvents`: Gson's coercions — numbers into strings, quoted or fractional numbers into longs,
// missing longs as 0 — and Android's all-or-nothing failure: one unreadable event discards the whole file).
//
// Deviation: Gson also accepts its lenient syntax (comments, single quotes, unquoted names); this reader takes
// standard JSON only. Android itself never writes the lenient forms.

import Foundation
import PixlFoundation

public enum PlaybackHistoryCodec {
    /// The file name in the app's data folder.
    public static let fileName = "playback_history.json"

    struct Failure: Error {}

    // MARK: Decoding

    /// `parseEvents`: the sanitised events, or `[]` for blank, invalid or unreadable content.
    public static func decode(_ text: String?) -> [PlaybackEvent] {
        guard let text, !text.isKotlinBlank else { return [] }
        guard let root = try? JSONParser(mode: .strict, maxDepth: 512).parse(text) else { return [] }
        guard case .array(let items) = root else { return [] }
        do {
            return try items.map { item -> PlaybackEvent in
                guard case .object(let object) = item else { throw Failure() }
                return PlaybackStats.sanitize(try event(object))
            }
        } catch {
            return []
        }
    }

    /// Decodes UTF-8 bytes (invalid sequences become U+FFFD, as Java's reader does).
    public static func decode(utf8 data: [UInt8]) -> [PlaybackEvent] { decode(String(decoding: data, as: UTF8.self)) }

    private static func event(_ object: JSONObject) throws -> PlaybackEvent {
        guard let songIdValue = object["songId"], let songId = try gsonString(songIdValue) else { throw Failure() }
        return PlaybackEvent(songId: songId,
                             timestamp: try object["timestamp"].map(gsonLong) ?? 0,
                             durationMs: try object["durationMs"].map(gsonLong) ?? 0,
                             startTimestamp: try object["startTimestamp"].flatMap(gsonOptionalLong),
                             endTimestamp: try object["endTimestamp"].flatMap(gsonOptionalLong))
    }

    /// Gson's `String` adapter: strings as is, numbers as their literal, booleans as "true"/"false", null as nil.
    static func gsonString(_ value: JSONValue) throws -> String? {
        switch value {
        case .null: return nil
        case .string(let s): return s
        case .number(let literal): return literal
        case .bool(let b): return b ? "true" : "false"
        case .array, .object: throw Failure()
        }
    }

    /// A primitive `long` field: null leaves the default 0.
    static func gsonLong(_ value: JSONValue) throws -> Int64 { try gsonOptionalLong(value) ?? 0 }

    /// A `Long?` field (`JsonPrimitive.getAsLong()`).
    static func gsonOptionalLong(_ value: JSONValue) throws -> Int64? {
        switch value {
        case .null: return nil
        case .number(let literal):
            guard let v = bigDecimalLongValue(literal) else { throw Failure() }
            return v
        case .string(let s):
            guard let v = javaParseLong(s) else { throw Failure() }
            return v
        case .bool, .array, .object: throw Failure()
        }
    }

    /// `Long.parseLong`: optional sign, ASCII digits, in range.
    static func javaParseLong(_ s: String) -> Int64? {
        let bytes = Array(s.utf8)
        guard !bytes.isEmpty else { return nil }
        var i = 0
        var negative = false
        if bytes[0] == UInt8(ascii: "-") || bytes[0] == UInt8(ascii: "+") {
            negative = bytes[0] == UInt8(ascii: "-")
            i = 1
            guard bytes.count > 1 else { return nil }
        }
        var result: Int64 = 0
        while i < bytes.count {
            let b = bytes[i]
            guard b >= 0x30, b <= 0x39 else { return nil }
            let (m, o1) = result.multipliedReportingOverflow(by: 10)
            let (r, o2) = negative ? m.subtractingReportingOverflow(Int64(b - 0x30)) : m.addingReportingOverflow(Int64(b - 0x30))
            if o1 || o2 { return nil }
            result = r
            i += 1
        }
        return result
    }

    /// `LazilyParsedNumber.longValue()`: `Long.parseLong`, else `BigDecimal(literal).longValue()` — truncated
    /// toward zero and wrapped to the low 64 bits. Nil when the literal is not a decimal number.
    static func bigDecimalLongValue(_ literal: String) -> Int64? {
        if let exact = javaParseLong(literal) { return exact }
        let bytes = Array(literal.utf8)
        var i = 0
        var negative = false
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") || bytes[i] == UInt8(ascii: "+") {
            negative = bytes[i] == UInt8(ascii: "-")
            i += 1
        }
        var digits: [UInt8] = []
        var fractionDigits = 0
        var sawDigit = false
        while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 { digits.append(bytes[i] - 0x30); sawDigit = true; i += 1 }
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            i += 1
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                digits.append(bytes[i] - 0x30)
                fractionDigits += 1
                sawDigit = true
                i += 1
            }
        }
        guard sawDigit else { return nil }
        var exponent = 0
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            i += 1
            var expNegative = false
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") || bytes[i] == UInt8(ascii: "+") {
                expNegative = bytes[i] == UInt8(ascii: "-")
                i += 1
            }
            var sawExp = false
            var e = 0
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                e = min(e * 10 + Int(bytes[i] - 0x30), 1_000_000_000)
                sawExp = true
                i += 1
            }
            guard sawExp else { return nil }
            exponent = expNegative ? -e : e
        }
        guard i == bytes.count else { return nil }
        let scale = exponent - fractionDigits
        var integerDigits = digits
        var trailingZeros = 0
        if scale < 0 {
            let drop = -scale
            integerDigits = drop >= digits.count ? [] : Array(digits[..<(digits.count - drop)])
        } else {
            trailingZeros = scale
        }
        var magnitude: UInt64 = 0
        for d in integerDigits { magnitude = magnitude &* 10 &+ UInt64(d) }
        // 10^k ≡ 0 (mod 2^64) once k ≥ 64.
        for _ in 0..<min(trailingZeros, 64) { magnitude = magnitude &* 10 }
        let value = Int64(bitPattern: magnitude)
        return negative ? 0 &- value : value
    }

    // MARK: Encoding

    /// `serializeEvents`: sanitises and writes the events exactly as Gson does.
    public static func encode(_ events: [PlaybackEvent]) -> String {
        var out = "["
        for (index, raw) in events.enumerated() {
            let event = PlaybackStats.sanitize(raw)
            if index > 0 { out += "," }
            out += "{\"songId\":"
            writeGsonString(event.songId, into: &out)
            out += ",\"timestamp\":\(event.timestamp),\"durationMs\":\(event.durationMs)"
            if let start = event.startTimestamp { out += ",\"startTimestamp\":\(start)" }
            if let end = event.endTimestamp { out += ",\"endTimestamp\":\(end)" }
            out += "}"
        }
        return out + "]"
    }

    /// The file contents as UTF-8.
    public static func encodeUTF8(_ events: [PlaybackEvent]) -> [UInt8] { Array(encode(events).utf8) }

    /// Gson `JsonWriter` with HTML-safe escaping: `"` `\` and C0 controls (`\t \b \n \r \f` short, others
    /// `\u00xx`), `< > & = '` and U+2028/U+2029 as `\uXXXX`; everything else raw.
    static func writeGsonString(_ s: String, into out: inout String) {
        out += "\""
        var scalars = String.UnicodeScalarView()
        func hex(_ v: UInt32) {
            let h = String(v, radix: 16)
            scalars.append(contentsOf: ("\\u" + String(repeating: "0", count: 4 - h.count) + h).unicodeScalars)
        }
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x22: scalars.append(contentsOf: "\\\"".unicodeScalars)
            case 0x5C: scalars.append(contentsOf: "\\\\".unicodeScalars)
            case 0x09: scalars.append(contentsOf: "\\t".unicodeScalars)
            case 0x08: scalars.append(contentsOf: "\\b".unicodeScalars)
            case 0x0A: scalars.append(contentsOf: "\\n".unicodeScalars)
            case 0x0D: scalars.append(contentsOf: "\\r".unicodeScalars)
            case 0x0C: scalars.append(contentsOf: "\\f".unicodeScalars)
            case 0x00..<0x20, 0x3C, 0x3E, 0x26, 0x3D, 0x27, 0x2028, 0x2029: hex(scalar.value)
            default: scalars.append(scalar)
            }
        }
        out += String(scalars)
        out += "\""
    }
}
