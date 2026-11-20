import Foundation
import PixlLibrary
import PixlModel
import PixlNet

/// The switch and the door of the optional assistant jobs (docs/brain-spec.md, 9.4, stage 4 milestone 2). Thread-safe reads only
/// (UserDefaults, a lock-protected network flag), so the refresh's actors ask freely.
nonisolated enum BrainAssistGate {
    /// "Let Taizo help the engine" is on (off by default) AND the remote config does not switch it off.
    static func allowed() -> Bool {
        UserDefaults.standard.bool(forKey: PreferenceKeys.brainAssistHelpEnabled) && BrainRemoteFlags.assistAllowed()
    }

    /// The assistant's own door: the automatic route (the built-in key, a connection, the monthly budget left, no own-key override).
    static func routeIsOpen() -> Bool { ClaudeCloud.shared.route() == .claude }
}

/// What Ask Taizo's helpers need beyond the chat (docs/brain-spec.md, 9.3 and 9.4): the optional weekly jobs, the cache of their answers, and
/// the weekly note on First Listen. Built with the mixes, never at launch; no file is read and nothing is asked until the refresh or First
/// Listen needs it. The decisions are PixlLibrary's (`AssistantHelp`, `WeeklyNoteService`, `AssistBatch`, `WeeklyNote`); this connects them to
/// the cloud assistant, the library and the brain's stores.
@MainActor
final class BrainAssist {
    /// The app (set by `AppEnvironment.start`): the cloud assistant's client and usage log, and the library.
    var environment: @MainActor @Sendable () -> AppEnvironment? = { nil }

    let cache: AssistCache
    /// Nil when the brain has no DNA files (UI tests): there is nothing for the jobs to tag or name.
    let help: AssistantHelp?
    let firstListen: FirstListenNote
    private let mixes: BrainMixes
    private let engine: BrainEngine
    private let repository: BrainRepository
    private let parts: Stage2bParts
    private let yourSound: YourSoundReader
    private weak var brain: BrainService?
    private var backend: BrainAssistantEngine?

    init(directory: URL, brain: BrainService, mixes: BrainMixes, engine: BrainEngine, repository: BrainRepository, parts: Stage2bParts,
         yourSound: YourSoundReader) {
        self.brain = brain
        self.mixes = mixes
        self.engine = engine
        self.repository = repository
        self.parts = parts
        self.yourSound = yourSound
        let cache = AssistCache(file: directory.appendingPathComponent(AssistCache.fileName), modelId: ClaudeAPI.model,
                                allowed: { BrainAssistGate.allowed() })
        self.cache = cache
        // The weekly note asks through the assistant's own door and budget; it is not behind the batch switch (it is one call a week, only
        // when First Listen is opened). `ask` is filled in below, once `self` exists.
        let holder = AskHolder()
        let note = WeeklyNoteService(file: directory.appendingPathComponent(WeeklyNoteService.fileName),
                                     mayAsk: { BrainAssistGate.routeIsOpen() },
                                     ask: { system, prompt, maxTokens in await holder.ask?(system, prompt, maxTokens) })
        firstListen = FirstListenNote(service: note, parts: parts, yourSound: yourSound)
        let hostHolder = HostHolder()
        help = parts.dna.map { dna in AssistantHelp(
            host: AssistantHelp.Host(
                allowed: { BrainAssistGate.allowed() },
                mayAsk: { BrainAssistGate.routeIsOpen() },
                ask: { system, prompt, maxTokens in await holder.ask?(system, prompt, maxTokens) },
                listenerGenres: { await yourSound.load().genres.map(\.atlasId) },
                resolve: { items in await hostHolder.resolve?(items) ?? [] },
                trackOf: { videoId in await hostHolder.trackOf?(videoId) }),
            cache: cache, islands: parts.islands, atlas: parts.atlas,
            dna: dna) }
        holder.ask = { [weak self] system, prompt, maxTokens in await self?.complete(system: system, prompt: prompt, maxTokens: maxTokens) }
        hostHolder.resolve = { [weak self] items in await self?.resolve(items) ?? [] }
        hostHolder.trackOf = { [weak self] videoId in await self?.trackOf(videoId) }
    }

    /// Wires what the assistant's answers feed (each only while the switch is on): Your sound's island names and the assistant mixes' extra
    /// artists. Called once, off the main actor's critical path.
    func connect() {
        let cache = self.cache
        let yourSound = self.yourSound
        let mixes = self.mixes
        Task {
            await yourSound.setAssistedIslandName { id, names in await cache.islandName(id: id, genreNames: names) }
            await mixes.setAssistSuggestions { await cache.suggestedRows() }
        }
    }

    // MARK: The one cloud call

    /// One short answer from the cloud assistant under the monthly budget, or nil (not on the automatic route, a failure, a refusal).
    private func complete(system: String, prompt: String, maxTokens: Int) async -> String? {
        guard let env = environment() else { return nil }
        let ai = env.ai
        guard ai.currentRoute() == .claude, let client = ai.claudeClient() else { return nil }
        return try? await ClaudeCompletion.short(client: client, system: system, prompt: prompt, maxTokens: maxTokens,
                                                 onUsage: ai.recordClaudeUsage)
    }

    // MARK: Looking up a suggested song (the same lookup `resolve_tracks` makes)

    private func engineBackend() -> BrainAssistantEngine? {
        if let backend { return backend }
        let environment = self.environment
        let made = BrainAssistantEngine(
            mixes: mixes, engine: engine, repository: repository, parts: parts, yourSound: yourSound,
            host: TaizoAssistantHost(environment: environment), library: { await MainActor.run { environment()?.library.songs ?? [] } })
        backend = made
        return made
    }

    private func resolve(_ items: [(title: String, artist: String)]) async -> [AssistantLookup] {
        guard let backend = engineBackend() else { return [] }
        return await backend.resolve(items)
    }

    private func trackOf(_ videoId: String) -> EngineTrack? {
        brain?.track(songId: EngineTrack.songIdPrefix + videoId)
    }
}

/// Late-bound closures: the object that answers them needs `self`, which does not exist while the parts are being made.
private final class AskHolder: @unchecked Sendable {
    var ask: (@Sendable (_ system: String, _ prompt: String, _ maxTokens: Int) async -> String?)?
}

private final class HostHolder: @unchecked Sendable {
    var resolve: (@Sendable (_ items: [(title: String, artist: String)]) async -> [AssistantLookup])?
    var trackOf: (@Sendable (_ videoId: String) async -> EngineTrack?)?
}
