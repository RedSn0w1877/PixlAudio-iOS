import Foundation
import PixlNet

/// The scripted provider UI tests use (`-uiTest`): no network, deterministic answers shaped like a real model's.
/// Playlist prompts get every other candidate id (up to the requested maximum), Taizo's intro line and chat get
/// fixed sentences, lyric translations echo each line with a bracketed translation.
nonisolated struct DemoAiClient: AiClient {
    static let introLine = "Here's some indie warmth straight from your library."
    static let chatReply = "Daft Punk produced Random Access Memories themselves, recording with session legends like "
        + "Nile Rodgers and Giorgio Moroder. Want me to queue something with that disco-funk feel?"

    /// A prompt containing this fails like a provider rejecting the key (the AI sheet's error state).
    static let errorTrigger = "#demo-error"
    /// A prompt containing this fails like "Use downloaded AI model" without the model downloaded.
    static let localModelTrigger = "#demo-local-model"

    var defaultModel: String { "demo-model" }

    func generateContent(model: String, systemPrompt: String, prompt: String, parameters: AiGenerationParameters) async throws -> String {
        if prompt.contains(Self.localModelTrigger) {
            throw AiProviderSupport.makeError(providerName: OnDeviceAiClient.providerName, statusCode: nil,
                                              transportMessage: OnDeviceFailure.localModelMissing.message,
                                              responseBody: nil, requestedModel: model)
        }
        if prompt.contains(Self.errorTrigger) {
            // The error screenshot: a rejected key, as a provider reports it.
            throw AiProviderSupport.makeError(providerName: "Demo", statusCode: 401, transportMessage: "Unauthorized",
                                              responseBody: #"{"error":{"message":"API key not valid. Please pass a valid API key."}}"#,
                                              requestedModel: model)
        }
        if AIPromptShape.expectsSongIdArray(systemPrompt: systemPrompt) {
            let ids = AIPromptShape.candidateIds(inPrompt: prompt)
            let limit = AIPromptShape.targetLength(inPrompt: prompt)?.max ?? 12
            let picked = ids.enumerated().filter { $0.offset % 2 == 0 }.map(\.element).prefix(limit)
            return AIPromptShape.jsonArray(Array(picked))
        }
        if prompt.hasPrefix("user_request=") { return Self.introLine }
        if prompt.contains("<task>Translate song lyrics") { return Self.translation(of: prompt) }
        return Self.chatReply
    }

    func countTokens(model: String, systemPrompt: String, prompt: String) async -> Int { (systemPrompt.count + prompt.count) / 4 }

    func availableModels(apiKey: String) async -> [String] { [defaultModel] }

    func validateApiKey(_ apiKey: String) async -> Bool { true }

    /// Every `[mm:ss.xx] text` line of the `<lyrics>` block, followed by the same timestamp and `(text)`.
    private static func translation(of prompt: String) -> String {
        guard let start = prompt.range(of: "<lyrics>\n"), let end = prompt.range(of: "\n</lyrics>") else { return "" }
        return prompt[start.upperBound..<end.lowerBound].split(separator: "\n").flatMap { line -> [String] in
            guard let close = line.firstIndex(of: "]"), line.hasPrefix("[") else { return [String(line)] }
            let stamp = line[...close]
            let text = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            return [String(line), "\(stamp) (\(text))"]
        }.joined(separator: "\n")
    }
}
