import Foundation

/// The chat format of the downloadable local model (Qwen2.5's ChatML template without tools):
/// `<|im_start|>role\ncontent<|im_end|>\n` per message, then `<|im_start|>assistant\n` for the reply.
public enum ChatMLTemplate {
    public enum Role: String, Sendable {
        case system, user, assistant
    }

    public struct Message: Sendable, Equatable {
        public var role: Role
        public var content: String

        public init(_ role: Role, _ content: String) {
            self.role = role
            self.content = content
        }
    }

    public static let start = "<|im_start|>"
    public static let end = "<|im_end|>"
    public static let endOfText = "<|endoftext|>"

    /// The prompt text for `messages`, ending with the assistant header when `addGenerationPrompt`. A missing system
    /// message gets none (the app always sends one; Qwen's own template would insert its default).
    public static func render(_ messages: [Message], addGenerationPrompt: Bool = true) -> String {
        var text = ""
        for message in messages {
            text += start + message.role.rawValue + "\n" + sanitize(message.content) + end + "\n"
        }
        if addGenerationPrompt { text += start + Role.assistant.rawValue + "\n" }
        return text
    }

    /// Control-token text inside content (a song title, a lyric line, a user's message) can't open or close a
    /// message: `<|` becomes `<` + a zero-width space + `|`, which tokenises as ordinary text.
    public static func sanitize(_ content: String) -> String {
        guard content.contains("<|") else { return content }
        return content.replacingOccurrences(of: "<|", with: "<\u{200B}|")
    }
}

/// Sampling settings for the local model.
public struct SamplingSettings: Sendable, Equatable {
    /// 0 (or less): greedy.
    public var temperature: Double
    public var topK: Int
    public var topP: Double
    /// Hugging Face's repetition penalty over `repetitionWindow` recent tokens (1: none).
    public var repetitionPenalty: Double
    public var repetitionWindow: Int

    public init(temperature: Double, topK: Int = 20, topP: Double = 0.8, repetitionPenalty: Double = 1.05,
                repetitionWindow: Int = 64) {
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.repetitionPenalty = repetitionPenalty
        self.repetitionWindow = repetitionWindow
    }

    /// Argmax, with a light repetition penalty so a small model doesn't loop.
    public static let greedy = SamplingSettings(temperature: 0, topK: 1, topP: 1, repetitionPenalty: 1.05)

    public var isGreedy: Bool { temperature <= 0 || topK == 1 }
}

/// Picks the next token from the model's logits: repetition penalty, banned and allowed tokens, then argmax (greedy)
/// or temperature + top-k + top-p sampling with a seeded generator (deterministic in tests).
public struct TokenSampler: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    /// SplitMix64.
    private mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A uniform double in [0, 1).
    private mutating func uniform() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// The next token. `logits` is scratch: the penalty and bans are applied in place. With `allowed`, only those ids
    /// are considered (constrained decoding); nil when nothing is allowed.
    public mutating func sample(_ logits: inout [Float], settings: SamplingSettings, recent: ArraySlice<Int> = [],
                                allowed: [Int]? = nil, banned: [Int] = []) -> Int? {
        let count = logits.count
        if settings.repetitionPenalty != 1, settings.repetitionPenalty > 0 {
            let penalty = Float(settings.repetitionPenalty)
            var seen = Set<Int>()
            for id in recent.suffix(max(settings.repetitionWindow, 0)) where id >= 0 && id < count && seen.insert(id).inserted {
                logits[id] = logits[id] > 0 ? logits[id] / penalty : logits[id] * penalty
            }
        }
        for id in banned where id >= 0 && id < count { logits[id] = -.infinity }

        let topK = settings.isGreedy ? 1 : max(1, settings.topK)
        var best: [(value: Float, id: Int)] = []
        best.reserveCapacity(topK + 1)
        func consider(_ id: Int) {
            let value = logits[id]
            guard value.isFinite else { return }
            if best.count == topK {
                // Ties keep the lower id (argmax's first occurrence): only a strictly larger value enters.
                guard let last = best.last, value > last.value else { return }
                best.removeLast()
            }
            var position = best.count
            while position > 0, best[position - 1].value < value { position -= 1 }
            best.insert((value, id), at: position)
        }
        if let allowed {
            for id in allowed.sorted() where id >= 0 && id < count { consider(id) }
        } else {
            for id in 0..<count { consider(id) }
        }
        guard let top = best.first else { return nil }
        if settings.isGreedy || best.count == 1 { return top.id }

        let temperature = max(settings.temperature, 1e-4)
        var weights = best.map { exp(Double($0.value - top.value) / temperature) }
        let total = weights.reduce(0, +)
        weights = weights.map { $0 / total }
        // Top-p: the smallest prefix whose mass reaches topP.
        var kept = weights.count
        if settings.topP < 1 {
            var mass = 0.0
            for (index, weight) in weights.enumerated() {
                mass += weight
                if mass >= settings.topP {
                    kept = index + 1
                    break
                }
            }
        }
        let keptMass = weights.prefix(kept).reduce(0, +)
        var target = uniform() * keptMass
        for index in 0..<kept {
            target -= weights[index]
            if target < 0 { return best[index].id }
        }
        return best[kept - 1].id
    }
}

/// Constrained decoding for "pick songs by number" (the local model's stand-in for the system model's guided
/// generation): the model can only write distinct numbers from 1 to `poolSize`, separated by commas (a space after
/// a comma optional), between `minimum` and `maximum` of them, then stop. Numbers are written digit by digit (Qwen's
/// pre-tokeniser splits every digit), so the allowed tokens are the digits, the comma, the space and the end token.
public struct NumberListConstraint: Sendable, Equatable {
    public struct Tokens: Sendable, Equatable {
        /// The ids of "0" … "9".
        public var digits: [Int]
        public var comma: Int
        public var space: Int
        public var end: Int

        public init(digits: [Int], comma: Int, space: Int, end: Int) {
            self.digits = digits
            self.comma = comma
            self.space = space
            self.end = end
        }
    }

    public let poolSize: Int
    public let minimum: Int
    public let maximum: Int
    public let tokens: Tokens

    public private(set) var picks: [Int] = []
    public private(set) var isFinished = false
    private var used: Set<Int> = []
    /// The number being written (nil between numbers).
    private var current: Int?
    private var afterComma = false

    public init(poolSize: Int, minimum: Int, maximum: Int, tokens: Tokens) {
        precondition(tokens.digits.count == 10)
        self.poolSize = max(poolSize, 0)
        self.maximum = min(max(maximum, 0), self.poolSize)
        self.minimum = min(max(minimum, 0), self.maximum)
        self.tokens = tokens
        if self.maximum == 0 { isFinished = true }
    }

    /// The tokens the model may write next (empty once finished).
    public func allowedTokens() -> [Int] {
        guard !isFinished else { return [] }
        var allowed: [Int] = []
        if let current {
            for digit in 0...9 where hasUnusedNumber(withPrefix: current * 10 + digit) { allowed.append(tokens.digits[digit]) }
            if isPickable(current) {
                if picks.count + 1 < maximum { allowed.append(tokens.comma) }
                if picks.count + 1 >= minimum { allowed.append(tokens.end) }
            }
        } else {
            if picks.count >= maximum || used.count >= poolSize { return [tokens.end] }
            for digit in 1...9 where hasUnusedNumber(withPrefix: digit) { allowed.append(tokens.digits[digit]) }
            if afterComma { allowed.append(tokens.space) }
            if !afterComma, picks.count >= minimum { allowed.append(tokens.end) }
        }
        return allowed
    }

    /// Records the token the model wrote (one of `allowedTokens()`).
    public mutating func accept(_ token: Int) {
        guard !isFinished else { return }
        if let digit = tokens.digits.firstIndex(of: token) {
            current = (current ?? 0) * 10 + digit
            afterComma = false
        } else if token == tokens.comma {
            commit()
            afterComma = true
        } else if token == tokens.space {
            afterComma = false
        } else if token == tokens.end {
            commit()
            isFinished = true
        }
    }

    private mutating func commit() {
        if let value = current, isPickable(value) {
            picks.append(value)
            used.insert(value)
        }
        current = nil
    }

    private func isPickable(_ value: Int) -> Bool { value >= 1 && value <= poolSize && !used.contains(value) }

    /// Whether some unused number in 1…poolSize starts with the digits of `prefix`.
    func hasUnusedNumber(withPrefix prefix: Int) -> Bool {
        guard prefix >= 1, prefix <= poolSize else { return false }
        var low = prefix
        var high = prefix
        while low <= poolSize {
            let upper = min(high, poolSize)
            if upper - low + 1 > used.filter({ $0 >= low && $0 <= upper }).count { return true }
            guard low <= poolSize / 10 else { break }
            low *= 10
            high = high * 10 + 9
        }
        return false
    }
}
