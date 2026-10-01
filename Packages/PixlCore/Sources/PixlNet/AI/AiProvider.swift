// Ports of `data/ai/provider/AiProvider.kt`, the endpoint table of `AiClientFactory.kt`, `AiProviderSupport.kt`
// (fallback chain, recovery model, error classification) and `UnifiedModelFilter.kt`.

import Foundation
import PixlFoundation

/// `AiProvider`.
public enum AiProvider: String, Sendable, Hashable, CaseIterable, Codable {
    case gemini = "GEMINI"
    case deepseek = "DEEPSEEK"
    case groq = "GROQ"
    case mistral = "MISTRAL"
    case nvidia = "NVIDIA"
    case kimi = "KIMI"
    case glm = "GLM"
    case openai = "OPENAI"
    case openrouter = "OPENROUTER"
    /// A local-network model runner: no fixed URL and no authentication by default.
    case ollama = "OLLAMA"
    case custom = "CUSTOM"
    /// Runs on the device (iOS: Foundation Models) — no network, no key.
    case onDevice = "ON_DEVICE"

    /// `AiProvider.entries` order.
    public static let entries: [AiProvider] = allCases

    public var displayName: String {
        switch self {
        case .gemini: return "Google Gemini"
        case .deepseek: return "DeepSeek"
        case .groq: return "Groq"
        case .mistral: return "Mistral"
        case .nvidia: return "NVIDIA NIM"
        case .kimi: return "Kimi (Moonshot)"
        case .glm: return "Zhipu GLM"
        case .openai: return "OpenAI"
        case .openrouter: return "OpenRouter"
        case .ollama: return "Ollama"
        case .custom: return "Custom Provider"
        case .onDevice: return "On-Device (Offline)"
        }
    }

    public var requiresApiKey: Bool {
        switch self {
        case .ollama, .onDevice: return false
        default: return true
        }
    }

    public var hasConfigurableUrl: Bool { self == .ollama || self == .custom }

    /// `fromString`: unknown names fall back to Gemini.
    public static func fromString(_ value: String) -> AiProvider { AiProvider(rawValue: value) ?? .gemini }

    /// `AiClientFactory.createClient`'s fixed endpoint for the OpenAI-compatible providers (nil for Gemini, the
    /// on-device model and the configurable-URL providers).
    public var openAICompatibleEndpoint: OpenAICompatibleEndpoint? {
        switch self {
        case .deepseek: return OpenAICompatibleEndpoint(baseUrl: "https://api.deepseek.com", defaultModel: "deepseek-chat", providerName: "DeepSeek")
        case .groq: return OpenAICompatibleEndpoint(baseUrl: "https://api.groq.com/openai/v1", defaultModel: "llama-3.1-8b-instant", providerName: "Groq")
        case .mistral: return OpenAICompatibleEndpoint(baseUrl: "https://api.mistral.ai/v1", defaultModel: "mistral-large-latest", providerName: "Mistral")
        case .nvidia: return OpenAICompatibleEndpoint(baseUrl: "https://integrate.api.nvidia.com/v1", defaultModel: "meta/llama-3.1-8b-instruct", providerName: "NVIDIA NIM")
        case .kimi: return OpenAICompatibleEndpoint(baseUrl: "https://api.moonshot.cn/v1", defaultModel: "moonshot-v1-8k", providerName: "Moonshot Kimi")
        case .glm: return OpenAICompatibleEndpoint(baseUrl: "https://open.bigmodel.cn/api/paas/v4", defaultModel: "glm-4", providerName: "Zhipu GLM")
        case .openai: return OpenAICompatibleEndpoint(baseUrl: "https://api.openai.com/v1", defaultModel: "gpt-4o-mini", providerName: "OpenAI")
        case .openrouter: return OpenAICompatibleEndpoint(baseUrl: "https://openrouter.ai/api/v1", defaultModel: "google/gemini-2.0-flash-lite-preview-02-05:free", providerName: "OpenRouter")
        case .gemini, .ollama, .custom, .onDevice: return nil
        }
    }

    /// `createClientWithUrl`: the user's base URL (trailing slashes removed), no default model, the display name.
    public func configurableEndpoint(baseUrl: String) -> OpenAICompatibleEndpoint {
        var trimmed = baseUrl
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return OpenAICompatibleEndpoint(baseUrl: trimmed, defaultModel: "", providerName: displayName)
    }
}

/// An OpenAI-compatible endpoint.
public struct OpenAICompatibleEndpoint: Sendable, Hashable {
    public var baseUrl: String
    public var defaultModel: String
    public var providerName: String

    public init(baseUrl: String, defaultModel: String, providerName: String) {
        self.baseUrl = baseUrl
        self.defaultModel = defaultModel
        self.providerName = providerName
    }
}

/// `AiProviderException`.
public struct AiProviderError: Error, Sendable, Hashable, CustomStringConvertible {
    public var providerName: String
    public var statusCode: Int?
    public var requestedModel: String?
    public var providerCode: String?
    public var providerType: String?
    public var rawBody: String?
    public var message: String

    public var description: String { message }

    private var searchText: String {
        NetText.lowercased([message, rawBody, providerCode, providerType].compactMap { $0 }.joined(separator: " "))
    }

    public func isModelUnavailable() -> Bool {
        let text = searchText
        let mentionsMissingModel = NetText.containsExact(text, "model") && (NetText.containsExact(text, "not found") || NetText.containsExact(text, "does not exist")
            || NetText.containsExact(text, "unknown model") || NetText.containsExact(text, "unsupported model") || NetText.containsExact(text, "invalid model")
            || NetText.containsExact(text, "model_not_found"))
        return statusCode == 404 || mentionsMissingModel
    }

    public func isBillingIssue() -> Bool {
        let text = searchText
        return statusCode == 402 || ["insufficient_quota", "quota", "credit", "credits", "billing", "payment required", "balance"]
            .contains { NetText.containsExact(text, $0) }
    }

    public func isApiKeyIssue() -> Bool {
        let text = searchText
        return statusCode == 401 || ["api_key_invalid", "api key not valid", "invalid api key", "invalid key", "incorrect api key",
                                     "authentication failed", "unauthorized"].contains { NetText.containsExact(text, $0) }
    }

    /// Provider outages and account problems put the provider on a 5-minute cooldown.
    public func shouldCooldown() -> Bool {
        let text = searchText
        return isBillingIssue() || isApiKeyIssue() || (statusCode.map { $0 >= 500 } ?? false)
            || ["timeout", "timed out", "unable to resolve host", "failed to connect", "connection reset", "network"].contains { NetText.containsExact(text, $0) }
    }
}

/// `AiProviderSupport`.
public enum AiProviderSupport {
    static let preferredFallbacks: [AiProvider] = [.groq, .gemini, .deepseek, .mistral, .openai, .openrouter, .nvidia, .kimi, .glm, .ollama, .custom]

    /// `buildProviderChain`: the primary first, then the preferred fallbacks, then every other provider.
    public static func buildProviderChain(_ primary: AiProvider) -> [AiProvider] {
        var chain = [primary]
        chain += preferredFallbacks.filter { $0 != primary }
        chain += AiProvider.entries.filter { $0 != primary && !preferredFallbacks.contains($0) }
        var seen = Set<AiProvider>()
        return chain.filter { seen.insert($0).inserted }
    }

    /// `selectRecoveryModel`: the default when it is offered and differs, else the first other available model,
    /// else the default when it differs.
    public static func selectRecoveryModel(currentModel: String, defaultModel: String, availableModels: [String]) -> String? {
        let current = NetText.trim(currentModel)
        let normalizedDefault = NetText.trim(defaultModel)
        var seen = Set<String>()
        let available = availableModels.map(NetText.trim).filter { !NetText.isBlank($0) }.filter { seen.insert($0).inserted }
        if !available.isEmpty {
            if let preferred = available.first(where: { $0 == normalizedDefault }), preferred != current { return preferred }
            if let alternative = available.first(where: { $0 != current }) { return alternative }
        }
        return !NetText.isBlank(normalizedDefault) && normalizedDefault != current ? normalizedDefault : nil
    }

    /// `createException`: the provider's `error.message` (else the transport message), prefixed with the
    /// provider, status and model.
    public static func makeError(providerName: String, statusCode: Int?, transportMessage: String?, responseBody: String?,
                                 requestedModel: String?) -> AiProviderError {
        let parsed = parseError(responseBody)
        let clean = parsed.message.flatMap { NetText.isBlank($0) ? nil : $0 }
            ?? transportMessage.flatMap { NetText.isBlank($0) ? nil : $0 }
            ?? "Unknown provider error"
        var prefix = providerName + " API error"
        if let statusCode { prefix += " (\(statusCode))" }
        let message = (requestedModel.map(NetText.isBlank) ?? true)
            ? "\(prefix): \(clean)"
            : "\(prefix) with model '\(requestedModel!)': \(clean)"
        return AiProviderError(providerName: providerName, statusCode: statusCode, requestedModel: requestedModel,
                               providerCode: parsed.code, providerType: parsed.type, rawBody: responseBody, message: message)
    }

    /// `wrapThrowable`: provider errors pass through; anything else becomes one, with a status inferred from the
    /// first three-digit 1xx–5xx number in its message.
    public static func wrap(providerName: String, error: any Error, requestedModel: String? = nil) -> AiProviderError {
        if let providerError = error as? AiProviderError { return providerError }
        let raw: String
        if let transport = error as? HTTPTransportError { raw = transport.message } else { raw = String(describing: error) }
        return makeError(providerName: providerName, statusCode: inferStatus(raw),
                         transportMessage: NetText.isBlank(raw) ? ((error as? HTTPTransportError)?.kind ?? String(describing: type(of: error))) : raw,
                         responseBody: nil, requestedModel: requestedModel)
    }

    /// `Regex("""\b([1-5]\d{2})\b""")`.
    static func inferStatus(_ message: String) -> Int? {
        let s = Array(message.unicodeScalars)
        var i = 0
        while i + 3 <= s.count {
            let boundaryBefore = i == 0 || !NetText.isWordChar(s[i - 1])
            if boundaryBefore, ("1"..."5").contains(s[i]), NetText.isAsciiDigit(s[i + 1]), NetText.isAsciiDigit(s[i + 2]),
               i + 3 == s.count || !NetText.isWordChar(s[i + 3]) {
                return Int(String(String.UnicodeScalarView(s[i..<(i + 3)])))
            }
            i += 1
        }
        return nil
    }

    /// `parseError`: `error.{message,code,type}` (or the root object's), the raw body as the message when it is not
    /// JSON. Primitive values read as their content (kotlinx `contentOrNull`).
    static func parseError(_ body: String?) -> (message: String?, code: String?, type: String?) {
        guard let body, !NetText.isBlank(body) else { return (nil, nil, nil) }
        guard let root = (try? JSONParser(mode: .kotlinx).parse(body))?.objectValue else { return (body, nil, nil) }
        let errorObject: JSONObject
        if let errorValue = root["error"] {
            guard let o = errorValue.objectValue else { return (body, nil, nil) }
            errorObject = o
        } else {
            errorObject = root
        }
        func content(_ key: String) -> String? {
            switch errorObject[key] {
            case .string(let s)?: return s
            case .number(let n)?: return n
            case .bool(let b)?: return b ? "true" : "false"
            case .null?, nil: return nil
            default: return nil
            }
        }
        // A non-primitive member makes `jsonPrimitive` throw → the whole body becomes the message.
        for key in ["message", "code", "type"] {
            if let v = errorObject[key], v.objectValue != nil || v.arrayValue != nil { return (body, nil, nil) }
        }
        return (content("message"), content("code"), content("type"))
    }
}

/// `UnifiedModelFilter`.
public enum UnifiedModelFilter {
    static let unsuitablePatterns = [
        "embedding", "embed", "aqa", "imagen", "image-generation",
        "tts", "text-to-speech", "speech", "audio", "whisper",
        "veo", "vision-only", "learnlm-embedding", "moderation",
        "dall-e", "stable-diffusion", "sdxl", "kandinsky",
        "upscale", "background", "remove-background",
        "segment", "detect", "classify", "object-detection",
    ]

    public static func isModelUsableForChat(_ modelName: String) -> Bool {
        let lower = NetText.lowercased(modelName)
        return !unsuitablePatterns.contains { NetText.containsExact(lower, $0) }
    }

    public static func filterChatModels(_ models: [String]) -> [String] { models.filter(isModelUsableForChat) }

    /// Chat models from the API plus the defaults, distinct, sorted (Kotlin `sorted()`: UTF-16 order).
    public static func filterChatModelsWithDefaults(apiModels: [String], defaultModels: [String]) -> [String] {
        var seen = Set<String>()
        return (apiModels.filter(isModelUsableForChat) + defaultModels).filter { seen.insert($0).inserted }.sorted(by: kotlinLess)
    }

    /// Kotlin `String.compareTo` (UTF-16 code unit order).
    static func kotlinLess(_ a: String, _ b: String) -> Bool { a.utf16.lexicographicallyPrecedes(b.utf16) }
}

/// `AiResponseCleaner`.
public enum AiResponseCleaner {
    /// Strips code fences and cuts a leading JSON array/object at its matching bracket.
    public static func cleanJsonResponse(_ raw: String) -> String {
        var cleaned = NetText.trim(raw.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```kotlin", with: "")
            .replacingOccurrences(of: "```", with: ""))
        let units = Array(cleaned.utf16)
        if NetText.startsWith(cleaned, "[") {
            let end = matching(units, 0, open: 0x5B, close: 0x5D)
            if end > 0 { cleaned = String(decoding: units[0...end], as: UTF16.self) }
        } else if NetText.startsWith(cleaned, "{") {
            let end = matching(units, 0, open: 0x7B, close: 0x7D)
            if end > 0 { cleaned = String(decoding: units[0...end], as: UTF16.self) }
        }
        return cleaned
    }

    public static func cleanTextResponse(_ raw: String) -> String {
        NetText.trim(raw.replacingOccurrences(of: "```text", with: "").replacingOccurrences(of: "```", with: ""))
    }

    /// The first `[`…`]` with a matching close (strings and escapes respected).
    public static func extractJsonArray(_ text: String) -> String? { extract(text, open: 0x5B, close: 0x5D) }

    /// The first `{`…`}` with a matching close.
    public static func extractJsonObject(_ text: String) -> String? { extract(text, open: 0x7B, close: 0x7D) }

    private static func extract(_ text: String, open: UInt16, close: UInt16) -> String? {
        let units = Array(text.utf16)
        for i in units.indices where units[i] == open {
            let end = matching(units, i, open: open, close: close)
            if end > i { return String(decoding: units[i...end], as: UTF16.self) }
        }
        return nil
    }

    private static func matching(_ text: [UInt16], _ start: Int, open: UInt16, close: UInt16) -> Int {
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < text.count {
            let c = text[i]
            defer { i += 1 }
            if escaped { escaped = false; continue }
            if inString {
                if c == 0x5C { escaped = true } else if c == 0x22 { inString = false }
                continue
            }
            if c == 0x5C {
                escaped = true
            } else if c == 0x22 {
                inString = true
            } else if c == open {
                depth += 1
            } else if c == close {
                depth -= 1
                if depth == 0 { return i }
            }
        }
        return -1
    }
}
