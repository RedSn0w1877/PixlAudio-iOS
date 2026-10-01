import Foundation
import Observation
import PixlModel
import PixlNet

/// One turn of the TAIS DJ chat (Android `TaisChatMessage`): the prompt, then a result or the in-flight state.
nonisolated enum TaisChatMessage: Identifiable, Sendable, Equatable {
    case user(id: Int, text: String)
    case thinking(id: Int, prompt: String)
    case djReply(id: Int, prompt: String, result: DjRouteResult, aiIntro: String?)
    /// A conversational answer (music trivia, recommendations) or an error.
    case textReply(id: Int, text: String, isError: Bool)

    var id: Int {
        switch self {
        case .user(let id, _), .thinking(let id, _), .djReply(let id, _, _, _), .textReply(let id, _, _): id
        }
    }
}

/// The chat state (Android `TaisChatViewModel`) over `TaisDjEngine`. Held by `AIService`, so the conversation
/// survives closing and reopening the sheet in the same session.
@Observable
final class TaisChatModel {
    private(set) var messages: [TaisChatMessage] = []
    var inputText = ""
    /// A catalogue import is running (rows and bulk buttons are disabled meanwhile).
    private(set) var isResolvingOnlineTracks = false

    @ObservationIgnored private var nextId = 0
    @ObservationIgnored private let engine: TaisDjEngine
    @ObservationIgnored private let playback: PlaybackStore

    /// Android `TAIZO_SUGGESTIONS` (sent as "Play some <x> songs").
    static let suggestions = ["Chill acoustic", "Energetic rock", "Sad indie", "Party anthems", "Focus beats", "Feel-good pop"]

    init(engine: TaisDjEngine, playback: PlaybackStore) {
        self.engine = engine
        self.playback = playback
    }

    private func makeId() -> Int {
        nextId += 1
        return nextId
    }

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
        let userId = makeId()
        let thinkingId = makeId()
        messages.append(.user(id: userId, text: prompt))
        messages.append(.thinking(id: thinkingId, prompt: prompt))
        inputText = ""
        return (prompt, thinkingId)
    }

    private func respond(to pending: (prompt: String, thinkingId: Int)) async {
        let turn = await engine.respond(pending.prompt)
        finish(thinkingId: pending.thinkingId, prompt: pending.prompt, turn: turn)
    }

    private func finish(thinkingId: Int, prompt: String, turn: TaizoTurn) {
        let reply: TaisChatMessage
        switch turn {
        case .media(_, let result, let intro): reply = .djReply(id: makeId(), prompt: prompt, result: result, aiIntro: intro)
        case .conversation(let text): reply = .textReply(id: makeId(), text: text, isError: false)
        case .error(let message): reply = .textReply(id: makeId(), text: message, isError: true)
        }
        if let index = messages.firstIndex(where: { $0.id == thinkingId }) {
            messages[index] = reply
        } else {
            messages.append(reply)
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
