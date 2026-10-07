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
///
/// It also runs the one-time move of key-less Gemini users to the on-device model (owner decision 2026-10-07).
enum AIProviderStatus {
    private struct Entry {
        let provider: String
        let baseUrl: String
        let isConfigured: Bool
        /// Why the on-device model can't answer (nil for cloud providers and when it can).
        let onDeviceIssue: OnDeviceFailure?
    }

    private static var cached: Entry?
    /// Bumped by every `refresh` and `invalidate()`; a check stores its answer only if it is still the latest.
    private static var generation = 0

    static func isConfigured(_ env: AppEnvironment) -> Bool {
        if env.launch.screen == .libraryCreatePlaylistOnDeviceOff { return false }
        let providerName = env.settings.ai.provider
        if let cached, cached.provider == providerName,
           cached.baseUrl == env.settings.ai.baseUrl(for: AiProvider.fromString(providerName).rawValue) {
            return cached.isConfigured
        }
        return env.ai.isProviderConfigured
    }

    /// Why the selected on-device model can't answer, when it is selected and can't (Library's "With AI" card says
    /// so instead of asking for an API key). The cached answer, else the same synchronous check `isConfigured` falls
    /// back to.
    static func onDeviceIssue(_ env: AppEnvironment) -> OnDeviceFailure? {
        if env.launch.screen == .libraryCreatePlaylistOnDeviceOff { return .intelligenceOff }
        let providerName = env.settings.ai.provider
        guard AiProvider.fromString(providerName) == .onDevice, !env.launch.isUITest else { return nil }
        if let cached, cached.provider == providerName { return cached.onDeviceIssue }
        return OnDeviceModel.unavailability
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
            cached = Entry(provider: providerName, baseUrl: baseUrl, isConfigured: true, onDeviceIssue: nil)
            return
        }
        let (configured, issue) = await check(provider, baseUrl: baseUrl)
        // A newer refresh or invalidation, or a provider or base URL change, while the check ran: its own refresh, or
        // the fallback, answers.
        guard started == generation, providerName == env.settings.ai.provider,
              baseUrl == env.settings.ai.baseUrl(for: provider.rawValue) else { return }
        cached = Entry(provider: providerName, baseUrl: baseUrl, isConfigured: configured, onDeviceIssue: issue)
    }

    /// `AIService.isProviderConfigured`, off the main actor, with the on-device model's reason when it can't answer.
    @concurrent
    nonisolated static func check(_ provider: AiProvider, baseUrl: String) async -> (Bool, OnDeviceFailure?) {
        switch provider {
        case .onDevice:
            let issue = OnDeviceModel.unavailability
            return (issue == nil, issue)
        case .ollama: return (!AISettingsBridge.storedKey(for: provider).isEmpty || !baseUrl.isEmpty, nil)
        default: return (!AISettingsBridge.storedKey(for: provider).isEmpty, nil)
        }
    }

    // MARK: One-time move to the on-device model

    /// Moves a user who had Gemini selected (Android's default) but never saved a Gemini key to the on-device model,
    /// once. Runs at launch and again after a settings restore (`ignoringFlag`): a restore — an Android backup in
    /// particular — can bring GEMINI back; if it brought the key too, Gemini stays. Someone who later picks Gemini
    /// on purpose before pasting a key isn't moved back, because the flag is set after the first run.
    static func migrateDefaultProviderIfNeeded(_ env: AppEnvironment, ignoringFlag: Bool = false) async {
        guard !env.launch.isUITest else { return }
        let ai = env.settings.ai
        guard ignoringFlag || !ai.providerMigrated else { return }
        let stored = ai.provider
        // The Keychain read is IPC: off the main actor.
        let hasGeminiKey = await hasStoredKey(.gemini)
        guard ai.provider == stored else { return } // changed meanwhile: the user decided
        if shouldMoveToOnDevice(storedProvider: stored, hasGeminiKey: hasGeminiKey) {
            ai.provider = AiProvider.onDevice.rawValue
        }
        ai.providerMigrated = true
    }

    /// The rule: Gemini (or an unknown name, which reads as Gemini) without a key moves.
    nonisolated static func shouldMoveToOnDevice(storedProvider: String, hasGeminiKey: Bool) -> Bool {
        AiProvider.fromString(storedProvider) == .gemini && !hasGeminiKey
    }

    @concurrent
    nonisolated private static func hasStoredKey(_ provider: AiProvider) async -> Bool {
        !AISettingsBridge.storedKey(for: provider).isEmpty
    }
}
