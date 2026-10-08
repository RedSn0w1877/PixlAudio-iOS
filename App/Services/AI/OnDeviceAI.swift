import Foundation
import FoundationModels
import NaturalLanguage
import PixlModel
import PixlNet

/// The app's on-device language-model sessions (Foundation Models), one owner for all of them (2026-10-07: the
/// on-device model is the default for every AI feature).
///
/// - **Chat** (Taizo): one multi-turn session, so Taizo remembers the conversation, with short instructions
///   (`TaizoPrompts`) and the `searchLibrary` tool. When the 4,096-token window fills up, a fresh session carries
///   the last two turns as text and the request is retried once.
/// - **Single requests** (intro lines, greetings, playlist picks and plans, lyric translation): a fresh session
///   each, so every request gets the whole window. Playlist and intro sessions can be prewarmed while a sheet opens.
/// - **Serialized per feature**: an actor alone doesn't stop a second request reaching a session while the first
///   awaits the model (reentrancy), and a session throws on concurrent requests. Each feature has its own queue, so a
///   chat reply never waits for a greeting. Waiting is cancellation-aware (timeouts and closing sheets).
///
/// Plain-text answers use the permissive-guardrails model (song titles and lyrics with explicit words); guided
/// output (`@Generable`, dynamic schemas) the standard one, which permissive mode doesn't cover.
actor OnDeviceAI {
    static let shared = OnDeviceAI()

    nonisolated enum Feature: Sendable, Hashable {
        case chat, intro, greeting, playlist, translation
    }

    /// What the chat session is built from.
    nonisolated struct ChatSetup: Sendable {
        var persona: String?
        var temperature: Double?
        var songs: @MainActor @Sendable () -> [Song]
    }

    // MARK: State

    private var busy: Set<Feature> = []
    private var waiters: [Feature: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)]] = [:]

    private var chatSession: LanguageModelSession?
    private var chatInstructions = ""
    private var chatTurns: [TaizoPrompts.Turn] = []
    private var warmIntro: LanguageModelSession?
    private var warmPlaylist: LanguageModelSession?

    // MARK: Prewarm

    /// Loads the model for a feature the user is about to use (a sheet opening): Apple's guidance is to prewarm only
    /// with at least a second to spare, which typing a prompt gives. Does nothing while the model can't answer.
    func prewarm(_ feature: Feature, chat: ChatSetup? = nil) {
        guard OnDeviceModel.isAvailable else { return }
        switch feature {
        case .chat:
            if let chat { session(for: chat).prewarm() }
            if warmIntro == nil {
                let session = Self.session(.permissive, TaizoPrompts.introInstructions)
                session.prewarm()
                warmIntro = session
            }
        case .playlist:
            if warmPlaylist == nil {
                let session = Self.session(.standard, OnDeviceCuration.instructions)
                session.prewarm()
                warmPlaylist = session
            }
        case .intro, .greeting, .translation:
            break
        }
    }

    // MARK: Chat

    /// Taizo's answer to `message`, remembering the conversation.
    func chat(_ message: String, setup: ChatSetup) async throws -> String {
        try Self.requireAvailable()
        try await acquire(.chat)
        defer { release(.chat) }
        let options = GenerationOptions(sampling: nil, temperature: setup.temperature, maximumResponseTokens: 400)
        do {
            let reply = try await Self.text(session(for: setup), message, options)
            remember(message, reply)
            return reply
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = OnDeviceModel.failure(for: error)
            guard failure == .tooLong else { throw failure }
        }
        // The window is full: a fresh session that carries the last two turns, once.
        let fresh = makeChatSession(setup, carrying: Array(chatTurns.suffix(2)))
        chatSession = fresh
        do {
            let reply = try await Self.text(fresh, message, options)
            remember(message, reply)
            return reply
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Even two turns don't fit (a very long message): start over without them next time.
            chatSession = nil
            chatTurns.removeAll()
            throw OnDeviceModel.failure(for: error)
        }
    }

    /// Keeps the last turns as text (only the last two are ever carried into a fresh session).
    private func remember(_ message: String, _ reply: String) {
        chatTurns.append(TaizoPrompts.Turn(user: message, reply: reply))
        if chatTurns.count > 8 { chatTurns.removeFirst(chatTurns.count - 8) }
    }

    /// Forgets the conversation (a new chat).
    func resetChat() {
        chatSession = nil
        chatTurns.removeAll()
    }

    private func session(for setup: ChatSetup) -> LanguageModelSession {
        let instructions = TaizoPrompts.chatInstructions(persona: setup.persona)
        if let chatSession, instructions == chatInstructions { return chatSession }
        // The persona changed in Settings: same conversation, new instructions.
        let session = makeChatSession(setup, carrying: Array(chatTurns.suffix(2)))
        chatSession = session
        return session
    }

    private func makeChatSession(_ setup: ChatSetup, carrying turns: [TaizoPrompts.Turn]) -> LanguageModelSession {
        let instructions = TaizoPrompts.chatInstructions(persona: setup.persona)
        chatInstructions = instructions
        return LanguageModelSession(model: OnDeviceModel.permissive, tools: [LibraryLookupTool(songs: setup.songs)],
                                    instructions: TaizoPrompts.carryOver(instructions, turns: turns))
    }

    // MARK: Single requests

    /// The one-line intro above Taizo's queue card.
    func introLine(request: String, count: Int) async throws -> String? {
        try Self.requireAvailable()
        try await acquire(.intro)
        defer { release(.intro) }
        let session = warmIntro ?? Self.session(.permissive, TaizoPrompts.introInstructions)
        warmIntro = nil
        let options = GenerationOptions(sampling: .greedy, temperature: nil, maximumResponseTokens: 40)
        let reply = try await Self.mapped { try await Self.text(session, TaizoPrompts.introPrompt(request: request, count: count), options) }
        return OnDeviceText.singleLine(reply, limit: 120)
    }

    /// Home's greeting headline or its longer insight.
    func greeting(instructions: String, prompt: String, temperature: Double?, maxTokens: Int) async throws -> String {
        try Self.requireAvailable()
        try await acquire(.greeting)
        defer { release(.greeting) }
        let session = Self.session(.permissive, instructions)
        let options = GenerationOptions(sampling: nil, temperature: temperature, maximumResponseTokens: maxTokens)
        return try await Self.mapped { try await Self.text(session, prompt, options) }
    }

    /// Plain text from fresh permissive-guardrails sessions (lyric translation chunks, the playlist fallback that
    /// asks for numbers as text).
    func text(_ feature: Feature, instructions: String, prompt: String, maxTokens: Int,
              temperature: Double? = nil) async throws -> String {
        try Self.requireAvailable()
        try await acquire(feature)
        defer { release(feature) }
        let session = Self.session(.permissive, instructions)
        let options = GenerationOptions(sampling: temperature == nil ? .greedy : nil, temperature: temperature,
                                        maximumResponseTokens: maxTokens)
        return try await Self.mapped { try await Self.text(session, prompt, options) }
    }

    /// Song numbers (1…`poolSize`) from a numbered list, `minimum`…`maximum` of them, through a dynamic schema
    /// (`{"picks": [Int]}`, each in range): the model can only answer with valid numbers.
    func pickNumbers(prompt: String, poolSize: Int, minimum: Int, maximum: Int, temperature: Double?) async throws -> [Int] {
        try Self.requireAvailable()
        try await acquire(.playlist)
        defer { release(.playlist) }
        let session = warmPlaylist ?? Self.session(.standard, OnDeviceCuration.instructions)
        warmPlaylist = nil
        let upper = max(poolSize, 1)
        let low = min(max(minimum, 0), upper)
        let high = min(max(maximum, max(low, 1)), upper)
        let item = DynamicGenerationSchema(type: Int.self, guides: [.range(1...upper)])
        let picks = DynamicGenerationSchema(arrayOf: item, minimumElements: low, maximumElements: high)
        let root = DynamicGenerationSchema(name: "Picks", properties: [
            DynamicGenerationSchema.Property(name: "picks", schema: picks),
        ])
        let options = GenerationOptions(sampling: nil, temperature: temperature,
                                        maximumResponseTokens: OnDeviceCuration.outputReserve(maximum: high))
        return try await Self.mapped {
            let schema = try GenerationSchema(root: root, dependencies: [])
            let response = try await session.respond(to: prompt, schema: schema, options: options)
            return OnDeviceCuration.numbers(inJSON: response.content.jsonString, key: "picks")
        }
    }

    /// A long playlist's plan: the genres and artists (each from the library's own top values), the mood words, an
    /// energy level and whether to lean on familiar songs. The app fills the playlist from it.
    func plan(prompt: String, genres: [String], artists: [String]) async throws -> OnDeviceCuration.Plan {
        try Self.requireAvailable()
        try await acquire(.playlist)
        defer { release(.playlist) }
        warmPlaylist = nil
        let session = Self.session(.standard, OnDeviceCuration.planInstructions)
        func list(_ values: [String], max: Int) -> DynamicGenerationSchema {
            let item = values.isEmpty ? DynamicGenerationSchema(type: String.self)
                : DynamicGenerationSchema(type: String.self, guides: [.anyOf(values)])
            return DynamicGenerationSchema(arrayOf: item, minimumElements: 0, maximumElements: max)
        }
        let root = DynamicGenerationSchema(name: "PlaylistPlan", properties: [
            DynamicGenerationSchema.Property(name: "genres", schema: list(genres, max: 3)),
            DynamicGenerationSchema.Property(name: "artists", schema: list(artists, max: 5)),
            DynamicGenerationSchema.Property(name: "moods", schema: list([], max: 3)),
            DynamicGenerationSchema.Property(name: "energy", schema: DynamicGenerationSchema(type: Int.self, guides: [.range(1...5)])),
            DynamicGenerationSchema.Property(name: "familiar", schema: DynamicGenerationSchema(type: Bool.self)),
        ])
        let options = GenerationOptions(sampling: .greedy, temperature: nil, maximumResponseTokens: 200)
        return try await Self.mapped {
            let schema = try GenerationSchema(root: root, dependencies: [])
            let response = try await session.respond(to: prompt, schema: schema, options: options)
            return OnDeviceCuration.Plan(json: response.content.jsonString)
        }
    }

    // MARK: Helpers

    private nonisolated enum ModelKind { case standard, permissive }

    private static func session(_ kind: ModelKind, _ instructions: String) -> LanguageModelSession {
        LanguageModelSession(model: kind == .permissive ? OnDeviceModel.permissive : OnDeviceModel.standard,
                             instructions: instructions)
    }

    private static func text(_ session: LanguageModelSession, _ prompt: String, _ options: GenerationOptions) async throws -> String {
        let response = try await session.respond(to: prompt, options: options)
        return OnDeviceModel.cleanReply(response.content)
    }

    /// Runs `work`, turning any model error into an `OnDeviceFailure` (cancellation passes through).
    private static func mapped<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OnDeviceModel.failure(for: error)
        }
    }

    private static func requireAvailable() throws {
        if let unavailable = OnDeviceModel.unavailability { throw unavailable }
    }

    // MARK: Per-feature queue

    private func acquire(_ feature: Feature) async throws {
        guard busy.contains(feature) else {
            busy.insert(feature)
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[feature, default: []].append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id, feature: feature) }
        }
    }

    private func cancelWaiter(_ id: UUID, feature: Feature) {
        guard var queue = waiters[feature], let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let waiter = queue.remove(at: index)
        waiters[feature] = queue
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Hands the feature to the next waiter (it stays busy), or frees it.
    private func release(_ feature: Feature) {
        if var queue = waiters[feature], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[feature] = queue
            next.continuation.resume()
        } else {
            busy.remove(feature)
        }
    }
}

/// Taizo's `searchLibrary` tool: what the user's library holds for an artist, album, genre or title
/// (`LibraryLookup`), so answers about their own music are grounded rather than guessed.
nonisolated struct LibraryLookupTool: Tool {
    let name = "searchLibrary"
    let description = "Looks up the user's music library by artist, album, genre or song title."
    let songs: @MainActor @Sendable () -> [Song]

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "An artist, album, genre or song title. Empty for an overview of the library.")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        let library = await songs()
        return await Self.lookup(arguments.query, in: library)
    }

    /// Off the main actor: a large library takes a moment to group.
    @concurrent
    static func lookup(_ query: String, in songs: [Song]) async -> String {
        LibraryLookup.summary(query: query, songs: songs)
    }
}

/// What the AI features need to run on the device: the sessions, and the settings that pick the provider and tune
/// the model (the persona and the temperature, the only knob Settings shows for on-device).
///
/// Local AI phase 2 (2026-10-07): with Settings › AI features › "Use downloaded AI model" on, every on-device
/// feature runs on the downloaded model (`local`) instead of the system's; the features themselves don't change.
nonisolated struct OnDeviceContext: Sendable {
    let ai: OnDeviceAI
    let settings: any AiSettingsProviding
    /// The downloaded model (nil: the system model only — unit tests).
    var local: LocalModelAI? = nil
    /// The "Use downloaded AI model" switch (a thread-safe settings read).
    var downloadedSwitch: @Sendable () -> Bool = { false }

    /// The on-device model is the selected provider (the system's or the downloaded one).
    func isActive() async -> Bool {
        await settings.selectedProvider() == .onDevice
    }

    /// The downloaded model answers instead of the system's.
    func usesDownloadedModel() -> Bool {
        local != nil && downloadedSwitch()
    }

    /// Why the model that would answer can't (nil when it can).
    func unavailability() -> OnDeviceFailure? {
        if usesDownloadedModel(), let local { return local.unavailability() }
        return OnDeviceModel.unavailability
    }

    /// The prompt budget of the model that would answer.
    var contextSize: Int {
        if usesDownloadedModel(), let local { return local.contextSize }
        return OnDeviceModel.contextSize
    }

    /// The user's persona for the on-device provider (nil: the default).
    func persona() async -> String? {
        let persona = await settings.systemPrompt(for: .onDevice).trimmingCharacters(in: .whitespacesAndNewlines)
        return persona.isEmpty ? nil : persona
    }

    /// Android's per-type temperature table over the user's temperature setting.
    func temperature(_ type: AiSystemPromptType) async -> Double {
        let setting = await settings.generationParameters().temperature
        return Double(AiPromptEngine.effectiveTemperature(type: type, setting: setting))
    }
}

nonisolated extension OnDeviceContext: TaizoOnDevice {
    func chat(_ message: String, songs: @escaping @MainActor @Sendable () -> [Song]) async throws -> String {
        if usesDownloadedModel(), let local {
            return try await local.chat(message, persona: await persona(), temperature: await temperature(.taizoChat),
                                        songs: songs)
        }
        let setup = OnDeviceAI.ChatSetup(persona: await persona(), temperature: await temperature(.taizoChat), songs: songs)
        return try await ai.chat(message, setup: setup)
    }

    func introLine(request: String, count: Int) async throws -> String? {
        if usesDownloadedModel(), let local { return try await local.introLine(request: request, count: count) }
        return try await ai.introLine(request: request, count: count)
    }

    /// The downloaded model computes every token on the phone and may load first: more time than the system's.
    var chatTimeoutSeconds: Double { usesDownloadedModel() ? 90 : TaisDjEngine.chatTimeoutSeconds }
    var introTimeoutSeconds: Double { usesDownloadedModel() ? 30 : TaisDjEngine.onDeviceIntroTimeoutSeconds }
}

// MARK: - Live wiring

extension OnDevicePlaylistCurator {
    /// The curator on the shared sessions: the system model's, or the downloaded model's when its switch is on
    /// (decided per call, so the switch applies to the next request).
    static func live(_ context: OnDeviceContext) -> OnDevicePlaylistCurator {
        let ai = context.ai
        let downloaded: @Sendable () -> LocalModelAI? = { context.usesDownloadedModel() ? context.local : nil }
        return OnDevicePlaylistCurator(model: Model(
            unavailability: { context.unavailability() },
            contextSize: { context.contextSize },
            tokens: { text in
                if let local = downloaded() { return await local.tokenCount(text) }
                return await OnDeviceModel.tokenCount(text)
            },
            temperature: { await context.temperature($0) },
            pick: { prompt, poolSize, minimum, maximum, temperature in
                if let local = downloaded() {
                    return try await local.pickNumbers(prompt: prompt, poolSize: poolSize, minimum: minimum,
                                                       maximum: maximum, temperature: temperature)
                }
                return try await ai.pickNumbers(prompt: prompt, poolSize: poolSize, minimum: minimum, maximum: maximum,
                                                temperature: temperature)
            },
            pickAsText: { prompt in
                if let local = downloaded() {
                    return try await local.text(instructions: OnDeviceCuration.instructions, prompt: prompt, maxTokens: 400)
                }
                return try await ai.text(.playlist, instructions: OnDeviceCuration.instructions, prompt: prompt, maxTokens: 400)
            },
            plan: { prompt, genres, artists in
                if let local = downloaded() { return try await local.plan(prompt: prompt, genres: genres, artists: artists) }
                return try await ai.plan(prompt: prompt, genres: genres, artists: artists)
            }))
    }
}

extension OnDeviceLyricsTranslator {
    /// The translator on the shared sessions (or the downloaded model), into the device language.
    static func live(_ context: OnDeviceContext) -> OnDeviceLyricsTranslator {
        let ai = context.ai
        return OnDeviceLyricsTranslator(
            isActive: { await context.isActive() },
            unavailability: { context.unavailability() },
            contextSize: { context.contextSize },
            respond: { instructions, prompt, maxTokens in
                if context.usesDownloadedModel(), let local = context.local {
                    return try await local.text(instructions: instructions, prompt: prompt, maxTokens: maxTokens)
                }
                return try await ai.text(.translation, instructions: instructions, prompt: prompt, maxTokens: maxTokens)
            },
            dominantLanguage: { text in
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(text)
                return recognizer.dominantLanguage.map { OnDeviceLyricsTranslation.baseCode($0.rawValue) }
            },
            targetLanguageCode: OnDeviceLyricsTranslation.baseCode(Locale.current.language.languageCode?.identifier ?? "en"))
    }
}
