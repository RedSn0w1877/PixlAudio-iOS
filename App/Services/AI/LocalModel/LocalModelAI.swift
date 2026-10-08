import Foundation
import PixlModel
import PixlNet

/// The AI features on the downloaded model (2026-10-07, local AI phase 2): the same requests `OnDeviceAI` makes of
/// the system model — Taizo's chat with memory, intro lines, Home's greeting, plain text (lyric translation chunks),
/// song picks and long-playlist plans — written as ChatML for Qwen2.5 and run by `LocalModelRuntime`.
///
/// Settings › AI features › "Use downloaded AI model" (off by default) routes every on-device feature here
/// (`OnDeviceContext.usesDownloadedModel`). Requests queue on the runtime one at a time; Taizo's chat also waits for
/// its own previous turn, so a message sent while a reply is being written still sees that reply.
actor LocalModelAI {
    static let shared = LocalModelAI(runtime: .shared)

    nonisolated let runtime: LocalModelRuntime
    private var turns: [(user: String, reply: String)] = []
    private var chatBusy = false
    private var chatWaiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    init(runtime: LocalModelRuntime) {
        self.runtime = runtime
    }

    // MARK: State

    /// Why the downloaded model can't answer (nil when it is installed). A few file checks, no loading.
    nonisolated func unavailability() -> OnDeviceFailure? {
        ModelManager.isInstalled(runtime.descriptor) ? nil : .localModelMissing
    }

    nonisolated var contextSize: Int { LocalModelPrompts.contextBudget }

    /// The exact token count of `text` (the model's own tokenizer); an estimate when the model isn't installed.
    func tokenCount(_ text: String) async -> Int {
        (try? await runtime.run { $0.tokenizer.count(text) }) ?? OnDeviceText.estimatedTokens(text)
    }

    nonisolated func prewarm() {
        guard unavailability() == nil else { return }
        runtime.prewarm()
    }

    // MARK: Chat

    /// Taizo's answer, remembering the conversation (the oldest turns drop out when the window fills up).
    func chat(_ message: String, persona: String?, temperature: Double?,
              songs: @escaping @MainActor @Sendable () -> [Song]) async throws -> String {
        if let issue = unavailability() { throw issue }
        try await acquireChat()
        defer { releaseChat() }
        let library = await songs()
        let note = await Self.note(for: message, songs: library)
        let user = LocalModelPrompts.chatTurn(message, note: note)
        let system = LocalModelPrompts.chatInstructions(persona: persona)
        let history = turns
        let sampling = LocalModelPrompts.sampling(temperature: temperature)
        let reply = try await Self.mapped {
            try await self.runtime.run { session -> String in
                let tokenizer = session.tokenizer
                let budget = session.contextLength - 320
                guard let messages = ChatMLTemplate.fit(system: system, turns: history, message: user, budget: budget,
                                                        count: { tokenizer.count(ChatMLTemplate.render($0)) }) else {
                    throw OnDeviceFailure.tooLong
                }
                return try Self.complete(session, messages: messages, maxTokens: 300, sampling: sampling)
            }
        }
        let cleaned = OnDeviceText.cleanReply(reply)
        turns.append((user, cleaned))
        if turns.count > 12 { turns.removeFirst(turns.count - 12) }
        return cleaned
    }

    /// Forgets the conversation.
    func resetChat() {
        turns.removeAll()
    }

    /// The library lookup, off the main actor (a large library takes a moment to group).
    @concurrent
    nonisolated private static func note(for message: String, songs: [Song]) async -> String? {
        LocalModelPrompts.libraryNote(for: message, songs: songs)
    }

    // MARK: Single requests

    /// The one-line intro above Taizo's queue card.
    func introLine(request: String, count: Int) async throws -> String? {
        if let issue = unavailability() { throw issue }
        let text = try await reply(system: TaizoPrompts.introInstructions,
                                   prompt: TaizoPrompts.introPrompt(request: request, count: count),
                                   maxTokens: 32, temperature: nil, singleLine: true)
        return OnDeviceText.singleLine(text, limit: 120)
    }

    /// Home's greeting headline or insight.
    func greeting(instructions: String, prompt: String, temperature: Double?, maxTokens: Int) async throws -> String {
        if let issue = unavailability() { throw issue }
        return try await reply(system: instructions, prompt: prompt, maxTokens: maxTokens, temperature: temperature)
    }

    /// Plain text: lyric translation chunks, the playlist fallback.
    func text(instructions: String, prompt: String, maxTokens: Int, temperature: Double? = nil) async throws -> String {
        if let issue = unavailability() { throw issue }
        return try await reply(system: instructions, prompt: prompt, maxTokens: maxTokens, temperature: temperature)
    }

    /// Song numbers from a numbered list, `minimum`…`maximum` of them: the model can only write distinct numbers in
    /// `1…poolSize`, separated by commas (`NumberListConstraint`).
    func pickNumbers(prompt: String, poolSize: Int, minimum: Int, maximum: Int, temperature: Double?) async throws -> [Int] {
        if let issue = unavailability() { throw issue }
        let system = OnDeviceCuration.instructions
        let user = LocalModelPrompts.pickPrompt(prompt)
        let sampling = LocalModelPrompts.pickSampling(temperature: temperature)
        return try await Self.mapped {
            try await self.runtime.run { session -> [Int] in
                let tokenizer = session.tokenizer
                guard let tokens = Self.numberTokens(tokenizer) else { throw OnDeviceFailure.other("its tokenizer") }
                let constraint = NumberListConstraint(poolSize: poolSize, minimum: minimum, maximum: maximum, tokens: tokens)
                let ids = tokenizer.encode(ChatMLTemplate.render([ChatMLTemplate.Message(.system, system),
                                                                  ChatMLTemplate.Message(.user, user)]))
                var request = Self.request(ids, tokenizer: tokenizer, maxTokens: LocalModelPrompts.pickTokens(maximum: maximum),
                                           sampling: sampling)
                request.numberList = constraint
                return try session.generate(request).picks ?? []
            }
        }
    }

    /// A long playlist's plan, from five labelled lines.
    func plan(prompt: String, genres: [String], artists: [String]) async throws -> OnDeviceCuration.Plan {
        if let issue = unavailability() { throw issue }
        let text = try await reply(system: LocalModelPrompts.planInstructions,
                                   prompt: LocalModelPrompts.planPrompt(prompt, genres: genres, artists: artists),
                                   maxTokens: 120, temperature: nil)
        return LocalModelPrompts.plan(text, genres: genres, artists: artists)
    }

    // MARK: Helpers

    private func reply(system: String, prompt: String, maxTokens: Int, temperature: Double?,
                       singleLine: Bool = false) async throws -> String {
        let sampling = LocalModelPrompts.sampling(temperature: temperature)
        let text = try await Self.mapped {
            try await self.runtime.run { session -> String in
                try Self.complete(session, messages: [ChatMLTemplate.Message(.system, system),
                                                      ChatMLTemplate.Message(.user, prompt)],
                                  maxTokens: maxTokens, sampling: sampling, singleLine: singleLine)
            }
        }
        return OnDeviceText.cleanReply(text)
    }

    /// On the runtime's queue: render, encode, generate, decode.
    private nonisolated static func complete(_ session: LocalModelRuntime.Session, messages: [ChatMLTemplate.Message],
                                             maxTokens: Int, sampling: SamplingSettings,
                                             singleLine: Bool = false) throws -> String {
        let tokenizer = session.tokenizer
        let ids = tokenizer.encode(ChatMLTemplate.render(messages))
        let request = request(ids, tokenizer: tokenizer, maxTokens: maxTokens, sampling: sampling)
        let result = try session.generate(request, stopWhen: { tokens in
            singleLine && tokenizer.decode(tokens).trimmingCharacters(in: .whitespaces).contains("\n")
        })
        return tokenizer.decode(result.tokens)
    }

    private nonisolated static func request(_ ids: [Int], tokenizer: BytePairTokenizer, maxTokens: Int,
                                            sampling: SamplingSettings) -> LocalGenerationRequest {
        let stops = Set([ChatMLTemplate.end, ChatMLTemplate.endOfText].compactMap { tokenizer.id(of: $0) })
        let banned = [ChatMLTemplate.start].compactMap { tokenizer.id(of: $0) }
        return LocalGenerationRequest(prompt: ids, maxNewTokens: maxTokens, sampling: sampling, stopTokens: stops,
                                      bannedTokens: banned, seed: UInt64.random(in: 1...UInt64.max))
    }

    /// The digits, the comma, the space and `<|im_end|>` (the list's end).
    nonisolated static func numberTokens(_ tokenizer: BytePairTokenizer) -> NumberListConstraint.Tokens? {
        let digits = (0...9).compactMap { tokenizer.id(of: String($0)) }
        guard digits.count == 10, let comma = tokenizer.id(of: ","), let space = tokenizer.id(of: " "),
              let end = tokenizer.id(of: ChatMLTemplate.end) else { return nil }
        return NumberListConstraint.Tokens(digits: digits, comma: comma, space: space, end: end)
    }

    /// Model errors as `OnDeviceFailure`s (cancellation passes through).
    private static func mapped<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as OnDeviceFailure {
            throw failure
        } catch let error as LocalGenerationError {
            switch error {
            case .promptTooLong: throw OnDeviceFailure.tooLong
            case .cancelled: throw CancellationError()
            case .nonFiniteLogits: throw OnDeviceFailure.other("its numbers went wrong")
            }
        } catch {
            throw OnDeviceFailure.other(error.localizedDescription)
        }
    }

    // MARK: Chat queue

    private func acquireChat() async throws {
        guard chatBusy else {
            chatBusy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    chatWaiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelChatWaiter(id) }
        }
    }

    private func cancelChatWaiter(_ id: UUID) {
        guard let index = chatWaiters.firstIndex(where: { $0.id == id }) else { return }
        chatWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func releaseChat() {
        if chatWaiters.isEmpty {
            chatBusy = false
        } else {
            chatWaiters.removeFirst().continuation.resume()
        }
    }
}
