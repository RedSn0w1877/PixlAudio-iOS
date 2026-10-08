import Foundation
import PixlModel
import PixlNet

/// The downloaded model's prompts and the pure parts of its features (2026-10-07, local AI phase 2). It runs the same
/// requests as the system model (`OnDeviceCuration`, `TaizoPrompts`, `OnDeviceLyricsTranslation`, Home's greeting),
/// with two differences a small open model needs:
/// - **No tool calling:** Taizo's library lookup runs before the model, and its result travels in the user's turn
///   (only when the message names something in the library or asks about the user's own music).
/// - **Text instead of schemas:** song picks are constrained token by token (`NumberListConstraint`), and a long
///   playlist's plan is five labelled lines (`LocalPlanText`).
nonisolated enum LocalModelPrompts {
    /// The prompt budget the features size their requests to: the model's 4,096-token window, less room for speed
    /// (every prompt token is computed on the phone before the first answer token).
    static let contextBudget = 3072

    // MARK: Taizo

    static func chatInstructions(persona: String?) -> String {
        var text = """
            You are Taizo, the AI DJ inside the PixlAudio music app, running privately on this iPhone.
            Answer in 1 to 4 warm, plain sentences. No markdown, no JSON, no lists unless the user asks for one.
            Answer music questions from what you know. If you aren't sure of a fact, say so.
            When a message brings notes from the user's library, answer questions about their own music from those \
            notes only.
            You can't play or queue songs from a reply. If asked to, say they can type "play some" and a mood, genre \
            or artist.
            """
        let custom = persona?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty, custom != AiPromptEngine.defaultSystemPrompt {
            text += "\nYour personality: " + String(custom.prefix(240))
        }
        return text
    }

    /// Words that make a message about the user's own music.
    static let libraryWords = ["my ", "mine", "library", "i have", "i own", "do i ", "i listen", "i like", "i love",
                               "i play", "i've", "favorite", "favourite", "liked"]

    /// What the library says about `message` (Taizo's `searchLibrary` tool, run ahead of the model): the matches when
    /// the message names something in the library, the overview when it asks about the user's own music, else nil.
    static func libraryNote(for message: String, songs: [Song]) -> String? {
        guard !songs.isEmpty else {
            return asksAboutLibrary(message) ? "The user's library is empty." : nil
        }
        let summary = LibraryLookup.summary(query: message, songs: songs)
        if !summary.hasPrefix("No artist") { return summary }
        return asksAboutLibrary(message) ? LibraryLookup.overview(songs) : nil
    }

    static func asksAboutLibrary(_ message: String) -> Bool {
        let lower = " " + message.lowercased() + " "
        return libraryWords.contains { lower.contains($0) }
    }

    /// The user's turn: the library note first, when there is one.
    static func chatTurn(_ message: String, note: String?) -> String {
        let text = String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1200))
        guard let note else { return text }
        return "Notes from my library:\n\(note)\n\nMy message: \(text)"
    }

    // MARK: Playlists

    /// The pick request: the system model's prompt, and how to write the answer.
    static func pickPrompt(_ prompt: String) -> String {
        prompt + "\n" + OnDeviceCuration.textAnswerLine
    }

    /// Tokens a number list of `maximum` picks needs: up to three digits, a comma and a space each.
    static func pickTokens(maximum: Int) -> Int { maximum * 5 + 8 }

    static let planInstructions = """
        You plan playlists from a listener's request. Pick the genres and artists that fit the request best, only \
        from the allowed values (none when nothing fits), up to three mood words, an energy level from 1 (calm) to 5 \
        (intense), and whether the listener's familiar favorites suit it. Answer in exactly five lines:
        \(LocalPlanText.format)
        """

    static func planPrompt(_ base: String, genres: [String], artists: [String]) -> String {
        var text = base
        if !genres.isEmpty { text += "\nAllowed genres: " + genres.joined(separator: ", ") }
        if !artists.isEmpty { text += "\nAllowed artists: " + artists.joined(separator: ", ") }
        return text
    }

    /// The text plan as the curator's plan.
    static func plan(_ text: String, genres: [String], artists: [String]) -> OnDeviceCuration.Plan {
        let parsed = LocalPlanText.parse(text, allowedGenres: genres, allowedArtists: artists)
        return OnDeviceCuration.Plan(genres: parsed.genres, artists: parsed.artists, moods: parsed.moods,
                                     energy: parsed.energy, familiar: parsed.familiar)
    }

    // MARK: Sampling

    /// Qwen2.5's recommended sampling (top-k 20, top-p 0.8, repetition penalty 1.05) at `temperature`; greedy when
    /// nil or 0.
    static func sampling(temperature: Double?) -> SamplingSettings {
        guard let temperature, temperature > 0 else { return .greedy }
        return SamplingSettings(temperature: temperature, topK: 20, topP: 0.8, repetitionPenalty: 1.05)
    }

    /// Picks repeat digits by nature: no repetition penalty.
    static func pickSampling(temperature: Double?) -> SamplingSettings {
        var settings = sampling(temperature: temperature.map { min($0, 0.8) })
        settings.repetitionPenalty = 1
        return settings
    }
}
