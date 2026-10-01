// Gson's semantics over PixlFoundation's `JSONValue`, because every Android backup payload is written and read with
// Gson (com.google.gson 2.14) and its conversions decide what Android accepts:
//
// * `Gson.parse` — `JsonParser.parseString` / `Gson.fromJson` input: lenient reading of unquoted tokens (a token
//   that is not a JSON number is an unquoted string, `true`/`false`/`null` in any letter case are keywords),
//   whole-document consumption, and "" or whitespace = no document. Gson's other lenient extras (comments,
//   single quotes, unquoted names, `;`/`=` separators) are not accepted; Android never writes them.
// * `GsonElement` — the `JsonElement` accessors (`getAsString`, `getAsLong`, `getAsInt` …) used by the validators
//   and the legacy adapter, with their failures.
// * `GsonRead` — `JsonReader` + `TypeAdapters` as used when Gson binds JSON to a class (`fromJson(payload, T)`).
// * `GsonWriter` — `Gson.toJson` output: compact or pretty (2-space indent, `": "`), HTML-safe escaping, nulls kept
//   or dropped, and numbers as Java prints them (`JavaNumberText`).

import Foundation
import PixlFoundation
import PixlLibrary

/// A Gson failure (`JsonSyntaxException`, `IllegalStateException`, `UnsupportedOperationException`,
/// `ClassCastException`, `NumberFormatException` …). `kind` names the Java exception class.
public struct GsonError: Error, Sendable, Equatable, CustomStringConvertible {
    public let kind: String
    public let message: String

    public init(_ kind: String, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var description: String { "\(kind): \(message)" }

    static func syntax(_ message: String) -> GsonError { GsonError("JsonSyntaxException", message) }
    static func illegalState(_ message: String) -> GsonError { GsonError("IllegalStateException", message) }
    static func unsupported(_ message: String) -> GsonError { GsonError("UnsupportedOperationException", message) }
    static func classCast(_ message: String) -> GsonError { GsonError("ClassCastException", message) }
    static func numberFormat(_ message: String) -> GsonError { GsonError("NumberFormatException", message) }
}

// MARK: - Parsing

public enum Gson {
    /// Parses a document the way Gson's lenient reader does (see the file comment). Returns nil for an empty
    /// document ("" or whitespace only), which `JsonParser` turns into `JsonNull` and `fromJson` into `null`.
    public static func parse(_ text: String) throws(GsonError) -> JSONValue? {
        if text.utf8.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) { return nil }
        do {
            return normalize(try JSONParser(mode: .kotlinx, maxDepth: 512).parse(text))
        } catch {
            throw .syntax(error.description)
        }
    }

    /// `JsonParser.parseString`: an empty document is JSON null.
    public static func parseTree(_ text: String) throws(GsonError) -> JSONValue {
        try parse(text) ?? .null
    }

    /// Gson's view of unquoted tokens: RFC numbers stay numbers, keywords match case-insensitively, the rest are
    /// (unquoted) strings.
    static func normalize(_ value: JSONValue) -> JSONValue {
        switch value {
        case .number(let token):
            if JSONGrammar.isNumber(token) { return value }
            switch token.lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default: return .string(token)
            }
        case .array(let items):
            return .array(items.map(normalize))
        case .object(let object):
            return .object(JSONObject(object.members.map { ($0.key, normalize($0.value)) }))
        default:
            return value
        }
    }

    /// `Gson.fromJson(text, T)`: nil for an empty document or JSON `null`.
    public static func fromJson<T>(_ text: String, _ decode: (JSONValue) throws(GsonError) -> T?) throws(GsonError) -> T? {
        guard let value = try parse(text) else { return nil }
        return try decode(value)
    }

    /// Looks up a member the way Gson's `JsonObject.get` does: `LinkedTreeMap` keeps the **last** duplicate.
    static func member(_ object: JSONObject, _ key: String) -> JSONValue? {
        for member in object.members.reversed() where KotlinText.equals(member.key, key) { return member.value }
        return nil
    }
}

// MARK: - JsonElement accessors

/// `JsonElement` accessors with Gson's conversions. A missing member is Kotlin's `?.` short-circuit (nil), so these
/// take non-optional values.
public enum GsonElement {
    public static func isPrimitive(_ v: JSONValue) -> Bool {
        switch v {
        case .string, .number, .bool: return true
        default: return false
        }
    }

    public static func isNumber(_ v: JSONValue) -> Bool { if case .number = v { return true } else { return false } }

    /// `getAsString()`.
    public static func asString(_ v: JSONValue) throws(GsonError) -> String {
        switch v {
        case .string(let s): return s
        case .number(let literal): return literal
        case .bool(let b): return b ? "true" : "false"
        case .array(let items): return try asString(single(items))
        case .null: throw .unsupported("JsonNull")
        case .object: throw .unsupported("JsonObject")
        }
    }

    /// `getAsLong()`: numbers via `LazilyParsedNumber.longValue()` (`Long.parseLong`, else
    /// `BigDecimal(literal).longValue()` — truncating toward zero, low 64 bits); strings and booleans via
    /// `Long.parseLong`.
    public static func asLong(_ v: JSONValue) throws(GsonError) -> Int64 {
        switch v {
        case .number(let literal):
            if let l = JavaNumbers.parseLong(literal) { return l }
            guard let l = JavaNumbers.bigDecimalLongValue(literal) else { throw .numberFormat(literal) }
            return l
        case .string(let s):
            guard let l = JavaNumbers.parseLong(s) else { throw .numberFormat("For input string: \"\(s)\"") }
            return l
        case .bool(let b): throw .numberFormat("For input string: \"\(b)\"")
        case .array(let items): return try asLong(single(items))
        case .null: throw .unsupported("JsonNull")
        case .object: throw .unsupported("JsonObject")
        }
    }

    /// `getAsInt()`: numbers keep the low 32 bits of their integer value; strings via `Integer.parseInt`.
    public static func asInt(_ v: JSONValue) throws(GsonError) -> Int32 {
        switch v {
        case .number: return Int32(truncatingIfNeeded: try asLong(v))
        case .string(let s):
            guard let i = JavaNumbers.parseInt(s) else { throw .numberFormat("For input string: \"\(s)\"") }
            return i
        case .bool(let b): throw .numberFormat("For input string: \"\(b)\"")
        case .array(let items): return try asInt(single(items))
        case .null: throw .unsupported("JsonNull")
        case .object: throw .unsupported("JsonObject")
        }
    }

    /// `getAsJsonObject()`.
    public static func asObject(_ v: JSONValue) throws(GsonError) -> JSONObject {
        guard case .object(let o) = v else { throw .illegalState("Not a JSON Object: \(JSONWriter.write(v))") }
        return o
    }

    /// `getAsJsonArray()`.
    public static func asArray(_ v: JSONValue) throws(GsonError) -> [JSONValue] {
        guard case .array(let a) = v else { throw .illegalState("Not a JSON Array: \(JSONWriter.write(v))") }
        return a
    }

    /// `JsonObject.getAsJsonArray(member)`: nil when absent, a cast failure unless an array (JSON null included).
    public static func memberArray(_ o: JSONObject, _ key: String) throws(GsonError) -> [JSONValue]? {
        guard let v = Gson.member(o, key) else { return nil }
        guard case .array(let a) = v else { throw .classCast("cannot be cast to com.google.gson.JsonArray") }
        return a
    }

    /// `JsonObject.getAsJsonObject(member)`.
    public static func memberObject(_ o: JSONObject, _ key: String) throws(GsonError) -> JSONObject? {
        guard let v = Gson.member(o, key) else { return nil }
        guard case .object(let obj) = v else { throw .classCast("cannot be cast to com.google.gson.JsonObject") }
        return obj
    }

    static func single(_ items: [JSONValue]) throws(GsonError) -> JSONValue {
        guard items.count == 1 else { throw .illegalState("Array must have size 1, but has size \(items.count)") }
        return items[0]
    }
}

// MARK: - Binding (JsonReader + TypeAdapters)

/// What Gson's type adapters do when binding a JSON value to a field. Every function returns nil for JSON null
/// (the field keeps its default when it is a primitive — callers apply that).
public enum GsonRead {
    /// `TypeAdapters.STRING`.
    public static func string(_ v: JSONValue) throws(GsonError) -> String? {
        switch v {
        case .null: return nil
        case .string(let s): return s
        case .number(let literal): return literal
        case .bool(let b): return b ? "true" : "false"
        case .array: throw .syntax("Expected a string but was BEGIN_ARRAY")
        case .object: throw .syntax("Expected a string but was BEGIN_OBJECT")
        }
    }

    /// `JsonReader.nextLong` (via `TypeAdapters.LONG`).
    public static func long(_ v: JSONValue) throws(GsonError) -> Int64? {
        switch v {
        case .null: return nil
        case .number(let literal):
            if JSONGrammar.isStrictInteger(literal), let l = Int64(literal) { return l }
            return try longFromDouble(literal)
        case .string(let s):
            if let l = JavaNumbers.parseLong(s) { return l }
            return try longFromDouble(s)
        default: throw .syntax("Expected a long but was \(tokenName(v))")
        }
    }

    /// `JsonReader.nextInt` (via `TypeAdapters.INTEGER`).
    public static func int(_ v: JSONValue) throws(GsonError) -> Int32? {
        switch v {
        case .null: return nil
        case .number(let literal):
            if JSONGrammar.isStrictInteger(literal), let l = Int64(literal) {
                guard let i = Int32(exactly: l) else { throw .syntax("Expected an int but was \(literal)") }
                return i
            }
            return try intFromDouble(literal)
        case .string(let s):
            if let i = JavaNumbers.parseInt(s) { return i }
            return try intFromDouble(s)
        default: throw .syntax("Expected an int but was \(tokenName(v))")
        }
    }

    /// `JsonReader.nextDouble` (lenient: NaN and infinities allowed).
    public static func double(_ v: JSONValue) throws(GsonError) -> Double? {
        switch v {
        case .null: return nil
        case .number(let text), .string(let text):
            guard let d = JavaNumbers.parseDouble(text) else { throw .syntax("NumberFormatException: \(text)") }
            return d
        default: throw .syntax("Expected a double but was \(tokenName(v))")
        }
    }

    /// `TypeAdapters.FLOAT`: `(float) nextDouble()`.
    public static func float(_ v: JSONValue) throws(GsonError) -> Float? {
        guard let d = try double(v) else { return nil }
        return Float(d)
    }

    /// `TypeAdapters.BOOLEAN`: strings through `Boolean.parseBoolean`, numbers rejected.
    public static func bool(_ v: JSONValue) throws(GsonError) -> Bool? {
        switch v {
        case .null: return nil
        case .bool(let b): return b
        case .string(let s): return s.lowercased() == "true" && s.utf8.count == 4
        default: throw .syntax("Expected a boolean but was \(tokenName(v))")
        }
    }

    /// `EnumTypeAdapter`: the constant with this name, nil for unknown names; booleans and containers fail
    /// (`nextString`).
    public static func enumName(_ v: JSONValue, allowed: [String]) throws(GsonError) -> String? {
        switch v {
        case .null: return nil
        case .string(let s), .number(let s): return allowed.first { KotlinText.equals($0, s) }
        default: throw .syntax("Expected a string but was \(tokenName(v))")
        }
    }

    /// A reflective object: nil for null, the object's members otherwise.
    public static func object(_ v: JSONValue) throws(GsonError) -> JSONObject? {
        switch v {
        case .null: return nil
        case .object(let o): return o
        default: throw .syntax("Expected BEGIN_OBJECT but was \(tokenName(v))")
        }
    }

    /// `CollectionTypeAdapterFactory` for `List<T>`.
    public static func list<T>(_ v: JSONValue, _ element: (JSONValue) throws(GsonError) -> T?) throws(GsonError) -> [T?]? {
        switch v {
        case .null: return nil
        case .array(let items):
            var out: [T?] = []
            out.reserveCapacity(items.count)
            for item in items { out.append(try element(item)) }
            return out
        default: throw .syntax("Expected BEGIN_ARRAY but was \(tokenName(v))")
        }
    }

    /// `Set<String>` (`LinkedHashSet`): first occurrence wins, one null at most.
    public static func stringSet(_ v: JSONValue) throws(GsonError) -> [String?]? {
        guard let items = try list(v, string) else { return nil }
        var seen = Set<KotlinKey>()
        var sawNull = false
        var out: [String?] = []
        for item in items {
            if let s = item {
                if seen.insert(KotlinKey(s)).inserted { out.append(s) }
            } else if !sawNull {
                sawNull = true
                out.append(nil)
            }
        }
        return out
    }

    /// `MapTypeAdapterFactory` for `Map<String, V>`: an object, or an array of `[key, value]` pairs; a duplicate key
    /// fails unless the earlier value was null (Gson checks `put(...) != null`).
    public static func map<V>(_ v: JSONValue, _ value: (JSONValue) throws(GsonError) -> V?) throws(GsonError) -> GsonMap<V>? {
        var map = GsonMap<V>()
        switch v {
        case .null: return nil
        case .object(let o):
            for member in o.members {
                let decoded = try value(member.value)
                if map.put(member.key, decoded) { throw .syntax("duplicate key: \(member.key)") }
            }
        case .array(let pairs):
            for pair in pairs {
                guard case .array(let kv) = pair else { throw .syntax("Expected BEGIN_ARRAY but was \(tokenName(pair))") }
                guard kv.count == 2 else { throw .syntax("Expected a [key, value] pair") }
                guard let key = try string(kv[0]) else { throw .syntax("null map key") }
                let decoded = try value(kv[1])
                if map.put(key, decoded) { throw .syntax("duplicate key: \(key)") }
            }
        default: throw .syntax("Expected BEGIN_OBJECT but was \(tokenName(v))")
        }
        return map
    }

    static func longFromDouble(_ text: String) throws(GsonError) -> Int64 {
        guard let d = JavaNumbers.parseDouble(text) else { throw .syntax("NumberFormatException: \(text)") }
        let result = KotlinMath.toLong(d)
        if Double(result) != d { throw .syntax("Expected a long but was \(text)") }
        return result
    }

    static func intFromDouble(_ text: String) throws(GsonError) -> Int32 {
        guard let d = JavaNumbers.parseDouble(text) else { throw .syntax("NumberFormatException: \(text)") }
        let result = KotlinMath.toInt(d)
        if Double(result) != d { throw .syntax("Expected an int but was \(text)") }
        return result
    }

    static func tokenName(_ v: JSONValue) -> String {
        switch v {
        case .null: return "NULL"
        case .bool: return "BOOLEAN"
        case .number: return "NUMBER"
        case .string: return "STRING"
        case .array: return "BEGIN_ARRAY"
        case .object: return "BEGIN_OBJECT"
        }
    }
}

/// Binds the members of a JSON object to fields the way Gson's reflective adapter does: members are visited in
/// order, each matched against the field's serialized names (`@SerializedName` value and alternates), so the last
/// matching member wins; unknown members are skipped.
public struct GsonFields {
    let object: JSONObject

    public init(_ object: JSONObject) { self.object = object }

    /// The value of the last member whose name is one of `names`.
    public func value(_ names: String...) -> JSONValue? {
        for member in object.members.reversed() where names.contains(where: { KotlinText.equals($0, member.key) }) {
            return member.value
        }
        return nil
    }

    /// Reads a field: nil when absent, else `read`'s result (nil for JSON null).
    public func read<T>(_ names: String..., with read: (JSONValue) throws(GsonError) -> T?) throws(GsonError) -> T?? {
        var found: JSONValue?
        for member in object.members.reversed() where names.contains(where: { KotlinText.equals($0, member.key) }) {
            found = member.value
            break
        }
        guard let found else { return .none }
        return .some(try read(found))
    }
}

/// `LinkedHashMap<String, V>` with Java string keys (exact code units), insertion order kept.
public struct GsonMap<Value> {
    public private(set) var entries: [(key: String, value: Value?)] = []
    private var index: [KotlinKey: Int] = [:]

    public init() {}

    public init(_ pairs: [(String, Value?)]) {
        for (k, v) in pairs { put(k, v) }
    }

    public subscript(key: String) -> Value?? {
        guard let i = index[KotlinKey(key)] else { return .none }
        return .some(entries[i].value)
    }

    public func contains(_ key: String) -> Bool { index[KotlinKey(key)] != nil }

    public var keys: [String] { entries.map(\.key) }
    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    /// `Map.put`; returns true when a non-null value was replaced.
    @discardableResult
    public mutating func put(_ key: String, _ value: Value?) -> Bool {
        if let i = index[KotlinKey(key)] {
            let replacedNonNull = entries[i].value != nil
            entries[i].value = value
            return replacedNonNull
        }
        index[KotlinKey(key)] = entries.count
        entries.append((key, value))
        return false
    }
}

extension GsonMap: Sendable where Value: Sendable {}

extension GsonMap: Equatable where Value: Equatable {
    public static func == (lhs: GsonMap, rhs: GsonMap) -> Bool {
        lhs.entries.count == rhs.entries.count
            && zip(lhs.entries, rhs.entries).allSatisfy { KotlinText.equals($0.key, $1.key) && $0.value == $1.value }
    }
}

extension GsonMap: Hashable where Value: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(entries.count)
        for entry in entries {
            hasher.combine(KotlinKey(entry.key))
            hasher.combine(entry.value)
        }
    }
}

// MARK: - Writing

/// `Gson.toJson` output for a `JSONValue` tree (build number members with `JavaNumberText`).
public enum GsonWriter {
    /// The backup Gson (`setPrettyPrinting().serializeNulls()`).
    public static func backup(_ value: JSONValue) -> String { write(value, pretty: true, serializeNulls: true) }

    /// The app's default `Gson()` (compact, nulls dropped from objects).
    public static func plain(_ value: JSONValue) -> String { write(value, pretty: false, serializeNulls: false) }

    public static func write(_ value: JSONValue, pretty: Bool, serializeNulls: Bool) -> String {
        var out = ""
        write(value, pretty: pretty, serializeNulls: serializeNulls, depth: 0, into: &out)
        return out
    }

    static func write(_ value: JSONValue, pretty: Bool, serializeNulls: Bool, depth: Int, into out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let literal): out += literal
        case .string(let s): writeString(s, into: &out)
        case .array(let items):
            if items.isEmpty {
                out += "[]"
                return
            }
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                newline(pretty, depth + 1, &out)
                write(item, pretty: pretty, serializeNulls: serializeNulls, depth: depth + 1, into: &out)
            }
            newline(pretty, depth, &out)
            out += "]"
        case .object(let object):
            let members = serializeNulls ? object.members : object.members.filter { !$0.value.isNull }
            if members.isEmpty {
                out += "{}"
                return
            }
            out += "{"
            for (i, member) in members.enumerated() {
                if i > 0 { out += "," }
                newline(pretty, depth + 1, &out)
                writeString(member.key, into: &out)
                out += pretty ? ": " : ":"
                write(member.value, pretty: pretty, serializeNulls: serializeNulls, depth: depth + 1, into: &out)
            }
            newline(pretty, depth, &out)
            out += "}"
        }
    }

    static func newline(_ pretty: Bool, _ depth: Int, _ out: inout String) {
        guard pretty else { return }
        out += "\n"
        out += String(repeating: "  ", count: depth)
    }

    /// `JsonWriter.string` with `htmlSafe`: `"` `\` and C0 controls escaped (`\t \b \n \r \f` short), U+2028/2029
    /// and `< > & = '` as `\u00xx`; everything else raw.
    public static func writeString(_ s: String, into out: inout String) {
        out += "\""
        var scalars = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x22: scalars.append(contentsOf: "\\\"".unicodeScalars)
            case 0x5C: scalars.append(contentsOf: "\\\\".unicodeScalars)
            case 0x09: scalars.append(contentsOf: "\\t".unicodeScalars)
            case 0x08: scalars.append(contentsOf: "\\b".unicodeScalars)
            case 0x0A: scalars.append(contentsOf: "\\n".unicodeScalars)
            case 0x0D: scalars.append(contentsOf: "\\r".unicodeScalars)
            case 0x0C: scalars.append(contentsOf: "\\f".unicodeScalars)
            case 0x00..<0x20, 0x2028, 0x2029, 0x3C, 0x3E, 0x26, 0x3D, 0x27:
                let hex = String(scalar.value, radix: 16)
                scalars.append(contentsOf: ("\\u" + String(repeating: "0", count: 4 - hex.count) + hex).unicodeScalars)
            default: scalars.append(scalar)
            }
        }
        out += String(scalars)
        out += "\""
    }
}

/// Builds Gson-shaped JSON values for records.
public enum GsonValue {
    public static func string(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }
    public static func long(_ v: Int64?) -> JSONValue { v.map { .number(String($0)) } ?? .null }
    public static func int(_ v: Int32?) -> JSONValue { v.map { .number(String($0)) } ?? .null }
    public static func bool(_ v: Bool?) -> JSONValue { v.map { .bool($0) } ?? .null }
    public static func float(_ v: Float?) -> JSONValue { v.map { .number(JavaNumberText.float($0)) } ?? .null }
    public static func double(_ v: Double?) -> JSONValue { v.map { .number(JavaNumberText.double($0)) } ?? .null }
    public static func strings(_ v: [String?]?) -> JSONValue { v.map { .array($0.map(string)) } ?? .null }

    public static func map<V>(_ m: GsonMap<V>?, _ encode: (V) -> JSONValue) -> JSONValue {
        guard let m else { return .null }
        return .object(JSONObject(m.entries.map { ($0.key, $0.value.map(encode) ?? .null) }))
    }

    public static func object(_ members: [(String, JSONValue)]) -> JSONValue { .object(JSONObject(members)) }
}
