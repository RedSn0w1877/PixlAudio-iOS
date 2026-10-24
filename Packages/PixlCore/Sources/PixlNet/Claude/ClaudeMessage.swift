// A Messages API response (assembled from a stream or read from a JSON body): the content blocks exactly as the API
// sent them — they go back unchanged in the next request (thinking, server_tool_use and *_tool_result blocks
// included) — plus the stop reason and the usage the budget is charged with.

import Foundation
import PixlFoundation

/// The usage of one response (`usage`), the inputs of the monthly budget.
public struct ClaudeUsage: Sendable, Hashable {
    public var inputTokens: Int64 = 0
    public var outputTokens: Int64 = 0
    public var cacheCreationInputTokens: Int64 = 0
    public var cacheReadInputTokens: Int64 = 0
    /// `server_tool_use.web_search_requests`.
    public var webSearchRequests: Int64 = 0
    /// `server_tool_use.web_fetch_requests` (no per-request fee; counted for diagnostics).
    public var webFetchRequests: Int64 = 0

    public init(inputTokens: Int64 = 0, outputTokens: Int64 = 0, cacheCreationInputTokens: Int64 = 0,
                cacheReadInputTokens: Int64 = 0, webSearchRequests: Int64 = 0, webFetchRequests: Int64 = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.webSearchRequests = webSearchRequests
        self.webFetchRequests = webFetchRequests
    }

    /// Reads a `usage` object. Missing fields stay as they are (a stream's `message_delta` carries only some).
    public mutating func merge(_ value: JSONValue?) {
        guard let usage = value?.objectValue else { return }
        func read(_ key: String) -> Int64? { usage[key].flatMap { KotlinxJSON.long($0) } }
        if let v = read("input_tokens") { inputTokens = v }
        if let v = read("output_tokens") { outputTokens = v }
        if let v = read("cache_creation_input_tokens") { cacheCreationInputTokens = v }
        if let v = read("cache_read_input_tokens") { cacheReadInputTokens = v }
        if let server = usage["server_tool_use"]?.objectValue {
            if let v = server["web_search_requests"].flatMap({ KotlinxJSON.long($0) }) { webSearchRequests = v }
            if let v = server["web_fetch_requests"].flatMap({ KotlinxJSON.long($0) }) { webFetchRequests = v }
        }
    }

    public static func + (lhs: ClaudeUsage, rhs: ClaudeUsage) -> ClaudeUsage {
        ClaudeUsage(inputTokens: lhs.inputTokens + rhs.inputTokens, outputTokens: lhs.outputTokens + rhs.outputTokens,
                    cacheCreationInputTokens: lhs.cacheCreationInputTokens + rhs.cacheCreationInputTokens,
                    cacheReadInputTokens: lhs.cacheReadInputTokens + rhs.cacheReadInputTokens,
                    webSearchRequests: lhs.webSearchRequests + rhs.webSearchRequests,
                    webFetchRequests: lhs.webFetchRequests + rhs.webFetchRequests)
    }
}

/// A client `tool_use` block, with the raw input text (the accumulated `partial_json` of a stream) for the
/// `INVALID_JSON` answer.
public struct ClaudeToolUse: Sendable, Hashable {
    public var id: String
    public var name: String
    /// The parsed input (an empty object when it didn't parse).
    public var input: JSONObject
    public var rawInput: String
    /// The input text was not one strict JSON object.
    public var inputParseFailed: Bool

    public init(id: String, name: String, input: JSONObject, rawInput: String, inputParseFailed: Bool = false) {
        self.id = id
        self.name = name
        self.input = input
        self.rawInput = rawInput
        self.inputParseFailed = inputParseFailed
    }
}

/// A web page the answer cites (shown under the reply).
public struct ClaudeSource: Sendable, Hashable, Identifiable {
    public var url: String
    public var title: String
    public var id: String { url }

    public init(url: String, title: String) {
        self.url = url
        self.title = title
    }
}

/// One assistant response.
public struct ClaudeMessage: Sendable, Hashable {
    public var content: [JSONValue]
    public var stopReason: String?
    public var usage: ClaudeUsage
    public var model: String?
    /// Raw inputs of the client tool calls whose streamed JSON did not parse, by tool_use id.
    public var failedToolInputs: [String: String]

    public init(content: [JSONValue], stopReason: String?, usage: ClaudeUsage = ClaudeUsage(), model: String? = nil,
                failedToolInputs: [String: String] = [:]) {
        self.content = content
        self.stopReason = stopReason
        self.usage = usage
        self.model = model
        self.failedToolInputs = failedToolInputs
    }

    /// Reads a non-streaming response body; nil when it isn't a message.
    public static func parse(_ body: String) -> ClaudeMessage? {
        guard let root = try? JSONParser(mode: .strict).parse(body), let object = root.objectValue,
              object["type"]?.stringValue == "message", let content = object["content"]?.arrayValue else { return nil }
        var usage = ClaudeUsage()
        usage.merge(object["usage"])
        return ClaudeMessage(content: content, stopReason: object["stop_reason"]?.stringValue, usage: usage,
                             model: object["model"]?.stringValue)
    }

    /// The visible text: every `text` block, in order.
    public var text: String {
        content.compactMap { block in block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil }.joined()
    }

    /// The client tool calls, in order (server tools are Claude's own and never appear here).
    public var toolUses: [ClaudeToolUse] {
        content.compactMap { block in
            guard block["type"]?.stringValue == "tool_use", let id = block["id"]?.stringValue,
                  let name = block["name"]?.stringValue else { return nil }
            let input = block["input"]?.objectValue ?? JSONObject()
            if let raw = failedToolInputs[id] {
                return ClaudeToolUse(id: id, name: name, input: input, rawInput: raw, inputParseFailed: true)
            }
            return ClaudeToolUse(id: id, name: name, input: input, rawInput: JSONWriter.write(.object(input)))
        }
    }

    public var hasToolUse: Bool { content.contains { $0["type"]?.stringValue == "tool_use" } }

    /// The pages the text cites (`citations[].url`), distinct, in order of first citation.
    public var citedSources: [ClaudeSource] {
        var seen = Set<String>()
        var sources: [ClaudeSource] = []
        for block in content where block["type"]?.stringValue == "text" {
            for citation in block["citations"]?.arrayValue ?? [] {
                guard let url = citation["url"]?.stringValue, !url.isEmpty, seen.insert(url).inserted else { continue }
                let title = citation["title"]?.stringValue ?? ""
                sources.append(ClaudeSource(url: url, title: title.isEmpty ? Self.host(url) : title))
            }
        }
        return sources
    }

    /// "example.com" from a URL (the title when a citation has none).
    static func host(_ url: String) -> String {
        guard let host = URL(string: url)?.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
