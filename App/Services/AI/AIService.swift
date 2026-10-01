import CryptoKit
import Foundation
import Observation
import PixlFoundation
import PixlLibrary
import PixlModel
import PixlNet

/// Stage 13: the app's AI layer (Android `data/ai/**` + `AiStateHolder` + `data/tais/dj/**`), on PixlNet's provider
/// codecs and prompt engine.
///
/// - `orchestrator` is PixlNet's `AiOrchestrator` (Android `AiHandler`): provider chain with cooldowns, 30-minute
///   response cache (`AICacheRecord`), model recovery and usage records (`AIUsageRecord`). It reads the settings
///   through `AISettingsBridge` (UserDefaults under Android's keys, API keys in the Keychain).
/// - Every OpenAI-compatible provider and Gemini go through `URLSessionHTTPClient`; a user's Ollama / custom base
///   URL may be plain HTTP on the LAN (Info.plist allows arbitrary loads, `NSLocalNetworkUsageDescription`).
/// - The on-device provider is the system language model (`OnDeviceAiClient`, Foundation Models).
/// - UI tests (`-uiTest`) get a scripted provider (`DemoAiClient`) so the sheets are deterministic and offline.
///
/// Feature state lives in two process-scoped holders, like Android's `@Singleton`s: `playlist` (the AI playlist
/// sheet and the AI Playlist Lab) and `chat` (the TAIS DJ chat).
@Observable
final class AIService {
    let orchestrator: AiOrchestrator
    let playlistGenerator: AiPlaylistGenerator
    let lyricsTranslator: AILyricsTranslator
    let playlist: AIPlaylistController
    let chat: TaisChatModel
    let isDemo: Bool

    @ObservationIgnored private let http: any HTTPClient
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let bridge: any AiSettingsProviding

    init(launch: LaunchConfiguration, settings: SettingsStore, persistence: PersistenceActor?, library: LibraryStore,
         home: HomeStore, playback: PlaybackStore, router: Router, searchProviders: [SearchSource: any SearchProviding],
         libraryEditor: @escaping @MainActor () -> LibraryEditor) {
        let isDemo = launch.isUITest
        self.isDemo = isDemo
        self.settings = settings
        let http = URLSessionHTTPClient()
        self.http = http
        let bridge: any AiSettingsProviding = isDemo ? DemoAiSettings() : AISettingsBridge(defaults: .standard)
        self.bridge = bridge
        let cache: (any AiResponseCaching)? = isDemo ? nil : persistence.map { AICacheStore(persistence: $0) }
        let usage: (any AiUsageRecording)? = isDemo ? nil : persistence.map { AIUsageStore(persistence: $0) }
        let onDevice: any AiClient = isDemo ? DemoAiClient() : OnDeviceAiClient()
        var factory: (@Sendable (AiProvider, String, String) throws -> any AiClient)?
        if isDemo { factory = { @Sendable _, _, _ in DemoAiClient() } }
        let orchestrator = AiOrchestrator(http: http, settings: bridge, cache: cache, usage: usage,
                                          sha256: AIService.sha256, onDeviceClient: onDevice,
                                          clientFactory: factory)
        self.orchestrator = orchestrator
        let generator = AiPlaylistGenerator(orchestrator: orchestrator)
        playlistGenerator = generator
        lyricsTranslator = AILyricsTranslator(orchestrator: orchestrator)
        playlist = AIPlaylistController(generator: generator, settings: settings, library: library, home: home,
                                        playback: playback, router: router, libraryEditor: libraryEditor)
        let remote: [any SearchProviding] = [searchProviders[.spotify], searchProviders[.youtubeMusic]].compactMap { $0 }
        let mediaRouter = TaisMediaRouter(songs: { library.songs }, remoteProviders: remote)
        chat = TaisChatModel(engine: TaisDjEngine(router: mediaRouter, orchestrator: orchestrator), playback: playback)
    }

    /// CryptoKit SHA-256 for PixlNet's cache keys (PixlCore takes it injected).
    nonisolated static let sha256: SHA256Function = { bytes in Array(SHA256.hash(data: Data(bytes))) }

    // MARK: Provider state (Android `hasActiveAiProviderApiKey`)

    /// Whether the selected assistant can answer: a stored API key, an Ollama base URL, or an available on-device
    /// model. UI tests always have the scripted provider.
    var isProviderConfigured: Bool {
        if isDemo { return true }
        let provider = AiProvider.fromString(settings.ai.provider)
        switch provider {
        case .onDevice: return OnDeviceAiClient.isAvailable
        case .ollama: return !AISettingsBridge.storedKey(for: provider).isEmpty || !settings.ai.baseUrl(for: provider.rawValue).isEmpty
        default: return !AISettingsBridge.storedKey(for: provider).isEmpty
        }
    }

    // MARK: Settings (Android `SettingsViewModel.fetchAvailableModels`)

    /// The selected provider's chat models for the settings picker: Gemini's list service (API models + the
    /// recommended defaults), else the provider's `/models`, trimmed, distinct. Falls back to the defaults.
    func availableModels(for provider: AiProvider, apiKey: String) async -> [GeminiModel] {
        if isDemo { return GeminiModel.defaults }
        let http = self.http
        switch provider {
        case .onDevice:
            return [GeminiModel(name: OnDeviceAiClient.modelName, displayName: "On-device model")]
        case .gemini:
            let response = try? await http.send(GeminiModel.listRequest(apiKey: apiKey))
            return GeminiModel.models(fromBody: response?.isSuccessful == true ? response?.text : nil)
        default:
            let baseUrl = provider.hasConfigurableUrl ? settings.ai.baseUrl(for: provider.rawValue) : ""
            guard let client = try? AiClientFactory.client(for: provider, apiKey: apiKey, baseUrl: baseUrl, http: http) else {
                return []
            }
            var seen = Set<String>()
            return await client.availableModels(apiKey: apiKey)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
                .map { GeminiModel(name: $0, displayName: AIService.modelDisplayName($0)) }
        }
    }

    /// Android `formatModelDisplayName`: drop `models/`, dashes and underscores to spaces, each word capitalised.
    nonisolated static func modelDisplayName(_ name: String) -> String {
        var trimmed = name
        if trimmed.hasPrefix("models/") { trimmed.removeFirst("models/".count) }
        return trimmed.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { token in
                let lower = token.lowercased()
                guard let first = lower.first else { return lower }
                return first.uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }
}
