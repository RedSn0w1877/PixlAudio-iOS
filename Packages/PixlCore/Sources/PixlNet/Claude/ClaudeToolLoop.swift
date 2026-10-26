// The agentic loop (spec A3): send, then
// - `tool_use`: append the FULL assistant content unchanged, run every client tool call of the turn (validated against
//   its schema; destructive ones confirmed by the user first) and return all `tool_result`s in ONE user message;
// - `pause_turn`: append the assistant turn and resend as-is, no user message (at most 5 times);
// - `refusal`: stop, run none of that turn's tools, the exchange is not kept;
// - `max_tokens` while writing a tool call: don't run it, retry the turn once with a doubled budget;
// - `end_turn` (or anything else): done.
// A short helper (`ClaudeCompletion`) runs single prompts for the other AI features on the same loop.

import Foundation
import PixlFoundation

/// What a client tool returned.
public struct ClaudeToolOutput: Sendable, Hashable {
    public var content: String
    public var isError: Bool

    public init(content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    /// `{"error": "<message>"}`, flagged as an error.
    public static func error(_ message: String) -> ClaudeToolOutput {
        ClaudeToolOutput(content: JSONWriter.write(ClaudeJSON.object([("error", .string(message))])), isError: true)
    }

    /// A JSON value written with the JSON writer.
    public static func json(_ value: JSONValue) -> ClaudeToolOutput { ClaudeToolOutput(content: JSONWriter.write(value)) }
}

/// The client tools of a conversation.
public protocol ClaudeToolExecuting: Sendable {
    /// In a fixed order (the tool list is part of the cached prefix).
    var definitions: [ClaudeToolDefinition] { get }
    /// A question the user must confirm before this call runs (a large or destructive action), or nil.
    func confirmation(for call: ClaudeToolUse) async -> String?
    func run(_ call: ClaudeToolUse) async -> ClaudeToolOutput
}

/// No client tools.
public struct ClaudeNoTools: ClaudeToolExecuting {
    public init() {}
    public var definitions: [ClaudeToolDefinition] { [] }
    public func confirmation(for call: ClaudeToolUse) async -> String? { nil }
    public func run(_ call: ClaudeToolUse) async -> ClaudeToolOutput { .error("No tools are available.") }
}

/// What the loop reports while it works.
public enum ClaudeLoopEvent: Sendable, Hashable {
    /// A request is about to be sent (the UI remembers the text so far).
    case requestStarted
    case stream(ClaudeStreamUpdate)
    /// The last request's streamed text is void (a turn retried after `max_tokens`, or refused).
    case turnDiscarded
    case toolRunning(name: String)
    case toolFinished(name: String, isError: Bool)
}

/// How a run ended.
public enum ClaudeLoopOutcome: Sendable, Hashable {
    case finished
    /// `stop_reason: refusal` — nothing of this exchange is kept.
    case refused
    /// Cut off at `max_tokens` (twice, for a tool call).
    case truncated
    /// Too many steps or `pause_turn` continuations.
    case stepLimit
}

public struct ClaudeLoopResult: Sendable, Hashable {
    /// The messages this run added after the history it was given (assistant turns and tool results).
    public var appended: [JSONValue]
    /// The visible text of every kept turn, in order.
    public var text: String
    public var sources: [ClaudeSource]
    public var usage: ClaudeUsage
    public var outcome: ClaudeLoopOutcome
}

public struct ClaudeToolLoop: Sendable {
    public static let maxPauseContinuations = 5
    public static let maxSteps = 14

    public let client: any ClaudeMessaging
    public let system: [ClaudeSystemBlock]
    public let tools: any ClaudeToolExecuting
    public let serverTools: [ClaudeServerTool]
    public let effort: ClaudeEffort
    public let stream: Bool
    /// Asks the user (a tap in the chat); false = declined.
    public let confirm: @Sendable (String) async -> Bool
    public let onEvent: @Sendable (ClaudeLoopEvent) async -> Void
    /// Called with every response's usage as soon as it arrives (the budget is charged even if a later step fails).
    public let onUsage: @Sendable (ClaudeUsage) async -> Void

    public init(client: any ClaudeMessaging, system: [ClaudeSystemBlock], tools: any ClaudeToolExecuting = ClaudeNoTools(),
                serverTools: [ClaudeServerTool] = [], effort: ClaudeEffort, stream: Bool,
                confirm: @escaping @Sendable (String) async -> Bool = { _ in false },
                onEvent: @escaping @Sendable (ClaudeLoopEvent) async -> Void = { _ in },
                onUsage: @escaping @Sendable (ClaudeUsage) async -> Void = { _ in }) {
        self.client = client
        self.system = system
        self.tools = tools
        self.serverTools = serverTools
        self.effort = effort
        self.stream = stream
        self.confirm = confirm
        self.onEvent = onEvent
        self.onUsage = onUsage
    }

    /// Runs from `history` (which ends with the user's message) until the model is done.
    public func run(history: [JSONValue]) async throws -> ClaudeLoopResult {
        let definitions = tools.definitions
        var messages = history
        var appended: [JSONValue] = []
        var text = ""
        var sources: [ClaudeSource] = []
        var seenSources = Set<String>()
        var usage = ClaudeUsage()
        var maxTokens = stream ? ClaudeAPI.maxTokensStreaming : ClaudeAPI.maxTokensNonStreaming
        var raisedForToolCall = false
        var pauses = 0

        func result(_ outcome: ClaudeLoopOutcome) -> ClaudeLoopResult {
            ClaudeLoopResult(appended: appended, text: text, sources: sources, usage: usage, outcome: outcome)
        }

        for _ in 0..<Self.maxSteps {
            try Task.checkCancellation()
            await onEvent(.requestStarted)
            let request = ClaudeRequest(system: system, messages: messages, tools: definitions, serverTools: serverTools,
                                        effort: effort, maxTokens: maxTokens, stream: stream)
            let onEvent = self.onEvent
            let message = try await client.send(request) { update in await onEvent(.stream(update)) }
            usage = usage + message.usage
            await onUsage(message.usage)

            if message.stopReason == "refusal" {
                await onEvent(.turnDiscarded)
                return ClaudeLoopResult(appended: [], text: "", sources: [], usage: usage, outcome: .refused)
            }
            if message.stopReason == "max_tokens", message.hasToolUse {
                await onEvent(.turnDiscarded)
                guard !raisedForToolCall else { return result(.truncated) }
                raisedForToolCall = true
                maxTokens = min(maxTokens * 2, ClaudeAPI.maxTokensCeiling)
                continue
            }

            text += message.text
            for source in message.citedSources where seenSources.insert(source.url).inserted { sources.append(source) }
            let assistant = ClaudeJSON.assistant(message.content)
            messages.append(assistant)
            appended.append(assistant)

            switch message.stopReason {
            case "pause_turn":
                pauses += 1
                if pauses > Self.maxPauseContinuations { return result(.stepLimit) }
            case "tool_use":
                let calls = message.toolUses
                guard !calls.isEmpty else { return result(.finished) }
                var results: [ClaudeToolResult] = []
                for call in calls {
                    results.append(await execute(call, definitions: definitions))
                }
                let toolMessage = ClaudeJSON.toolResults(results)
                messages.append(toolMessage)
                appended.append(toolMessage)
            case "max_tokens":
                return result(.truncated)
            default:
                return result(.finished)
            }
        }
        return result(.stepLimit)
    }

    /// One client tool call → its `tool_result` (never throws: failures go back to the model as errors).
    func execute(_ call: ClaudeToolUse, definitions: [ClaudeToolDefinition]) async -> ClaudeToolResult {
        // The model occasionally changes a name's letter case: accept an unambiguous match.
        let definition = definitions.first { $0.name == call.name }
            ?? Self.unique(definitions.filter { $0.name.lowercased() == call.name.lowercased() })
        guard let definition else {
            let names = definitions.map(\.name).joined(separator: ", ")
            return ClaudeToolResult(toolUseId: call.id, content: ClaudeToolOutput.error(
                "Unknown tool '\(call.name)'. Available tools: \(names).").content, isError: true)
        }
        if call.inputParseFailed {
            return .invalidJSON(toolUseId: call.id, raw: call.rawInput)
        }
        if !ClaudeSchemaValidator.validate(.object(call.input), against: definition.inputSchema).isEmpty {
            return .invalidJSON(toolUseId: call.id, raw: call.rawInput)
        }
        var named = call
        named.name = definition.name
        if let question = await tools.confirmation(for: named) {
            guard await confirm(question) else {
                return ClaudeToolResult(toolUseId: call.id, content: JSONWriter.write(ClaudeJSON.object([
                    ("declined", .bool(true)),
                    ("message", .string("The user tapped Cancel. Don't do this unless they ask again.")),
                ])))
            }
        }
        await onEvent(.toolRunning(name: definition.name))
        let output = await tools.run(named)
        await onEvent(.toolFinished(name: definition.name, isError: output.isError))
        return ClaudeToolResult(toolUseId: call.id, content: output.content, isError: output.isError)
    }

    private static func unique(_ matches: [ClaudeToolDefinition]) -> ClaudeToolDefinition? {
        matches.count == 1 ? matches[0] : nil
    }
}

/// Conversation history helpers.
public enum ClaudeConversation {
    /// Adds the user's text as the next message. When the history already ends with a user message (a run that
    /// stopped right after tool results), the text joins that message so roles keep alternating.
    public static func appendingUserText(_ history: [JSONValue], _ text: String) -> [JSONValue] {
        let block = ClaudeJSON.object([("type", .string("text")), ("text", .string(text))])
        guard let last = history.last, ClaudeJSON.role(last) == "user", var object = last.objectValue else {
            return history + [ClaudeJSON.userText(text)]
        }
        let content: [JSONValue]
        switch object["content"] {
        case .array(let blocks)?: content = blocks + [block]
        case .string(let existing)?:
            content = [ClaudeJSON.object([("type", .string("text")), ("text", .string(existing))]), block]
        default: content = [block]
        }
        object = ClaudeJSON.setting(object, "content", .array(content))
        return Array(history.dropLast()) + [.object(object)]
    }

    /// The most recent messages that fit `maxMessages`, cut so the kept part starts with a user message carrying
    /// text (never with tool results, whose `tool_use` would be gone).
    public static func trimmed(_ history: [JSONValue], maxMessages: Int) -> [JSONValue] {
        guard history.count > maxMessages else { return history }
        var start = history.count - maxMessages
        while start < history.count {
            let message = history[start]
            if ClaudeJSON.role(message) == "user", !isToolResultMessage(message) { break }
            start += 1
        }
        return Array(history[start...])
    }

    static func isToolResultMessage(_ message: JSONValue) -> Bool {
        guard let blocks = message["content"]?.arrayValue else { return false }
        return blocks.contains { $0["type"]?.stringValue == "tool_result" }
    }
}

/// A single prompt (playlists, insights, greetings, translations): the loop with no client tools, not streamed.
public enum ClaudeCompletion {
    /// A refusal: the feature falls back like for any other failure.
    public struct Refused: Error, Sendable, Hashable {}

    public static func text(client: any ClaudeMessaging, system: [ClaudeSystemBlock], prompt: String, effort: ClaudeEffort,
                            serverTools: [ClaudeServerTool] = [],
                            onUsage: @escaping @Sendable (ClaudeUsage) async -> Void = { _ in }) async throws -> String {
        let loop = ClaudeToolLoop(client: client, system: system, serverTools: serverTools, effort: effort, stream: false,
                                  onUsage: onUsage)
        let result = try await loop.run(history: [ClaudeJSON.userText(prompt)])
        if result.outcome == .refused { throw Refused() }
        return result.text
    }
}
