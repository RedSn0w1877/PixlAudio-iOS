// Gson/kotlinx-style lenient field readers for the Retrofit DTO ports (Spotify, Google OAuth, AI providers). A field
// of the wrong shape reads as absent instead of failing the whole response (Gson would throw; see the API notes).

import Foundation
import PixlFoundation

enum LenientJSON {
    /// A string field: strings as is, number literals and booleans as their text (Gson's STRING adapter).
    static func string(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let s)?: return s
        case .number(let literal)?: return literal
        case .bool(let b)?: return b ? "true" : "false"
        default: return nil
        }
    }

    /// A Long field: integral numbers or numeric strings (a whole-valued double is accepted, as Gson's `nextLong`).
    static func long(_ value: JSONValue?) -> Int64? {
        let literal: String
        switch value {
        case .number(let l)?: literal = l
        case .string(let s)?: literal = s
        default: return nil
        }
        if let l = Int64(literal) { return l }
        guard let d = Double(literal), d.isFinite, d.rounded(.towardZero) == d, abs(d) < 9.2e18 else { return nil }
        return Int64(d)
    }

    /// An Int field.
    static func int(_ value: JSONValue?) -> Int? {
        guard let l = long(value), let i = Int32(exactly: l) else { return nil }
        return Int(i)
    }

    /// A Double field (numbers or numeric strings).
    static func double(_ value: JSONValue?) -> Double? {
        switch value {
        case .number(let l)?: return Double(l)
        case .string(let s)?: return Double(s)
        default: return nil
        }
    }

    /// A Boolean field (booleans or "true"/"false" strings).
    static func bool(_ value: JSONValue?) -> Bool? {
        switch value {
        case .bool(let b)?: return b
        case .string(let s)?: return s.lowercased() == "true" ? true : (s.lowercased() == "false" ? false : nil)
        default: return nil
        }
    }

    static func object(_ value: JSONValue?) -> JSONObject? { value?.objectValue }
    static func array(_ value: JSONValue?) -> [JSONValue]? { value?.arrayValue }

    /// A list of strings (non-string items skipped).
    static func strings(_ value: JSONValue?) -> [String]? {
        array(value)?.compactMap { string($0) }
    }
}
