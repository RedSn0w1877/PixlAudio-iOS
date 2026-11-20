import Foundation
import Observation
import PixlLibrary
import PixlModel
import PixlNet

/// The state of a confirmation card (a large or destructive tool call waiting for a tap).
nonisolated enum TaizoConfirmState: Sendable, Equatable {
    case pending, approved, declined
}

/// One turn of Ask Taizo (Android `TaisChatMessage`, grown for the cloud assistant): the prompt, then a result or the
/// in-flight state.
nonisolated enum TaisChatMessage: Identifiable, Sendable, Equatable {
    case user(id: Int, text: String)
    case thinking(id: Int, prompt: String)
    case djReply(id: Int, prompt: String, result: DjRouteResult, aiIntro: String?)
    /// A conversational answer (music trivia, recommendations) or an error.
    case textReply(id: Int, text: String, isError: Bool)
    /// Claude's answer, streaming in: the text so far, the pages it cites, what it is doing right now.
    case assistant(id: Int, text: String, sources: [ClaudeSource], activity: String?, isStreaming: Bool)
    /// "Create “Road Trip” with 60 songs?" — Confirm / Cancel.
    case confirm(id: Int, question: String, state: TaizoConfirmState)
    /// A one-line note (offline, the month's cloud limit, a lost connection).
    case note(id: Int, text: String)
    /// A mix `build_mix` made (docs/brain-spec.md, 9.3): "Late drive · 30 songs", Play, Save and the chips under it. A chip is a delta on the
    /// stored request applied on the phone, with no model call. Not saved with the chat.
    case mix(id: Int, card: MixCard, state: MixCardState)
    /// The one-tap "Less trap" that ends an explanation of the listener's taste or of one pick.
    case less(id: Int, offer: LessOffer)

    var id: Int {
        switch self {
        case .user(let id, _), .thinking(let id, _), .djReply(let id, _, _, _), .textReply(let id, _, _),
             .assistant(let id, _, _, _, _), .confirm(let id, _, _), .note(let id, _), .mix(let id, _, _), .less(let id, _): id
        }
    }
}

/// Ask Taizo's state (Android `TaisChatViewModel`, upgraded 2026-10-23). Held by `AIService`, so the conversation
/// survives closing and reopening the sheet.
///
/// - Online (the router says Claude): every prompt goes to Claude Sonnet 5.5 with the listening context, the "now"
///   block, the tools and web search / fetch; the answer streams in, sources are listed, large actions wait for a tap.
///   The conversation is saved (the newest five, `TaizoConversationStore`) and "New chat" starts another.
/// - Offline, over the month's limit or without a built-in key: TAIS Engine 3 as before (`TaisDjEngine`: the intent
///   parser and media router, the on-device model with the library lookup) — tools limited to what the phone can do,
///   no web. Those turns are added to the conversation as plain text, so Claude knows them later.
/// - A Claude call that fails before anything happened falls back to the on-device answer for that prompt.
@Observable
final class TaisChatModel {
    private(set) var messages: [TaisChatMessage] = []
    var inputText = ""
    /// A prompt is in flight (its thinking row is showing): the header orb stirs and says "Thinking…".
    var isThinking: Bool {
        messages.contains { message in
            switch message {
            case .thinking: true
            case .assistant(_, _, _, _, let streaming): streaming
            default: false
            }
        }
    }
    /// A catalogue import is running (rows and bulk buttons are disabled meanwhile).
    private(set) var isResolvingOnlineTracks = false
    /// The last route used: the header says "Claude" or "On this iPhone".
    private(set) var lastRoute: AIRoute?
    /// The saved conversations (newest first), for the header's menu.
    private(set) var recentConversations: [TaizoConversationRecord] = []
    /// The conversation on screen (nil: a new one, created with the first cloud prompt).
    private(set) var conversation: TaizoConversationRecord?

    @ObservationIgnored private var nextId = 0
    @ObservationIgnored private let engine: TaisDjEngine
    @ObservationIgnored private let playback: PlaybackStore
    @ObservationIgnored private let assistant: TaizoCloudAssistant?
    /// One toolbox per conversation (its catalogue cache keeps the ids of earlier searches usable).
    @ObservationIgnored private var toolbox: TaizoToolbox?
    @ObservationIgnored private var confirmations: [Int: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var didRestore = false
    /// Streamed text not yet shown (flushed at most every 50 ms, so a fast stream doesn't re-render per token).
    @ObservationIgnored private var pendingText: [Int: String] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// The turn in flight. One at a time: two turns would share the toolbox (and its taste-change guard) and the
    /// conversation record, and drive playback against each other. "New chat" and opening another chat cancel it.
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    /// The Claude reply that is streaming right now: its full raw text so far and the conversation's record of what tools returned, so what the
    /// listener reads while it streams is checked like the final reply (a name no tool returned is never shown, even for a moment).
    @ObservationIgnored private var streamingReply: (id: Int, progress: ClaudeTurnProgress, grounding: TaizoGrounding)?
    /// What an on-device or plain-provider chat knows (the listener's own words), when there is no cloud toolbox.
    @ObservationIgnored private let deviceGrounding = TaizoGrounding()

    /// Android `TAIZO_SUGGESTIONS` (sent as "Play some <x> songs"; the chips are `TaizoSuggestion.moods`).
    static let suggestions = ["Chill acoustic", "Energetic rock", "Sad indie", "Party anthems", "Focus beats", "Feel-good pop"]

    init(engine: TaisDjEngine, playback: PlaybackStore, assistant: TaizoCloudAssistant? = nil) {
        self.engine = engine
        self.playback = playback
        self.assistant = assistant
    }

    private func makeId() -> Int {
        nextId += 1
        return nextId
    }

    /// Whether the next prompt goes to Claude (the header's subtitle; checked again when a prompt is sent).
    var routesToCloud: Bool { assistant?.route() == .claude }

    /// `sendPrompt`: appends the prompt and a thinking row, then replaces the thinking row with Taizo's turn.
    func sendPrompt() {
        guard !isThinking, let pending = enqueue() else { return }
        turnTask = Task { [weak self] in await self?.respond(to: pending) }
    }

    /// Sends a prompt as if typed (suggestion chips).
    func send(_ prompt: String) {
        inputText = prompt
        sendPrompt()
    }

    /// Sends prompts one after another, each waiting for Taizo's turn (the UI tests' scripted conversation).
    func runScript(_ prompts: [String]) async {
        for prompt in prompts {
            inputText = prompt
            guard let pending = enqueue() else { continue }
            await respond(to: pending)
        }
    }

    private func enqueue() -> (prompt: String, thinkingId: Int)? {
        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }
        // A card still waiting for a tap is answered "no" by a new prompt.
        resolveAllConfirmations(false)
        let userId = makeId()
        let thinkingId = makeId()
        messages.append(.user(id: userId, text: prompt))
        messages.append(.thinking(id: thinkingId, prompt: prompt))
        inputText = ""
        return (prompt, thinkingId)
    }

    private func respond(to pending: (prompt: String, thinkingId: Int)) async {
        if let assistant {
            let route = assistant.route()
            lastRoute = route
            if route == .claude, let client = assistant.client() {
                if await respondWithClaude(pending, assistant: assistant, client: client) { return }
            } else if let note = AIRouter.note(route), !messages.contains(where: { if case .note(_, note) = $0 { true } else { false } }) {
                insert(.note(id: makeId(), text: note), before: pending.thinkingId)
            }
        }
        await respondOnDevice(to: pending)
    }

    // MARK: On the device (TAIS Engine 3)

    private func respondOnDevice(to pending: (prompt: String, thinkingId: Int)) async {
        let rawTurn = await engine.respond(pending.prompt)
        // The chat was cleared or switched meanwhile: this answer belongs to a conversation that is gone.
        guard !Task.isCancelled else { return }
        let grounding = toolbox?.music.grounding ?? deviceGrounding
        grounding.noteUser(pending.prompt)
        let turn = await checked(rawTurn, grounding: grounding)
        guard !Task.isCancelled else { return }
        // "Start a station from X" is read by rules, so it works with no connection and no model: X is looked up in the library and the atlas.
        if case .station(let name) = turn {
            let started = await startStation(named: name)
            guard !Task.isCancelled else { return }
            let text = started ? BrainStrings.taizoStationStarted(name) : BrainStrings.taizoStationNotFound(name)
            let resolved: TaizoTurn = started ? .conversation(text) : .error(text)
            finish(thinkingId: pending.thinkingId, prompt: pending.prompt, turn: resolved)
            await rememberOnDeviceTurn(prompt: pending.prompt, turn: resolved, intro: nil)
            return
        }
        let replyId = finish(thinkingId: pending.thinkingId, prompt: pending.prompt, turn: turn)
        // On-device, the card is already up; its intro line follows when the model has written it.
        var intro: String?
        if case .media(_, let result, nil) = turn, let deferred = await engine.deferredIntro(prompt: pending.prompt, result: result),
           let line = grounding.introLine(deferred) {
            setIntro(id: replyId, text: line)
            intro = line
        }
        await rememberOnDeviceTurn(prompt: pending.prompt, turn: turn, intro: intro)
    }

    /// An answer from the phone's model or a plain provider, checked like a Claude reply (docs/brain-spec.md, 1 principle 9): a name that is
    /// not the listener's own words and not a title, album or artist of their library is replaced, and an intro line that names one is
    /// dropped. Names only: the numbers the phone model read through its own library lookup are not visible here.
    private func checked(_ turn: TaizoTurn, grounding: TaizoGrounding) async -> TaizoTurn {
        switch turn {
        case .conversation(let text):
            let library = engine.router.songs()
            let shown = await Task.detached(priority: .userInitiated) {
                grounding.shown(text, numbers: false) { names in TaizoGrounding.libraryNames(among: names, in: library) }
            }.value
            return .conversation(shown)
        case .media(let intent, let result, let intro):
            return .media(intent, result, aiIntro: intro.flatMap { grounding.introLine($0) })
        case .error, .station:
            return turn
        }
    }

    /// A station from a sentence (`StationSentence`): false when there is no music engine to ask or the name is none of the listener's.
    private func startStation(named name: String) async -> Bool {
        guard let assistant else { return false }
        let tools = toolbox ?? assistant.toolbox()
        toolbox = tools
        return await tools.music.startStation(named: name, environment: tools.environment)
    }

    /// Replaces the thinking row with Taizo's turn; returns the reply's id.
    @discardableResult
    private func finish(thinkingId: Int, prompt: String, turn: TaizoTurn) -> Int {
        let id = makeId()
        let reply: TaisChatMessage
        switch turn {
        case .media(_, let result, let intro): reply = .djReply(id: id, prompt: prompt, result: result, aiIntro: intro)
        case .conversation(let text): reply = .textReply(id: id, text: text, isError: false)
        case .error(let message): reply = .textReply(id: id, text: message, isError: true)
        case .station(let name): reply = .textReply(id: id, text: BrainStrings.taizoStationStarted(name), isError: false)
        }
        replace(thinkingId, with: reply)
        return id
    }

    /// Fills in the intro line of a queue card that was shown without one.
    func setIntro(id: Int, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              case .djReply(let replyId, let prompt, let result, nil) = messages[index] else { return }
        messages[index] = .djReply(id: replyId, prompt: prompt, result: result, aiIntro: text)
    }

    /// An on-device exchange joins the saved conversation as plain text (append-only, so a later Claude turn sees it).
    private func rememberOnDeviceTurn(prompt: String, turn: TaizoTurn, intro: String?) async {
        guard let assistant, var record = conversation else { return }
        let reply: String
        switch turn {
        case .media(_, let result, _): reply = (intro.map { $0 + " " } ?? "") + "(Found \(result.count) songs on this iPhone.)"
        case .conversation(let text): reply = text
        case .error(let message): reply = message
        case .station(let name): reply = BrainStrings.taizoStationStarted(name)
        }
        record.messages = ClaudeConversation.appendingUserText(record.messages, prompt)
        record.messages.append(ClaudeJSON.assistant([ClaudeJSON.object([("type", .string("text")), ("text", .string(reply))])]))
        record.transcript.append(TaizoTranscriptEntry(role: .user, text: prompt))
        record.transcript.append(TaizoTranscriptEntry(role: .assistant, text: reply))
        record.updatedAt = currentTimeMillis()
        await save(record, store: assistant.store)
    }

    // MARK: Claude

    /// One prompt with Claude. Returns false when nothing happened and the on-device answer should run instead.
    private func respondWithClaude(_ pending: (prompt: String, thinkingId: Int), assistant: TaizoCloudAssistant,
                                   client: any ClaudeMessaging) async -> Bool {
        let replyId = makeId()
        replace(pending.thinkingId, with: .assistant(id: replyId, text: "", sources: [], activity: nil, isStreaming: true))
        var record: TaizoConversationRecord
        if let conversation {
            record = conversation
        } else {
            let now = currentTimeMillis()
            record = TaizoConversationRecord(id: UUID().uuidString, title: TaizoConversationRecord.title(from: pending.prompt),
                                             createdAt: now, context: await assistant.context())
            toolbox = nil
        }
        let now = await assistant.now(record.lyricsSongKey)
        let history = ClaudeConversation.appendingUserText(record.messages,
                                                           TaizoAssistant.userMessage(now: now.context, text: pending.prompt))
        let tools = toolbox ?? assistant.toolbox()
        toolbox = tools
        // The user's own words for this turn: the only thing that may justify a taste change (`TasteChangeGuard`).
        tools.turn.begin(userMessage: pending.prompt)
        defer { tools.turn.end() }
        // The grounding rule (docs/brain-spec.md, 1 principle 9, 9.4): what the model is shown, what earlier turns of this chat returned and
        // what the listener says are things the reply may say back; a name or a number about the listener nothing returned is not.
        let grounding = tools.music.grounding
        if !grounding.isSeeded { grounding.noteHistory(record.messages) }
        grounding.noteContext(record.context)
        grounding.noteContext(now.context.render())
        grounding.noteUser(pending.prompt)
        await tools.music.beginTurn()
        let progress = ClaudeTurnProgress()
        streamingReply = (replyId, progress, grounding)
        defer { streamingReply = nil }
        let loop = ClaudeToolLoop(
            client: client, system: record.system, tools: tools, serverTools: TaizoAssistant.serverTools,
            effort: .medium, stream: true,
            confirm: { [weak self] question in await self?.askConfirmation(question) ?? false },
            onEvent: { [weak self] event in await self?.handle(event, replyId: replyId, progress: progress) },
            onUsage: assistant.onUsage)
        do {
            let result = try await loop.run(history: ClaudeConversation.forRequest(history))
            flushPendingText()
            // Cleared or switched while the loop finished: don't write the old chat back over the new one.
            if Task.isCancelled { return true }
            switch result.outcome {
            case .refused:
                let text = "I can't help with that one — ask me anything else about music."
                setAssistant(replyId, text: text, sources: [], streaming: false)
                record.transcript.append(TaizoTranscriptEntry(role: .user, text: pending.prompt))
                record.transcript.append(TaizoTranscriptEntry(role: .assistant, text: text))
            case .finished, .truncated, .stepLimit:
                // What a web search or fetch returned in this turn is something the model read, not something it invented.
                grounding.noteServerResults(result.appended)
                var text = Self.groundedReply(result.text.trimmingCharacters(in: .whitespacesAndNewlines), grounding)
                if text.isEmpty {
                    text = result.outcome == .finished ? "Done." : "That got too long for one answer — try asking for less at once."
                }
                setAssistant(replyId, text: text, sources: result.sources, streaming: false)
                await showCards(after: replyId, prompt: pending.prompt, tools: tools)
                record.messages = history + result.appended
                record.lyricsSongKey = now.lyricsSongKey
                record.transcript.append(TaizoTranscriptEntry(role: .user, text: pending.prompt))
                record.transcript.append(TaizoTranscriptEntry(role: .assistant, text: text, sources: result.sources))
            }
            record.updatedAt = currentTimeMillis()
            conversation = record
            await save(record, store: assistant.store)
            return true
        } catch is CancellationError {
            flushPendingText()
            setAssistant(replyId, text: Self.groundedPartial(progress.text, tools.music.grounding) ?? "Stopped.", sources: [], streaming: false)
            return true
        } catch {
            flushPendingText()
            if Task.isCancelled { return true }
            await assistant.onFallback("assistant: \(error)")
            if progress.ranTool || !progress.text.isEmpty {
                // Something already happened (text shown, a tool ran): keep it rather than answer twice.
                setAssistant(replyId, text: Self.groundedPartial(progress.text, tools.music.grounding) ?? "Done so far.", sources: [], streaming: false)
                insert(.note(id: makeId(), text: "The connection dropped, so that answer may be incomplete."), after: replyId)
                return true
            }
            // Nothing happened yet: this phone's model answers the prompt instead.
            let thinkingId = makeId()
            replace(replyId, with: .thinking(id: thinkingId, prompt: pending.prompt))
            insert(.note(id: makeId(), text: "\(ClaudeError.unavailableMessage) — this iPhone's AI is answering."), before: thinkingId)
            await respondOnDevice(to: (pending.prompt, thinkingId))
            return true
        }
    }

    private func handle(_ event: ClaudeLoopEvent, replyId: Int, progress: ClaudeTurnProgress) {
        switch event {
        case .requestStarted:
            flushPendingText()
            progress.turnStart = progress.text
        case .turnDiscarded:
            pendingText[replyId] = nil
            progress.text = progress.turnStart
            setAssistant(replyId, text: streamingReply?.grounding.streaming(progress.text) ?? TaizoMusicStrings.withoutMarks(progress.text), sources: [],
                         streaming: true)
        case .stream(.text(let piece)):
            progress.text += piece
            pendingText[replyId, default: ""] += piece
            scheduleFlush(replyId)
        case .stream(.toolStarted(let name, let server)):
            setActivity(replyId, Self.activity(for: name, server: server))
        case .stream(.serverToolResult):
            break
        case .toolRunning(let name):
            progress.ranTool = true
            setActivity(replyId, Self.activity(for: name, server: false))
        case .toolFinished:
            setActivity(replyId, nil)
        }
    }

    /// What Taizo is doing, in a few words.
    static func activity(for tool: String, server: Bool) -> String {
        if server { return tool == ClaudeServerTool.webFetch.rawValue ? "Reading a page…" : "Searching the web…" }
        switch TaizoTool(rawValue: tool) {
        case .searchLibrary?: return "Looking through your library…"
        case .searchSpotifyCatalog?: return "Searching Spotify…"
        case .playSongs?: return "Starting the music…"
        case .addToQueue?: return "Adding to your queue…"
        case .playbackControl?: return "On it…"
        case .createPlaylist?: return "Creating the playlist…"
        case .addToPlaylist?: return "Adding to the playlist…"
        case .getListeningInsights?: return "Reading your listening stats…"
        case .getLyrics?: return "Getting the lyrics…"
        case .startSing?: return "Getting Sing ready…"
        case .likeSong?: return "Saving your like…"
        case .getTasteProfile?: return "Reading your taste…"
        case .getLibraryOverview?: return "Looking at your library…"
        case .adjustTaste?: return "Updating your taste…"
        case .listTasteAdjustments?: return "Checking your taste changes…"
        case .removeTasteAdjustment?: return "Undoing a taste change…"
        case .resolveTracks?, .recommend?, .buildMix?, .startStation?, .steerSession?, .explainTrack?, .explainTaste?, .lookupGenre?,
             .similarArtists?, .newReleases?:
            return TaizoMusicStrings.activity(for: TaizoTool(rawValue: tool) ?? .recommend) ?? "Working on it…"
        case nil: return "Working on it…"
        }
    }

    // MARK: The grounding rule

    /// The reply as the listener reads it (docs/brain-spec.md, 1 principle 9, 9.4): a track, album or artist that no tool returned in this
    /// chat (and the listener did not say) is replaced, a sentence with a number about the listener that no tool returned is left out, and
    /// the marks the model put around names are taken off. The saved history keeps what the model wrote; only what is shown is cleaned.
    nonisolated static func groundedReply(_ raw: String, _ grounding: TaizoGrounding) -> String {
        if raw.isEmpty { return raw }
        // When every sentence is left out a fixed sentence says so: the raw text is never shown in its place.
        return grounding.shown(raw)
    }

    /// The text of a reply that was cut short (stopped, or the connection dropped): its finished part, checked, or nil when there is none.
    nonisolated static func groundedPartial(_ raw: String, _ grounding: TaizoGrounding) -> String? {
        let finished = TaizoGrounding.holdBack(raw)
        if finished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return grounding.shown(finished)
    }

    // MARK: Streaming display

    private func scheduleFlush(_ replyId: Int) {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            self?.flushPendingText()
        }
    }

    private func flushPendingText() {
        flushTask?.cancel()
        flushTask = nil
        for (id, piece) in pendingText where !piece.isEmpty {
            guard let index = messages.firstIndex(where: { $0.id == id }),
                  case .assistant(_, let text, let sources, _, let streaming) = messages[index] else { continue }
            // Text arriving clears the activity line: the answer is being written. What is shown is checked like the final reply (an unclosed
            // mark, the word being typed and a trailing run of capitalised words are held back; the marks are never shown).
            let shown: String
            if let live = streamingReply, live.id == id {
                shown = live.grounding.streaming(live.progress.text)
            } else {
                shown = TaizoMusicStrings.withoutMarks(text + piece)
            }
            messages[index] = .assistant(id: id, text: shown, sources: sources, activity: nil, isStreaming: streaming)
        }
        pendingText.removeAll()
    }

    private func setAssistant(_ id: Int, text: String, sources: [ClaudeSource], streaming: Bool) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index] = .assistant(id: id, text: text, sources: sources, activity: nil, isStreaming: streaming)
    }

    private func setActivity(_ id: Int, _ activity: String?) {
        flushPendingText()
        guard let index = messages.firstIndex(where: { $0.id == id }),
              case .assistant(_, let text, let sources, let current, let streaming) = messages[index], current != activity else { return }
        messages[index] = .assistant(id: id, text: text, sources: sources, activity: activity, isStreaming: streaming)
    }

    // MARK: Cards under the answer (docs/brain-spec.md, 9.3): nothing below calls a model

    /// The mixes `build_mix` made in this turn get their card under the answer (read from what the engine kept, never from the model's text),
    /// and an explanation of the listener's taste gets its one-tap "Less X" when the listener's own words named it.
    private func showCards(after replyId: Int, prompt: String, tools: TaizoToolbox) async {
        var anchor = replyId
        for card in await tools.music.takeNewMixCards() {
            let id = makeId()
            insert(.mix(id: id, card: card, state: MixCardState()), after: anchor)
            anchor = id
        }
        if let offer = LessOffer.offer(userText: prompt, named: await tools.music.namedThisTurn()) {
            insert(.less(id: makeId(), offer: offer), after: anchor)
        }
    }

    private func mixCard(_ id: Int) -> (card: MixCard, state: MixCardState)? {
        guard let message = messages.first(where: { $0.id == id }), case .mix(_, let card, let state) = message else { return nil }
        return (card, state)
    }

    private func setMix(_ id: Int, card: MixCard? = nil, state: MixCardState) {
        guard let index = messages.firstIndex(where: { $0.id == id }), case .mix(_, let current, _) = messages[index] else { return }
        messages[index] = .mix(id: id, card: card ?? current, state: state)
    }

    /// Play on a mix card: the queue becomes the mix.
    func playMix(id: Int) {
        guard let (card, state) = mixCard(id), !state.busy, let tools = toolbox else { return }
        Task { [weak self] in
            let ok = await tools.playMix(card.mixId)
            guard let self, let now = self.mixCard(id) else { return }
            self.setMix(id, state: now.state.afterPlay(succeeded: ok))
        }
    }

    /// Save on a mix card: a playlist of the listener's with the mix's songs.
    func saveMix(id: Int) {
        guard let (card, state) = mixCard(id), !state.busy, !state.saved, let tools = toolbox else { return }
        var working = state
        working.busy = true
        working.failed = false
        setMix(id, state: working)
        Task { [weak self] in
            let ok = await tools.saveMix(card.mixId)
            guard let self, let now = self.mixCard(id) else { return }
            self.setMix(id, state: now.state.afterSave(succeeded: ok))
        }
    }

    /// A chip under a mix card: the stored request with that delta, built again by the engine on the phone.
    func applyChip(id: Int, chip: MixCardChip) {
        guard let (card, state) = mixCard(id), !state.busy, let tools = toolbox else { return }
        var working = state
        working.busy = true
        working.failed = false
        setMix(id, state: working)
        Task { [weak self] in
            let next = await tools.music.adjustMix(card.mixId, chip: chip.chip)
            guard let self, let now = self.mixCard(id) else { return }
            if let next {
                self.setMix(id, card: next, state: now.state.afterChip(succeeded: true))
            } else {
                self.setMix(id, state: now.state.afterChip(succeeded: false))
            }
        }
    }

    private func lessOffer(_ id: Int) -> LessOffer? {
        guard let message = messages.first(where: { $0.id == id }), case .less(_, let offer) = message else { return nil }
        return offer
    }

    private func setLess(_ id: Int, _ offer: LessOffer) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index] = .less(id: id, offer: offer)
    }

    /// "Less trap": the existing taste change (undone with Undo here, or in Taste changes).
    func tapLess(id: Int) {
        guard let offer = lessOffer(id), offer.phase != .done, let tools = toolbox else { return }
        Task { [weak self] in
            let adjustment = await tools.lessLike(kind: offer.kind, name: offer.name)
            guard let self, let current = self.lessOffer(id) else { return }
            self.setLess(id, current.tapped(adjustmentId: adjustment))
        }
    }

    func undoLess(id: Int) {
        guard let offer = lessOffer(id), let adjustment = offer.adjustmentId, let tools = toolbox else { return }
        Task { [weak self] in
            await tools.undoLess(id: adjustment)
            guard let self, let current = self.lessOffer(id) else { return }
            self.setLess(id, current.undone())
        }
    }

    // MARK: Confirmations

    private func askConfirmation(_ question: String) async -> Bool {
        flushPendingText()
        let id = makeId()
        messages.append(.confirm(id: id, question: question, state: .pending))
        return await withCheckedContinuation { continuation in
            confirmations[id] = continuation
        }
    }

    /// The card's Confirm / Cancel.
    func resolveConfirmation(id: Int, approved: Bool) {
        guard let continuation = confirmations.removeValue(forKey: id) else { return }
        if let index = messages.firstIndex(where: { $0.id == id }), case .confirm(_, let question, _) = messages[index] {
            messages[index] = .confirm(id: id, question: question, state: approved ? .approved : .declined)
        }
        continuation.resume(returning: approved)
    }

    private func resolveAllConfirmations(_ approved: Bool) {
        for id in Array(confirmations.keys) { resolveConfirmation(id: id, approved: approved) }
    }

    // MARK: Conversations

    /// Restores the last conversation when the sheet first opens (if it was used in the last six hours) and loads the
    /// list for the menu.
    func restoreIfNeeded() {
        guard !didRestore, let store = assistant?.store else { return }
        didRestore = true
        Task { [weak self] in
            let records = await store.load()
            guard let self else { return }
            self.recentConversations = records
            if self.messages.isEmpty, let latest = records.first,
               currentTimeMillis() - latest.updatedAt < 6 * 3_600_000 {
                self.show(latest)
            }
        }
    }

    /// "New chat": the next prompt starts a new conversation.
    func newChat() {
        turnTask?.cancel()
        turnTask = nil
        resolveAllConfirmations(false)
        messages.removeAll()
        conversation = nil
        toolbox = nil
        deviceGrounding.reset()
        inputText = ""
    }

    /// Opens a saved conversation from the menu.
    func open(_ id: String) {
        guard let record = recentConversations.first(where: { $0.id == id }) else { return }
        turnTask?.cancel()
        turnTask = nil
        resolveAllConfirmations(false)
        show(record)
    }

    private func show(_ record: TaizoConversationRecord) {
        conversation = record
        toolbox = nil
        deviceGrounding.reset()
        messages = record.transcript.map { entry in
            let id = makeId()
            switch entry.role {
            case .user: return .user(id: id, text: entry.text)
            case .assistant: return .assistant(id: id, text: entry.text, sources: entry.sources, activity: nil, isStreaming: false)
            case .note: return .note(id: id, text: entry.text)
            }
        }
    }

    private func save(_ record: TaizoConversationRecord, store: TaizoConversationStore?) async {
        conversation = record
        guard let store else { return }
        await store.save(record)
        recentConversations = await store.load()
    }

    // MARK: Message list edits

    private func replace(_ id: Int, with message: TaisChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }

    private func insert(_ message: TaisChatMessage, before id: Int) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages.insert(message, at: index)
        } else {
            messages.append(message)
        }
    }

    private func insert(_ message: TaisChatMessage, after id: Int) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages.insert(message, at: index + 1)
        } else {
            messages.append(message)
        }
    }

    // MARK: Playback commands (Android `onPlaySongs` / `onQueueSongs`)

    /// Plays `songs` from the first (queue name "TAIS DJ" on Android).
    func play(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        playback.play(songs, startIndex: 0, source: .assistant)
    }

    /// Appends `songs` to the queue.
    func queue(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        playback.addToQueue(songs)
    }

    /// `resolveOnlineTracks`: imports catalogue results into the library (Search's import pipeline), then plays or
    /// queues the songs that resolved. One import at a time, so a double tap can't import twice.
    func resolveOnlineTracks(_ items: [SearchResultItem], source: SearchSource, thenPlay: Bool, onPlayed: @escaping () -> Void) {
        guard !items.isEmpty, !isResolvingOnlineTracks else { return }
        isResolvingOnlineTracks = true
        let router = engine.router
        Task { [weak self] in
            let songs = await router.resolve(items, source: source)
            guard let self else { return }
            self.isResolvingOnlineTracks = false
            guard !songs.isEmpty else { return }
            if thenPlay {
                self.play(songs)
                onPlayed()
            } else {
                self.queue(songs)
            }
        }
    }
}

/// What a Claude turn has done so far (main actor only).
final class ClaudeTurnProgress {
    var text = ""
    /// The text when the current request started (a discarded turn goes back to it).
    var turnStart = ""
    var ranTool = false
}
