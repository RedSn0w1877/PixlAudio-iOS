// Saved "Ask Taizo" conversations (spec A4: the last few are kept on the phone; "New chat" starts another). Each keeps
// what the user saw (the transcript) and what the API needs to carry on (the system blocks it started with and the
// messages exactly as exchanged — assistant turns unchanged, so preserved thinking and the prompt cache keep working).
// Written as one JSON document with PixlFoundation's writer; unreadable or unknown entries are skipped on read.

import Foundation
import PixlFoundation

/// One line of the transcript.
public struct TaizoTranscriptEntry: Sendable, Hashable {
    public enum Role: String, Sendable, Hashable {
        case user, assistant, note
    }

    public var role: Role
    public var text: String
    public var sources: [ClaudeSource]
    public var isError: Bool

    public init(role: Role, text: String, sources: [ClaudeSource] = [], isError: Bool = false) {
        self.role = role
        self.text = text
        self.sources = sources
        self.isError = isError
    }
}

/// One conversation.
public struct TaizoConversationRecord: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var createdAt: Int64
    public var updatedAt: Int64
    /// The instruction block the conversation started with.
    public var instructions: String
    /// The listening-context block it started with.
    public var context: String
    public var messages: [JSONValue]
    public var transcript: [TaizoTranscriptEntry]
    /// The song whose lyrics were last sent (they aren't sent again while it plays).
    public var lyricsSongKey: String?

    public init(id: String, title: String = "", createdAt: Int64, updatedAt: Int64? = nil,
                instructions: String = TaizoAssistant.instructions, context: String, messages: [JSONValue] = [],
                transcript: [TaizoTranscriptEntry] = [], lyricsSongKey: String? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.instructions = instructions
        self.context = context
        self.messages = messages
        self.transcript = transcript
        self.lyricsSongKey = lyricsSongKey
    }

    public var system: [ClaudeSystemBlock] { TaizoAssistant.system(instructions: instructions, context: context) }

    /// A title from the first thing the user asked (at most 48 characters, on a word boundary).
    public static func title(from text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard flat.count > 48 else { return flat }
        var cut = String(flat.prefix(48))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > 24 {
            cut = String(cut[..<space])
        }
        return cut + "…"
    }
}

public enum TaizoConversationCodec {
    public static let formatVersion = 1
    /// Conversations kept (newest first).
    public static let maxConversations = 5

    /// The newest `maxConversations`, newest first.
    public static func pruned(_ records: [TaizoConversationRecord]) -> [TaizoConversationRecord] {
        Array(records.sorted { $0.updatedAt > $1.updatedAt }.prefix(maxConversations))
    }

    public static func encode(_ records: [TaizoConversationRecord]) -> String {
        JSONWriter.write(ClaudeJSON.object([
            ("version", .integer(formatVersion)),
            ("conversations", .array(pruned(records).map(encode))),
        ]))
    }

    static func encode(_ record: TaizoConversationRecord) -> JSONValue {
        var members: [(String, JSONValue)] = [
            ("id", .string(record.id)),
            ("title", .string(record.title)),
            ("createdAt", .integer(record.createdAt)),
            ("updatedAt", .integer(record.updatedAt)),
            ("instructions", .string(record.instructions)),
            ("context", .string(record.context)),
            ("messages", .array(record.messages)),
            ("transcript", .array(record.transcript.map(encode))),
        ]
        if let key = record.lyricsSongKey { members.append(("lyricsSongKey", .string(key))) }
        return ClaudeJSON.object(members)
    }

    static func encode(_ entry: TaizoTranscriptEntry) -> JSONValue {
        var members: [(String, JSONValue)] = [("role", .string(entry.role.rawValue)), ("text", .string(entry.text))]
        if !entry.sources.isEmpty {
            members.append(("sources", .array(entry.sources.map {
                ClaudeJSON.object([("url", .string($0.url)), ("title", .string($0.title))])
            })))
        }
        if entry.isError { members.append(("isError", .bool(true))) }
        return ClaudeJSON.object(members)
    }

    /// Reads a saved document; nothing (rather than an error) when it can't be read.
    public static func decode(_ text: String) -> [TaizoConversationRecord] {
        guard let root = try? JSONParser(mode: .strict).parse(text), let list = root["conversations"]?.arrayValue else { return [] }
        return pruned(list.compactMap(decodeRecord))
    }

    static func decodeRecord(_ value: JSONValue) -> TaizoConversationRecord? {
        guard let id = value["id"]?.stringValue, let context = value["context"]?.stringValue,
              let createdAt = value["createdAt"]?.int64Value else { return nil }
        let transcript: [TaizoTranscriptEntry] = (value["transcript"]?.arrayValue ?? []).compactMap { entry in
            guard let role = entry["role"]?.stringValue.flatMap(TaizoTranscriptEntry.Role.init(rawValue:)),
                  let text = entry["text"]?.stringValue else { return nil }
            let sources = (entry["sources"]?.arrayValue ?? []).compactMap { source -> ClaudeSource? in
                guard let url = source["url"]?.stringValue else { return nil }
                return ClaudeSource(url: url, title: source["title"]?.stringValue ?? url)
            }
            return TaizoTranscriptEntry(role: role, text: text, sources: sources, isError: entry["isError"]?.boolValue ?? false)
        }
        let messages = (value["messages"]?.arrayValue ?? []).filter { ClaudeJSON.role($0) == "user" || ClaudeJSON.role($0) == "assistant" }
        return TaizoConversationRecord(id: id, title: value["title"]?.stringValue ?? "", createdAt: createdAt,
                                       updatedAt: value["updatedAt"]?.int64Value ?? createdAt,
                                       instructions: value["instructions"]?.stringValue ?? TaizoAssistant.instructions,
                                       context: context, messages: messages, transcript: transcript,
                                       lyricsSongKey: value["lyricsSongKey"]?.stringValue)
    }
}

public extension ClaudeConversation {
    /// The history to send: at most `maxMessages` recent messages. When older ones were dropped, the kept assistant
    /// turns lose their thinking blocks (they were produced after messages that are gone, which the API rejects).
    static func forRequest(_ history: [JSONValue], maxMessages: Int = 80) -> [JSONValue] {
        let kept = trimmed(history, maxMessages: maxMessages)
        guard kept.count < history.count else { return history }
        return kept.map { message in
            guard ClaudeJSON.role(message) == "assistant", let object = message.objectValue,
                  let blocks = object["content"]?.arrayValue else { return message }
            let filtered = blocks.filter {
                let type = $0["type"]?.stringValue
                return type != "thinking" && type != "redacted_thinking"
            }
            let content = filtered.isEmpty ? [ClaudeJSON.object([("type", .string("text")), ("text", .string("…"))])] : filtered
            return .object(ClaudeJSON.setting(object, "content", .array(content)))
        }
    }
}
