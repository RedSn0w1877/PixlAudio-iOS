// Streaming (SSE) for the Messages API: `ClaudeSSEParser` turns lines into events and `ClaudeStreamAccumulator`
// assembles them into the final `ClaudeMessage`, block by block, keeping every block's fields as the API sent them
// (unknown block types pass through untouched).
//
// Events: message_start, content_block_start / content_block_delta / content_block_stop, message_delta (stop_reason,
// usage), message_stop, ping, error. Deltas: text_delta, input_json_delta (client and server tool inputs), thinking_delta,
// signature_delta, citations_delta.
//
// Client tool inputs stream eagerly (`eager_input_streaming`), so the API no longer validates them: the accumulated
// `partial_json` is parsed strictly here, and a block whose text isn't one JSON object keeps `input: {}` and is listed
// in `failedToolInputs` with its raw text (the tool loop answers it with `{"INVALID_JSON": "<raw>"}`).

import Foundation
import PixlFoundation

/// One server-sent event's data, decoded.
public enum ClaudeStreamEvent: Sendable, Hashable {
    case messageStart(JSONObject)
    case contentBlockStart(index: Int, block: JSONObject)
    case contentBlockDelta(index: Int, delta: JSONObject)
    case contentBlockStop(index: Int)
    case messageDelta(delta: JSONObject, usage: JSONValue?)
    case messageStop
    case ping
    /// An `error` event mid-stream (`overloaded_error`, `api_error`, ...).
    case error(type: String, message: String)
    /// An event type this client doesn't know (ignored, as the API asks).
    case unknown(String)
}

/// Line-oriented SSE reader. Each Messages API event has one `data:` line holding JSON with a `type`, so an event is
/// dispatched on its data line — blank lines (which some line splitters drop) are not needed. `event:` lines are
/// redundant with `type` and ignored.
public struct ClaudeSSEParser: Sendable {
    public init() {}

    /// The event on this line, if it is a data line.
    public func parse(line rawLine: String) -> ClaudeStreamEvent? {
        var line = Substring(rawLine)
        if line.hasSuffix("\r") { line = line.dropLast() }
        guard line.hasPrefix("data:") else { return nil }
        var payload = line.dropFirst(5)
        if payload.first == " " { payload = payload.dropFirst() }
        guard !payload.isEmpty, let value = try? JSONParser(mode: .strict).parse(String(payload)),
              let object = value.objectValue, let type = object["type"]?.stringValue else { return nil }
        return Self.event(type: type, object: object)
    }

    static func event(type: String, object: JSONObject) -> ClaudeStreamEvent {
        func index() -> Int { object["index"].flatMap { KotlinxJSON.long($0) }.map(Int.init) ?? 0 }
        switch type {
        case "message_start": return .messageStart(object["message"]?.objectValue ?? JSONObject())
        case "content_block_start": return .contentBlockStart(index: index(), block: object["content_block"]?.objectValue ?? JSONObject())
        case "content_block_delta": return .contentBlockDelta(index: index(), delta: object["delta"]?.objectValue ?? JSONObject())
        case "content_block_stop": return .contentBlockStop(index: index())
        case "message_delta": return .messageDelta(delta: object["delta"]?.objectValue ?? JSONObject(), usage: object["usage"])
        case "message_stop": return .messageStop
        case "ping": return .ping
        case "error":
            let error = object["error"]?.objectValue
            return .error(type: error?["type"]?.stringValue ?? "api_error", message: error?["message"]?.stringValue ?? "")
        default: return .unknown(type)
        }
    }
}

/// What a stream update means for the UI.
public enum ClaudeStreamUpdate: Sendable, Hashable {
    /// Visible text was appended to the reply.
    case text(String)
    /// A tool call started: a client tool (`server == false`) or web search / fetch.
    case toolStarted(name: String, server: Bool)
    /// A server tool's results arrived (`web_search_tool_result`, `web_fetch_tool_result`).
    case serverToolResult(type: String)
}

/// Assembles a streamed response.
public struct ClaudeStreamAccumulator: Sendable {
    private struct Block: Sendable {
        var object: JSONObject
        var text = ""
        var thinking = ""
        var signature = ""
        var partialJSON = ""
        var citations: [JSONValue] = []
        var finished: JSONValue?
    }

    private var blocks: [Int: Block] = [:]
    private var order: [Int] = []
    public private(set) var stopReason: String?
    public private(set) var usage = ClaudeUsage()
    public private(set) var model: String?
    public private(set) var isComplete = false
    public private(set) var failedToolInputs: [String: String] = [:]

    public init() {}

    /// Applies one event; returns what changed for the UI. Throws on an `error` event.
    @discardableResult
    public mutating func apply(_ event: ClaudeStreamEvent) throws(ClaudeError) -> ClaudeStreamUpdate? {
        switch event {
        case .messageStart(let message):
            model = message["model"]?.stringValue
            usage.merge(message["usage"])
            return nil
        case .contentBlockStart(let index, let block):
            if blocks[index] == nil { order.append(index) }
            var entry = Block(object: block)
            if block["type"]?.stringValue == "text" { entry.text = block["text"]?.stringValue ?? "" }
            if block["type"]?.stringValue == "thinking" {
                entry.thinking = block["thinking"]?.stringValue ?? ""
                entry.signature = block["signature"]?.stringValue ?? ""
            }
            blocks[index] = entry
            switch block["type"]?.stringValue {
            case "tool_use": return .toolStarted(name: block["name"]?.stringValue ?? "", server: false)
            case "server_tool_use": return .toolStarted(name: block["name"]?.stringValue ?? "", server: true)
            case let type? where type.hasSuffix("_tool_result"): return .serverToolResult(type: type)
            case "text":
                let initial = entry.text
                return initial.isEmpty ? nil : .text(initial)
            default: return nil
            }
        case .contentBlockDelta(let index, let delta):
            guard var entry = blocks[index] else { return nil }
            defer { blocks[index] = entry }
            switch delta["type"]?.stringValue {
            case "text_delta":
                let piece = delta["text"]?.stringValue ?? ""
                entry.text += piece
                return piece.isEmpty ? nil : .text(piece)
            case "input_json_delta":
                entry.partialJSON += delta["partial_json"]?.stringValue ?? ""
            case "thinking_delta":
                entry.thinking += delta["thinking"]?.stringValue ?? ""
            case "signature_delta":
                entry.signature += delta["signature"]?.stringValue ?? ""
            case "citations_delta":
                if let citation = delta["citation"] { entry.citations.append(citation) }
            default:
                break
            }
            return nil
        case .contentBlockStop(let index):
            guard var entry = blocks[index] else { return nil }
            let finished = finish(&entry)
            entry.finished = finished
            blocks[index] = entry
            return nil
        case .messageDelta(let delta, let usageValue):
            if let reason = delta["stop_reason"]?.stringValue { stopReason = reason }
            usage.merge(usageValue)
            return nil
        case .messageStop:
            isComplete = true
            return nil
        case .ping, .unknown:
            return nil
        case .error(let type, let message):
            throw ClaudeError.stream(type: type, message: message)
        }
    }

    /// The block as it goes back to the API: the start object with the streamed fields filled in.
    private mutating func finish(_ entry: inout Block) -> JSONValue {
        var object = entry.object
        switch object["type"]?.stringValue {
        case "text":
            object = ClaudeJSON.setting(object, "text", .string(entry.text))
            if !entry.citations.isEmpty {
                let existing = object["citations"]?.arrayValue ?? []
                object = ClaudeJSON.setting(object, "citations", .array(existing + entry.citations))
            }
        case "thinking":
            object = ClaudeJSON.setting(object, "thinking", .string(entry.thinking))
            object = ClaudeJSON.setting(object, "signature", .string(entry.signature))
        case "tool_use", "server_tool_use":
            let raw = entry.partialJSON
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // No input streamed: the start object's input stands (normally `{}`).
                if object["input"]?.objectValue == nil { object = ClaudeJSON.setting(object, "input", .object(JSONObject())) }
            } else if let parsed = try? JSONParser(mode: .strict).parse(raw), let input = parsed.objectValue {
                object = ClaudeJSON.setting(object, "input", .object(input))
            } else {
                object = ClaudeJSON.setting(object, "input", .object(JSONObject()))
                if object["type"]?.stringValue == "tool_use", let id = object["id"]?.stringValue { failedToolInputs[id] = raw }
            }
        default:
            break
        }
        return .object(object)
    }

    /// The assembled message. Blocks that never got a `content_block_stop` (a cut stream) are finished as they are.
    public mutating func message() -> ClaudeMessage {
        var content: [JSONValue] = []
        for index in order.sorted() {
            guard var entry = blocks[index] else { continue }
            if let finished = entry.finished {
                content.append(finished)
            } else {
                content.append(finish(&entry))
            }
        }
        return ClaudeMessage(content: content, stopReason: stopReason, usage: usage, model: model,
                             failedToolInputs: failedToolInputs)
    }
}
