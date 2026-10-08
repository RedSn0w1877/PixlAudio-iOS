import Foundation

/// A causal language model over a fixed-size key/value cache: the downloadable local AI model's Core ML program in
/// the app (`ci/ml/convert_llm.py` documents the contract), a stand-in in tests.
///
/// `step` feeds `tokens` at positions `past..<past + tokens.count` — rows `0..<past` of the cache must already hold
/// this sequence's earlier tokens — and writes the logits that follow the last of them into `logits`
/// (`vocabularySize` values). Rows past the fed tokens are never read, so a cache can be reused for any prompt that
/// shares a prefix with the previous one.
public protocol CausalLanguageModel: AnyObject {
    /// The cache's length: prompt and answer together never exceed it.
    var contextLength: Int { get }
    /// The most tokens one `step` may feed.
    var maxQueryLength: Int { get }
    var vocabularySize: Int { get }
    func step(_ tokens: ArraySlice<Int>, past: Int, logits: inout [Float]) throws
}

/// What to generate.
public struct LocalGenerationRequest: Sendable, Equatable {
    /// The whole prompt (the ChatML text's tokens). A prefix the cache already holds is not fed again.
    public var prompt: [Int]
    public var maxNewTokens: Int
    public var sampling: SamplingSettings
    /// Tokens that end the answer (not part of it): `<|im_end|>`, `<|endoftext|>`.
    public var stopTokens: Set<Int>
    /// Tokens the model may never write (`<|im_start|>` …).
    public var bannedTokens: [Int]
    /// Constrained decoding: the answer is a list of distinct numbers (its end token should be a stop token).
    public var numberList: NumberListConstraint?
    public var seed: UInt64
    /// Tokens fed per prefill step (the CI parity gate measured 64).
    public var prefillChunk: Int
    /// A prompt that leaves fewer answer tokens than this is refused as too long.
    public var minimumAnswerTokens: Int

    public init(prompt: [Int], maxNewTokens: Int, sampling: SamplingSettings, stopTokens: Set<Int>,
                bannedTokens: [Int] = [], numberList: NumberListConstraint? = nil, seed: UInt64 = 0,
                prefillChunk: Int = 64, minimumAnswerTokens: Int = 8) {
        self.prompt = prompt
        self.maxNewTokens = maxNewTokens
        self.sampling = sampling
        self.stopTokens = stopTokens
        self.bannedTokens = bannedTokens
        self.numberList = numberList
        self.seed = seed
        self.prefillChunk = prefillChunk
        self.minimumAnswerTokens = minimumAnswerTokens
    }
}

/// What came out, with the timings Settings shows (only the phone can measure the real speed).
public struct LocalGenerationResult: Sendable, Equatable {
    public enum Finish: Sendable, Equatable {
        /// A stop token.
        case stop
        /// `maxNewTokens`, or the end of the context.
        case length
        /// The caller's stop condition (`stopWhen`).
        case condition
        /// The number list is complete.
        case numberList
    }

    /// The answer's tokens (no stop token).
    public var tokens: [Int]
    public var finish: Finish
    /// The number list's picks (with a constraint).
    public var picks: [Int]?
    public var promptTokens: Int
    /// Prompt tokens the cache already held (not fed again).
    public var reusedTokens: Int
    public var prefillSeconds: Double
    public var decodeSeconds: Double

    /// Answer tokens per second while decoding (0 before the first decoded token).
    public var tokensPerSecond: Double {
        guard decodeSeconds > 0, tokens.count > 1 else { return 0 }
        return Double(tokens.count - 1) / decodeSeconds
    }
}

public enum LocalGenerationError: Error, Sendable, Equatable {
    /// The prompt leaves no room for an answer.
    case promptTooLong(tokens: Int, limit: Int)
    case cancelled
    /// The model produced NaN or no finite logit (a numerics problem on this compute unit).
    case nonFiniteLogits
}

/// Runs a `CausalLanguageModel`: reuses the cached prefix, prefills the rest in chunks, then samples token by token
/// (`TokenSampler`, optionally constrained by a `NumberListConstraint`) until a stop token, the length limit or the
/// caller's condition. Synchronous and single-threaded: the app runs it on its own serial queue, and `isCancelled`
/// is checked before every model step.
public final class LocalLLMGenerator {
    public let model: any CausalLanguageModel
    /// The tokens whose keys and values are in the cache's first rows.
    public private(set) var cachedTokens: [Int] = []
    private var logits: [Float]

    public init(model: any CausalLanguageModel) {
        self.model = model
        logits = [Float](repeating: 0, count: model.vocabularySize)
    }

    /// Forgets the cache (a new state, or after a failed step).
    public func reset() {
        cachedTokens.removeAll()
    }

    /// The length of the prefix two token sequences share.
    public static func commonPrefix(_ a: [Int], _ b: [Int]) -> Int {
        var count = 0
        let limit = min(a.count, b.count)
        while count < limit, a[count] == b[count] { count += 1 }
        return count
    }

    public func generate(_ request: LocalGenerationRequest, stopWhen: ([Int]) -> Bool = { _ in false },
                         isCancelled: () -> Bool = { false }) throws -> LocalGenerationResult {
        let prompt = request.prompt
        let limit = model.contextLength
        guard !prompt.isEmpty, prompt.count + max(request.minimumAnswerTokens, 1) <= limit else {
            throw LocalGenerationError.promptTooLong(tokens: prompt.count, limit: limit)
        }
        let maxNew = max(0, min(request.maxNewTokens, limit - prompt.count))
        let clock = ContinuousClock()
        let started = clock.now

        // Prefill: what the cache doesn't hold yet (at least the last prompt token, for its logits).
        let reused = min(Self.commonPrefix(cachedTokens, prompt), prompt.count - 1)
        cachedTokens.removeSubrange(reused...)
        let chunk = max(1, min(request.prefillChunk, model.maxQueryLength))
        var start = reused
        do {
            while start < prompt.count {
                if isCancelled() { throw LocalGenerationError.cancelled }
                let end = min(start + chunk, prompt.count)
                try model.step(prompt[start..<end], past: start, logits: &logits)
                cachedTokens.append(contentsOf: prompt[start..<end])
                start = end
            }
        } catch {
            throw failed(error)
        }
        let prefilled = clock.now

        var sampler = TokenSampler(seed: request.seed)
        var constraint = request.numberList
        var tokens: [Int] = []
        var finish = LocalGenerationResult.Finish.length
        var recent = Array(prompt.suffix(max(request.sampling.repetitionWindow, 0)))
        do {
            while tokens.count < maxNew {
                try Self.checkFinite(logits)
                let allowed = constraint?.allowedTokens()
                if let allowed, allowed.isEmpty {
                    finish = .numberList
                    break
                }
                guard let token = sampler.sample(&logits, settings: request.sampling, recent: recent[...],
                                                 allowed: allowed, banned: request.bannedTokens) else {
                    throw LocalGenerationError.nonFiniteLogits
                }
                constraint?.accept(token)
                if request.stopTokens.contains(token) {
                    finish = constraint == nil ? .stop : .numberList
                    break
                }
                tokens.append(token)
                recent.append(token)
                if recent.count > 256 { recent.removeFirst(recent.count - 256) }
                if constraint?.isFinished == true {
                    finish = .numberList
                    break
                }
                if stopWhen(tokens) {
                    finish = .condition
                    break
                }
                guard tokens.count < maxNew else { break }
                if isCancelled() { throw LocalGenerationError.cancelled }
                let past = prompt.count + tokens.count - 1
                try model.step([token][...], past: past, logits: &logits)
                cachedTokens.append(token)
            }
        } catch {
            throw failed(error)
        }
        let done = clock.now
        return LocalGenerationResult(tokens: tokens, finish: finish, picks: constraint?.picks, promptTokens: prompt.count,
                                     reusedTokens: reused, prefillSeconds: Self.seconds(prefilled - started),
                                     decodeSeconds: Self.seconds(done - prefilled))
    }

    /// A failed step may have written part of a chunk: the cache keeps only the rows known to be right. Cancellation
    /// stops between steps, so everything fed so far stays usable.
    private func failed(_ error: any Error) -> any Error {
        if let error = error as? LocalGenerationError, error == .cancelled { return error }
        reset()
        return error
    }

    static func checkFinite(_ logits: [Float]) throws {
        for value in logits where value.isNaN { throw LocalGenerationError.nonFiniteLogits }
    }

    static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

// MARK: - Prompt fitting

extension ChatMLTemplate {
    /// The conversation that fits `budget` tokens: the system message, as many of the latest turns as fit (oldest
    /// dropped first, whole turns only), then the new message. Nil when even the system message and the new message
    /// alone don't fit.
    public static func fit(system: String, turns: [(user: String, reply: String)], message: String, budget: Int,
                           count: ([Message]) -> Int) -> [Message]? {
        let head = [Message(.system, system)]
        let tail = [Message(.user, message)]
        guard count(head + tail) <= budget else { return nil }
        var kept = 0
        while kept < turns.count {
            let candidate = turns.suffix(kept + 1).flatMap { [Message(.user, $0.user), Message(.assistant, $0.reply)] }
            guard count(head + candidate + tail) <= budget else { break }
            kept += 1
        }
        let history = turns.suffix(kept).flatMap { [Message(.user, $0.user), Message(.assistant, $0.reply)] }
        return head + history + tail
    }
}

// MARK: - Playlist plans as text

/// A long playlist's plan written by the local model as five labelled lines (the system model fills a schema
/// instead): `genres: Rock, Indie` / `artists: Radiohead` / `moods: calm, rainy` / `energy: 2` / `familiar: yes`.
/// Genres and artists are kept only when they name one of the allowed values (the library's own), case- and
/// accent-insensitively; anything unreadable keeps its default.
public struct LocalPlanText: Sendable, Equatable {
    public var genres: [String] = []
    public var artists: [String] = []
    public var moods: [String] = []
    public var energy = 3
    public var familiar = true

    public init(genres: [String] = [], artists: [String] = [], moods: [String] = [], energy: Int = 3,
                familiar: Bool = true) {
        self.genres = genres
        self.artists = artists
        self.moods = moods
        self.energy = energy
        self.familiar = familiar
    }

    /// The answer format the prompt asks for.
    public static let format = "genres: …\nartists: …\nmoods: …\nenergy: 1-5\nfamiliar: yes or no"

    public static func parse(_ text: String, allowedGenres: [String], allowedArtists: [String]) -> LocalPlanText {
        var plan = LocalPlanText()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: " -*•#")).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "genres", "genre": plan.genres = pick(list(value), from: allowedGenres, max: 3)
            case "artists", "artist": plan.artists = pick(list(value), from: allowedArtists, max: 5)
            case "moods", "mood": plan.moods = Array(list(value).filter { $0.count <= 24 }.prefix(3))
            case "energy":
                if let digit = value.first(where: { $0.isASCII && $0.isNumber }), let number = Int(String(digit)) {
                    plan.energy = min(max(number, 1), 5)
                }
            case "familiar":
                let lower = value.lowercased()
                if lower.hasPrefix("y") || lower.hasPrefix("true") { plan.familiar = true }
                if lower.hasPrefix("n") || lower.hasPrefix("false") { plan.familiar = false }
            default: continue
            }
        }
        return plan
    }

    /// Comma-separated values, without quotes, brackets, "none" or empties.
    static func list(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "/" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'[]().")) }
            .filter { !$0.isEmpty && !["none", "n/a", "-", "…", "..."].contains($0.lowercased()) }
    }

    /// The allowed values the answer names, in the answer's order, distinct.
    static func pick(_ values: [String], from allowed: [String], max: Int) -> [String] {
        func key(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespaces)
        }
        var byKey: [String: String] = [:]
        for value in allowed where byKey[key(value)] == nil { byKey[key(value)] = value }
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            guard let match = byKey[key(value)], seen.insert(match).inserted else { continue }
            result.append(match)
            if result.count >= max { break }
        }
        return result
    }
}

// MARK: - Causal mask

/// The `causalMask` input of one step: `[1, 1, count, past + count]`, row `i` attending to columns `0...past + i`.
public enum CausalMask {
    /// Row-major values: 0 where attended, `-infinity` where masked.
    public static func values(past: Int, count: Int) -> [Float] {
        let width = past + count
        var mask = [Float](repeating: -.infinity, count: count * width)
        for row in 0..<count {
            for column in 0...(past + row) { mask[row * width + column] = 0 }
        }
        return mask
    }
}
