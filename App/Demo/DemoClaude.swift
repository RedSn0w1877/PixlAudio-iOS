import Foundation
import PixlFoundation
import PixlNet

/// The scripted Claude of the `taisChatCloud` UI test (no network, no key): it drives the real tool loop, tools and
/// UI. A question about the song gets a streamed answer citing a web page; a playlist request searches the demo library
/// with `search_library`, then asks to create a 60-song playlist, which waits for the tap to confirm.
nonisolated struct DemoClaudeClient: ClaudeMessaging {
    func send(_ request: ClaudeRequest, onUpdate: @escaping @concurrent @Sendable (ClaudeStreamUpdate) async -> Void) async throws -> ClaudeMessage {
        let last = request.messages.last
        let blocks = last?["content"]?.arrayValue ?? []
        let lastText = blocks.compactMap { $0["text"]?.stringValue }.joined().lowercased()
        if let result = blocks.first(where: { $0["type"]?.stringValue == "tool_result" }) {
            return await afterSearch(result, onUpdate: onUpdate)
        }
        if lastText.contains("playlist") {
            await onUpdate(.toolStarted(name: TaizoTool.searchLibrary.rawValue, server: false))
            return ClaudeMessage(content: [
                text("Let me pull some driving songs from your library."),
                toolUse("toolu_demo_1", TaizoTool.searchLibrary.rawValue, ClaudeJSON.object([("query", .string("")), ("limit", .integer(30))])),
            ], stopReason: "tool_use", usage: ClaudeUsage(inputTokens: 900, outputTokens: 60))
        }
        await onUpdate(.toolStarted(name: ClaudeServerTool.webSearch.rawValue, server: true))
        let answer = "It's about chasing a feeling you can't hold for long — the chorus keeps circling back because the "
            + "moment keeps slipping away. The band has said they wrote it on a night drive after their first tour."
        for piece in Self.chunks(answer) {
            try? await Task.sleep(for: .milliseconds(40))
            await onUpdate(.text(piece))
        }
        var cited = JSONObject()
        cited.append("type", .string("text"))
        cited.append("text", .string(answer))
        cited.append("citations", .array([ClaudeJSON.object([
            ("type", .string("web_search_result_location")), ("url", .string("https://example.com/interview")),
            ("title", .string("Interview: the story behind the song")), ("cited_text", .string("a night drive")),
        ])]))
        return ClaudeMessage(content: [.object(cited)], stopReason: "end_turn",
                             usage: ClaudeUsage(inputTokens: 1200, outputTokens: 80, webSearchRequests: 1))
    }

    /// After the library search: a playlist of 60 picks (the demo library repeated), which needs a tap to confirm.
    private func afterSearch(_ result: JSONValue, onUpdate: @escaping @concurrent @Sendable (ClaudeStreamUpdate) async -> Void) async -> ClaudeMessage {
        if let content = result["content"]?.stringValue, content.contains("\"declined\"") || content.contains("\"created\"") {
            let reply = content.contains("\"created\"") ? "Done — “Road Trip” is in your library." : "No problem, I left it."
            await onUpdate(.text(reply))
            return ClaudeMessage(content: [text(reply)], stopReason: "end_turn")
        }
        let parsed = (result["content"]?.stringValue).flatMap { try? JSONParser().parse($0) }
        let ids = (parsed?["songs"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
        let picks = ids.isEmpty ? [] : (0..<60).map { ids[$0 % ids.count] }
        await onUpdate(.toolStarted(name: TaizoTool.createPlaylist.rawValue, server: false))
        return ClaudeMessage(content: [
            toolUse("toolu_demo_2", TaizoTool.createPlaylist.rawValue, ClaudeJSON.object([
                ("name", .string("Road Trip")), ("song_ids", .array(picks.map(JSONValue.string))),
            ])),
        ], stopReason: "tool_use", usage: ClaudeUsage(inputTokens: 1500, outputTokens: 400))
    }

    private func text(_ value: String) -> JSONValue {
        ClaudeJSON.object([("type", .string("text")), ("text", .string(value))])
    }

    private func toolUse(_ id: String, _ name: String, _ input: JSONValue) -> JSONValue {
        ClaudeJSON.object([("type", .string("tool_use")), ("id", .string(id)), ("name", .string(name)), ("input", input)])
    }

    private static func chunks(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            current += (current.isEmpty && out.isEmpty ? "" : " ") + word
            if current.count > 24 {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
