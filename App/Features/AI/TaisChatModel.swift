import Foundation
import Observation
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

    var id: Int {
        switch self {
        case .user(let id, _), .thinking(let id, _), .djReply(let id, _, _, _), .textReply(let id, _, _),
             .assistant(let id, _, _, _, _), .confirm(let id, _, _), .note(let id, _): id
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
        guard let pending = enqueue() else { return }
        Task { [weak self] in await self?.respond(to: pending) }
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
        let turn = await engine.respond(pending.prompt)
        let replyId = finish(thinkingId: pending.thinkingId, prompt: pending.prompt, turn: turn)
        // On-device, the card is already up; its intro line follows when the model has written it.
        var intro: String?
        if case .media(_, let result, nil) = turn, let deferred = await engine.deferredIntro(prompt: pending.prompt, result: result) {
            setIntro(id: replyId, text: deferred)
            intro = deferred
        }
        await rememberOnDeviceTurn(prompt: pending.prompt, turn: turn, intro: intro)
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
        let progress = ClaudeTurnProgress()
        let loop = ClaudeToolLoop(
            client: client, system: record.system, tools: tools, serverTools: TaizoAssistant.serverTools,
            effort: .medium, stream: true,
            confirm: { [weak self] question in await self?.askConfirmation(question) ?? false },
            onEvent: { [weak self] event in await self?.handle(event, replyId: replyId, progress: progress) },
            onUsage: assistant.onUsage)
        do {
            let result = try await loop.run(history: ClaudeConversation.forRequest(history))
            flushPendingText()
            switch result.outcome {
            case .refused:
                let text = "I can't help with that one — ask me anything else about music."
                setAssistant(replyId, text: text, sources: [], streaming: false)
                record.transcript.append(TaizoTranscriptEntry(role: .user, text: pending.prompt))
                record.transcript.append(TaizoTranscriptEntry(role: .assistant, text: text))
            case .finished, .truncated, .stepLimit:
                var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    text = result.outcome == .finished ? "Done." : "That got too long for one answer — try asking for less at once."
                }
                setAssistant(replyId, text: text, sources: result.sources, streaming: false)
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
            setAssistant(replyId, text: progress.text.isEmpty ? "Stopped." : progress.text, sources: [], streaming: false)
            return true
        } catch {
            flushPendingText()
            await assistant.onFallback("assistant: \(error)")
            if progress.ranTool || !progress.text.isEmpty {
                // Something already happened (text shown, a tool ran): keep it rather than answer twice.
                setAssistant(replyId, text: progress.text.isEmpty ? "Done so far." : progress.text, sources: [], streaming: false)
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
            setAssistant(replyId, text: progress.text, sources: [], streaming: true)
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
        case nil: return "Working on it…"
        }
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
            // Text arriving clears the activity line: the answer is being written.
            messages[index] = .assistant(id: id, text: text + piece, sources: sources, activity: nil, isStreaming: streaming)
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
        resolveAllConfirmations(false)
        messages.removeAll()
        conversation = nil
        toolbox = nil
        inputText = ""
    }

    /// Opens a saved conversation from the menu.
    func open(_ id: String) {
        guard let record = recentConversations.first(where: { $0.id == id }) else { return }
        resolveAllConfirmations(false)
        show(record)
    }

    private func show(_ record: TaizoConversationRecord) {
        conversation = record
        toolbox = nil
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
        playback.play(songs, startIndex: 0)
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
