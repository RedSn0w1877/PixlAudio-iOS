import Foundation
import PixlNet

/// Home's AI greeting (Android `HomeGreetingStateHolder`, ported 2026-10-07): the selected assistant writes the
/// headline once a day and the longer insight when the card is expanded; Home keeps its local texts until then and
/// whenever the assistant can't answer.
///
/// - On-device (the default): `OnDeviceAI.greeting`. The headline uses Android's GREETING prompt layer (persona
///   included); the insight gets its own short instructions, because the GREETING layer asks for exactly one sentence
///   while the insight asks for two or three.
/// - A cloud assistant: the orchestrator's GREETING request, as on Android, and only with a key (Ollama: a base URL).
///   Android skips the headline for providers without a key, the on-device one included; iOS asks the on-device model.
enum HomeAIGreeter {
    static let insightInstructions = """
        You write a short listening insight for a music app's home screen. From the facts given, write 2 to 3 warm \
        sentences about the listener's habits and what they might enjoy next. No quotes, no emoji, no markdown. \
        Do not call tools.
        """

    /// The greeter Home asks (nil in UI tests: the local greeting stays, screenshots stay stable).
    static func make(_ env: AppEnvironment) -> HomeStore.Greeter? {
        guard !env.launch.isUITest else { return nil }
        return { [weak env] kind, facts in
            guard let env else { return nil }
            return await greet(env, kind: kind, facts: facts)
        }
    }

    static func greet(_ env: AppEnvironment, kind: HomeGreetingKind, facts: HomeGreetingFacts) async -> String? {
        let ai = env.settings.ai
        let provider = AiProvider.fromString(ai.provider)
        let prompt = kind == .headline ? HomeLogic.greetingPrompt(facts) : HomeLogic.insightPrompt(facts)
        let limit = kind == .headline ? 140 : 600
        if provider == .onDevice {
            let persona = ai.systemPrompt(for: provider.rawValue) ?? AiPromptEngine.defaultSystemPrompt
            let instructions = kind == .headline
                ? AiPromptEngine.buildPrompt(basePersona: persona, type: .greeting) : insightInstructions
            let temperature = Double(AiPromptEngine.effectiveTemperature(type: .greeting, setting: Float(ai.temperature)))
            let text = try? await OnDeviceAI.shared.greeting(instructions: instructions, prompt: prompt,
                                                             temperature: temperature,
                                                             maxTokens: kind == .headline ? 60 : 220)
            return text.flatMap { HomeLogic.cleanGreeting(OnDeviceText.cleanReply($0), limit: limit) }
        }
        let (configured, _) = await AIProviderStatus.check(provider, baseUrl: ai.baseUrl(for: provider.rawValue))
        guard configured else { return nil }
        let orchestrator = env.ai.orchestrator
        let text = try? await orchestrator.generateContent(prompt: prompt, type: .greeting)
        return text.flatMap { HomeLogic.cleanGreeting($0, limit: limit) }
    }
}
