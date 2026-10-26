import Foundation
import PixlLibrary
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
/// - Claude first (2026-10-23): while the router sends requests to Claude, Claude writes both (the insight at high
///   effort); when it doesn't answer, the paths above run.
enum HomeAIGreeter {
    static let insightInstructions = """
        You write a short listening insight for a music app's home screen. From the facts given, write 2 short, warm \
        sentences about what the listener has been into and what they might enjoy next. Never mention play counts, \
        totals or how many songs are in the library. No quotes, no emoji, no markdown. Do not call tools.
        """

    /// An assistant's answer as Home shows it: the headline is one short line, the insight a few short sentences,
    /// and neither ever reads as a statistic (nil keeps the local text).
    static func clean(_ kind: HomeGreetingKind, _ text: String) -> String? {
        kind == .headline ? HomeLogic.cleanGreeting(text) : HomeLogic.cleanInsight(text)
    }

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
        if env.ai.currentRoute() == .claude, let client = env.ai.claudeClient() {
            let persona = ai.systemPrompt(for: provider.rawValue) ?? AiPromptEngine.defaultSystemPrompt
            let system = kind == .headline
                ? ClaudeRoutedGenerator.system(persona: persona, type: .greeting, context: "")
                    + [ClaudeSystemBlock(HomeSummary.headlineRules)]
                : [ClaudeSystemBlock(insightInstructions, cacheBreakpoint: true)]
            let recordUsage = env.ai.recordClaudeUsage
            let text = try? await withTimeout(seconds: timeoutSeconds) {
                try await ClaudeCompletion.text(client: client, system: system, prompt: prompt,
                                                effort: kind == .headline ? .medium : .high, onUsage: recordUsage)
            }
            if let cleaned = text.flatMap({ clean(kind, $0) }) { return cleaned }
            env.ai.cloud.logFallback("home \(kind == .headline ? "headline" : "insight") had no answer")
        }
        if provider == .onDevice {
            let persona = ai.systemPrompt(for: provider.rawValue) ?? AiPromptEngine.defaultSystemPrompt
            let instructions = kind == .headline
                ? AiPromptEngine.buildPrompt(basePersona: persona, type: .greeting) + HomeSummary.headlineRulesSeparator
                    + HomeSummary.headlineRules
                : insightInstructions
            let temperature = Double(AiPromptEngine.effectiveTemperature(type: .greeting, setting: Float(ai.temperature)))
            let maxTokens = kind == .headline ? 32 : 160
            // The card's chevron waits for the insight: never longer than this (the downloaded model computes every
            // token on the phone and may have to load first).
            let downloaded = ai.useDownloadedModel
            // The downloaded model (~900 MB) is never loaded by Home by itself: it killed the app on every launch. Home keeps
            // its local greeting (the gate logs the refusal).
            if downloaded {
                _ = LocalModelGate.canLoad(reason: .automatic)
                return nil
            }
            let text = try? await withTimeout(seconds: downloaded ? downloadedTimeoutSeconds : timeoutSeconds) {
                () async throws -> String in
                if downloaded {
                    return try await LocalModelAI.shared.greeting(instructions: instructions, prompt: prompt,
                                                                  temperature: temperature, maxTokens: maxTokens)
                }
                return try await OnDeviceAI.shared.greeting(instructions: instructions, prompt: prompt,
                                                            temperature: temperature, maxTokens: maxTokens)
            }
            return text.flatMap { clean(kind, OnDeviceText.cleanReply($0)) }
        }
        let (configured, _) = await AIProviderStatus.check(provider, baseUrl: ai.baseUrl(for: provider.rawValue))
        guard configured else { return nil }
        let orchestrator = env.ai.orchestrator
        let text = try? await withTimeout(seconds: timeoutSeconds) {
            try await orchestrator.generateContent(prompt: prompt, type: .greeting)
        }
        return text.flatMap { clean(kind, $0) }
    }

    /// The longest Home waits for an AI greeting or insight before keeping its local text.
    static let timeoutSeconds: Double = 20
    /// The same with the downloaded model.
    static let downloadedTimeoutSeconds: Double = 45
}
