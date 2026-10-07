import Foundation
import PixlLyrics
import PixlModel

/// The lyrics-translation seam (Android `LyricsStateHolder.translateLyricsViaAi` → `AiStateHolder.translateLyrics`).
/// Stage 13 implements it with the configured AI provider (`AILyricsTranslator`, `env.ai.lyricsTranslator`); stage 9's
/// lyrics options call it from "Translate via AI", show `outcome.message` as the toast, and on `.translated` store
/// `validated.sanitizedContent` as the song's lyrics (same-timestamp pairs parse into `SyncedLine.translation`).
nonisolated protocol LyricsTranslating: Sendable {
    /// Translates `rawLyrics` (the song's stored LRC / embedded text) into `targetLanguage` (a display name such as
    /// "English"). `current` is what the player shows now: lyrics that already carry a translation are refused.
    func translate(rawLyrics: String?, current: Lyrics?, targetLanguage: String) async -> LyricsTranslationOutcome
}

/// The result of a translation request, with Android's user-facing messages.
nonisolated enum LyricsTranslationOutcome: Sendable, Equatable {
    /// The translated LRC, validated like an imported file.
    case translated(ValidatedLyricsImport)
    case alreadyTranslated
    case alreadyInTargetLanguage
    case notFound
    /// No usable provider (Android matches "key"/"config" in the error). The on-device model reports its own reason
    /// as `.failed` instead (it has no key to set up).
    case notConfigured
    case failed(detail: String)

    /// The toast text (`lyrics_translate_*`, `ai_state_error_*`).
    var message: String {
        switch self {
        case .translated: "Lyrics translated successfully!"
        case .alreadyTranslated: "These lyrics already have a translation"
        case .alreadyInTargetLanguage: "These lyrics are already in this language"
        case .notFound: "Lyrics not found"
        case .notConfigured: "Add a valid API key for the selected cloud assistant in Settings › AI features."
        case .failed(let detail): "AI Error: \(detail)"
        }
    }

    /// Shown while the request runs (`lyrics_translate_progress`).
    static let progressMessage = "Translating lyrics..."
}
