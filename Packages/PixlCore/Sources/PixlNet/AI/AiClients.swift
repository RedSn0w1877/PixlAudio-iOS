// The provider clients (`AiClient`, `GeminiAiClient`, `GenericOpenAiClient`) over `HTTPClient`, and `AiHandler`'s
// orchestration: per-type temperature, response cache (30 min), provider fallback chain with 5-minute cooldowns,
// model recovery when the chosen model disappeared, usage estimates, and the final error message.

import Foundation
import PixlFoundation
import PixlModel

/// `AiClient`.
public protocol AiClient: Sendable {
    func generateContent(model: String, systemPrompt: String, prompt: String, parameters: AiGenerationParameters) async throws -> String
    func countTokens(model: String, systemPrompt: String, prompt: String) async -> Int
    func availableModels(apiKey: String) async -> [String]
    func validateApiKey(_ apiKey: String) async -> Bool
    var defaultModel: String { get }
}

/// `GeminiAiClient`.
public struct GeminiAiClient: AiClient {
    public let http: any HTTPClient
    public let apiKey: String

    public init(http: any HTTPClient, apiKey: String) {
        self.http = http
        self.apiKey = apiKey
    }

    public var defaultModel: String { GeminiCodec.defaultModel }

    public func generateContent(model: String, systemPrompt: String, prompt: String, parameters: AiGenerationParameters) async throws -> String {
        let resolved = NetText.isBlank(model) ? GeminiCodec.defaultModel : model
        let request = GeminiCodec.request(model: resolved, apiKey: apiKey,
                                          body: GeminiCodec.generateBody(systemPrompt: systemPrompt, prompt: prompt, parameters: parameters))
        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AiProviderSupport.wrap(providerName: "Gemini", error: error, requestedModel: resolved)
        }
        let body = response.text
        if !response.isSuccessful {
            throw AiProviderSupport.makeError(providerName: "Gemini", statusCode: response.statusCode,
                                              transportMessage: HTTPReason.phrase(response.statusCode), responseBody: body, requestedModel: resolved)
        }
        switch GeminiCodec.parseGenerateResponse(body) {
        case .text(let text):
            return text
        case .blocked(let reason):
            throw AiProviderSupport.makeError(providerName: "Gemini", statusCode: response.statusCode,
                                              transportMessage: "Request was blocked by Gemini (reason: \(reason)). Try rephrasing your prompt.",
                                              responseBody: body, requestedModel: resolved)
        case .empty:
            throw AiProviderSupport.makeError(providerName: "Gemini", statusCode: response.statusCode,
                                              transportMessage: "Gemini returned an empty response. The model may have filtered the content.",
                                              responseBody: body, requestedModel: resolved)
        case .malformed:
            throw AiProviderSupport.makeError(providerName: "Gemini", statusCode: nil, transportMessage: "Unexpected response format",
                                              responseBody: nil, requestedModel: resolved)
        }
    }

    public func countTokens(model: String, systemPrompt: String, prompt: String) async -> Int {
        let resolved = NetText.isBlank(model) ? GeminiCodec.defaultModel : model
        let estimate = GeminiCodec.estimatedTokens(systemPrompt: systemPrompt, prompt: prompt)
        let request = GeminiCodec.request(model: resolved, method: "countTokens", apiKey: apiKey,
                                          body: GeminiCodec.countTokensBody(systemPrompt: systemPrompt, prompt: prompt))
        guard let response = try? await http.send(request), response.isSuccessful else { return estimate }
        return GeminiCodec.totalTokens(response.text) ?? estimate
    }

    public func availableModels(apiKey: String) async -> [String] {
        guard let response = try? await http.send(GeminiCodec.modelsRequest(apiKey: apiKey)), response.isSuccessful else {
            return GeminiCodec.defaultModels
        }
        return GeminiCodec.chatModels(fromModelsBody: response.text)
    }

    public func validateApiKey(_ apiKey: String) async -> Bool {
        (try? await http.send(GeminiCodec.modelsRequest(apiKey: apiKey)))?.isSuccessful ?? false
    }
}

/// `GenericOpenAiClient` (DeepSeek, Groq, Mistral, NVIDIA, Kimi, GLM, OpenAI, OpenRouter, Ollama, custom).
public struct OpenAICompatibleAiClient: AiClient {
    public let http: any HTTPClient
    public let apiKey: String
    public let endpoint: OpenAICompatibleEndpoint

    public init(http: any HTTPClient, apiKey: String, endpoint: OpenAICompatibleEndpoint) {
        self.http = http
        self.apiKey = apiKey
        self.endpoint = endpoint
    }

    public var defaultModel: String { endpoint.defaultModel }

    public func generateContent(model: String, systemPrompt: String, prompt: String, parameters: AiGenerationParameters) async throws -> String {
        let resolved = NetText.isBlank(model) ? endpoint.defaultModel : model
        let request = OpenAICodec.chatRequest(endpoint: endpoint, apiKey: apiKey,
                                              body: OpenAICodec.chatBody(model: resolved, systemPrompt: systemPrompt, prompt: prompt, parameters: parameters))
        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AiProviderSupport.wrap(providerName: endpoint.providerName, error: error, requestedModel: resolved)
        }
        let body = response.text
        if !response.isSuccessful {
            throw AiProviderSupport.makeError(providerName: endpoint.providerName, statusCode: response.statusCode,
                                              transportMessage: HTTPReason.phrase(response.statusCode), responseBody: body, requestedModel: resolved)
        }
        guard let content = OpenAICodec.parseChatContent(body) else {
            throw AiProviderSupport.makeError(providerName: endpoint.providerName, statusCode: response.statusCode,
                                              transportMessage: "Response had no content", responseBody: body, requestedModel: resolved)
        }
        return content
    }

    public func countTokens(model: String, systemPrompt: String, prompt: String) async -> Int {
        OpenAICodec.estimatedTokens(systemPrompt: systemPrompt, prompt: prompt)
    }

    public func availableModels(apiKey: String) async -> [String] {
        guard let response = try? await http.send(OpenAICodec.modelsRequest(endpoint: endpoint, apiKey: apiKey)), response.isSuccessful,
              let models = OpenAICodec.parseModels(response.text) else { return [endpoint.defaultModel] }
        return models
    }

    public func validateApiKey(_ apiKey: String) async -> Bool {
        (try? await http.send(OpenAICodec.modelsRequest(endpoint: endpoint, apiKey: apiKey)))?.isSuccessful ?? false
    }
}

/// `AiClientFactory`.
public enum AiClientFactory {
    /// `createClient` (fixed endpoints) or `createClientWithUrl` (Ollama/custom). Throws for a blank key on a
    /// fixed-endpoint provider and for the on-device provider (the app supplies that client).
    public static func client(for provider: AiProvider, apiKey: String, baseUrl: String = "", http: any HTTPClient) throws -> any AiClient {
        if provider.hasConfigurableUrl {
            return OpenAICompatibleAiClient(http: http, apiKey: apiKey, endpoint: provider.configurableEndpoint(baseUrl: baseUrl))
        }
        if provider == .onDevice {
            throw AiProviderError(providerName: provider.displayName, message: "AiProvider.ON_DEVICE must go through the on-device client, not createClient() — it has no API key to build from.")
        }
        if NetText.isBlank(apiKey) {
            throw AiProviderError(providerName: provider.displayName, message: "API Key cannot be blank for \(provider.displayName)")
        }
        if provider == .gemini { return GeminiAiClient(http: http, apiKey: apiKey) }
        return OpenAICompatibleAiClient(http: http, apiKey: apiKey, endpoint: provider.openAICompatibleEndpoint!)
    }
}

// MARK: - Orchestration (AiHandler)

/// The AI settings `AiHandler` reads (`AiPreferencesRepository`).
public protocol AiSettingsProviding: Sendable {
    /// The provider the user picked (`ai_provider`, default GEMINI).
    func selectedProvider() async -> AiProvider
    func apiKey(for provider: AiProvider) async -> String
    func model(for provider: AiProvider) async -> String
    func setModel(_ model: String, for provider: AiProvider) async
    /// The persona (blank means the default system prompt).
    func systemPrompt(for provider: AiProvider) async -> String
    func baseUrl(for provider: AiProvider) async -> String
    func generationParameters() async -> AiGenerationParameters
}

/// The response cache (`AiCacheEntity`).
public protocol AiResponseCaching: Sendable {
    func cachedResponse(hash: String) async -> (response: String, timestampMs: Int64)?
    func store(hash: String, response: String, timestampMs: Int64) async
}

// One usage row (`AiUsageEntity`) is PixlModel's `AiUsageRecord`, shared with PixlBackup.

/// Records usage (`AiUsageDao`).
public protocol AiUsageRecording: Sendable {
    func record(_ usage: AiUsageRecord) async
}

/// The final error when every provider failed.
public struct AiGenerationError: Error, Sendable, Hashable, CustomStringConvertible {
    public let message: String
    public let failures: [String]
    public var description: String { message }
}

/// `AiHandler`.
public actor AiOrchestrator {
    public static let cooldownMs: Int64 = 1000 * 60 * 5
    public static let cacheTTLMs: Int64 = 1000 * 60 * 30
    public static let requestTimeoutSeconds: Double = 60

    private let http: any HTTPClient
    private let settings: any AiSettingsProviding
    private let cache: (any AiResponseCaching)?
    private let usage: (any AiUsageRecording)?
    private let sha256: SHA256Function
    private let onDeviceClient: (any AiClient)?
    private let nowMs: @Sendable () -> Int64
    private let clientFactory: @Sendable (AiProvider, String, String) throws -> any AiClient
    private var providerCooldowns: [AiProvider: Int64] = [:]

    public init(http: any HTTPClient, settings: any AiSettingsProviding, cache: (any AiResponseCaching)? = nil,
                usage: (any AiUsageRecording)? = nil, sha256: @escaping SHA256Function, onDeviceClient: (any AiClient)? = nil,
                nowMs: @escaping @Sendable () -> Int64 = { currentTimeMillis() },
                clientFactory: (@Sendable (AiProvider, String, String) throws -> any AiClient)? = nil) {
        self.http = http
        self.settings = settings
        self.cache = cache
        self.usage = usage
        self.sha256 = sha256
        self.onDeviceClient = onDeviceClient
        self.nowMs = nowMs
        let client = http
        self.clientFactory = clientFactory ?? { provider, apiKey, baseUrl in
            try AiClientFactory.client(for: provider, apiKey: apiKey, baseUrl: baseUrl, http: client)
        }
    }

    private func basePersona(_ provider: AiProvider) async -> String {
        let prompt = await settings.systemPrompt(for: provider)
        return NetText.isBlank(prompt) ? AiPromptEngine.defaultSystemPrompt : prompt
    }

    /// The cache key: SHA-256 hex of provider name + system prompt + prompt.
    public static func cacheKey(provider: AiProvider, systemPrompt: String, prompt: String, sha256: SHA256Function) -> String {
        NetText.hex(sha256(Array((provider.rawValue + systemPrompt + prompt).utf8)))
    }

    /// `generateContent(prompt, type, temperature, context)`.
    public func generateContent(prompt: String, type: AiSystemPromptType = .general, temperature: Float = 0.7, context: String = "") async throws -> String {
        var params = await settings.generationParameters()
        params.temperature = AiPromptEngine.effectiveTemperature(type: type, requested: temperature, setting: params.temperature)

        let userProvider = await settings.selectedProvider()
        let combinedSystemPrompt = AiPromptEngine.buildPrompt(basePersona: await basePersona(userProvider), type: type, context: context)
        let hash = Self.cacheKey(provider: userProvider, systemPrompt: combinedSystemPrompt, prompt: prompt, sha256: sha256)
        if let cached = await cache?.cachedResponse(hash: hash), nowMs() - cached.timestampMs < Self.cacheTTLMs {
            return cached.response
        }

        var failed: [String] = []
        let now = nowMs()
        for provider in AiProviderSupport.buildProviderChain(userProvider) {
            let expiry = providerCooldowns[provider] ?? 0
            if now < expiry {
                failed.append("\(provider.rawValue): on cooldown (\((expiry - now) / 1000)s remaining)")
                continue
            }
            do {
                let apiKey = await settings.apiKey(for: provider)
                if NetText.isBlank(apiKey) && provider.requiresApiKey {
                    failed.append("\(provider.rawValue): no API key configured")
                    continue
                }
                let finalSystemPrompt = AiPromptEngine.buildPrompt(basePersona: await basePersona(provider), type: type, context: context)
                let result = try await generateWithRecovery(provider: provider, apiKey: apiKey, systemPrompt: finalSystemPrompt,
                                                            prompt: prompt, parameters: params)
                if NetText.isBlank(result.response) {
                    failed.append("\(provider.rawValue): returned empty response")
                    continue
                }
                let thinking = NetText.containsIgnoreCase(finalSystemPrompt, "think") || NetText.containsIgnoreCase(provider.rawValue, "reasoning")
                let promptTokens = (NetText.length(finalSystemPrompt) + NetText.length(prompt)) / 4
                let outputTokens = NetText.length(result.response) / 4
                let thoughtTokens = thinking ? Int(KotlinMath.toInt(Double(outputTokens) * 1.5)) : 0
                await usage?.record(AiUsageRecord(timestamp: now, provider: provider.displayName, model: result.model,
                                                  promptType: type.rawValue, promptTokens: promptTokens,
                                                  outputTokens: outputTokens, thoughtTokens: thoughtTokens))
                await cache?.store(hash: hash, response: result.response, timestampMs: nowMs())
                return result.response
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let failure = AiProviderSupport.wrap(providerName: provider.displayName, error: error)
                failed.append("\(provider.rawValue): \(failure.message)")
                if failure.shouldCooldown() { providerCooldowns[provider] = now + Self.cooldownMs }
            }
        }
        throw AiGenerationError(message: Self.failureMessage(failed), failures: failed)
    }

    /// The user-facing message when every provider failed.
    public static func failureMessage(_ failed: [String]) -> String {
        if failed.allSatisfy({ $0.contains("no API key") }) {
            return "No API key configured. Go to Settings → AI Integration to set up your API key."
        }
        if failed.allSatisfy({ $0.contains("cooldown") }) {
            return "All AI providers are on cooldown after recent errors. Wait a few minutes and try again."
        }
        if failed.count == 1 { return "AI generation failed: \(failed[0])" }
        return "AI generation failed after trying \(failed.count) providers:\n• " + failed.joined(separator: "\n• ")
    }

    private func generateWithRecovery(provider: AiProvider, apiKey: String, systemPrompt: String, prompt: String,
                                      parameters: AiGenerationParameters) async throws -> (response: String, model: String) {
        let client: any AiClient
        if provider == .onDevice {
            guard let onDeviceClient else {
                throw AiProviderError(providerName: provider.displayName, message: "No on-device model available — check Settings > AI > On-Device")
            }
            client = onDeviceClient
        } else {
            client = try clientFactory(provider, apiKey, provider.hasConfigurableUrl ? await settings.baseUrl(for: provider) : "")
        }
        let stored = await settings.model(for: provider)
        let requestedModel = NetText.isBlank(stored) ? client.defaultModel : stored

        func call(_ model: String) async throws -> String {
            let outcome = try await withTimeout(seconds: Self.requestTimeoutSeconds) {
                try await client.generateContent(model: model, systemPrompt: systemPrompt, prompt: prompt, parameters: parameters)
            }
            guard let outcome else {
                throw AiProviderSupport.makeError(providerName: provider.displayName, statusCode: nil,
                                                  transportMessage: "Request timed out after \(Int(Self.requestTimeoutSeconds))s. The model may be overloaded.",
                                                  responseBody: nil, requestedModel: model)
            }
            return outcome
        }

        do {
            return (try await call(requestedModel), requestedModel)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = AiProviderSupport.wrap(providerName: provider.displayName, error: error, requestedModel: requestedModel)
            guard failure.isModelUnavailable() else { throw failure }
            let available = await client.availableModels(apiKey: apiKey)
            guard let recovered = AiProviderSupport.selectRecoveryModel(currentModel: requestedModel, defaultModel: client.defaultModel,
                                                                        availableModels: available) else { throw failure }
            await settings.setModel(recovered, for: provider)
            return (try await call(recovered), recovered)
        }
    }
}
