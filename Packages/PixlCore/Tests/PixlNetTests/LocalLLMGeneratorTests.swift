import Foundation
import Testing
@testable import PixlNet

/// The local model's generation loop (2026-10-07, local AI phase 2) against a scripted model that keeps its own
/// "cache" rows and fails the test whenever a step reads a row nobody wrote: prefix reuse, chunked prefill, stop
/// tokens and conditions, length limits, cancellation, bad numerics, the constrained number list; plus prompt
/// fitting, plan parsing and the causal mask.
@Suite("Local LLM generation")
struct LocalLLMGeneratorTests {
    /// Favors one next token, computed from the whole sequence its cache holds; records every step.
    final class ScriptedModel: CausalLanguageModel {
        let contextLength: Int
        let maxQueryLength: Int
        let vocabularySize: Int
        var rows: [Int?]
        var calls: [(tokens: [Int], past: Int)] = []
        var next: ([Int]) -> Int
        var poison = false

        init(context: Int = 64, maxQuery: Int = 16, vocabulary: Int = 32, next: @escaping ([Int]) -> Int) {
            contextLength = context
            maxQueryLength = maxQuery
            vocabularySize = vocabulary
            rows = [Int?](repeating: nil, count: context)
            self.next = next
        }

        func step(_ tokens: ArraySlice<Int>, past: Int, logits: inout [Float]) throws {
            precondition(tokens.count <= maxQueryLength && past + tokens.count <= contextLength)
            calls.append((Array(tokens), past))
            for (offset, token) in tokens.enumerated() { rows[past + offset] = token }
            let sequence = rows[0..<(past + tokens.count)].map { row -> Int in
                guard let row else {
                    Issue.record("a step read a cache row that was never written")
                    return -1
                }
                return row
            }
            for index in logits.indices { logits[index] = 0 }
            logits[next(sequence)] = 10
            if poison { logits[3] = .nan }
        }
    }

    static func counting(_ sequence: [Int]) -> Int { ((sequence.last ?? 0) + 1) % 32 }

    static func request(_ prompt: [Int], max: Int = 8, stop: Set<Int> = [31]) -> LocalGenerationRequest {
        LocalGenerationRequest(prompt: prompt, maxNewTokens: max, sampling: .greedy, stopTokens: stop, prefillChunk: 4)
    }

    @Test func greedyFollowsTheModelUntilAStopToken() throws {
        let model = ScriptedModel(next: Self.counting)
        let generator = LocalLLMGenerator(model: model)
        let result = try generator.generate(Self.request([25, 26, 27], max: 20))
        // 28, 29, 30, then 31 (the stop token, not part of the answer).
        #expect(result.tokens == [28, 29, 30])
        #expect(result.finish == .stop)
        #expect(result.promptTokens == 3 && result.reusedTokens == 0)
        // Every answer token was fed (its logits chose the next); the stop token never is.
        #expect(generator.cachedTokens == [25, 26, 27, 28, 29, 30])
    }

    @Test func prefillsInChunksThenDecodesOneTokenAtATime() throws {
        let model = ScriptedModel(next: { _ in 5 })
        let generator = LocalLLMGenerator(model: model)
        let result = try generator.generate(Self.request(Array(0..<10), max: 3))
        #expect(result.tokens == [5, 5, 5] && result.finish == .length)
        #expect(model.calls.map { $0.past } == [0, 4, 8, 10, 11])
        #expect(model.calls.map { $0.tokens.count } == [4, 4, 2, 1, 1])
    }

    @Test func reusesTheCachedPrefix() throws {
        let model = ScriptedModel(next: { _ in 5 })
        let generator = LocalLLMGenerator(model: model)
        _ = try generator.generate(Self.request([1, 2, 3, 4, 6, 7], max: 2))
        model.calls.removeAll()
        // Shares [1, 2, 3, 4] with the cache.
        let second = try generator.generate(Self.request([1, 2, 3, 4, 9, 9, 9], max: 1))
        #expect(second.reusedTokens == 4)
        #expect(model.calls.first?.past == 4)
        model.calls.removeAll()
        // The same prompt again: only its last token is fed (for its logits).
        let third = try generator.generate(Self.request([1, 2, 3, 4, 9, 9, 9], max: 1))
        #expect(third.reusedTokens == 6)
        #expect(model.calls.count == 1 && model.calls[0].past == 6 && model.calls[0].tokens == [9])
    }

    @Test func aContinuedConversationFeedsOnlyTheNewTurn() throws {
        let model = ScriptedModel(next: Self.counting)
        let generator = LocalLLMGenerator(model: model)
        let first = try generator.generate(Self.request([10, 11], max: 3))
        #expect(first.tokens == [12, 13, 14])
        model.calls.removeAll()
        // The next prompt is the first one, its answer, and a new message.
        let second = try generator.generate(Self.request([10, 11, 12, 13, 14, 20, 21], max: 1))
        #expect(second.reusedTokens == 4)
        #expect(model.calls.first?.tokens == [14, 20, 21])
    }

    @Test func refusesAPromptThatLeavesNoRoom() {
        let model = ScriptedModel(context: 16, next: { _ in 1 })
        let generator = LocalLLMGenerator(model: model)
        #expect(throws: LocalGenerationError.promptTooLong(tokens: 12, limit: 16)) {
            try generator.generate(Self.request(Array(0..<12)))
        }
        #expect(model.calls.isEmpty)
    }

    @Test func theAnswerStopsAtTheEndOfTheContext() throws {
        let model = ScriptedModel(context: 16, next: { _ in 1 })
        let generator = LocalLLMGenerator(model: model)
        var request = Self.request(Array(0..<6), max: 100)
        request.minimumAnswerTokens = 4
        let result = try generator.generate(request)
        #expect(result.tokens.count == 10 && result.finish == .length)
        #expect(model.calls.allSatisfy { $0.past + $0.tokens.count <= 16 })
    }

    @Test func stopsWhenTheCallerSaysSo() throws {
        let model = ScriptedModel(next: Self.counting)
        let generator = LocalLLMGenerator(model: model)
        let result = try generator.generate(Self.request([1], max: 20), stopWhen: { $0.contains(4) })
        #expect(result.tokens == [2, 3, 4] && result.finish == .condition)
    }

    @Test func cancellationStopsBetweenStepsAndKeepsTheCacheUsable() throws {
        let model = ScriptedModel(next: Self.counting)
        let generator = LocalLLMGenerator(model: model)
        var steps = 0
        do {
            _ = try generator.generate(Self.request(Array(0..<10), max: 20), isCancelled: {
                steps += 1
                return steps > 2
            })
            Issue.record("the generation was not cancelled")
        } catch {
            #expect(error as? LocalGenerationError == .cancelled)
        }
        // Two prefill chunks went in before the cancellation: their rows stay valid for the next request.
        #expect(generator.cachedTokens == Array(0..<8))
        model.calls.removeAll()
        let result = try generator.generate(Self.request(Array(0..<10), max: 2))
        #expect(result.reusedTokens == 8)
        #expect(result.tokens == [10, 11])
    }

    @Test func nanLogitsFailAndForgetTheCache() {
        let model = ScriptedModel(next: { _ in 2 })
        model.poison = true
        let generator = LocalLLMGenerator(model: model)
        #expect(throws: LocalGenerationError.nonFiniteLogits) {
            try generator.generate(Self.request([1, 2, 3]))
        }
        #expect(generator.cachedTokens.isEmpty)
    }

    @Test func bannedTokensAreNeverWritten() throws {
        let model = ScriptedModel(next: { _ in 7 })
        let generator = LocalLLMGenerator(model: model)
        var request = Self.request([1], max: 3)
        request.bannedTokens = [7]
        let result = try generator.generate(request)
        #expect(!result.tokens.contains(7))
        #expect(result.tokens.count == 3)
    }

    @Test func theNumberListConstrainsWhateverTheModelWants() throws {
        // Digits 0-9 are ids 0-9, the comma 10, the space 11, the end 12 (also the stop token).
        let tokens = NumberListConstraint.Tokens(digits: Array(0...9), comma: 10, space: 11, end: 12)
        // The model always wants "1", then a comma: a list of distinct numbers still comes out.
        let model = ScriptedModel(vocabulary: 32, next: { sequence in sequence.last == 1 ? 10 : 1 })
        let generator = LocalLLMGenerator(model: model)
        var request = Self.request([20, 21], max: 30, stop: [12])
        request.numberList = NumberListConstraint(poolSize: 12, minimum: 2, maximum: 3, tokens: tokens)
        let result = try generator.generate(request)
        let picks = try #require(result.picks)
        #expect(picks.count >= 2 && picks.count <= 3)
        #expect(Set(picks).count == picks.count)
        #expect(picks.allSatisfy { (1...12).contains($0) })
        #expect(result.finish == .numberList)
        #expect(picks.first == 1)
    }

    @Test func throughputCountsDecodedTokens() {
        let result = LocalGenerationResult(tokens: [1, 2, 3, 4, 5], finish: .length, picks: nil, promptTokens: 3,
                                           reusedTokens: 0, prefillSeconds: 1, decodeSeconds: 2)
        #expect(result.tokensPerSecond == 2)
    }

    // MARK: Prompt fitting

    @Test func fittingDropsTheOldestTurnsFirst() throws {
        let turns = [(user: "one", reply: "1"), (user: "two", reply: "2"), (user: "three", reply: "3")]
        let count: ([ChatMLTemplate.Message]) -> Int = { $0.count * 10 }
        // System + new message = 20; each turn adds 20.
        let all = try #require(ChatMLTemplate.fit(system: "s", turns: turns, message: "m", budget: 80, count: count))
        #expect(all.count == 8)
        let two = try #require(ChatMLTemplate.fit(system: "s", turns: turns, message: "m", budget: 79, count: count))
        #expect(two.map(\.content) == ["s", "two", "2", "three", "3", "m"])
        let none = try #require(ChatMLTemplate.fit(system: "s", turns: turns, message: "m", budget: 25, count: count))
        #expect(none.map(\.content) == ["s", "m"])
        #expect(ChatMLTemplate.fit(system: "s", turns: turns, message: "m", budget: 19, count: count) == nil)
    }

    // MARK: Plans

    @Test func plansKeepOnlyTheLibrarysValues() {
        let text = """
            Here is the plan:
            genres: indie, Jazz Fusion, ROCK
            artists: "Phoebe Bridgers", Taylor Swift, the national
            moods: rainy, calm, cozy, sleepy
            energy: 2 (calm)
            familiar: no
            """
        let plan = LocalPlanText.parse(text, allowedGenres: ["Rock", "Indie", "Folk"],
                                       allowedArtists: ["Phoebe Bridgers", "The National", "Bon Iver"])
        #expect(plan.genres == ["Indie", "Rock"])
        #expect(plan.artists == ["Phoebe Bridgers", "The National"])
        #expect(plan.moods == ["rainy", "calm", "cozy"])
        #expect(plan.energy == 2)
        #expect(plan.familiar == false)
    }

    @Test func anUnreadablePlanKeepsItsDefaults() {
        let plan = LocalPlanText.parse("I'd love to help!", allowedGenres: ["Rock"], allowedArtists: [])
        #expect(plan == LocalPlanText())
        let clamped = LocalPlanText.parse("energy: 9\ngenres: none", allowedGenres: ["Rock"], allowedArtists: [])
        #expect(clamped.energy == 5 && clamped.genres.isEmpty)
    }

    // MARK: Mask

    @Test func theCausalMaskAttendsToThePastAndItself() {
        let mask = CausalMask.values(past: 2, count: 2)
        // Row 0 sees columns 0...2, row 1 sees 0...3.
        #expect(mask.map { $0 == 0 } == [true, true, true, false, true, true, true, true])
        #expect(mask[3] == -.infinity)
        #expect(CausalMask.values(past: 5, count: 1) == [0, 0, 0, 0, 0, 0])
    }
}
