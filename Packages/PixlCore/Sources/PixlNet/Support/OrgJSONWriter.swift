// Android `org.json` serialisation (`JSONObject.toString()` / `JSONStringer`): compact, members in insertion order,
// and strings escaped with org.json's table — notably `/` is written as `\/` and U+2028/U+2029 are escaped. The
// InnerTube request bodies are written with this so they match Android's bytes.

import Foundation
import PixlFoundation

enum OrgJSONWriter {
    static func write(_ value: JSONValue) -> String {
        var out = ""
        write(value, into: &out)
        return out
    }

    static func write(_ value: JSONValue, into out: inout String) {
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
            for (i, member) in OrgJSON.members(object).enumerated() {
                if i > 0 { out += "," }
                writeString(member.key, into: &out)
                out += ":"
                write(member.value, into: &out)
            }
            out += "}"
        }
    }

    static func writeString(_ s: String, into out: inout String) {
        out += "\""
        var scalars = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x22: scalars.append(contentsOf: "\\\"".unicodeScalars)
            case 0x5C: scalars.append(contentsOf: "\\\\".unicodeScalars)
            case 0x2F: scalars.append(contentsOf: "\\/".unicodeScalars)
            case 0x09: scalars.append(contentsOf: "\\t".unicodeScalars)
            case 0x08: scalars.append(contentsOf: "\\b".unicodeScalars)
            case 0x0A: scalars.append(contentsOf: "\\n".unicodeScalars)
            case 0x0D: scalars.append(contentsOf: "\\r".unicodeScalars)
            case 0x0C: scalars.append(contentsOf: "\\f".unicodeScalars)
            case 0x00..<0x20, 0x2028, 0x2029:
                let hex = String(scalar.value, radix: 16)
                scalars.append(contentsOf: ("\\u" + String(repeating: "0", count: 4 - hex.count) + hex).unicodeScalars)
            default: scalars.append(scalar)
            }
        }
        out += String(scalars)
        out += "\""
    }

    /// `JSONObject.quote(s)`.
    static func quote(_ s: String) -> String {
        var out = ""
        writeString(s, into: &out)
        return out
    }
}
