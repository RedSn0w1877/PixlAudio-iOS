import Foundation
import PixlNet

/// Whether the selected AI provider can answer, cached on the main actor and re-checked off it — at launch, when a
/// key is saved or deleted and when the provider changes. Library's "New playlist" sheet asks while it is built:
/// answering from `AIService` there built the whole AI service on the main thread and read the Keychain (an IPC
/// call) inside the sheet's presentation. Until the first check lands, the old synchronous check answers.
enum AIProviderStatus {
    private static var cached: (provider: String, isConfigured: Bool)?

    static func isConfigured(_ env: AppEnvironment) -> Bool {
        if let cached, cached.provider == env.settings.ai.provider { return cached.isConfigured }
        return env.ai.isProviderConfigured
    }

    static func refresh(_ env: AppEnvironment) async {
        let providerName = env.settings.ai.provider
        guard !env.launch.isUITest else {
            cached = (providerName, true)
            return
        }
        let provider = AiProvider.fromString(providerName)
        let baseUrl = env.settings.ai.baseUrl(for: provider.rawValue)
        let configured = await check(provider, baseUrl: baseUrl)
        cached = (providerName, configured)
    }

    /// `AIService.isProviderConfigured`, off the main actor.
    @concurrent
    nonisolated static func check(_ provider: AiProvider, baseUrl: String) async -> Bool {
        switch provider {
        case .onDevice: return OnDeviceAiClient.isAvailable
        case .ollama: return !AISettingsBridge.storedKey(for: provider).isEmpty || !baseUrl.isEmpty
        default: return !AISettingsBridge.storedKey(for: provider).isEmpty
        }
    }
}
