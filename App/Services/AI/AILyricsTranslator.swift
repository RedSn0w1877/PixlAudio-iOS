import Foundation
import PixlLyrics
import PixlModel
import PixlNet

/// Lyric translation through the configured AI provider (Android `AiStateHolder.translateLyrics` + the outcome
/// handling of `LyricsStateHolder.translateLyricsViaAi`): Android's prompt, `GENERAL` type at temperature 0.1, the
/// `ALREADY_IN_TARGET_LANGUAGE` sentinel, and the reply validated like an imported LRC file.
nonisolated struct AILyricsTranslator: LyricsTranslating {
    let orchestrator: AiOrchestrator

    /// The device language's display name (Android `locales[0].displayLanguage`).
    static var deviceLanguageName: String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return Locale.current.localizedString(forLanguageCode: code) ?? "English"
    }

    func translate(rawLyrics: String?, current: Lyrics?, targetLanguage: String) async -> LyricsTranslationOutcome {
        if let synced = current?.synced, synced.contains(where: { !($0.translation ?? "").trimmingCharacters(in: .whitespaces).isEmpty }) {
            return .alreadyTranslated
        }
        guard let rawLyrics, !rawLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .notFound }
        do {
            let response = try await orchestrator.generateContent(prompt: Self.prompt(lyrics: rawLyrics, targetLanguage: targetLanguage),
                                                                  type: .general, temperature: 0.1)
            return Self.outcome(forResponse: response)
        } catch is CancellationError {
            return .failed(detail: "Cancelled")
        } catch {
            let message = (error as? AiGenerationError)?.message ?? String(describing: error)
            return Self.outcome(forFailure: message)
        }
    }

    /// Android's prompt: a raw string with no indentation, so `trimIndent()` only drops the blank first and last
    /// lines (and normalises line breaks).
    static func prompt(lyrics: String, targetLanguage: String) -> String {
        let normalized = lyrics.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return """
            <task>Translate song lyrics into \(targetLanguage).</task>

            <rules>
            - Preserve ALL timestamps [mm:ss.xx] exactly — never modify, merge, or drop them.
            - Output TWO lines per original line: the original, then the translation with the same timestamp.
            - NEVER add explanations, labels, numbering, section headers, or formatting.
            - NEVER remove, merge, split, or reorder lines.
            - If lyrics are ALREADY mostly in \(targetLanguage), output ONLY: ALREADY_IN_TARGET_LANGUAGE
            </rules>

            <format>
            [original timestamp] original text
            [same timestamp] translated text
            </format>

            <lyrics>
            \(normalized)
            </lyrics>
            """
    }

    static func outcome(forResponse response: String) -> LyricsTranslationOutcome {
        if response.trimmingCharacters(in: .whitespacesAndNewlines) == "ALREADY_IN_TARGET_LANGUAGE" { return .alreadyInTargetLanguage }
        guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failed(detail: "Empty response") }
        switch LyricsImportSecurity.validateImportedLrcContent(response) {
        case .valid(let validated): return .translated(validated)
        case .invalid(let reason): return .failed(detail: LyricsImportSecurity.message(for: reason))
        }
    }

    /// Android: a message mentioning "key" or "config" means no usable provider.
    static func outcome(forFailure message: String) -> LyricsTranslationOutcome {
        let lower = message.lowercased()
        if lower.contains("key") || lower.contains("config") { return .notConfigured }
        return .failed(detail: message)
    }
}
