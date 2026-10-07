import Foundation
import FoundationModels

/// The system's on-device language model (Foundation Models), shared by every on-device AI feature: availability,
/// the context budget, token counting, the two model configurations and error mapping. The model is the same ~3B one
/// on every eligible iPhone; its context window (instructions + prompt + schema + answer) is 4,096 tokens.
nonisolated enum OnDeviceModel {
    /// The documented window when the system reports none.
    static let fallbackContextSize = 4096

    /// Default guardrails: guided (`@Generable` / schema) outputs.
    static let standard = SystemLanguageModel.default
    /// Plain-text answers (chat, intro lines, greetings, lyric translation): permissive content transformations,
    /// so song titles or lyrics with explicit words don't trip a guardrail violation. Applies to String output only.
    static let permissive = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)

    // MARK: Availability

    /// Why the model can't be used now (nil when it can).
    static var unavailability: OnDeviceFailure? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .intelligenceOff
        case .unavailable(.modelNotReady): return .notReady
        case .unavailable: return .other("unknown state")
        }
    }

    static var isAvailable: Bool { unavailability == nil }

    /// Whether the device language qualifies for the model (language fallbacks included).
    static func supportsLocale(_ locale: Locale = .current) -> Bool {
        SystemLanguageModel.default.supportsLocale(locale)
    }

    // MARK: Budget

    /// The model's context window in tokens (back-deployed to 26.0; values ≤ 0 mean the documented 4,096).
    static var contextSize: Int {
        let size = SystemLanguageModel.default.contextSize
        return size > 0 ? size : fallbackContextSize
    }

    /// The model's own count on iOS 26.4+, else `estimatedTokens`.
    static func tokenCount(_ text: String) async -> Int {
        if #available(iOS 26.4, *) {
            if let count = try? await SystemLanguageModel.default.tokenCount(for: Instructions { text }) { return count }
        }
        return estimatedTokens(text)
    }

    /// `OnDeviceText.estimatedTokens`.
    static func estimatedTokens(_ text: String) -> Int { OnDeviceText.estimatedTokens(text) }

    /// `OnDeviceText.responseBudget`.
    static func responseBudget(contextSize: Int, inputTokens: Int, cap: Int) -> Int {
        OnDeviceText.responseBudget(contextSize: contextSize, inputTokens: inputTokens, cap: cap)
    }

    // MARK: Replies

    /// `OnDeviceText.cleanReply`.
    static func cleanReply(_ text: String) -> String { OnDeviceText.cleanReply(text) }

    // MARK: Errors

    /// Maps anything a session throws: iOS 26's `GenerationError` first, then the iOS 27 error types (through
    /// `Compat27`, the only file allowed to name them), else the error's description.
    static func failure(for error: any Error) -> OnDeviceFailure {
        if let failure = error as? OnDeviceFailure { return failure }
        if let failure = generationFailure(error) { return failure }
        if let failure = Compat27.onDeviceFailure(error) { return failure }
        return .other(error.localizedDescription)
    }

    /// iOS 26's error type (deprecated in the iOS 27 SDK in favour of `LanguageModelError`; a deprecation warning).
    private static func generationFailure(_ error: any Error) -> OnDeviceFailure? {
        guard let error = error as? LanguageModelSession.GenerationError else { return nil }
        switch error {
        case .exceededContextWindowSize: return .tooLong
        case .guardrailViolation, .refusal: return .blocked
        case .unsupportedLanguageOrLocale: return .language
        case .assetsUnavailable: return .notReady
        case .rateLimited, .concurrentRequests: return .busy
        default: return .other(error.localizedDescription)
        }
    }
}
