// Claude (Anthropic Messages API) over raw HTTPS — there is no Swift SDK, so PixlNet builds the request bodies itself
// (with PixlFoundation's ordered JSON writer) and the app sends them with URLSession. Constants and rules follow the
// shared AI spec (docs: "Claude everywhere", section A3) and are the same on Android:
//
// - `POST https://api.anthropic.com/v1/messages`, headers `x-api-key`, `anthropic-version: 2026-10-21`,
//   `content-type: application/json` and `anthropic-beta: server-side-fallback-2026-07-01` with `"fallbacks": "default"`.
// - `model: claude-sonnet-5-5`. Never `temperature` / `top_p` / `top_k` (400 on this API version) and never
//   `thinking: {type: "disabled"}` (400): `thinking` is omitted (adaptive) and depth is `output_config.effort`.
// - `max_tokens` 16000 non-streaming, 32000 streaming. `tool_choice` is `auto` only (forced tool use is a 400 on
//   Sonnet 5.5); client tools are `strict` with `additionalProperties: false`, and `eager_input_streaming` when streamed.
// - The system prompt is a list of blocks; `cache_control: ephemeral` goes on the last stable block.

import Foundation
import PixlFoundation

/// The fixed parts of every Claude request.
public enum ClaudeAPI {
    public static let endpoint = "https://api.anthropic.com/v1/messages"
    public static let apiVersion = "2026-10-21"
    /// The scalar `fallbacks: "default"` form needs exactly this beta header (the array form uses another one).
    public static let fallbackBeta = "server-side-fallback-2026-07-01"
    public static let model = "claude-sonnet-5-5"
    public static let maxTokensNonStreaming = 16000
    public static let maxTokensStreaming = 32000
    /// The one retry of a turn cut off at `max_tokens` while it was writing a tool call doubles the budget, up to this.
    public static let maxTokensCeiling = 64000
    /// `max_uses` of the web search and web fetch server tools.
    public static let webToolMaxUses = 10
    /// The longest a request may take (a long streamed answer with web research included).
    public static let requestTimeoutSeconds: Double = 120
}

/// `output_config.effort`. Owner decision 2026-10-23: quality over cost — `medium` for chat, `high` for playlist
/// building and insights.
public enum ClaudeEffort: String, Sendable, Hashable, CaseIterable {
    case low, medium, high
}

/// One block of the system prompt.
public struct ClaudeSystemBlock: Sendable, Hashable {
    public var text: String
    /// Puts `cache_control: {"type": "ephemeral"}` on this block: everything up to and including it is cached.
    public var cacheBreakpoint: Bool

    public init(_ text: String, cacheBreakpoint: Bool = false) {
        self.text = text
        self.cacheBreakpoint = cacheBreakpoint
    }

    public var json: JSONValue {
        var object = JSONObject()
        object.append("type", .string("text"))
        object.append("text", .string(text))
        if cacheBreakpoint { object.append("cache_control", ClaudeJSON.object([("type", .string("ephemeral"))])) }
        return .object(object)
    }
}

/// A client tool the app runs (`tool_use` → `tool_result`).
public struct ClaudeToolDefinition: Sendable, Hashable {
    public var name: String
    /// Says *when* to call it, not only what it does.
    public var description: String
    /// A JSON Schema object (`additionalProperties: false` on every object, for `strict`).
    public var inputSchema: JSONValue
    /// `strict` tools share one budget of 24 optional parameters per request (more is a 400 for the whole request), so a
    /// tool with many optional filters opts out and the app validates its input itself.
    public var strict: Bool

    public init(name: String, description: String, inputSchema: JSONValue, strict: Bool = true) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.strict = strict
    }

    /// The `tools[]` entry. `streaming` adds `eager_input_streaming` (only valid, and only useful, on streamed requests).
    public func json(streaming: Bool) -> JSONValue {
        var object = JSONObject()
        object.append("name", .string(name))
        object.append("description", .string(description))
        object.append("input_schema", inputSchema)
        if strict { object.append("strict", .bool(true)) }
        if streaming { object.append("eager_input_streaming", .bool(true)) }
        return .object(object)
    }
}

/// The server tools Claude runs itself (no client code; results come back as content blocks, errors included).
public enum ClaudeServerTool: String, Sendable, Hashable, CaseIterable {
    case webSearch = "web_search"
    case webFetch = "web_fetch"

    public var type: String {
        switch self {
        case .webSearch: "web_search_20260209"
        case .webFetch: "web_fetch_20260209"
        }
    }

    public func json(maxUses: Int = ClaudeAPI.webToolMaxUses) -> JSONValue {
        ClaudeJSON.object([("type", .string(type)), ("name", .string(rawValue)), ("max_uses", .integer(maxUses))])
    }
}

/// One Messages API request.
public struct ClaudeRequest: Sendable, Hashable {
    public var system: [ClaudeSystemBlock]
    /// Full message objects (`{"role": ..., "content": ...}`), oldest first; assistant turns exactly as received.
    public var messages: [JSONValue]
    public var tools: [ClaudeToolDefinition]
    public var serverTools: [ClaudeServerTool]
    public var effort: ClaudeEffort
    public var maxTokens: Int
    public var stream: Bool

    public init(system: [ClaudeSystemBlock], messages: [JSONValue], tools: [ClaudeToolDefinition] = [],
                serverTools: [ClaudeServerTool] = [], effort: ClaudeEffort, maxTokens: Int? = nil, stream: Bool = false) {
        self.system = system
        self.messages = messages
        self.tools = tools
        self.serverTools = serverTools
        self.effort = effort
        self.maxTokens = maxTokens ?? (stream ? ClaudeAPI.maxTokensStreaming : ClaudeAPI.maxTokensNonStreaming)
        self.stream = stream
    }

    /// The body, keys in a fixed order (a stable prefix keeps the prompt cache warm). Client tools first, then the
    /// server tools, always in the order given.
    public var body: JSONValue {
        var object = JSONObject()
        object.append("model", .string(ClaudeAPI.model))
        object.append("max_tokens", .integer(maxTokens))
        if stream { object.append("stream", .bool(true)) }
        if !system.isEmpty { object.append("system", .array(system.map(\.json))) }
        object.append("messages", .array(messages))
        let toolEntries = tools.map { $0.json(streaming: stream) } + serverTools.map { $0.json() }
        if !toolEntries.isEmpty {
            object.append("tools", .array(toolEntries))
            object.append("tool_choice", ClaudeJSON.object([("type", .string("auto"))]))
        }
        object.append("output_config", ClaudeJSON.object([("effort", .string(effort.rawValue))]))
        object.append("fallbacks", .string("default"))
        return .object(object)
    }

    /// The HTTP request. The key goes only into the `x-api-key` header — never into a URL, a body or a log.
    public func httpRequest(apiKey: String) -> HTTPRequest {
        HTTPRequest(method: .post, url: ClaudeAPI.endpoint,
                    headers: [HTTPHeader("x-api-key", apiKey),
                              HTTPHeader("anthropic-version", ClaudeAPI.apiVersion),
                              HTTPHeader("anthropic-beta", ClaudeAPI.fallbackBeta),
                              HTTPHeader("content-type", "application/json"),
                              HTTPHeader("accept", stream ? "text/event-stream" : "application/json")],
                    body: Data(JSONWriter.write(body).utf8),
                    timeout: ClaudeAPI.requestTimeoutSeconds)
    }
}

/// Small builders for the request JSON.
public enum ClaudeJSON {
    public static func object(_ members: [(String, JSONValue)]) -> JSONValue {
        .object(JSONObject(members.map { (key: $0.0, value: $0.1) }))
    }

    /// `{"role": "user", "content": "<text>"}`.
    public static func userText(_ text: String) -> JSONValue {
        object([("role", .string("user")), ("content", .array([object([("type", .string("text")), ("text", .string(text))])]))])
    }

    /// `{"role": "assistant", "content": [...]}` — the assistant's blocks exactly as they arrived.
    public static func assistant(_ content: [JSONValue]) -> JSONValue {
        object([("role", .string("assistant")), ("content", .array(content))])
    }

    /// `{"role": "user", "content": [tool_result, ...]}`.
    public static func toolResults(_ results: [ClaudeToolResult]) -> JSONValue {
        object([("role", .string("user")), ("content", .array(results.map(\.json)))])
    }

    /// The role of a message object.
    public static func role(_ message: JSONValue) -> String? { message["role"]?.stringValue }

    /// Replaces (in place, keeping the key order) or appends a member.
    public static func setting(_ object: JSONObject, _ key: String, _ value: JSONValue) -> JSONObject {
        var copy = object
        if let index = copy.members.lastIndex(where: { $0.key == key }) {
            copy.members[index].value = value
        } else {
            copy.append(key, value)
        }
        return copy
    }
}

/// One `tool_result` block.
public struct ClaudeToolResult: Sendable, Hashable {
    public var toolUseId: String
    /// Text the model reads (JSON written with the JSON writer, never by concatenation).
    public var content: String
    public var isError: Bool

    public init(toolUseId: String, content: String, isError: Bool = false) {
        self.toolUseId = toolUseId
        self.content = content
        self.isError = isError
    }

    /// `{"INVALID_JSON": "<raw>"}` for a tool input that didn't parse or didn't match the schema.
    public static func invalidJSON(toolUseId: String, raw: String) -> ClaudeToolResult {
        ClaudeToolResult(toolUseId: toolUseId, content: JSONWriter.write(ClaudeJSON.object([("INVALID_JSON", .string(raw))])),
                         isError: true)
    }

    public var json: JSONValue {
        var object = JSONObject()
        object.append("type", .string("tool_result"))
        object.append("tool_use_id", .string(toolUseId))
        object.append("content", .string(content))
        if isError { object.append("is_error", .bool(true)) }
        return .object(object)
    }
}
