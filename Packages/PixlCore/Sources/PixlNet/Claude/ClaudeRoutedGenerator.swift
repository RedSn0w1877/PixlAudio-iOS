// Every prompt-in, text-out AI feature (AI playlists, the Daily Mix reasons, translations, the TAIS DJ intro lines,
// Home's greeting) asks an `AiContentGenerating`. `ClaudeRoutedGenerator` puts the router in front of the existing
// orchestrator: Claude when the router says so, the orchestrator (the on-device model, or a developer's own cloud
// provider) otherwise — and also when a Claude call fails for any reason (offline mid-way, a refusal, 4xx/5xx).

import Foundation
import PixlFoundation

/// Prompt in, text out (`AiOrchestrator.generateContent`).
public protocol AiContentGenerating: Sendable {
    func generateContent(prompt: String, type: AiSystemPromptType, temperature: Float, context: String) async throws -> String
}

public extension AiContentGenerating {
    func generateContent(prompt: String, type: AiSystemPromptType) async throws -> String {
        try await generateContent(prompt: prompt, type: type, temperature: 0.7, context: "")
    }

    func generateContent(prompt: String, type: AiSystemPromptType, temperature: Float) async throws -> String {
        try await generateContent(prompt: prompt, type: type, temperature: temperature, context: "")
    }
}

extension AiOrchestrator: AiContentGenerating {}

/// A fallback that always fails: `ClaudeRoutedGenerator(…, fallback: ClaudeUnavailableGenerator())` is "Claude or an
/// error", for features that have their own on-device path to run when Claude doesn't answer.
public struct ClaudeUnavailableGenerator: AiContentGenerating {
    public struct Unavailable: Error, Sendable, Hashable {}

    public init() {}

    public func generateContent(prompt: String, type: AiSystemPromptType, temperature: Float, context: String) async throws -> String {
        throw Unavailable()
    }
}

/// Claude in front of a fallback generator.
public struct ClaudeRoutedGenerator: AiContentGenerating {
    /// The route for this request (read per call: the network or the budget may have changed).
    public let route: @Sendable () async -> AIRoute
    /// A Claude client, or nil when this build has no key.
    public let claude: @Sendable () async -> (any ClaudeMessaging)?
    public let fallback: any AiContentGenerating
    /// The persona the user set (blank: the default).
    public let persona: @Sendable () async -> String
    public let onUsage: @Sendable (ClaudeUsage) async -> Void
    /// Reports a Claude failure that fell back (developer diagnostics; never includes the key).
    public let onFallback: @Sendable (String) async -> Void

    public init(route: @escaping @Sendable () async -> AIRoute, claude: @escaping @Sendable () async -> (any ClaudeMessaging)?,
                fallback: any AiContentGenerating, persona: @escaping @Sendable () async -> String = { "" },
                onUsage: @escaping @Sendable (ClaudeUsage) async -> Void = { _ in },
                onFallback: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.route = route
        self.claude = claude
        self.fallback = fallback
        self.persona = persona
        self.onUsage = onUsage
        self.onFallback = onFallback
    }

    /// Owner decision 2026-10-23: quality first — `high` for playlist building and insights, `medium` for the rest.
    public static func effort(for type: AiSystemPromptType) -> ClaudeEffort {
        switch type {
        case .playlist, .dailyMix, .metadata, .tagging, .moodAnalysis: .high
        case .persona, .general, .taizoChat, .greeting: .medium
        }
    }

    /// The system prompt: the persona and the feature's instructions (Android's prompt layers) as one cached block.
    public static func system(persona: String, type: AiSystemPromptType, context: String) -> [ClaudeSystemBlock] {
        let base = persona.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AiPromptEngine.defaultSystemPrompt : persona
        return [ClaudeSystemBlock(AiPromptEngine.buildPrompt(basePersona: base, type: type, context: context), cacheBreakpoint: true)]
    }

    public func generateContent(prompt: String, type: AiSystemPromptType, temperature: Float, context: String) async throws -> String {
        if await route() == .claude, let client = await claude() {
            do {
                let text = try await ClaudeCompletion.text(client: client,
                                                           system: Self.system(persona: await persona(), type: type, context: context),
                                                           prompt: prompt, effort: Self.effort(for: type), onUsage: onUsage)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
                await onFallback("Cloud AI returned no text for \(type.rawValue)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await onFallback("Cloud AI failed for \(type.rawValue): \(error)")
            }
        }
        return try await fallback.generateContent(prompt: prompt, type: type, temperature: temperature, context: context)
    }
}
