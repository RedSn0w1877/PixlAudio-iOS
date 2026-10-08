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
/// - The on-device provider is the system language model (Foundation Models), and the default (2026-10-07). With it
///   selected, the features run on-device paths sized for its 4,096-token window instead of the orchestrator's
///   cloud prompts: `OnDevicePlaylistCurator` (playlists, Daily Mix), `OnDeviceAI` (Taizo's chat with memory and the
///   library tool, intro lines, Home's greeting) and `OnDeviceLyricsTranslator`. The orchestrator never falls back
///   from on-device to a cloud provider (`AISettingsBridge.providerChain`); `OnDeviceAiClient` stays for a cloud
///   selection whose chain ends on the device.
/// - UI tests (`-uiTest`) get a scripted provider (`DemoAiClient`) so the sheets are deterministic and offline; none
///   of the on-device paths run there (CI simulators have no system language model).
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
    /// The on-device sessions and the settings they read (nil in UI tests).
    let onDevice: OnDeviceContext?

    @ObservationIgnored private let http: any HTTPClient
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let bridge: any AiSettingsProviding
    /// The library, for Taizo's lookup tool.
    @ObservationIgnored private let librarySongs: @MainActor @Sendable () -> [Song]

    init(launch: LaunchConfiguration, settings: SettingsStore, persistence: PersistenceActor?, library: LibraryStore,
         home: HomeStore, playback: PlaybackStore, router: Router, searchProviders: [SearchSource: any SearchProviding],
         libraryEditor: @escaping @MainActor () -> LibraryEditor) {
        let isDemo = launch.isUITest
        self.isDemo = isDemo
        self.settings = settings
        let http = URLSessionHTTPClient()
        self.http = http
        let realBridge: AISettingsBridge? = isDemo ? nil : AISettingsBridge(defaults: .standard)
        let bridge: any AiSettingsProviding = realBridge ?? DemoAiSettings()
        self.bridge = bridge
        let cache: (any AiResponseCaching)? = isDemo ? nil : persistence.map { AICacheStore(persistence: $0) }
        let usage: (any AiUsageRecording)? = isDemo ? nil : persistence.map { AIUsageStore(persistence: $0) }
        let onDeviceClient: any AiClient = isDemo ? DemoAiClient() : OnDeviceAiClient()
        var factory: (@Sendable (AiProvider, String, String) throws -> any AiClient)?
        if isDemo { factory = { @Sendable _, _, _ in DemoAiClient() } }
        // On-device stays on the device; the scripted UI-test settings keep the default chain.
        var chain: (@Sendable (AiProvider) async -> [AiProvider])?
        if let realBridge { chain = { @Sendable provider in await realBridge.providerChain(provider) } }
        let orchestrator = AiOrchestrator(http: http, settings: bridge, cache: cache, usage: usage,
                                          sha256: AIService.sha256, onDeviceClient: onDeviceClient,
                                          clientFactory: factory, providerChain: chain)
        self.orchestrator = orchestrator
        // "Use downloaded AI model" (off by default) moves every on-device feature to the downloaded model.
        let onDevice = realBridge.map {
            OnDeviceContext(ai: .shared, settings: $0, local: LocalModelAI.shared,
                            downloadedSwitch: { UserDefaults.standard.bool(forKey: PreferenceKeys.aiUseDownloadedModel) })
        }
        self.onDevice = onDevice
        let generator = AiPlaylistGenerator(orchestrator: orchestrator)
        playlistGenerator = generator
        lyricsTranslator = AILyricsTranslator(orchestrator: orchestrator, onDevice: onDevice.map(OnDeviceLyricsTranslator.live))
        playlist = AIPlaylistController(generator: generator, settings: settings, library: library, home: home,
                                        playback: playback, router: router, libraryEditor: libraryEditor,
                                        curator: onDevice.map(OnDevicePlaylistCurator.live),
                                        usesOnDeviceCurator: { AiProvider.fromString(settings.ai.provider) == .onDevice })
        let remote: [any SearchProviding] = [searchProviders[.spotify], searchProviders[.youtubeMusic]].compactMap { $0 }
        let librarySongs: @MainActor @Sendable () -> [Song] = { library.songs }
        self.librarySongs = librarySongs
        let mediaRouter = TaisMediaRouter(songs: librarySongs, remoteProviders: remote)
        chat = TaisChatModel(engine: TaisDjEngine(router: mediaRouter, orchestrator: orchestrator, onDevice: onDevice),
                             playback: playback)
    }

    /// Loads the on-device model for a sheet that is opening (fire and forget): nothing in UI tests or with a cloud
    /// assistant selected.
    func prewarm(_ feature: OnDeviceAI.Feature) {
        guard let onDevice, AiProvider.fromString(settings.ai.provider) == .onDevice else { return }
        if settings.ai.useDownloadedModel {
            // Loading the downloaded model (and, the first time, specialising it for the GPU) takes seconds.
            if feature == .chat || feature == .playlist { onDevice.local?.prewarm() }
            return
        }
        let songs = librarySongs
        Task.detached(priority: .utility) {
            var setup: OnDeviceAI.ChatSetup?
            if feature == .chat {
                setup = OnDeviceAI.ChatSetup(persona: await onDevice.persona(),
                                             temperature: await onDevice.temperature(.taizoChat), songs: songs)
            }
            await onDevice.ai.prewarm(feature, chat: setup)
        }
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
        case .onDevice:
            return settings.ai.useDownloadedModel ? ModelManager.isInstalled(ModelCatalog.llm) : OnDeviceModel.isAvailable
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
