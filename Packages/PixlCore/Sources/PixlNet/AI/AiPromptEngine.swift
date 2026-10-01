// Port of `data/ai/AiSystemPromptEngine.kt` (prompt layers, see the generated `AiPromptTemplates.swift`), the
// system-prompt default of `AiPreferencesRepository`, and `AiHandler.generateContent`'s per-type temperature table.

import Foundation
import PixlFoundation

/// `AiSystemPromptType`.
public enum AiSystemPromptType: String, Sendable, Hashable, CaseIterable, Codable {
    case playlist = "PLAYLIST"
    case metadata = "METADATA"
    case tagging = "TAGGING"
    case moodAnalysis = "MOOD_ANALYSIS"
    case persona = "PERSONA"
    case dailyMix = "DAILY_MIX"
    case general = "GENERAL"
    /// Taizo's freeform chat (conversational, so it skips the "no conversational framing" constraints).
    case taizoChat = "TAIZO_CHAT"
    /// The one-line home-screen greeting.
    case greeting = "GREETING"
}

/// `AiSystemPromptEngine`.
public enum AiPromptEngine {
    /// `AiPreferencesRepository.DEFAULT_SYSTEM_PROMPT` (the persona when the user set none).
    public static let defaultSystemPrompt = """
        You are 'Vibe-Engine', a professional music curator.
        Analyze the user's request and listening profile to provide perfect music recommendations.
        Always prioritize flow, emotional resonance, and discovery.
        """

    /// `buildPrompt(basePersona, type, context)`.
    public static func buildPrompt(basePersona: String, type: AiSystemPromptType, context: String = "") -> String {
        let requirementLayer: String
        switch type {
        case .playlist: requirementLayer = AiPromptTemplates.playlistLayer(playlistFewShot: AiPromptTemplates.playlistFewShot)
        case .dailyMix: requirementLayer = AiPromptTemplates.dailyMixLayer
        case .metadata: requirementLayer = AiPromptTemplates.metadataLayer(metadataFewShot: AiPromptTemplates.metadataFewShot)
        case .tagging: requirementLayer = AiPromptTemplates.taggingLayer(taggingFewShot: AiPromptTemplates.taggingFewShot)
        case .moodAnalysis: requirementLayer = AiPromptTemplates.moodAnalysisLayer(moodAnalysisFewShot: AiPromptTemplates.moodAnalysisFewShot)
        case .persona: requirementLayer = AiPromptTemplates.personaLayer(basePersona: basePersona,
                                                                         dailyMixPersonaPrompt: AiPromptTemplates.dailyMixPersonaPrompt)
        case .general: requirementLayer = AiPromptTemplates.generalLayer
        case .greeting: requirementLayer = AiPromptTemplates.greetingLayer
        case .taizoChat: requirementLayer = AiPromptTemplates.taizoChatLayer(basePersona: basePersona)
        }
        let contextLayer = KotlinIndent.isBlank(context) ? "" : AiPromptTemplates.contextLayer(context: context)
        let systemBlock = AiPromptTemplates.systemBlock(basePersona: basePersona, requirementLayer: requirementLayer)
        let parts = type == .persona || type == .taizoChat
            ? [systemBlock, contextLayer]
            : [systemBlock, AiPromptTemplates.universalConstraints, contextLayer]
        return parts.filter { !KotlinIndent.isBlank($0) }.joined(separator: "\n\n")
    }

    /// `generateContent`'s temperature: the per-type default only while both the setting and the caller keep 0.7.
    public static func effectiveTemperature(type: AiSystemPromptType, requested: Float = 0.7, setting: Float) -> Float {
        guard setting == 0.7 else { return setting }
        guard requested == 0.7 else { return requested }
        switch type {
        case .metadata: return 0.1
        case .moodAnalysis: return 0.2
        case .tagging: return 0.4
        case .playlist, .dailyMix: return 0.6
        case .persona: return 0.85
        case .general: return 0.7
        case .taizoChat: return 0.8
        case .greeting: return 0.75
        }
    }
}

/// Kotlin `String.trimIndent()` / `lines()` / `isBlank()`.
enum KotlinIndent {
    /// Kotlin `CharSequence.lines()`: split on CRLF, LF and CR.
    static func lines(_ s: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        var it = s.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = it.next()
        while let c = pending {
            pending = it.next()
            if c == "\r" {
                out.append(String(current))
                current = String.UnicodeScalarView()
                if pending == "\n" { pending = it.next() }
            } else if c == "\n" {
                out.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(c)
            }
        }
        out.append(String(current))
        return out
    }

    static func isBlank(_ s: String) -> Bool { NetText.isBlank(s) }

    /// `indentWidth`: index of the first non-whitespace char (UTF-16), or the length.
    private static func indentWidth(_ line: String) -> Int {
        var i = 0
        for scalar in line.unicodeScalars {
            if !TextScripts.isKotlinWhitespace(scalar) { return i }
            i += scalar.utf16.count
        }
        return line.utf16.count
    }

    /// Kotlin `trimIndent()`: removes the common minimal indent of non-blank lines, drops a blank first and last
    /// line, joins with "\n".
    static func trimIndent(_ s: String) -> String {
        let all = lines(s)
        let minIndent = all.filter { !isBlank($0) }.map(indentWidth).min() ?? 0
        let lastIndex = all.count - 1
        var kept: [String] = []
        for (index, line) in all.enumerated() {
            if (index == 0 || index == lastIndex) && isBlank(line) { continue }
            let units = Array(line.utf16)
            kept.append(units.count <= minIndent ? "" : String(decoding: units[minIndent...], as: UTF16.self))
        }
        return kept.joined(separator: "\n")
    }
}

