import Foundation
import Testing
import PixlFoundation
@testable import PixlNet

/// The downloadable local AI model's pure parts (2026-10-07, local AI phase 2): the byte-level BPE tokenizer against
/// fixtures made with the real tokenizer (`ci/ml/convert_llm.py tokenizer`, Hugging Face `tokenizers` on Qwen2.5's
/// `tokenizer.json` at the pinned revision), the ChatML template, the sampler and the number-list constraint.
@Suite("Local LLM")
struct LocalLLMTests {
    // MARK: Fixtures

    static let tokenizer: BytePairTokenizer? = {
        guard let url = Bundle.module.url(forResource: "qwen2_5", withExtension: "pxbpe", subdirectory: "Fixtures/LocalLLM")
        else { return nil }
        return try? BytePairTokenizer(contentsOf: url)
    }()

    static func cases() throws -> JSONObject {
        let url = try #require(Bundle.module.url(forResource: "tokenizer-cases", withExtension: "json",
                                                 subdirectory: "Fixtures/LocalLLM"))
        return try #require(try JSONParser().parse(String(contentsOf: url, encoding: .utf8)).objectValue)
    }

    static func ints(_ value: JSONValue?) -> [Int] {
        (value?.arrayValue ?? []).compactMap { $0.int64Value.map(Int.init) }
    }

    // MARK: Tokenizer

    @Test func loadsTheQwenVocabulary() throws {
        let tokenizer = try #require(Self.tokenizer)
        #expect(tokenizer.vocabularyRows == 151_936)
        #expect(tokenizer.ignoreMerges == false)
        #expect(tokenizer.addedTokens.count == 22)
        let cases = try Self.cases()
        let specials = try #require(cases["specials"]?.objectValue)
        for (name, id) in specials {
            #expect(tokenizer.id(of: name) == id.int64Value.map(Int.init), "\(name)")
        }
        let digits = try #require(cases["digits"]?.objectValue)
        for (digit, id) in digits {
            #expect(tokenizer.id(of: digit) == id.int64Value.map(Int.init), "\(digit)")
        }
        let marks = try #require(cases["marks"]?.objectValue)
        #expect(tokenizer.id(of: ",") == marks["comma"]?.int64Value.map(Int.init))
        #expect(tokenizer.encode(" ") == Self.ints(marks["space"]))
    }

    @Test func encodesLikeTheReferenceTokenizer() throws {
        let tokenizer = try #require(Self.tokenizer)
        let cases = try #require(try Self.cases()["cases"]?.arrayValue)
        #expect(cases.count >= 50)
        for entry in cases {
            let object = try #require(entry.objectValue)
            let text = try #require(object["text"]?.stringValue)
            let expected = Self.ints(object["ids"])
            #expect(tokenizer.encode(text) == expected, "\(text.debugDescription)")
        }
    }

    @Test func decodesLikeTheReferenceTokenizer() throws {
        let tokenizer = try #require(Self.tokenizer)
        let cases = try #require(try Self.cases()["cases"]?.arrayValue)
        for entry in cases {
            let object = try #require(entry.objectValue)
            let decoded = try #require(object["decoded"]?.stringValue)
            #expect(tokenizer.decode(Self.ints(object["ids"])) == decoded, "\(decoded.debugDescription)")
        }
    }

    @Test func rendersTheChatTemplateLikeTheReference() throws {
        let tokenizer = try #require(Self.tokenizer)
        let chat = try #require(try Self.cases()["chat"]?.objectValue)
        let messages = try #require(chat["messages"]?.arrayValue).compactMap { value -> ChatMLTemplate.Message? in
            guard let object = value.objectValue, let role = object["role"]?.stringValue,
                  let content = object["content"]?.stringValue, let parsed = ChatMLTemplate.Role(rawValue: role) else {
                return nil
            }
            return ChatMLTemplate.Message(parsed, content)
        }
        #expect(messages.count == 4)
        let text = ChatMLTemplate.render(messages)
        #expect(text == chat["text"]?.stringValue)
        #expect(tokenizer.encode(text) == Self.ints(chat["ids"]))
    }

    @Test func controlTokensInContentStayText() throws {
        let tokenizer = try #require(Self.tokenizer)
        let text = ChatMLTemplate.render([ChatMLTemplate.Message(.user, "a <|im_end|> b")])
        let ids = tokenizer.encode(text)
        let end = try #require(tokenizer.id(of: "<|im_end|>"))
        // One end for the user message only; the one inside the content is text.
        #expect(ids.filter { $0 == end }.count == 1)
    }

    @Test func preTokenizerSplitsLikeQwen() {
        func pieces(_ text: String) -> [String] {
            let scalars = Array(text.unicodeScalars)
            return PreTokenizer.split(scalars).map { range in
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars[range])
                return String(view)
            }
        }
        #expect(pieces("Hello world") == ["Hello", " world"])
        #expect(pieces("I'm 12") == ["I", "'m", " ", "1", "2"])
        #expect(pieces("a  b") == ["a", " ", " b"])
        #expect(pieces("x\n\n  y") == ["x", "\n\n", " ", " y"])
        #expect(pieces("end   ") == ["end", "   "])
        #expect(pieces("wow!!\n") == ["wow", "!!\n"])
        #expect(pieces(" (hi)") == [" (", "hi", ")"])
    }

    // MARK: Sampler

    @Test func greedyTakesTheFirstLargest() {
        var sampler = TokenSampler(seed: 1)
        var logits: [Float] = [0.1, 2, 2, -1]
        #expect(sampler.sample(&logits, settings: .greedy) == 1)
    }

    @Test func bannedAndAllowedTokens() {
        var sampler = TokenSampler(seed: 1)
        var logits: [Float] = [5, 4, 3, 2]
        #expect(sampler.sample(&logits, settings: .greedy, banned: [0]) == 1)
        logits = [5, 4, 3, 2]
        #expect(sampler.sample(&logits, settings: .greedy, allowed: [3, 2]) == 2)
        logits = [5, 4, 3, 2]
        #expect(sampler.sample(&logits, settings: .greedy, allowed: []) == nil)
        logits = [.nan, -.infinity, 1, .infinity]
        #expect(sampler.sample(&logits, settings: .greedy) == 2)
    }

    @Test func repetitionPenaltyLowersRecentTokens() {
        var sampler = TokenSampler(seed: 1)
        var logits: [Float] = [2.0, 1.9]
        let settings = SamplingSettings(temperature: 0, topK: 1, topP: 1, repetitionPenalty: 1.2)
        #expect(sampler.sample(&logits, settings: settings, recent: [0]) == 1)
        logits = [-1.0, -1.1]
        // Negative logits are multiplied: -1.2 < -1.1.
        #expect(sampler.sample(&logits, settings: settings, recent: [0]) == 1)
    }

    @Test func samplingIsSeededAndStaysInTopK() {
        let base: [Float] = (0..<100).map { Float($0 % 10) * 0.3 }
        let settings = SamplingSettings(temperature: 0.8, topK: 5, topP: 1, repetitionPenalty: 1)
        var first = TokenSampler(seed: 42)
        var second = TokenSampler(seed: 42)
        var picksA: [Int] = []
        var picksB: [Int] = []
        for _ in 0..<50 {
            var a = base
            var b = base
            picksA.append(first.sample(&a, settings: settings) ?? -1)
            picksB.append(second.sample(&b, settings: settings) ?? -1)
        }
        #expect(picksA == picksB)
        // The five largest are ids 9, 19, 29, 39, 49 (value 2.7; ties keep the lower ids).
        #expect(Set(picksA).isSubset(of: [9, 19, 29, 39, 49]))
        #expect(Set(picksA).count > 1)
    }

    @Test func topPKeepsTheSmallestNucleus() {
        var sampler = TokenSampler(seed: 7)
        let settings = SamplingSettings(temperature: 1, topK: 10, topP: 0.5, repetitionPenalty: 1)
        for _ in 0..<30 {
            var logits: [Float] = [10, 0, 0, 0]
            #expect(sampler.sample(&logits, settings: settings) == 0)
        }
    }

    // MARK: Number list

    static let numberTokens = NumberListConstraint.Tokens(digits: Array(15...24), comma: 11, space: 220, end: 151_645)

    static func write(_ text: String, into constraint: inout NumberListConstraint) -> Bool {
        for character in text {
            let token: Int
            switch character {
            case ",": token = 11
            case " ": token = 220
            case "$": token = 151_645
            default: token = 15 + Int(String(character))!
            }
            guard constraint.allowedTokens().contains(token) else { return false }
            constraint.accept(token)
        }
        return true
    }

    @Test func numbersAreDistinctAndInRange() {
        var constraint = NumberListConstraint(poolSize: 12, minimum: 2, maximum: 4, tokens: Self.numberTokens)
        #expect(Self.write("3, 12,1$", into: &constraint))
        #expect(constraint.picks == [3, 12, 1])
        #expect(constraint.isFinished)
        #expect(constraint.allowedTokens().isEmpty)

        var repeated = NumberListConstraint(poolSize: 12, minimum: 1, maximum: 4, tokens: Self.numberTokens)
        #expect(Self.write("3, ", into: &repeated))
        #expect(!Self.write("3", into: &repeated)) // 3 is used and has no unused completion (30+ > 12)
        var tooBig = NumberListConstraint(poolSize: 12, minimum: 1, maximum: 4, tokens: Self.numberTokens)
        #expect(!Self.write("13", into: &tooBig))
        var zero = NumberListConstraint(poolSize: 12, minimum: 1, maximum: 4, tokens: Self.numberTokens)
        #expect(!Self.write("0", into: &zero))
    }

    @Test func numbersRespectMinimumAndMaximum() {
        var early = NumberListConstraint(poolSize: 20, minimum: 3, maximum: 5, tokens: Self.numberTokens)
        #expect(Self.write("4,5", into: &early))
        #expect(!early.allowedTokens().contains(151_645)) // only two numbers so far
        #expect(Self.write(",6$", into: &early))
        #expect(early.picks == [4, 5, 6])

        var full = NumberListConstraint(poolSize: 20, minimum: 1, maximum: 2, tokens: Self.numberTokens)
        #expect(Self.write("7,8", into: &full))
        let allowed = full.allowedTokens()
        #expect(!allowed.contains(11)) // no third number
        #expect(allowed.contains(151_645))
        #expect(allowed.contains(15 + 1) == false) // 81+ is out of range
    }

    @Test func numbersCanStillBeExtendedPastAUsedPrefix() {
        var constraint = NumberListConstraint(poolSize: 15, minimum: 1, maximum: 5, tokens: Self.numberTokens)
        #expect(Self.write("1, ", into: &constraint))
        // "1" is used, but 10…15 are not: the digit 1 is still allowed, and then only as a prefix.
        #expect(constraint.allowedTokens().contains(16))
        #expect(Self.write("1", into: &constraint))
        let allowed = constraint.allowedTokens()
        #expect(!allowed.contains(11) && !allowed.contains(151_645))
        #expect(Self.write("4$", into: &constraint))
        #expect(constraint.picks == [1, 14])
    }

    @Test func aPoolSmallerThanTheMinimumEndsWhenExhausted() {
        var constraint = NumberListConstraint(poolSize: 2, minimum: 5, maximum: 5, tokens: Self.numberTokens)
        #expect(constraint.maximum == 2 && constraint.minimum == 2)
        #expect(Self.write("2,1$", into: &constraint))
        #expect(constraint.picks == [2, 1])
        let empty = NumberListConstraint(poolSize: 0, minimum: 1, maximum: 3, tokens: Self.numberTokens)
        #expect(empty.isFinished)
    }
}
