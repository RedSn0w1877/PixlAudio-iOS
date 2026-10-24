import Foundation
import Testing
import PixlFoundation
@testable import PixlNet

// Claude over raw HTTPS (spec A3): request bodies, SSE assembly, retries, the tool loop, the router, the budget, the
// assistant's context and the saved-conversation format.

private func parse(_ text: String) throws -> JSONValue { try JSONParser(mode: .strict).parse(text) }

private func fixtureLines(_ name: String) throws -> [String] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/claude"))
    let text = try String(contentsOf: url, encoding: .utf8)
    return text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}

private func message(_ content: [JSONValue], stop: String, usage: ClaudeUsage = ClaudeUsage(outputTokens: 10)) -> ClaudeMessage {
    ClaudeMessage(content: content, stopReason: stop, usage: usage)
}

private func textBlock(_ text: String) -> JSONValue { ClaudeJSON.object([("type", .string("text")), ("text", .string(text))]) }

private func toolUseBlock(_ id: String, _ name: String, _ input: JSONValue) -> JSONValue {
    ClaudeJSON.object([("type", .string("tool_use")), ("id", .string(id)), ("name", .string(name)), ("input", input)])
}

/// Answers with scripted messages, recording each request.
private final class ScriptedClaude: ClaudeMessaging, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [ClaudeMessage]
    private(set) var requests: [ClaudeRequest] = []

    init(_ script: [ClaudeMessage]) { self.script = script }

    func send(_ request: ClaudeRequest, onUpdate: @escaping @Sendable (ClaudeStreamUpdate) async -> Void) async throws -> ClaudeMessage {
        let next: ClaudeMessage = lock.withLock {
            requests.append(request)
            return script.removeFirst()
        }
        let text = next.text
        if !text.isEmpty { await onUpdate(.text(text)) }
        return next
    }

    var recorded: [ClaudeRequest] { lock.withLock { requests } }
}

/// Records tool calls; answers with a fixed output.
private final class RecordingTools: ClaudeToolExecuting, @unchecked Sendable {
    let definitions: [ClaudeToolDefinition]
    let question: String?
    private let lock = NSLock()
    private var calls: [ClaudeToolUse] = []

    init(definitions: [ClaudeToolDefinition] = TaizoTool.definitions, question: String? = nil) {
        self.definitions = definitions
        self.question = question
    }

    func confirmation(for call: ClaudeToolUse) async -> String? { question }

    func run(_ call: ClaudeToolUse) async -> ClaudeToolOutput {
        lock.withLock { calls.append(call) }
        return .json(ClaudeJSON.object([("ok", .bool(true)), ("tool", .string(call.name))]))
    }

    var ran: [ClaudeToolUse] { lock.withLock { calls } }
}

private struct FixtureStreamer: ClaudeLineStreaming {
    let lines: [String]
    var failure: HTTPResponse?

    func open(_ request: HTTPRequest) async throws -> ClaudeStreamOpening {
        if let failure { return .failure(failure) }
        let lines = self.lines
        return .lines(AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        })
    }
}

@Suite struct ClaudeRequestTests {
    @Test func bodyFollowsTheApiRules() throws {
        let request = ClaudeRequest(system: TaizoAssistant.system(context: "<listening_context>x</listening_context>"),
                                    messages: [ClaudeJSON.userText("hi")], tools: TaizoTool.definitions,
                                    serverTools: TaizoAssistant.serverTools, effort: .medium, stream: true)
        let body = request.body
        #expect(body["model"]?.stringValue == "claude-sonnet-5-5")
        #expect(body["max_tokens"]?.int64Value == 32000)
        #expect(body["stream"]?.boolValue == true)
        #expect(body["fallbacks"]?.stringValue == "default")
        #expect(body["output_config"]?["effort"]?.stringValue == "medium")
        #expect(body["tool_choice"]?["type"]?.stringValue == "auto")
        for forbidden in ["temperature", "top_p", "top_k", "thinking"] { #expect(body[forbidden] == nil) }
        // System: instructions, then the context with the only cache breakpoint.
        let system = try #require(body["system"]?.arrayValue)
        #expect(system.count == 2)
        #expect(system[0]["cache_control"] == nil)
        #expect(system[1]["cache_control"]?["type"]?.stringValue == "ephemeral")
        // Tools: the client tools (strict, eager), then web search and fetch with max_uses 10.
        let tools = try #require(body["tools"]?.arrayValue)
        let clientCount = TaizoTool.allCases.count
        #expect(clientCount == 16)
        #expect(tools.count == clientCount + 2)
        #expect(tools.prefix(clientCount).map { $0["name"]?.stringValue ?? "" } == TaizoTool.allCases.map(\.rawValue))
        for tool in tools.prefix(clientCount) {
            // search_library opts out of strict (its 12 optional filters would break the API's budget of 24).
            #expect((tool["strict"]?.boolValue == true) == (tool["name"]?.stringValue != "search_library"))
            #expect(tool["eager_input_streaming"]?.boolValue == true)
            #expect(tool["input_schema"]?["additionalProperties"]?.boolValue == false)
        }
        #expect(tools[clientCount]["type"]?.stringValue == "web_search_20260209")
        #expect(tools[clientCount + 1]["type"]?.stringValue == "web_fetch_20260209")
        #expect(tools[clientCount + 1]["max_uses"]?.int64Value == 10)
        #expect(tools[clientCount]["eager_input_streaming"] == nil)
    }

    @Test func nonStreamingDefaultsAndHeaders() throws {
        let request = ClaudeRequest(system: [], messages: [ClaudeJSON.userText("hi")], effort: .high)
        #expect(request.maxTokens == 16000)
        #expect(request.body["stream"] == nil)
        #expect(request.body["tools"] == nil)
        #expect(request.body["tool_choice"] == nil)
        let http = request.httpRequest(apiKey: "sk-ant-test")
        #expect(http.url == "https://api.anthropic.com/v1/messages")
        #expect(http.method == .post)
        #expect(http.header("x-api-key") == "sk-ant-test")
        #expect(http.header("anthropic-version") == "2026-10-21")
        #expect(http.header("anthropic-beta") == "server-side-fallback-2026-07-01")
        #expect(http.header("content-type") == "application/json")
        #expect(!(http.bodyText ?? "").contains("sk-ant-test"), "the key never goes into the body")
    }

    @Test func nonStreamedToolsHaveNoEagerFlag() {
        let json = TaizoTool.searchSpotifyCatalog.definition.json(streaming: false)
        #expect(json["eager_input_streaming"] == nil)
        #expect(json["strict"]?.boolValue == true)
    }

    @Test func strictToolsStayWithinTheApisOptionalParameterBudget() {
        // The API refuses the whole request when the strict tools together have more than 24 optional parameters.
        var optional = 0
        for tool in TaizoTool.definitions where tool.strict {
            let properties = tool.inputSchema["properties"]?.objectValue?.members.count ?? 0
            let required = tool.inputSchema["required"]?.arrayValue?.count ?? 0
            optional += properties - required
        }
        #expect(optional <= 24, "strict tools have \(optional) optional parameters; the API limit is 24")
    }

    @Test func invalidJsonResultIsBuiltWithTheWriter() throws {
        let result = ClaudeToolResult.invalidJSON(toolUseId: "t1", raw: "{\"a\": \"b")
        #expect(result.isError)
        let decoded = try parse(result.content)
        #expect(decoded["INVALID_JSON"]?.stringValue == "{\"a\": \"b")
        #expect(result.json["is_error"]?.boolValue == true)
        #expect(result.json["tool_use_id"]?.stringValue == "t1")
    }
}

@Suite struct ClaudeStreamTests {
    @Test func assemblesEveryBlockKind() throws {
        let parser = ClaudeSSEParser()
        var accumulator = ClaudeStreamAccumulator()
        var updates: [ClaudeStreamUpdate] = []
        for line in try fixtureLines("stream-tool-use") {
            guard let event = parser.parse(line: line) else { continue }
            if let update = try accumulator.apply(event) { updates.append(update) }
        }
        #expect(accumulator.isComplete)
        let message = accumulator.message()
        #expect(message.stopReason == "tool_use")
        #expect(message.content.count == 6)
        #expect(message.content[0]["type"]?.stringValue == "thinking")
        #expect(message.content[0]["signature"]?.stringValue == "sig-abc")
        #expect(message.text == "Let me look that up.")
        #expect(message.content[2]["input"]?["query"]?.stringValue == "Daft Punk tour 2026")
        #expect(message.content[3]["content"]?.arrayValue?.first?["encrypted_content"]?.stringValue == "enc1",
                "server tool results pass through unchanged")
        // Client tools: the good one parsed, the broken one kept with its raw text.
        let tools = message.toolUses
        #expect(tools.count == 2)
        #expect(tools[0].name == "search_library")
        #expect(tools[0].input["limit"]?.int64Value == 5)
        #expect(!tools[0].inputParseFailed)
        #expect(tools[1].inputParseFailed)
        #expect(tools[1].rawInput == "{\"song_ids\": [\"a\", \"b\"] trailing")
        #expect(message.content[5]["input"]?.objectValue?.members.isEmpty == true)
        // Usage: message_start's input side, message_delta's output side.
        #expect(message.usage.inputTokens == 1200)
        #expect(message.usage.cacheCreationInputTokens == 3000)
        #expect(message.usage.outputTokens == 180)
        #expect(message.usage.webSearchRequests == 1)
        #expect(updates.contains(.text("Let me look ")))
        #expect(updates.contains(.toolStarted(name: "web_search", server: true)))
        #expect(updates.contains(.toolStarted(name: "search_library", server: false)))
        #expect(updates.contains(.serverToolResult(type: "web_search_tool_result")))
    }

    @Test func citationsBecomeSources() throws {
        let parser = ClaudeSSEParser()
        var accumulator = ClaudeStreamAccumulator()
        for line in try fixtureLines("stream-text-citations") {
            if let event = parser.parse(line: line) { try accumulator.apply(event) }
        }
        let message = accumulator.message()
        #expect(message.stopReason == "end_turn")
        #expect(message.text == "They tour from May.")
        #expect(message.content[0]["citations"]?.arrayValue?.count == 1)
        #expect(message.citedSources == [ClaudeSource(url: "https://www.example.com/tour", title: "Tour dates")])
    }

    @Test func parserIgnoresNonDataLinesAndHandlesCR() {
        let parser = ClaudeSSEParser()
        #expect(parser.parse(line: "event: ping") == nil)
        #expect(parser.parse(line: "") == nil)
        #expect(parser.parse(line: ": comment") == nil)
        #expect(parser.parse(line: "data: {\"type\":\"ping\"}\r") == .ping)
        #expect(parser.parse(line: "data:{\"type\":\"message_stop\"}") == .messageStop)
        #expect(parser.parse(line: "data: not json") == nil)
    }

    @Test func errorEventThrows() {
        var accumulator = ClaudeStreamAccumulator()
        #expect(throws: ClaudeError.stream(type: "overloaded_error", message: "Overloaded")) {
            try accumulator.apply(.error(type: "overloaded_error", message: "Overloaded"))
        }
    }

    @Test func streamingClientAssemblesAndReportsText() async throws {
        let client = ClaudeClient(apiKey: "k", http: FixtureHTTPClient { _ in HTTPResponse(statusCode: 500, text: "") },
                                  streamer: FixtureStreamer(lines: try fixtureLines("stream-text-citations")), sleep: { _ in })
        let seen = Box<[String]>([])
        let message = try await client.send(ClaudeRequest(system: [], messages: [ClaudeJSON.userText("x")], effort: .low, stream: true)) { update in
            if case .text(let text) = update { seen.mutate { $0.append(text) } }
        }
        #expect(message.text == "They tour from May.")
        #expect(seen.value == ["They tour from May."])
    }
}

@Suite struct ClaudeRetryTests {
    @Test func retriesRateLimitsAndServerErrorsTwice() async throws {
        let calls = Box(0)
        let http = FixtureHTTPClient { _ in
            calls.mutate { $0 += 1 }
            if calls.value < 3 { return HTTPResponse(statusCode: calls.value == 1 ? 429 : 529, headers: [HTTPHeader("retry-after", "3")], text: "{}") }
            return HTTPResponse(statusCode: 200, text: """
                {"type":"message","model":"claude-sonnet-5-5","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":5,"output_tokens":1}}
                """)
        }
        let waits = Box<[Double]>([])
        let client = ClaudeClient(apiKey: "k", http: http, sleep: { seconds in waits.mutate { $0.append(seconds) } })
        let message = try await client.send(ClaudeRequest(system: [], messages: [ClaudeJSON.userText("x")], effort: .low))
        #expect(message.text == "ok")
        #expect(calls.value == 3)
        #expect(waits.value == [3, 3], "retry-after is honoured")
    }

    @Test func givesUpAfterTwoRetries() async {
        let calls = Box(0)
        let http = FixtureHTTPClient { _ in
            calls.mutate { $0 += 1 }
            return HTTPResponse(statusCode: 503, text: "{\"type\":\"error\",\"error\":{\"type\":\"api_error\",\"message\":\"down\"}}")
        }
        let client = ClaudeClient(apiKey: "k", http: http, sleep: { _ in })
        await #expect(throws: ClaudeError.self) {
            _ = try await client.send(ClaudeRequest(system: [], messages: [], effort: .low))
        }
        #expect(calls.value == 3)
    }

    @Test func clientErrorsAreNotRetried() async {
        for status in [400, 401, 403] {
            let calls = Box(0)
            let http = FixtureHTTPClient { _ in
                calls.mutate { $0 += 1 }
                return HTTPResponse(statusCode: status, text: "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"bad\"}}")
            }
            let client = ClaudeClient(apiKey: "k", http: http, sleep: { _ in })
            do {
                _ = try await client.send(ClaudeRequest(system: [], messages: [], effort: .low))
                Issue.record("expected a failure")
            } catch let error as ClaudeError {
                #expect(error == .http(status: status, type: "invalid_request_error", message: "bad", retryAfterSeconds: nil))
            } catch {
                Issue.record("unexpected \(error)")
            }
            #expect(calls.value == 1)
        }
    }

    @Test func networkErrorsAreRetried() async throws {
        let calls = Box(0)
        let http = FixtureHTTPClient { _ in
            calls.mutate { $0 += 1 }
            if calls.value == 1 { throw HTTPTransportError(message: "The network connection was lost.") }
            return HTTPResponse(statusCode: 200, text: "{\"type\":\"message\",\"content\":[],\"stop_reason\":\"end_turn\"}")
        }
        let client = ClaudeClient(apiKey: "k", http: http, sleep: { _ in })
        _ = try await client.send(ClaudeRequest(system: [], messages: [], effort: .low))
        #expect(calls.value == 2)
    }

    @Test func policy() {
        #expect(ClaudeRetryPolicy.delay(for: .network("x"), attempt: 1) == 1)
        #expect(ClaudeRetryPolicy.delay(for: .network("x"), attempt: 2) == 2.5)
        #expect(ClaudeRetryPolicy.delay(for: .network("x"), attempt: 3) == nil)
        #expect(ClaudeRetryPolicy.delay(for: .http(status: 429, type: nil, message: nil, retryAfterSeconds: 60), attempt: 1) == nil,
                "a long retry-after gives up and falls back")
        #expect(ClaudeRetryPolicy.delay(for: .interrupted("x"), attempt: 1) == nil)
        #expect(ClaudeRetryPolicy.delay(for: .stream(type: "overloaded_error", message: ""), attempt: 1) == 1)
        #expect(ClaudeRetryPolicy.delay(for: .noKey, attempt: 1) == nil)
    }

    @Test func missingKeyFailsFast() async {
        let client = ClaudeClient(apiKey: "", http: FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: "") })
        await #expect(throws: ClaudeError.noKey) {
            _ = try await client.send(ClaudeRequest(system: [], messages: [], effort: .low))
        }
    }
}

@Suite struct ClaudeToolLoopTests {
    private func loop(_ client: ScriptedClaude, tools: any ClaudeToolExecuting = RecordingTools(),
                      confirm: @escaping @Sendable (String) async -> Bool = { _ in true },
                      events: Box<[ClaudeLoopEvent]> = Box([])) -> ClaudeToolLoop {
        ClaudeToolLoop(client: client, system: TaizoAssistant.system(context: "ctx"), tools: tools,
                       serverTools: TaizoAssistant.serverTools, effort: .medium, stream: true, confirm: confirm,
                       onEvent: { event in events.mutate { $0.append(event) } })
    }

    @Test func runsAllToolCallsAndReturnsResultsInOneMessage() async throws {
        let thinking = ClaudeJSON.object([("type", .string("thinking")), ("thinking", .string("")), ("signature", .string("s"))])
        let first = message([thinking, textBlock("On it. "),
                             toolUseBlock("t1", "search_library", ClaudeJSON.object([("query", .string("daft"))])),
                             toolUseBlock("t2", "playback_control", ClaudeJSON.object([("action", .string("pause"))]))],
                            stop: "tool_use")
        let second = message([textBlock("Paused.")], stop: "end_turn")
        let client = ScriptedClaude([first, second])
        let tools = RecordingTools()
        let result = try await loop(client, tools: tools).run(history: [ClaudeJSON.userText("pause and find daft")])
        #expect(result.outcome == .finished)
        #expect(result.text == "On it. Paused.")
        #expect(tools.ran.map(\.name) == ["search_library", "playback_control"])
        // The full assistant content (thinking included) went back unchanged, then one user message with both results.
        let nextRequest = client.recorded[1].messages
        #expect(nextRequest.count == 3)
        #expect(nextRequest[1] == ClaudeJSON.assistant(first.content))
        let results = try #require(nextRequest[2]["content"]?.arrayValue)
        #expect(results.map { $0["tool_use_id"]?.stringValue } == ["t1", "t2"])
        #expect(result.appended.count == 3)
        #expect(result.usage.outputTokens == 20)
    }

    @Test func invalidAndSchemaBreakingInputsAreAnsweredWithInvalidJson() async throws {
        var broken = message([toolUseBlock("t1", "play_songs", ClaudeJSON.object([]))], stop: "tool_use")
        broken.failedToolInputs = ["t1": "{\"song_ids\": [\"a\""]
        let wrongType = message([toolUseBlock("t2", "search_library", ClaudeJSON.object([("query", .integer(5))]))], stop: "tool_use")
        let client = ScriptedClaude([broken, wrongType, message([textBlock("Sorry.")], stop: "end_turn")])
        let tools = RecordingTools()
        _ = try await loop(client, tools: tools).run(history: [ClaudeJSON.userText("x")])
        #expect(tools.ran.isEmpty, "invalid input never runs a tool")
        let firstResult = try #require(client.recorded[1].messages.last?["content"]?.arrayValue?.first)
        #expect(firstResult["is_error"]?.boolValue == true)
        #expect(try parse(firstResult["content"]?.stringValue ?? "")["INVALID_JSON"]?.stringValue == "{\"song_ids\": [\"a\"")
        let secondResult = try #require(client.recorded[2].messages.last?["content"]?.arrayValue?.first)
        #expect(try parse(secondResult["content"]?.stringValue ?? "")["INVALID_JSON"]?.stringValue == "{\"query\":5}")
    }

    @Test func pauseTurnIsResentWithoutAUserMessage() async throws {
        let paused = message([ClaudeJSON.object([("type", .string("server_tool_use")), ("id", .string("s1")),
                                                 ("name", .string("web_search")), ("input", ClaudeJSON.object([]))])],
                             stop: "pause_turn")
        let client = ScriptedClaude([paused, message([textBlock("Done.")], stop: "end_turn")])
        let result = try await loop(client).run(history: [ClaudeJSON.userText("x")])
        #expect(result.outcome == .finished)
        #expect(client.recorded[1].messages.count == 2)
        #expect(ClaudeJSON.role(client.recorded[1].messages[1]) == "assistant")
    }

    @Test func pauseTurnStopsAfterFiveContinuations() async throws {
        let paused = message([textBlock("…")], stop: "pause_turn")
        let client = ScriptedClaude(Array(repeating: paused, count: 6))
        let result = try await loop(client).run(history: [ClaudeJSON.userText("x")])
        #expect(result.outcome == .stepLimit)
        #expect(client.recorded.count == 6)
    }

    @Test func refusalRunsNoToolsAndKeepsNothing() async throws {
        let refused = message([textBlock("I can't"), toolUseBlock("t1", "playback_control",
                                                                  ClaudeJSON.object([("action", .string("next"))]))], stop: "refusal")
        let client = ScriptedClaude([refused])
        let tools = RecordingTools()
        let events = Box<[ClaudeLoopEvent]>([])
        let result = try await loop(client, tools: tools, events: events).run(history: [ClaudeJSON.userText("x")])
        #expect(result.outcome == .refused)
        #expect(result.appended.isEmpty)
        #expect(result.text.isEmpty)
        #expect(tools.ran.isEmpty)
        #expect(events.value.contains(.turnDiscarded))
    }

    @Test func maxTokensWithAToolCallRetriesOnceWithMoreTokens() async throws {
        let cut = message([toolUseBlock("t1", "create_playlist", ClaudeJSON.object([("name", .string("x"))]))], stop: "max_tokens")
        let client = ScriptedClaude([cut, cut])
        let tools = RecordingTools()
        let result = try await loop(client, tools: tools).run(history: [ClaudeJSON.userText("x")])
        #expect(result.outcome == .truncated)
        #expect(tools.ran.isEmpty)
        #expect(client.recorded.map(\.maxTokens) == [32000, 64000])
        #expect(client.recorded[1].messages.count == 1, "the cut turn is not appended")
    }

    @Test func declinedConfirmationDoesNotRun() async throws {
        let call = message([toolUseBlock("t1", "play_songs", ClaudeJSON.object([("song_ids", .array([.string("a")]))]))], stop: "tool_use")
        let client = ScriptedClaude([call, message([textBlock("OK, left it.")], stop: "end_turn")])
        let tools = RecordingTools(question: "Replace your queue?")
        let asked = Box<[String]>([])
        _ = try await loop(client, tools: tools, confirm: { question in
            asked.mutate { $0.append(question) }
            return false
        }).run(history: [ClaudeJSON.userText("x")])
        #expect(asked.value == ["Replace your queue?"])
        #expect(tools.ran.isEmpty)
        let result = try #require(client.recorded[1].messages.last?["content"]?.arrayValue?.first)
        #expect(try parse(result["content"]?.stringValue ?? "")["declined"]?.boolValue == true)
    }

    @Test func unknownToolsAndCaseSlipsAreHandled() async throws {
        let calls = message([toolUseBlock("t1", "Search_Library", ClaudeJSON.object([("query", .string("x"))])),
                             toolUseBlock("t2", "teleport", ClaudeJSON.object([]))], stop: "tool_use")
        let client = ScriptedClaude([calls, message([textBlock("ok")], stop: "end_turn")])
        let tools = RecordingTools()
        _ = try await loop(client, tools: tools).run(history: [ClaudeJSON.userText("x")])
        #expect(tools.ran.map(\.name) == ["search_library"])
        let results = try #require(client.recorded[1].messages.last?["content"]?.arrayValue)
        #expect(results[1]["is_error"]?.boolValue == true)
    }

    @Test func completionThrowsOnRefusal() async {
        let client = ScriptedClaude([message([], stop: "refusal")])
        await #expect(throws: ClaudeCompletion.Refused.self) {
            _ = try await ClaudeCompletion.text(client: client, system: [], prompt: "x", effort: .low)
        }
    }
}

@Suite struct ClaudeConversationTests {
    @Test func userTextJoinsATrailingUserMessage() {
        let history = [ClaudeJSON.userText("a"), ClaudeJSON.assistant([textBlock("b")]),
                       ClaudeJSON.toolResults([ClaudeToolResult(toolUseId: "t", content: "{}")])]
        let next = ClaudeConversation.appendingUserText(history, "c")
        #expect(next.count == 3)
        #expect(next[2]["content"]?.arrayValue?.count == 2)
        let fresh = ClaudeConversation.appendingUserText([ClaudeJSON.userText("a"), ClaudeJSON.assistant([textBlock("b")])], "c")
        #expect(fresh.count == 3)
        #expect(fresh[2] == ClaudeJSON.userText("c"))
    }

    @Test func trimmingStartsAtAUserTextAndDropsThinking() {
        let thinking = ClaudeJSON.object([("type", .string("thinking")), ("thinking", .string("")), ("signature", .string("s"))])
        var history: [JSONValue] = []
        for index in 0..<10 {
            history.append(ClaudeJSON.userText("q\(index)"))
            history.append(ClaudeJSON.assistant([thinking, toolUseBlock("t\(index)", "search_library", ClaudeJSON.object([]))]))
            history.append(ClaudeJSON.toolResults([ClaudeToolResult(toolUseId: "t\(index)", content: "{}")]))
            history.append(ClaudeJSON.assistant([thinking, textBlock("a\(index)")]))
        }
        let kept = ClaudeConversation.forRequest(history, maxMessages: 10)
        #expect(kept.count <= 10)
        #expect(ClaudeJSON.role(kept[0]) == "user")
        #expect(!ClaudeConversation.isToolResultMessage(kept[0]))
        for message in kept where ClaudeJSON.role(message) == "assistant" {
            #expect(!(message["content"]?.arrayValue ?? []).contains { $0["type"]?.stringValue == "thinking" })
        }
        #expect(ClaudeConversation.forRequest(history, maxMessages: 100) == history, "untrimmed history is unchanged")
    }
}

@Suite struct AIRoutingTests {
    @Test func decisions() {
        #expect(AIRouter.decide(AIRoutingInputs(isOnline: true, hasBuiltInKey: true, budgetExhausted: false)) == .claude)
        #expect(AIRouter.decide(AIRoutingInputs(isOnline: false, hasBuiltInKey: true, budgetExhausted: false)) == .onDevice(.offline))
        #expect(AIRouter.decide(AIRoutingInputs(isOnline: true, hasBuiltInKey: false, budgetExhausted: false)) == .onDevice(.noBuiltInKey))
        #expect(AIRouter.decide(AIRoutingInputs(isOnline: true, hasBuiltInKey: true, budgetExhausted: true)) == .onDevice(.budgetUsed))
        #expect(AIRouter.decide(AIRoutingInputs(isOnline: false, hasBuiltInKey: false, budgetExhausted: true,
                                                ownProviderOverride: true)) == .ownProvider)
        #expect(AIRouter.statusLine(.claude) == "Claude (cloud) — switches to this phone when offline")
        #expect(AIRouter.note(.claude) == nil)
        #expect(AIRouter.note(.onDevice(.budgetUsed)) != nil)
    }

    @Test func routedGeneratorFallsBackOnFailure() async throws {
        struct Fallback: AiContentGenerating {
            func generateContent(prompt: String, type: AiSystemPromptType, temperature: Float, context: String) async throws -> String {
                "local:\(prompt)"
            }
        }
        let failing = ClaudeClient(apiKey: "k", http: FixtureHTTPClient { _ in throw HTTPTransportError(message: "offline") },
                                   sleep: { _ in })
        let fallbacks = Box(0)
        let routed = ClaudeRoutedGenerator(route: { .claude }, claude: { failing }, fallback: Fallback(),
                                           onFallback: { _ in fallbacks.mutate { $0 += 1 } })
        #expect(try await routed.generateContent(prompt: "p", type: .playlist) == "local:p")
        #expect(fallbacks.value == 1)

        let client = ScriptedClaude([message([textBlock("cloud")], stop: "end_turn", usage: ClaudeUsage(inputTokens: 100))])
        let usage = Box(ClaudeUsage())
        let cloud = ClaudeRoutedGenerator(route: { .claude }, claude: { client }, fallback: Fallback(),
                                          onUsage: { used in usage.mutate { $0 = $0 + used } })
        #expect(try await cloud.generateContent(prompt: "p", type: .playlist) == "cloud")
        #expect(client.recorded[0].effort == .high, "playlist building runs at high effort")
        #expect(client.recorded[0].stream == false)
        #expect(usage.value.inputTokens == 100)

        let offline = ClaudeRoutedGenerator(route: { .onDevice(.offline) }, claude: { client }, fallback: Fallback())
        #expect(try await offline.generateContent(prompt: "p", type: .general) == "local:p")
        #expect(ClaudeRoutedGenerator.effort(for: .taizoChat) == .medium)
    }
}

@Suite struct ClaudeBudgetTests {
    @Test func pricesSonnet() {
        #expect(ClaudePricing.cost(ClaudeUsage(inputTokens: 1_000_000)) == 2 * ClaudePricing.unitsPerDollar)
        #expect(ClaudePricing.cost(ClaudeUsage(outputTokens: 1_000_000)) == 10 * ClaudePricing.unitsPerDollar)
        #expect(ClaudePricing.cost(ClaudeUsage(cacheReadInputTokens: 1_000_000)) == 2_000_000) // $0.20
        #expect(ClaudePricing.cost(ClaudeUsage(cacheCreationInputTokens: 1_000_000)) == 25_000_000) // $2.50
        #expect(ClaudePricing.cost(ClaudeUsage(webSearchRequests: 1000)) == 10 * ClaudePricing.unitsPerDollar)
        #expect(ClaudePricing.dollars(ClaudePricing.cost(ClaudeUsage(inputTokens: 1500, outputTokens: 500))) == 0.008)
    }

    @Test func capAndMonthRollover() {
        var budget = ClaudeBudget(month: "2026-10", spentUnits: 0)
        #expect(!budget.isExhausted(capDollars: 50, month: "2026-10"))
        budget = budget.recording(ClaudeUsage(outputTokens: 5_000_000), month: "2026-10") // $50
        #expect(budget.isExhausted(capDollars: 50, month: "2026-10"))
        #expect(!budget.isExhausted(capDollars: 60, month: "2026-10"))
        #expect(!budget.isExhausted(capDollars: 50, month: "2026-11"), "a new month starts again")
        #expect(budget.recording(ClaudeUsage(outputTokens: 1), month: "2026-11").spentUnits == 100)
        #expect(ClaudeBudget(month: "2026-10", spentUnits: 0).isExhausted(capDollars: 0, month: "2026-10"), "$0 turns the key off")
        #expect(ClaudeBudget.clampCap(500) == 200)
        #expect(ClaudeBudget.clampCap(-1) == 0)
        #expect(ClaudeBudget.clampCap(.nan) == 50)
        #expect(ClaudeBudget.defaultCapDollars == 50)
    }

    @Test func monthKey() {
        let date = Date(timeIntervalSince1970: 1_793_000_000) // 2026-10-26 UTC
        #expect(ClaudeBudget.monthKey(date, timeZone: TimeZone(identifier: "UTC")!) == "2026-10")
        #expect(ClaudeBudget.monthKey(Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!) == "1970-01")
    }
}

@Suite struct ClaudeSchemaTests {
    @Test func validatesTheToolSchemas() {
        let schema = TaizoTool.playbackControl.definition.inputSchema
        #expect(ClaudeSchemaValidator.validate(ClaudeJSON.object([("action", .string("seek")), ("seek_ms", .integer(1000))]), against: schema).isEmpty)
        #expect(!ClaudeSchemaValidator.validate(ClaudeJSON.object([("action", .string("rewind"))]), against: schema).isEmpty)
        #expect(!ClaudeSchemaValidator.validate(ClaudeJSON.object([]), against: schema).isEmpty, "action is required")
        #expect(!ClaudeSchemaValidator.validate(ClaudeJSON.object([("action", .string("play")), ("volume", .integer(3))]), against: schema).isEmpty,
                "closed objects reject unknown keys")
        #expect(!ClaudeSchemaValidator.validate(ClaudeJSON.object([("action", .string("seek")), ("seek_ms", .number("1.5"))]), against: schema).isEmpty)
        let play = TaizoTool.playSongs.definition.inputSchema
        #expect(ClaudeSchemaValidator.validate(ClaudeJSON.object([("song_ids", .array([.string("a")]))]), against: play).isEmpty)
        #expect(!ClaudeSchemaValidator.validate(ClaudeJSON.object([("song_ids", .array([.integer(1)]))]), against: play).isEmpty)
        #expect(ClaudeSchemaValidator.validate(ClaudeJSON.object([]), against: TaizoTool.startSing.definition.inputSchema).isEmpty)
    }

    @Test func everyToolSchemaIsStrictCompatible() {
        func check(_ schema: JSONValue) {
            guard let object = schema.objectValue else { return }
            if object["type"]?.stringValue == "object" { #expect(object["additionalProperties"]?.boolValue == false) }
            for forbidden in ["minimum", "maximum", "minLength", "maxLength", "multipleOf"] { #expect(object[forbidden] == nil) }
            for member in object["properties"]?.objectValue?.members ?? [] { check(member.value) }
            if let items = object["items"] { check(items) }
        }
        for tool in TaizoTool.allCases {
            check(tool.definition.inputSchema)
            #expect(tool.definition.description.contains("Call this"), "\(tool.rawValue) says when to call it")
        }
    }
}

@Suite struct TaizoAssistantTests {
    @Test func contextRendersCompactly() {
        let context = TaizoListeningContext(librarySongCount: 1200, libraryArtistCount: 300,
                                            playlistNames: (1...50).map { "List \($0)" }, periodLabel: "last 30 days",
                                            topArtists: ["Daft Punk", "Air"], topGenres: ["Electronic"],
                                            topSongs: [TaizoSongLine(title: "One More Time", artist: "Daft Punk", detail: "12 plays")],
                                            recentPlays: [TaizoSongLine(title: "La femme d'argent", artist: "Air")],
                                            importedHistory: "48,210 plays from Spotify")
        let text = context.render()
        #expect(text.hasPrefix("<listening_context>"))
        #expect(text.contains("Library: 1200 songs by 300 artists."))
        #expect(text.contains("(+10 more)"))
        #expect(text.contains("- One More Time — Daft Punk (12 plays)"))
        #expect(text.contains("Imported history: 48,210 plays from Spotify"))
        #expect(text.count < 4000)
    }

    @Test func nowBlockCarriesTheSongAndSendsLyricsOnce() {
        let song = TaizoCurrentSong(id: "s1", title: "Get Lucky", artists: "Daft Punk, Pharrell Williams", album: "RAM", year: 2013,
                                    durationMs: 369_000, positionMs: 65_000, isPlaying: true, spotifyId: "sp1", isrc: "USQX91300108",
                                    hasInstrumental: true)
        var now = TaizoNowContext(localTime: "Fri 21:05", song: song, upNext: [TaizoSongLine(title: "Lose Yourself to Dance", artist: "Daft Punk")],
                                  lyrics: "Like the legend of the phoenix\n\n\nAll ends with beginnings")
        let text = now.render()
        #expect(text.contains("Playing: Get Lucky — Daft Punk, Pharrell Williams"))
        #expect(text.contains("position 1:05 of 6:09"))
        #expect(text.contains("spotify_id sp1"))
        #expect(text.contains("ISRC USQX91300108"))
        #expect(text.contains("instrumental ready for Sing"))
        #expect(text.contains("Like the legend of the phoenix\n\nAll ends with beginnings"), "blank runs collapse")
        now.lyricsAlreadySent = true
        #expect(now.render().contains("Lyrics: as sent earlier"))
        #expect(TaizoNowContext(localTime: "t", song: nil).render().contains("Nothing is playing."))
        let long = String(repeating: "la la la la la la la la\n", count: 500)
        #expect(TaizoNowContext.trimLyrics(long).count <= TaizoNowContext.maxLyricsCharacters + 2)
        #expect(TaizoNowContext.trimLyrics(long).hasSuffix("…"))
    }

    @Test func confirmationRules() {
        let ids = JSONValue.array((0..<51).map { .string("s\($0)") })
        #expect(TaizoAssistant.confirmationQuestion(tool: "create_playlist",
                                                    input: JSONObject([(key: "name", value: .string("Road")), (key: "song_ids", value: ids)]),
                                                    currentQueueCount: 0) == "Create “Road” with 51 songs?")
        #expect(TaizoAssistant.confirmationQuestion(tool: "create_playlist", input: JSONObject([(key: "song_ids", value: .array([.string("a")]))]),
                                                    currentQueueCount: 0) == nil)
        #expect(TaizoAssistant.confirmationQuestion(tool: "play_songs", input: JSONObject([(key: "song_ids", value: .array([.string("a")]))]),
                                                    currentQueueCount: 12) == "Replace your queue (12 songs) with 1 song?")
        #expect(TaizoAssistant.confirmationQuestion(tool: "play_songs", input: JSONObject(), currentQueueCount: 1) == nil)
        #expect(TaizoAssistant.confirmationQuestion(tool: "add_to_queue", input: JSONObject(), currentQueueCount: 50) == nil)
    }

    @Test func conversationsRoundTripAndKeepTheNewestFive() throws {
        let assistant = ClaudeJSON.assistant([ClaudeJSON.object([("type", .string("thinking")), ("thinking", .string("")),
                                                                 ("signature", .string("sig"))]), textBlock("Hi")])
        var records: [TaizoConversationRecord] = []
        for index in 0..<7 {
            records.append(TaizoConversationRecord(
                id: "c\(index)", title: "Chat \(index)", createdAt: Int64(index), updatedAt: Int64(index * 10), context: "ctx\(index)",
                messages: [ClaudeJSON.userText("hello"), assistant],
                transcript: [TaizoTranscriptEntry(role: .user, text: "hello"),
                             TaizoTranscriptEntry(role: .assistant, text: "Hi", sources: [ClaudeSource(url: "https://a.b", title: "A")]),
                             TaizoTranscriptEntry(role: .note, text: "Offline", isError: true)],
                lyricsSongKey: index == 6 ? "s1" : nil))
        }
        let decoded = TaizoConversationCodec.decode(TaizoConversationCodec.encode(records))
        #expect(decoded.map(\.id) == ["c6", "c5", "c4", "c3", "c2"])
        #expect(decoded[0] == records[6], "messages (thinking signature included) survive unchanged")
        #expect(TaizoConversationCodec.decode("not json").isEmpty)
        #expect(TaizoConversationRecord.title(from: "Tell me everything about the meaning behind this song and its video please")
            .hasSuffix("…"))
        #expect(TaizoConversationRecord.title(from: "Who sings this?") == "Who sings this?")
    }

    @Test func keySharesCombineAndRedact() {
        let key = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789"
        var seed: UInt8 = 7
        let shares = ClaudeKeyShares.split(key, count: 4) {
            seed = seed &* 31 &+ 11
            return seed
        }
        #expect(shares.count == 4)
        #expect(!shares.contains { String(decoding: $0, as: UTF8.self) == key })
        #expect(ClaudeKeyShares.combine(shares) == key)
        #expect(ClaudeKeyShares.combine([]) == nil, "the committed stub: no built-in key")
        #expect(ClaudeKeyShares.combine([[1, 2], [3]]) == nil)
        #expect(ClaudeKeyShares.redact("x-api-key: \(key)", key: key) == "x-api-key: [redacted]")
    }
}
