import Foundation
import PixlLyrics
import PixlModel

/// "Translate via AI" on the on-device model (2026-10-07), behind `AILyricsTranslator`'s unchanged API.
///
/// The cloud prompt sends the whole LRC and asks the model to echo every line and timestamp next to its translation.
/// On-device that overflows the 4,096-token window for most songs (twice the lyrics, about one token per character
/// in CJK or Vietnamese), so the translator works line by line instead:
/// - the lyrics are parsed (`LyricsUtils.parseLyrics`); the timestamps never reach the model, so they can't be lost;
/// - each distinct line is translated once (choruses repeat), in numbered chunks sized to the window;
/// - each line gets its translation as `SyncedLine.translation` and the result is written as LRC with a same-time
///   translation line, then validated like an imported file (`AILyricsTranslator.outcome(forResponse:)`), exactly
///   what the cloud path stores.
/// Lyrics already in the target language are recognised on the device (the injected language check), without a
/// model call. The permissive-guardrails model translates, so explicit lyrics don't stop it.
nonisolated struct OnDeviceLyricsTranslator: Sendable {
    /// The on-device model is the selected provider.
    var isActive: @Sendable () async -> Bool
    var unavailability: @Sendable () -> OnDeviceFailure?
    var contextSize: @Sendable () -> Int
    /// One chunk: instructions, prompt, answer budget → the model's text.
    var respond: @Sendable (String, String, Int) async throws -> String
    /// The dominant language of a text, as a language code ("en"), when it can tell.
    var dominantLanguage: @Sendable (String) -> String?
    /// The device language's code: the target.
    var targetLanguageCode: String

    @concurrent
    func translate(rawLyrics: String, current: Lyrics?, targetLanguage: String) async -> LyricsTranslationOutcome {
        if let issue = unavailability() { return .failed(detail: issue.message) }
        var synced = LyricsUtils.parseLyrics(rawLyrics).synced ?? []
        if synced.isEmpty, let shown = current?.synced { synced = shown }
        let texts = OnDeviceLyricsTranslation.distinctTexts(synced)
        guard !texts.isEmpty else { return .failed(detail: OnDeviceLyricsTranslation.needsTimestampsMessage) }
        if let code = dominantLanguage(texts.joined(separator: "\n")), code == targetLanguageCode {
            return .alreadyInTargetLanguage
        }
        var translations: [String: String] = [:]
        do {
            let budget = OnDeviceLyricsTranslation.chunkBudget(contextSize: contextSize())
            for chunk in OnDeviceLyricsTranslation.chunks(texts, budget: budget) {
                try Task.checkCancellation()
                try await translate(chunk, to: targetLanguage, splitsLeft: 2, collecting: &translations)
            }
        } catch is CancellationError {
            return .failed(detail: "Cancelled")
        } catch {
            return .failed(detail: ((error as? OnDeviceFailure) ?? .other(error.localizedDescription)).message)
        }
        if OnDeviceLyricsTranslation.isUnchanged(translations) { return .alreadyInTargetLanguage }
        guard let lrc = OnDeviceLyricsTranslation.merge(synced, translations: translations) else {
            return .failed(detail: OnDeviceLyricsTranslation.noTranslationMessage)
        }
        return AILyricsTranslator.outcome(forResponse: lrc)
    }

    /// One chunk; a "too long" answer splits it in half and tries again (twice at most).
    private func translate(_ chunk: [String], to language: String, splitsLeft: Int,
                           collecting translations: inout [String: String]) async throws {
        let prompt = OnDeviceLyricsTranslation.prompt(chunk, language: language)
        let input = OnDeviceText.estimatedTokens(OnDeviceLyricsTranslation.instructions + prompt)
        let answer = OnDeviceText.responseBudget(contextSize: contextSize(), inputTokens: input, cap: 2400)
        do {
            let reply = try await respond(OnDeviceLyricsTranslation.instructions, prompt, answer)
            let numbered = OnDeviceLyricsTranslation.parse(reply)
            for (index, text) in chunk.enumerated() {
                if let translation = numbered[index + 1] { translations[text] = translation }
            }
        } catch let failure as OnDeviceFailure where failure == .tooLong && splitsLeft > 0 && chunk.count > 1 {
            let half = chunk.count / 2
            try await translate(Array(chunk[..<half]), to: language, splitsLeft: splitsLeft - 1, collecting: &translations)
            try await translate(Array(chunk[half...]), to: language, splitsLeft: splitsLeft - 1, collecting: &translations)
        }
    }
}

/// The translator's pure parts.
nonisolated enum OnDeviceLyricsTranslation {
    static let instructions = """
        You translate song lyrics. Translate each numbered line into the language the user names, keeping its \
        meaning and tone. Answer with one line per number, in the same order: the number, a period, then only the \
        translation. Keep names as they are. No notes. Do not call tools.
        """

    /// "zh-Hans" → "zh": language codes compared without script or region.
    static func baseCode(_ code: String) -> String {
        String(code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(code)).lowercased()
    }

    static let needsTimestampsMessage = "These lyrics have no timestamps to pair a translation with."
    static let noTranslationMessage = "The on-device model gave no translation. Try again."

    /// The input tokens per chunk: what is left of the window after the instructions, with room for an answer
    /// about 1.4 times as long as the lines.
    static func chunkBudget(contextSize: Int) -> Int {
        max(200, (contextSize - 300) * 10 / 24)
    }

    /// A line as the model sees it: one line, single spaces.
    static func text(_ line: SyncedLine) -> String {
        line.line.split(whereSeparator: \.isNewline).joined(separator: " / ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Every non-blank line text once, in order of first appearance.
    static func distinctTexts(_ lines: [SyncedLine]) -> [String] {
        var seen = Set<String>()
        return lines.map(text).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Consecutive chunks whose estimated tokens stay within `budget` (a longer line gets a chunk of its own).
    static func chunks(_ texts: [String], budget: Int) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        var used = 0
        for text in texts {
            let cost = OnDeviceText.estimatedTokens(text) + 2
            if !current.isEmpty, used + cost > budget {
                result.append(current)
                current = []
                used = 0
            }
            current.append(text)
            used += cost
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func prompt(_ chunk: [String], language: String) -> String {
        "Translate into \(language):\n" + chunk.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    /// `3. text` (or `3) text`, `3: text`) lines → number → text; the first answer per number wins.
    static func parse(_ reply: String) -> [Int: String] {
        var result: [Int: String] = [:]
        for raw in OnDeviceText.cleanReply(reply).split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let digits = line.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, let number = Int(digits) else { continue }
            var rest = line.dropFirst(digits.count)
            guard let marker = rest.first, ".):-".contains(marker) else { continue }
            rest = rest.dropFirst()
            var text = rest.trimmingCharacters(in: .whitespaces)
            while text.first == "\"" || text.first == "“" { text.removeFirst() }
            while text.last == "\"" || text.last == "”" { text.removeLast() }
            if !text.isEmpty, result[number] == nil { result[number] = text }
        }
        return result
    }

    /// The model left (almost) every line as it was: the lyrics are already in the target language.
    static func isUnchanged(_ translations: [String: String]) -> Bool {
        guard !translations.isEmpty else { return false }
        let same = translations.filter { same($0.key, $0.value) }.count
        return Double(same) / Double(translations.count) >= 0.8
    }

    /// The lines with their translations as LRC (a same-time line per translation), or nil when no line changed.
    static func merge(_ lines: [SyncedLine], translations: [String: String]) -> String? {
        var changed = false
        let translated = lines.map { line -> SyncedLine in
            var copy = line
            if let translation = translations[text(line)], !same(text(line), translation) {
                copy.translation = translation
                changed = true
            }
            return copy
        }
        return changed ? LyricsUtils.syncedToLrcString(translated) : nil
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            == b.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
