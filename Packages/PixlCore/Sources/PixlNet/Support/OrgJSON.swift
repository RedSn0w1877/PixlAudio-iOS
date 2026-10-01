// Android's `org.json` reading semantics over PixlFoundation's ordered JSON model. The InnerTube and Piped ports
// read responses through these so `optString`/`optInt`/`optBoolean` coerce exactly as on Android (numbers become
// their Java text, numeric strings become ints, JSON null reads as the string "null"), and object members iterate
// in document order with a duplicate key keeping its first position and its last value (LinkedHashMap.put).

import Foundation
import PixlFoundation

/// Android `org.json` accessors.
public enum OrgJSON {
    /// Parses a JSON document (strict RFC 8259; InnerTube/Piped always send that).
    public static func parse(_ data: Data) -> JSONValue? {
        try? JSONParser(mode: .strict).parse(utf8: Array(data))
    }

    /// Parses JSON text.
    public static func parse(_ text: String) -> JSONValue? {
        try? JSONParser(mode: .strict).parse(text)
    }

    /// `JSONObject(text)`: the document when it is an object.
    public static func object(_ text: String) -> JSONObject? { parse(text)?.objectValue }

    /// `JSONObject.keys()` with values: unique names in first-seen order, last value wins.
    public static func members(_ object: JSONObject) -> [(key: String, value: JSONValue)] {
        var order: [String] = []
        var values: [String: JSONValue] = [:]
        for member in object.members {
            if values.updateValue(member.value, forKey: member.key) == nil { order.append(member.key) }
        }
        return order.map { ($0, values[$0]!) }
    }

    /// `has(name)`.
    public static func has(_ object: JSONObject, _ key: String) -> Bool { object[key] != nil }

    /// `opt(name)` (nil when absent; JSON null is `.null`).
    public static func opt(_ object: JSONObject?, _ key: String) -> JSONValue? { object?[key] }

    /// `optJSONObject(name)`.
    public static func optObject(_ object: JSONObject?, _ key: String) -> JSONObject? { object?[key]?.objectValue }

    /// `optJSONArray(name)`.
    public static func optArray(_ object: JSONObject?, _ key: String) -> [JSONValue]? { object?[key]?.arrayValue }

    /// `optString(name)` / `optString(name, fallback)`: strings as is, other values as their org.json text
    /// (`JSONObject.NULL` reads "null"), absent → fallback.
    public static func optString(_ object: JSONObject?, _ key: String, _ fallback: String = "") -> String {
        guard let value = object?[key] else { return fallback }
        return string(value)
    }

    /// `JSON.toString(value)` for a present value.
    public static func string(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let literal): return numberText(literal)
        case .array, .object: return JSONWriter.write(value)
        }
    }

    /// `optInt(name, fallback)`.
    public static func optInt(_ object: JSONObject?, _ key: String, _ fallback: Int = 0) -> Int {
        guard let value = object?[key] else { return fallback }
        return int(value) ?? fallback
    }

    /// `JSON.toInteger(value)`.
    public static func int(_ value: JSONValue) -> Int? {
        switch value {
        case .number(let literal):
            switch number(literal) {
            case .integer(let l): return Int(Int32(truncatingIfNeeded: l))
            case .double(let d): return Int(KotlinMath.toInt(d))
            case nil: return nil
            }
        case .string(let s):
            guard let d = javaParseDouble(s) else { return nil }
            return Int(KotlinMath.toInt(d))
        default: return nil
        }
    }

    /// `optLong(name, fallback)`.
    public static func optLong(_ object: JSONObject?, _ key: String, _ fallback: Int64 = 0) -> Int64 {
        guard let value = object?[key] else { return fallback }
        switch value {
        case .number(let literal):
            switch number(literal) {
            case .integer(let l): return l
            case .double(let d): return KotlinMath.toLong(d)
            case nil: return fallback
            }
        case .string(let s):
            guard let d = javaParseDouble(s) else { return fallback }
            return KotlinMath.toLong(d)
        default: return fallback
        }
    }

    /// `optBoolean(name, fallback)`: booleans and the strings "true"/"false" (any case).
    public static func optBoolean(_ object: JSONObject?, _ key: String, _ fallback: Bool = false) -> Bool {
        guard let value = object?[key] else { return fallback }
        switch value {
        case .bool(let b): return b
        case .string(let s):
            let lower = s.lowercased()
            if lower == "true" { return true }
            if lower == "false" { return false }
            return fallback
        default: return fallback
        }
    }

    // MARK: Numbers

    enum Number { case integer(Int64), double(Double) }

    /// `JSONTokener.readLiteral` for a number: integers without `.`/exponent that fit a Long stay integral
    /// (Integer/Long), everything else is a Double.
    static func number(_ literal: String) -> Number? {
        let hasFraction = literal.contains(".") || literal.contains("e") || literal.contains("E")
        if !hasFraction, let l = Int64(literal) { return .integer(l) }
        if let d = Double(literal) { return .double(d) }
        return nil
    }

    static func numberText(_ literal: String) -> String {
        switch number(literal) {
        case .integer(let l): return String(l)
        case .double(let d): return NetText.javaDoubleString(d)
        case nil: return literal
        }
    }

    /// `Double.parseDouble` for the plain decimal forms org.json meets (surrounding whitespace allowed).
    static func javaParseDouble(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\u{0B}\u{0C}\u{00}"))
        guard !trimmed.isEmpty else { return nil }
        var body = Substring(trimmed)
        if let last = body.last, "dDfF".contains(last) { body = body.dropLast() }
        if body == "NaN" || body == "+NaN" || body == "-NaN" { return .nan }
        if body == "Infinity" || body == "+Infinity" { return .infinity }
        if body == "-Infinity" { return -.infinity }
        guard body.allSatisfy({ "0123456789+-.eE".contains($0) }) else { return nil }
        return Double(body)
    }
}
