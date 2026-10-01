import Foundation
import FoundationModels
import PixlNet

/// The on-device provider (`AiProvider.onDevice`, Android `OnDeviceAiClient` on MediaPipe) on the system's
/// on-device language model (Foundation Models): no network, no key, availability-gated at run time.
///
/// Each call is a fresh `LanguageModelSession` whose instructions are the orchestrator's layered system prompt.
/// Playlist and Daily Mix prompts (whose schema asks for a JSON array of song ids) use guided generation
/// (`OnDevicePlaylistSelection`, `@Generable`), so the small model can't wrap the ids in prose; the ids come back
/// as the JSON array PixlNet's parser expects.
nonisolated struct OnDeviceAiClient: AiClient {
    /// Android's `getDefaultModel()`.
    static let modelName = "on-device"

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    var defaultModel: String { Self.modelName }

    func generateContent(model: String, systemPrompt: String, prompt: String, parameters: AiGenerationParameters) async throws -> String {
        guard Self.isAvailable else {
            throw Self.error("The on-device model isn't available on this iPhone right now. Pick another assistant in Settings › AI features.")
        }
        let session = LanguageModelSession(instructions: systemPrompt)
        let options = GenerationOptions(sampling: nil, temperature: Double(parameters.temperature),
                                        maximumResponseTokens: min(max(parameters.maxTokens, 256), 4096))
        do {
            if AIPromptShape.expectsSongIdArray(systemPrompt: systemPrompt) {
                let response = try await session.respond(to: prompt, generating: OnDevicePlaylistSelection.self, options: options)
                return AIPromptShape.jsonArray(response.content.songIds)
            }
            let response = try await session.respond(to: prompt, options: options)
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.error(Self.message(for: error))
        }
    }

    func countTokens(model: String, systemPrompt: String, prompt: String) async -> Int {
        (systemPrompt.count + prompt.count) / 4
    }

    func availableModels(apiKey: String) async -> [String] { [Self.modelName] }

    func validateApiKey(_ apiKey: String) async -> Bool { true }

    private static func error(_ message: String) -> AiProviderError {
        AiProviderSupport.makeError(providerName: AiProvider.onDevice.displayName, statusCode: nil, transportMessage: message,
                                    responseBody: nil, requestedModel: nil)
    }

    private static func message(for error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize:
            return "The request is too long for the on-device model. Keep \"Save on usage\" on or lower the sample size in AI settings."
        case .guardrailViolation, .refusal:
            return "Content was blocked by safety filters. Try rephrasing your prompt."
        case .unsupportedLanguageOrLocale:
            return "The on-device model doesn't support this language yet."
        case .assetsUnavailable:
            return "The on-device model is still being prepared; try again later."
        case .rateLimited, .concurrentRequests:
            return "The on-device model is busy. Wait a moment and try again."
        default:
            return error.localizedDescription
        }
    }
}

/// Guided-generation output for playlist prompts (the candidate ids the model picked, in play order).
@Generable(description: "The songs chosen for the playlist, in play order")
nonisolated struct OnDevicePlaylistSelection {
    @Guide(description: "Song ids copied exactly from the candidate_pool entries' id field")
    var songIds: [String]
}

/// What a layered system prompt asks for (PixlNet's playlist / Daily Mix layers end in an id-array schema).
nonisolated enum AIPromptShape {
    static let songIdArraySchema = "Return ONLY a raw JSON array of song IDs."

    static func expectsSongIdArray(systemPrompt: String) -> Bool { systemPrompt.contains(songIdArraySchema) }

    /// `["a","b"]` with JSON string escaping.
    static func jsonArray(_ ids: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: ids), let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    /// The `<candidate_pool>` JSON of a playlist prompt, decoded to its entries' ids (in pool order).
    static func candidateIds(inPrompt prompt: String) -> [String] {
        guard let start = prompt.range(of: "<candidate_pool>"), let end = prompt.range(of: "</candidate_pool>"),
              start.upperBound <= end.lowerBound else { return [] }
        let json = prompt[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = json.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return entries.compactMap { $0["id"] as? String }
    }

    /// The `<target_length>min-max tracks</target_length>` of a playlist prompt.
    static func targetLength(inPrompt prompt: String) -> (min: Int, max: Int)? {
        guard let start = prompt.range(of: "<target_length>"), let end = prompt.range(of: " tracks</target_length>"),
              start.upperBound <= end.lowerBound else { return nil }
        let parts = prompt[start.upperBound..<end.lowerBound].split(separator: "-")
        guard parts.count == 2, let low = Int(parts[0]), let high = Int(parts[1]) else { return nil }
        return (low, high)
    }
}
