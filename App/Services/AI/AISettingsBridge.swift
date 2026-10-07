import Foundation
import PixlModel
import PixlNet
import SwiftData

/// What `AiOrchestrator` reads (Android `AiPreferencesRepository`): the same UserDefaults keys `AISettings` writes,
/// and the API keys from the Keychain (`<provider>_api_key`, no access group). Thread-safe reads only, so the
/// orchestrator actor can call it directly; model recovery writes the new model back like Android.
nonisolated final class AISettingsBridge: AiSettingsProviding, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The Keychain API key of `provider`, trimmed ("" when none).
    static func storedKey(for provider: AiProvider) -> String {
        guard let data = try? KeychainStore.data(for: PreferenceKeys.aiApiKeyAccount(provider.rawValue)) else { return "" }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The stored provider; unset means the on-device model (the iOS default, `AISettings.provider`).
    func selectedProvider() async -> AiProvider {
        AiProvider.fromString(defaults.string(forKey: PreferenceKeys.aiProvider) ?? AiProvider.onDevice.rawValue)
    }

    /// The providers a request tries, in order (`AiOrchestrator`'s `providerChain`).
    func providerChain(_ primary: AiProvider) async -> [AiProvider] { Self.providerChain(primary) }

    /// On-device stays on the device: no automatic cloud fallback (owner decision 2026-10-07). A cloud selection
    /// keeps Android's chain (the other providers with a key, then the on-device model).
    static func providerChain(_ primary: AiProvider) -> [AiProvider] {
        primary == .onDevice ? [.onDevice] : AiProviderSupport.buildProviderChain(primary)
    }

    func apiKey(for provider: AiProvider) async -> String { Self.storedKey(for: provider) }

    func model(for provider: AiProvider) async -> String {
        defaults.string(forKey: PreferenceKeys.aiModel(provider.rawValue)) ?? ""
    }

    func setModel(_ model: String, for provider: AiProvider) async {
        defaults.set(model, forKey: PreferenceKeys.aiModel(provider.rawValue))
    }

    func systemPrompt(for provider: AiProvider) async -> String {
        defaults.string(forKey: PreferenceKeys.aiSystemPrompt(provider.rawValue)) ?? ""
    }

    func baseUrl(for provider: AiProvider) async -> String {
        defaults.string(forKey: PreferenceKeys.aiBaseUrl(provider.rawValue)) ?? ""
    }

    func generationParameters() async -> AiGenerationParameters {
        AiGenerationParameters(
            temperature: Float(defaults.double(PreferenceKeys.aiTemperature, default: 0.7)),
            topP: Float(defaults.double(PreferenceKeys.aiTopP, default: 0.95)),
            topK: defaults.int(PreferenceKeys.aiTopK, default: 64),
            maxTokens: defaults.int(PreferenceKeys.aiMaxTokens, default: 4096),
            presencePenalty: Float(defaults.double(PreferenceKeys.aiPresencePenalty, default: 0)),
            frequencyPenalty: Float(defaults.double(PreferenceKeys.aiFrequencyPenalty, default: 0)))
    }
}

/// UI-test settings: Gemini with a placeholder key, so the orchestrator reaches the scripted client.
nonisolated struct DemoAiSettings: AiSettingsProviding {
    func selectedProvider() async -> AiProvider { .gemini }
    func apiKey(for provider: AiProvider) async -> String { "demo-key" }
    func model(for provider: AiProvider) async -> String { "" }
    func setModel(_ model: String, for provider: AiProvider) async {}
    func systemPrompt(for provider: AiProvider) async -> String { "" }
    func baseUrl(for provider: AiProvider) async -> String { "" }
    func generationParameters() async -> AiGenerationParameters { AiGenerationParameters() }
}

// MARK: - Cache and usage records

/// `AiCacheDao` on `AICacheRecord`.
nonisolated struct AICacheStore: AiResponseCaching {
    let persistence: PersistenceActor

    func cachedResponse(hash: String) async -> (response: String, timestampMs: Int64)? {
        try? await persistence.aiCachedResponse(hash: hash)
    }

    func store(hash: String, response: String, timestampMs: Int64) async {
        try? await persistence.aiStoreResponse(hash: hash, response: response, timestampMs: timestampMs)
    }
}

/// `AiUsageDao.insertUsage` on `AIUsageRecord`.
nonisolated struct AIUsageStore: AiUsageRecording {
    let persistence: PersistenceActor

    func record(_ usage: AiUsageRecord) async {
        try? await persistence.aiRecordUsage(usage)
    }
}

extension PersistenceActor {
    /// `getCache(hash)`.
    func aiCachedResponse(hash: String) throws -> (response: String, timestampMs: Int64)? {
        var descriptor = FetchDescriptor<AICacheRecord>(predicate: #Predicate { $0.promptHash == hash })
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return nil }
        return (record.responseJSON, record.timestamp)
    }

    /// `insert(cache)` with `OnConflictStrategy.REPLACE`, then `clearOldCache` for rows past the 30-minute TTL.
    func aiStoreResponse(hash: String, response: String, timestampMs: Int64) throws {
        var descriptor = FetchDescriptor<AICacheRecord>(predicate: #Predicate { $0.promptHash == hash })
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            existing.responseJSON = response
            existing.timestamp = timestampMs
        } else {
            modelContext.insert(AICacheRecord(promptHash: hash, responseJSON: response, timestamp: timestampMs))
        }
        let cutoff = timestampMs - AiOrchestrator.cacheTTLMs
        try modelContext.delete(model: AICacheRecord.self, where: #Predicate { $0.timestamp < cutoff })
        try modelContext.save()
    }

    /// `insertUsage(usage)`.
    func aiRecordUsage(_ usage: AiUsageRecord) throws {
        modelContext.insert(AIUsageRecord(timestamp: usage.timestamp, provider: usage.provider, model: usage.model,
                                          promptType: usage.promptType, promptTokens: usage.promptTokens,
                                          outputTokens: usage.outputTokens, thoughtTokens: usage.thoughtTokens))
        try modelContext.save()
    }
}
