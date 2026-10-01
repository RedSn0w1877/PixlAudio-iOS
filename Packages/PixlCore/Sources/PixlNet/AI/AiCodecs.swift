// Request/response codecs of `GeminiAiClient.kt` (Generative Language REST API) and `GenericOpenAiClient.kt`
// (OpenAI-compatible chat completions), plus the model lists of `GeminiAiClient`/`GeminiModelService`. Request bodies
// are written like Android's kotlinx `Json` (encodeDefaults = false): a field equal to its declared default is
// omitted, Doubles print as Java `Double.toString` (so a Float setting of 0.7 sends 0.699999988079071).

import Foundation
import PixlFoundation

/// Generation settings (`AiPreferencesRepository` values; Android defaults).
public struct AiGenerationParameters: Sendable, Hashable, Codable {
    public var temperature: Float
    public var topP: Float
    public var topK: Int
    public var maxTokens: Int
    public var presencePenalty: Float
    public var frequencyPenalty: Float

    public init(temperature: Float = 0.7, topP: Float = 0.95, topK: Int = 64, maxTokens: Int = 4096,
                presencePenalty: Float = 0, frequencyPenalty: Float = 0) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.maxTokens = maxTokens
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
    }
}

/// A kotlinx Double literal.
private func kotlinxDouble(_ d: Double) -> JSONValue { .number(NetText.javaDoubleString(d)) }

/// Gemini (`generativelanguage.googleapis.com/v1beta`).
public enum GeminiCodec {
    public static let baseURL = "https://generativelanguage.googleapis.com/v1beta"
    public static let defaultModel = "gemini-3.1-flash-lite"
    public static let defaultModels = ["gemini-3.1-flash-lite", "gemini-3.5-flash", "gemini-3.1-pro-preview", "gemini-flash-latest"]
    public static let requestTimeoutSeconds: Double = 60

    /// The `GenerateRequest` body.
    public static func generateBody(systemPrompt: String, prompt: String, parameters: AiGenerationParameters) -> String {
        var config = JSONObject()
        config.append("temperature", kotlinxDouble(Double(parameters.temperature)))
        if parameters.topK != 64 { config.append("topK", .integer(parameters.topK)) }
        let topP = Double(parameters.topP)
        if topP != 0.95 { config.append("topP", kotlinxDouble(topP)) }
        if parameters.maxTokens != 8192 { config.append("maxOutputTokens", .integer(parameters.maxTokens)) }
        let presence = Double(parameters.presencePenalty)
        if presence != 0 { config.append("presencePenalty", kotlinxDouble(presence)) }
        let frequency = Double(parameters.frequencyPenalty)
        if frequency != 0 { config.append("frequencyPenalty", kotlinxDouble(frequency)) }
        return requestJSON(systemPrompt: systemPrompt, prompt: prompt, generationConfig: config)
    }

    /// The `countTokens` body (`GenerationConfig(temperature = 0.0)`).
    public static func countTokensBody(systemPrompt: String, prompt: String) -> String {
        var config = JSONObject()
        config.append("temperature", kotlinxDouble(0))
        return requestJSON(systemPrompt: systemPrompt, prompt: prompt, generationConfig: config)
    }

    private static func requestJSON(systemPrompt: String, prompt: String, generationConfig: JSONObject) -> String {
        func content(role: String?, text: String) -> JSONValue {
            var o = JSONObject()
            if let role { o.append("role", .string(role)) }
            var part = JSONObject()
            part.append("text", .string(text))
            o.append("parts", .array([.object(part)]))
            return .object(o)
        }
        var root = JSONObject()
        root.append("contents", .array([content(role: "user", text: prompt)]))
        if !NetText.isBlank(systemPrompt) { root.append("systemInstruction", content(role: nil, text: systemPrompt)) }
        root.append("generationConfig", .object(generationConfig))
        return JSONWriter.write(.object(root))
    }

    /// `POST models/<model>:generateContent` (or `:countTokens`) with the key in `x-goog-api-key`.
    public static func request(model: String, method: String = "generateContent", apiKey: String, body: String) -> HTTPRequest {
        HTTPRequest(method: .post, url: "\(baseURL)/models/\(model):\(method)",
                    headers: [HTTPHeader("x-goog-api-key", apiKey), HTTPHeader("Content-Type", "application/json")],
                    body: Data(body.utf8), timeout: requestTimeoutSeconds)
    }

    /// `GET models` (model list / key validation).
    public static func modelsRequest(apiKey: String) -> HTTPRequest {
        HTTPRequest(url: "\(baseURL)/models", headers: [HTTPHeader("x-goog-api-key", apiKey)], timeout: requestTimeoutSeconds)
    }

    /// The outcome of a generate response body (HTTP status already successful).
    public enum Outcome: Sendable, Hashable {
        case text(String)
        /// `promptFeedback.blockReason`.
        case blocked(reason: String)
        /// No non-blank candidate text.
        case empty
        /// Not the expected JSON shape (kotlinx would throw).
        case malformed
    }

    /// `GenerateResponse` decoding (unknown keys ignored, lenient).
    public static func parseGenerateResponse(_ body: String) -> Outcome {
        guard let root = (try? JSONParser(mode: .kotlinx).parse(body))?.objectValue else { return .malformed }
        if let feedback = root["promptFeedback"], case .object(let fb) = feedback, case .string(let reason)? = fb["blockReason"] {
            return .blocked(reason: reason)
        }
        var candidates: [JSONValue] = []
        if let c = root["candidates"] {
            guard let array = c.arrayValue else { return .malformed }
            candidates = array
        }
        guard let first = candidates.first else { return .empty }
        guard let candidate = first.objectValue else { return .malformed }
        guard let contentValue = candidate["content"], !contentValue.isNull else { return .empty }
        guard let content = contentValue.objectValue, let parts = content["parts"]?.arrayValue else { return .malformed }
        var text = ""
        for part in parts {
            guard let p = part.objectValue, case .string(let t)? = p["text"] else { return .malformed }
            text += t
        }
        return NetText.isBlank(text) ? .empty : .text(text)
    }

    /// `countTokens`' `"totalTokens"\s*:\s*(\d+)` match, else nil.
    public static func totalTokens(_ body: String) -> Int? {
        guard let range = body.range(of: "\"totalTokens\"") else { return nil }
        var rest = body[range.upperBound...].drop { NetText.isRegexSpace($0.unicodeScalars.first!) && $0.unicodeScalars.count == 1 }
        guard rest.first == ":" else { return nil }
        rest = rest.dropFirst().drop { NetText.isRegexSpace($0.unicodeScalars.first!) && $0.unicodeScalars.count == 1 }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        return digits.isEmpty ? nil : NetText.toInt(String(digits))
    }

    /// The local estimate when counting fails: `prompt.length / 4 + systemPrompt.length / 4`.
    public static func estimatedTokens(systemPrompt: String, prompt: String) -> Int {
        NetText.length(prompt) / 4 + NetText.length(systemPrompt) / 4
    }

    /// Every `"name": "models/…"` in a model list body.
    static func modelNames(_ body: String) -> [String] {
        var out: [String] = []
        let marker = "\"name\":"
        var search = body.startIndex
        while let r = body.range(of: marker, range: search..<body.endIndex) {
            var i = r.upperBound
            while i < body.endIndex, let s = body[i].unicodeScalars.first, body[i].unicodeScalars.count == 1, NetText.isRegexSpace(s) {
                i = body.index(after: i)
            }
            if body[i...].hasPrefix("\"models/") {
                let start = body.index(i, offsetBy: 1)
                if let end = body[start...].firstIndex(of: "\""), end > body.index(start, offsetBy: 7) {
                    out.append(String(body[start..<end]))
                }
            }
            search = r.upperBound
        }
        return out
    }

    /// `GeminiAiClient.parseModelsFromResponse`: gemini/gemma chat models plus the defaults, distinct, sorted.
    public static func chatModels(fromModelsBody body: String) -> [String] {
        var models: [String] = []
        for full in modelNames(body) {
            let name = NetText.removePrefix(full, "models/")
            if (NetText.hasPrefixIgnoreCase(name, "gemini") || NetText.hasPrefixIgnoreCase(name, "gemma")) && UnifiedModelFilter.isModelUsableForChat(name) {
                models.append(name)
            }
        }
        var seen = Set<String>()
        return (models + defaultModels).filter { seen.insert($0).inserted }.sorted(by: UnifiedModelFilter.kotlinLess)
    }
}

/// `GeminiModel` / `GeminiModelService` (the settings model picker).
public struct GeminiModel: Sendable, Hashable {
    public var name: String
    public var displayName: String

    public init(name: String, displayName: String) {
        self.name = name
        self.displayName = displayName
    }

    public static let defaults: [GeminiModel] = [
        GeminiModel(name: "gemini-3.1-flash-lite", displayName: "Gemini 3.1 Flash Lite (Recommended Default)"),
        GeminiModel(name: "gemini-3.5-flash", displayName: "Gemini 3.5 Flash"),
        GeminiModel(name: "gemini-3.1-pro-preview", displayName: "Gemini 3.1 Pro (Preview)"),
        GeminiModel(name: "gemini-flash-lite-latest", displayName: "Gemini Flash Lite Latest"),
        GeminiModel(name: "gemini-flash-latest", displayName: "Gemini Flash Latest"),
        GeminiModel(name: "gemma-4-31b-it", displayName: "Gemma 4 31B IT"),
        GeminiModel(name: "gemma-4-26b-a4b-it", displayName: "Gemma 4 26B MoE"),
    ]

    static let nonChatMarkers = ["embedding", "aqa", "imagen", "image-generation", "tts", "audio", "veo", "vision-only", "learnlm-embedding"]

    /// `GET .../models?key=…` (GeminiModelService puts the key in the URL).
    public static func listRequest(apiKey: String) -> HTTPRequest {
        HTTPRequest(url: "\(GeminiCodec.baseURL)/models?key=\(apiKey)", timeout: 10)
    }

    /// `formatDisplayName`: dash-separated words, each first character upper-cased.
    public static func displayName(for modelName: String) -> String {
        modelName.components(separatedBy: "-").map { word in
            guard let first = word.unicodeScalars.first else { return word }
            return String(first).uppercased() + String(word.unicodeScalars.dropFirst())
        }.joined(separator: " ")
    }

    /// `makeModelsListRequest`'s result: API models (when the call succeeded) plus defaults, distinct by name,
    /// defaults first in their order, then by display name (lower case).
    public static func models(fromBody body: String?) -> [GeminiModel] {
        var api: [GeminiModel] = []
        for full in GeminiCodec.modelNames(body ?? "") {
            let name = NetText.removePrefix(full, "models/")
            let lower = NetText.lowercased(name)
            if (NetText.hasPrefixIgnoreCase(name, "gemini") || NetText.hasPrefixIgnoreCase(name, "gemma"))
                && !nonChatMarkers.contains(where: { NetText.containsExact(lower, $0) }) {
                api.append(GeminiModel(name: name, displayName: displayName(for: name)))
            }
        }
        var seen = Set<String>()
        let merged = (api + defaults).filter { seen.insert($0.name).inserted }
        let preferred = defaults.map(\.name)
        return merged.enumerated().sorted { a, b in
            let ia = preferred.firstIndex(of: a.element.name) ?? Int(Int32.max)
            let ib = preferred.firstIndex(of: b.element.name) ?? Int(Int32.max)
            if ia != ib { return ia < ib }
            let da = NetText.lowercased(a.element.displayName), db = NetText.lowercased(b.element.displayName)
            if da != db { return UnifiedModelFilter.kotlinLess(da, db) }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// `estimateTokens`.
    public static func estimateTokens(_ text: String) -> Int { max(NetText.length(text) / 4, 1) }
}

/// OpenAI-compatible chat completions.
public enum OpenAICodec {
    public static let openRouterReferer = "https://github.com/theovilardo/PixelPlayer"
    public static let openRouterTitle = "PixelPlayer"
    public static let requestTimeoutSeconds: Double = 60

    /// The `ChatRequest` body.
    public static func chatBody(model: String, systemPrompt: String, prompt: String, parameters: AiGenerationParameters) -> String {
        var messages: [JSONValue] = []
        func message(_ role: String, _ content: String) -> JSONValue {
            var o = JSONObject()
            o.append("role", .string(role))
            o.append("content", .string(content))
            return .object(o)
        }
        if !NetText.isBlank(systemPrompt) { messages.append(message("system", systemPrompt)) }
        messages.append(message("user", prompt))
        var root = JSONObject()
        root.append("model", .string(model))
        root.append("messages", .array(messages))
        let temperature = Double(parameters.temperature)
        if temperature != 0.7 { root.append("temperature", kotlinxDouble(temperature)) }
        root.append("top_p", kotlinxDouble(Double(parameters.topP)))
        if parameters.maxTokens > 0 { root.append("max_tokens", .integer(parameters.maxTokens)) }
        root.append("presence_penalty", kotlinxDouble(Double(parameters.presencePenalty)))
        root.append("frequency_penalty", kotlinxDouble(Double(parameters.frequencyPenalty)))
        return JSONWriter.write(.object(root))
    }

    private static func headers(apiKey: String, providerName: String, json: Bool) -> [HTTPHeader] {
        var headers: [HTTPHeader] = json ? [HTTPHeader("Content-Type", "application/json")] : []
        if !NetText.isBlank(apiKey) { headers.append(HTTPHeader("Authorization", "Bearer \(apiKey)")) }
        if json && NetText.equalsIgnoreCase(providerName, "OpenRouter") {
            headers.append(HTTPHeader("HTTP-Referer", openRouterReferer))
            headers.append(HTTPHeader("X-Title", openRouterTitle))
        }
        return headers
    }

    private static func trimmedBase(_ baseUrl: String) -> String {
        var base = baseUrl
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    /// `POST <base>/chat/completions`.
    public static func chatRequest(endpoint: OpenAICompatibleEndpoint, apiKey: String, body: String) -> HTTPRequest {
        HTTPRequest(method: .post, url: trimmedBase(endpoint.baseUrl) + "/chat/completions",
                    headers: headers(apiKey: apiKey, providerName: endpoint.providerName, json: true),
                    body: Data(body.utf8), timeout: requestTimeoutSeconds)
    }

    /// `GET <base>/models`.
    public static func modelsRequest(endpoint: OpenAICompatibleEndpoint, apiKey: String) -> HTTPRequest {
        HTTPRequest(url: trimmedBase(endpoint.baseUrl) + "/models", headers: headers(apiKey: apiKey, providerName: endpoint.providerName, json: false),
                    timeout: requestTimeoutSeconds)
    }

    /// `ChatResponse`: the first choice's message content; nil when there is no choice or the shape is wrong.
    public static func parseChatContent(_ body: String) -> String? {
        guard let root = (try? JSONParser(mode: .kotlinx).parse(body))?.objectValue,
              let choices = root["choices"]?.arrayValue, let first = choices.first?.objectValue,
              let message = first["message"]?.objectValue, case .string(let content)? = message["content"],
              case .string? = message["role"] else { return nil }
        return content
    }

    /// `ModelsResponse` ids filtered to chat models; nil when the body is not that shape.
    public static func parseModels(_ body: String) -> [String]? {
        guard let root = (try? JSONParser(mode: .kotlinx).parse(body))?.objectValue, let data = root["data"]?.arrayValue else { return nil }
        var ids: [String] = []
        for item in data {
            guard let o = item.objectValue, case .string(let id)? = o["id"] else { return nil }
            ids.append(id)
        }
        return UnifiedModelFilter.filterChatModels(ids)
    }

    /// The local estimate `(systemPrompt.length + prompt.length) / 4`.
    public static func estimatedTokens(systemPrompt: String, prompt: String) -> Int {
        (NetText.length(systemPrompt) + NetText.length(prompt)) / 4
    }
}

/// HTTP reason phrases (OkHttp `response.message` over HTTP/1.1) used as the fallback error text.
enum HTTPReason {
    static func phrase(_ code: Int) -> String? {
        switch code {
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 402: return "Payment Required"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 422: return "Unprocessable Entity"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return nil
        }
    }
}
