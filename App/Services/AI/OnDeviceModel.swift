import Foundation
import FoundationModels

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
    case other(String)

    /// Every failure with a fixed message, for matching text back to a failure.
    static let fixed: [OnDeviceFailure] = [.tooLong, .blocked, .language, .notReady, .busy, .slow, .deviceNotEligible,
                                           .intelligenceOff]

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
        case .other(let detail):
            Self.isSafeDetail(detail) ? "The on-device model couldn't answer (\(detail)). Try again."
                : "The on-device model couldn't answer. Try again."
        }
    }

    /// A short label for Settings and the creation sheet.
    var title: String {
        switch self {
        case .deviceNotEligible: "Not available on this iPhone"
        case .intelligenceOff: "Turned off in system settings"
        case .notReady: "Downloading"
        case .language: "Language not supported yet"
        default: "Unavailable right now"
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

    /// A conservative estimate: one token per CJK, kana, Hangul, Thai or Vietnamese letter (Apple's context-window
    /// guide: about one character per token there), one per 3.5 other characters (three to four in Latin text),
    /// plus 10 %.
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

    // MARK: Replies

    /// A String answer without the wrappers small models sometimes leak (iOS 27 beta release notes, forum thread
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
