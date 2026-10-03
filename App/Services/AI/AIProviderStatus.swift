import Foundation
import PixlNet

/// Whether the selected AI provider can answer, cached on the main actor and re-checked off it — at launch, when a
/// key is saved or deleted, when the provider or its base URL changes and after a settings restore. Library's
/// "New playlist" sheet asks while it is built: answering from `AIService` there built the whole AI service on the
/// main thread and read the Keychain (an IPC call) inside the sheet's presentation.
///
/// The answer is only reused for the provider and base URL it was computed for (both cheap `UserDefaults` reads), so
/// a change that skipped `refresh` — or a check still in flight — falls back to the old synchronous check, which is
/// always right. `invalidate()` drops it when the Keychain changed behind its back (a restore writes the keys), and
/// every `refresh` drops it while its own check runs, so a key just saved or deleted is never answered from the old
/// entry. A check that finishes after a newer `refresh` or `invalidate()` is discarded (`generation`).
enum AIProviderStatus {
    private struct Entry {
        let provider: String
        let baseUrl: String
        let isConfigured: Bool
    }

    private static var cached: Entry?
    /// Bumped by every `refresh` and `invalidate()`; a check stores its answer only if it is still the latest.
    private static var generation = 0

    static func isConfigured(_ env: AppEnvironment) -> Bool {
        let providerName = env.settings.ai.provider
        if let cached, cached.provider == providerName,
           cached.baseUrl == env.settings.ai.baseUrl(for: AiProvider.fromString(providerName).rawValue) {
            return cached.isConfigured
        }
        return env.ai.isProviderConfigured
    }

    /// Forgets the cached answer; the next question is answered synchronously until a `refresh` lands.
    static func invalidate() {
        generation &+= 1
        cached = nil
    }

    static func refresh(_ env: AppEnvironment) async {
        // Until this check lands, the synchronous check answers (the key or URL may just have changed).
        invalidate()
        let started = generation
        let providerName = env.settings.ai.provider
        let provider = AiProvider.fromString(providerName)
        let baseUrl = env.settings.ai.baseUrl(for: provider.rawValue)
        guard !env.launch.isUITest else {
            cached = Entry(provider: providerName, baseUrl: baseUrl, isConfigured: true)
            return
        }
        let configured = await check(provider, baseUrl: baseUrl)
        // A newer refresh or invalidation, or a provider or base URL change, while the check ran: its own refresh, or
        // the fallback, answers.
        guard started == generation, providerName == env.settings.ai.provider,
              baseUrl == env.settings.ai.baseUrl(for: provider.rawValue) else { return }
        cached = Entry(provider: providerName, baseUrl: baseUrl, isConfigured: configured)
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
