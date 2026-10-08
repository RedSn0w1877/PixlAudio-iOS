import Foundation
import PixlModel
import PixlNet

// The pure side of the on-device AI features (no Foundation Models here, so AppTests cover all of it and it
// type-checks without the iOS SDK): failures and their messages, token estimates and reply clean-up, the library
// lookup Taizo's tool answers with, and Taizo's prompts. `OnDeviceAI` runs the model with them.

/// Why an on-device request failed, with the message the user sees.
///
/// No message contains a word other code matches for network or provider-key problems ("network", "connect",
/// "offline", "wifi", "timeout", "timed out", "key", "config", "denied", "permission"): `AiPlaylistPrompt
/// .detailedErrorMessage`, `AIPlaylistController.resolveErrorMessage` and `AILyricsTranslator.outcome(forFailure:)`
/// classify failures by those words, and an on-device failure used to come out as "No Internet Connection" because
/// the provider was named "On-Device (Offline)".
nonisolated enum OnDeviceFailure: Error, Sendable, Equatable {
    /// The request and its answer don't fit the model's context window.
    case tooLong
    /// The safety guardrails (or a refusal) stopped the request.
    case blocked
    /// The device language isn't one the model supports.
    case language
    /// The model is still downloading.
    case notReady
    /// Another request is running, or the system rate-limited the app.
    case busy
    /// The model didn't answer within the feature's time budget.
    case slow
    /// This iPhone can't run the on-device model.
    case deviceNotEligible
    /// The system's intelligence features are turned off.
    case intelligenceOff
    /// "Use downloaded AI model" is on but the model isn't installed (2026-10-07, local AI phase 2).
    case localModelMissing
    case other(String)

    /// Every failure with a fixed message, for matching text back to a failure.
    static let fixed: [OnDeviceFailure] = [.tooLong, .blocked, .language, .notReady, .busy, .slow, .deviceNotEligible,
                                           .intelligenceOff, .localModelMissing]

    var message: String {
        switch self {
        case .tooLong: "That request is too long for the on-device model. Try a shorter request or fewer songs."
        case .blocked: "The on-device model's safety filters stopped this request. Try rephrasing it."
        case .language: "The on-device model doesn't support this language yet."
        case .notReady: "The on-device model is still downloading. Try again in a few minutes."
        case .busy: "The on-device model is busy. Wait a moment and try again."
        case .slow: "The on-device model took too long to answer. Try again."
        case .deviceNotEligible:
            "On-device AI isn't supported on this iPhone. You can add a cloud assistant in Settings › AI features."
        case .intelligenceOff: "On-device AI is turned off. Turn on the intelligence features in the iPhone's Settings app."
        case .localModelMissing:
            "The downloaded AI model isn't on this iPhone yet. Download it in Settings › AI features, or turn off \"Use downloaded AI model\"."
        case .other(let detail):
            Self.isSafeDetail(detail) ? "The on-device model couldn't answer (\(detail)). Try again."
                : "The on-device model couldn't answer. Try again."
        }
    }

    /// A short state for Settings and the creation sheet.
    var title: String {
        switch self {
        case .deviceNotEligible: "Not available on this iPhone"
        case .intelligenceOff: "Turned off in system settings"
        case .notReady: "Downloading"
        case .language: "Language not supported yet"
        case .localModelMissing: "Downloaded model not on this iPhone"
        default: "Can't be used right now"
        }
    }

    /// The fixed failure whose message `text` contains (a failure that travelled through a text-only error).
    static func matching(_ text: String) -> OnDeviceFailure? {
        fixed.first { text.contains($0.message) }
    }

    /// Words other code reads as a network or provider-key problem.
    static let reservedWords = ["network", "connect", "offline", "wifi", "wi-fi", "timeout", "timed out", "key", "config",
                                "denied", "permission", "unauthorized", "not found", "unavailable", "empty response"]

    /// A system error description that can be shown without being misread as another kind of failure.
    static func isSafeDetail(_ detail: String) -> Bool {
        let lower = detail.lowercased()
        guard !lower.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, detail.count <= 160 else { return false }
        return !reservedWords.contains { lower.contains($0) }
    }
}

/// Token estimates, answer budgets and reply clean-up.
nonisolated enum OnDeviceText {
    /// A conservative estimate: one token per CJK, kana, Hangul, Thai or Vietnamese letter (the framework's
    /// context-window guide: about one character per token there), one per 3.5 other characters (three to four in
    /// Latin text), plus 10 %.
    static func estimatedTokens(_ text: String) -> Int {
        var dense = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if isDense(scalar) { dense += 1 } else { other += 1 }
        }
        let raw = Double(dense) + Double(other) / 3.5
        return Int((raw * 1.1).rounded(.up))
    }

    private static func isDense(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0E00...0x0E7F, // Thai
             0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF, // Hangul
             0x3040...0x30FF, 0x31F0...0x31FF, // kana
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F, // CJK ideographs
             0x1EA0...0x1EF9, 0x01A0, 0x01A1, 0x01AF, 0x01B0, 0x0110, 0x0111: // Vietnamese letters
            return true
        default:
            return false
        }
    }

    /// The answer budget left once `inputTokens` are spent: never above `cap`, never below 64.
    static func responseBudget(contextSize: Int, inputTokens: Int, cap: Int) -> Int {
        max(64, min(cap, contextSize - inputTokens - 32))
    }

    /// A String answer without the wrappers small models sometimes leak (iOS 27 beta notes, developer forums thread
    /// 840236): reasoning blocks, code fences, or a JSON object around the text.
    static func cleanReply(_ text: String) -> String {
        var reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let range = reply.range(of: #"(?s)<think>.*?</think>"#, options: .regularExpression) {
            reply.removeSubrange(range)
        }
        reply = reply.replacingOccurrences(of: #"```[A-Za-z]*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if reply.hasPrefix("{"), reply.hasSuffix("}"), let data = reply.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for field in ["response", "reply", "answer", "text", "content", "message"] {
                if let value = object[field] as? String {
                    reply = value
                    break
                }
            }
        }
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line of plain text: cleaned, the first non-empty line, Kotlin `trim('"')`, at most `limit` characters.
    static func singleLine(_ text: String, limit: Int) -> String? {
        let cleaned = cleanReply(text)
        guard let first = cleaned.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        var slice = Substring(first)
        while slice.first == "\"" || slice.first == "“" { slice = slice.dropFirst() }
        while slice.last == "\"" || slice.last == "”" { slice = slice.dropLast() }
        let line = String(slice.prefix(limit)).trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
    }
}

// MARK: - Library lookup (Taizo's tool)

/// What Taizo's `searchLibrary` tool answers: the artists, albums, genres and titles of the user's library that match
/// a query, as a few short lines (the model reads them as its tool output, so the answer stays well under 1k tokens).
/// An empty query gives an overview.
nonisolated enum LibraryLookup {
    static let maxCharacters = 900
    static let examples = 3

    static func summary(query: String, songs: [Song]) -> String {
        guard !songs.isEmpty else { return "The user's library is empty." }
        let needle = normalized(query)
        guard needle.count >= 2 else { return overview(songs) }
        var lines: [String] = []

        let artists = groups(songs, key: { $0.displayArtist }).filter { matches($0.name, needle) }
        for group in artists.prefix(3) {
            let albums = distinct(group.songs.map(\.album)).prefix(4)
            var line = "Artist \(group.name): \(count(group.songs.count)) in the library"
            if !albums.isEmpty { line += "; albums: \(albums.joined(separator: ", "))" }
            line += "; e.g. \(titles(group.songs))."
            lines.append(line)
        }
        let albums = groups(songs, key: { $0.album }).filter { matches($0.name, needle) }
        for group in albums.prefix(3) {
            let by = distinct(group.songs.map(\.displayArtist)).prefix(2).joined(separator: ", ")
            lines.append("Album \(group.name) by \(by): \(count(group.songs.count)); e.g. \(titles(group.songs)).")
        }
        let genres = genreGroups(songs).filter { matches($0.name, needle) }
        for group in genres.prefix(2) {
            let top = groups(group.songs, key: { $0.displayArtist }).prefix(4).map(\.name).joined(separator: ", ")
            lines.append("Genre \(group.name): \(count(group.songs.count)); artists: \(top).")
        }
        let titled = songs.filter { normalized($0.title).contains(needle) }
        if !titled.isEmpty {
            let list = titled.prefix(5).map { "\"\($0.title)\" by \($0.displayArtist)" }.joined(separator: "; ")
            lines.append("Songs titled like that: \(list).")
        }
        if lines.isEmpty {
            return "No artist, album, genre or song in the user's library matches \"\(query)\". " + overview(songs)
        }
        return clip(lines.joined(separator: "\n"))
    }

    /// Size, favourites, top genres and artists.
    static func overview(_ songs: [Song]) -> String {
        let artists = groups(songs, key: { $0.displayArtist })
        let genres = genreGroups(songs)
        var text = "The library has \(count(songs.count)) by \(artists.count) artists"
        let favorites = songs.filter(\.isFavorite).count
        if favorites > 0 { text += ", \(favorites) liked" }
        text += "."
        if !genres.isEmpty {
            text += " Top genres: " + genres.prefix(4).map { "\($0.name) (\($0.songs.count))" }.joined(separator: ", ") + "."
        }
        if !artists.isEmpty {
            text += " Top artists: " + artists.prefix(5).map { "\($0.name) (\($0.songs.count))" }.joined(separator: ", ") + "."
        }
        return clip(text)
    }

    nonisolated struct Bucket {
        var name: String
        var songs: [Song]
    }

    /// Songs grouped by a non-empty key, biggest group first (ties by name).
    static func groups(_ songs: [Song], key: (Song) -> String) -> [Bucket] {
        var order: [String] = []
        var byKey: [String: Bucket] = [:]
        for song in songs {
            let name = key(song).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !isUnknown(name) else { continue }
            let id = normalized(name)
            if byKey[id] == nil {
                order.append(id)
                byKey[id] = Bucket(name: name, songs: [])
            }
            byKey[id]?.songs.append(song)
        }
        return order.compactMap { byKey[$0] }.sorted {
            $0.songs.count != $1.songs.count ? $0.songs.count > $1.songs.count : $0.name < $1.name
        }
    }

    /// Genres, a comma-separated genre tag counting for each of its parts.
    static func genreGroups(_ songs: [Song]) -> [Bucket] {
        var expanded: [(String, Song)] = []
        for song in songs {
            for part in (song.genre ?? "").split(separator: ",") {
                expanded.append((part.trimmingCharacters(in: .whitespaces), song))
            }
        }
        var order: [String] = []
        var byKey: [String: Bucket] = [:]
        for (name, song) in expanded where !name.isEmpty && !isUnknown(name) {
            let id = normalized(name)
            if byKey[id] == nil {
                order.append(id)
                byKey[id] = Bucket(name: name, songs: [])
            }
            byKey[id]?.songs.append(song)
        }
        return order.compactMap { byKey[$0] }.sorted {
            $0.songs.count != $1.songs.count ? $0.songs.count > $1.songs.count : $0.name < $1.name
        }
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The name contains the query, or the query contains the (3+ letter) name: "radiohead songs" finds Radiohead.
    private static func matches(_ name: String, _ needle: String) -> Bool {
        let value = normalized(name)
        return value.contains(needle) || (value.count >= 3 && needle.contains(value))
    }

    private static func isUnknown(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "<unknown>" || lower.hasPrefix("unknown")
    }

    private static func distinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isUnknown($0) && seen.insert(normalized($0)).inserted }
    }

    private static func titles(_ songs: [Song]) -> String {
        songs.prefix(examples).map { "\"\($0.title)\"" }.joined(separator: ", ")
    }

    private static func count(_ n: Int) -> String { n == 1 ? "1 song" : "\(n) songs" }

    private static func clip(_ text: String) -> String {
        text.count <= maxCharacters ? text : String(text.prefix(maxCharacters - 1)) + "…"
    }
}

// MARK: - Taizo

/// What Taizo needs from the on-device model: `OnDeviceContext` in the app, a stand-in in unit tests.
nonisolated protocol TaizoOnDevice: Sendable {
    /// The on-device model is the selected provider.
    func isActive() async -> Bool
    /// The answer to a question, remembering the conversation; `songs` backs the library lookup tool.
    func chat(_ message: String, songs: @escaping @MainActor @Sendable () -> [Song]) async throws -> String
    /// The one-line intro above a queue card (nil: none).
    func introLine(request: String, count: Int) async throws -> String?
    /// How long a reply may take (the downloaded model needs longer than the system's).
    var chatTimeoutSeconds: Double { get }
    var introTimeoutSeconds: Double { get }
}

nonisolated extension TaizoOnDevice {
    var chatTimeoutSeconds: Double { TaisDjEngine.chatTimeoutSeconds }
    var introTimeoutSeconds: Double { TaisDjEngine.onDeviceIntroTimeoutSeconds }
}

/// Taizo's on-device instructions and prompts: short (the whole conversation shares one 4,096-token window), with
/// the library tool for questions about the user's own music.
nonisolated enum TaizoPrompts {
    /// One exchange, kept to carry the conversation into a fresh session when the window fills up.
    nonisolated struct Turn: Sendable, Equatable {
        var user: String
        var reply: String
    }

    /// The chat session's instructions: Android's TAIZO_CHAT layer condensed to about 120 tokens, plus the user's
    /// own persona when they set one (the default "Vibe-Engine" curator persona is for playlists, not chat).
    static func chatInstructions(persona: String?) -> String {
        var text = """
            You are Taizo, the AI DJ inside the PixlAudio music app, running privately on this iPhone.
            Answer in 1 to 4 warm, plain sentences. No markdown, no JSON, no lists unless the user asks for one.
            Answer music questions from what you know. If you aren't sure of a fact, say so.
            For anything about the user's own music (their artists, albums, genres, songs or library), call \
            searchLibrary first and answer from its result.
            You can't play or queue songs from a reply. If asked to, say they can type "play some" and a mood, genre \
            or artist.
            """
        let custom = persona?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty, custom != AiPromptEngine.defaultSystemPrompt {
            text += "\nYour personality: " + String(custom.prefix(240))
        }
        return text
    }

    /// The instructions of a session that continues a conversation whose window ran out: the last turns as text.
    static func carryOver(_ instructions: String, turns: [Turn]) -> String {
        guard !turns.isEmpty else { return instructions }
        let history = turns.map { "User: \(String($0.user.prefix(200)))\nTaizo: \(String($0.reply.prefix(300)))" }
        return instructions + "\n\nThe conversation so far:\n" + history.joined(separator: "\n")
    }

    /// The intro line above a queue card (Android `buildAiIntro`).
    static let introInstructions = """
        Write one short, upbeat sentence of at most 12 words that introduces the music the user asked for. \
        No quotes, no emoji, no lists. Do not call tools.
        """

    static func introPrompt(request: String, count: Int) -> String {
        "Request: \(String(request.prefix(200)))\nSongs found: \(count)"
    }
}
