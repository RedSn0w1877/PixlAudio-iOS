// Validates a tool input against the tool's JSON Schema before the tool runs (eagerly streamed inputs are not checked
// by the API). Covers the subset the tools use — and the subset strict tool use accepts: `type` (one or a list),
// `enum`, `properties`, `required`, `additionalProperties: false`, `items`, `anyOf`.

import Foundation
import PixlFoundation

public enum ClaudeSchemaValidator {
    /// The problems found ("" path = the root); empty when the value is valid.
    public static func validate(_ value: JSONValue, against schema: JSONValue, path: String = "$") -> [String] {
        guard let schema = schema.objectValue else { return [] }
        if let options = schema["anyOf"]?.arrayValue, !options.isEmpty {
            if options.contains(where: { validate(value, against: $0, path: path).isEmpty }) { return [] }
            return ["\(path): matches none of the allowed shapes"]
        }
        var problems: [String] = []
        if let typeValue = schema["type"] {
            let types = typeValue.arrayValue?.compactMap(\.stringValue) ?? [typeValue.stringValue].compactMap { $0 }
            if !types.isEmpty, !types.contains(where: { matches(value, type: $0) }) {
                return ["\(path): expected \(types.joined(separator: " or "))"]
            }
        }
        if let allowed = schema["enum"]?.arrayValue, !allowed.contains(value) {
            problems.append("\(path): not one of the allowed values")
        }
        if case .object(let object) = value {
            let properties = schema["properties"]?.objectValue ?? JSONObject()
            for name in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[name] == nil {
                problems.append("\(path).\(name): required")
            }
            let closed = schema["additionalProperties"]?.boolValue == false
            for member in object.members {
                if let propertySchema = properties[member.key] {
                    problems += validate(member.value, against: propertySchema, path: "\(path).\(member.key)")
                } else if closed {
                    problems.append("\(path).\(member.key): unknown property")
                }
            }
        }
        if case .array(let items) = value, let itemSchema = schema["items"] {
            for (index, item) in items.enumerated() {
                problems += validate(item, against: itemSchema, path: "\(path)[\(index)]")
            }
        }
        return problems
    }

    static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null): true
        case ("number", .number(let literal)): JSONGrammar.isNumber(literal)
        case ("integer", .number(let literal)):
            JSONGrammar.isStrictInteger(literal) || (Double(literal).map { $0.rounded() == $0 } ?? false)
        default: false
        }
    }
}
