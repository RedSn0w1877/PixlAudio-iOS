import Foundation
import Testing
@testable import PixlLibrary

/// "Let Taizo help the engine" (docs/brain-spec.md, 9.4, stage 4 milestone 2): the optional weekly batch jobs run over real record files with a
/// fake assistant. A port of Android's `AssistantHelp` checks: nothing is asked while the switch is off, an answer is data (an id off the
/// track's shortlist is dropped), the same input is never asked twice, and turning the switch off takes the written genres back out.
@Suite("Assistant help")
struct AssistantHelpTests {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on: Bool
        init(_ on: Bool) { self.on = on }
        var value: Bool {
            get { lock.withLock { on } }
            set { lock.withLock { on = newValue } }
        }
    }

    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [(system: String, prompt: String, maxTokens: Int)] = []
        func add(_ system: String, _ prompt: String, _ maxTokens: Int) { lock.withLock { list.append((system, prompt, maxTokens)) } }
        var all: [(system: String, prompt: String, maxTokens: Int)] { lock.withLock { list } }
    }

    private let answered = DnaSource.deezer | DnaSource.musicbrainz | DnaSource.itunes

    /// The ids the test lists as the genres the listener plays: shown atlas genres, so a shortlist has six or more.
    private func playedGenres(_ atlas: GenreAtlas) -> [Int] {
        Array(atlas.allIds.filter { AtlasNames.genreName(atlas, $0) != nil }.prefix(8))
    }

    private struct Rig {
        let help: AssistantHelp
        let cache: AssistCache
        let dna: DnaRepository
        let allowed: Flag
        let mayAsk: Flag
        let asked: Asked
        let allowedIds: [Int]
        let directory: URL
    }

    private func rig(answer: @escaping @Sendable (String) -> String?) async throws -> Rig {
        let dir = BrainStage2bM2Tests.tempDirectory("assist-help")
        let atlas = KnowledgeFixtures.atlas
        let dna = DnaRepository(directory: dir)
        let allowed = Flag(true), mayAsk = Flag(true)
        let asked = Asked()
        let cache = AssistCache(file: dir.appendingPathComponent(AssistCache.fileName), modelId: "test-model", allowed: { allowed.value })
        let genres = playedGenres(atlas)
        let host = AssistantHelp.Host(
            allowed: { allowed.value }, mayAsk: { mayAsk.value },
            ask: { system, prompt, maxTokens in
                asked.add(system, prompt, maxTokens)
                return answer(prompt)
            },
            listenerGenres: { genres }, resolve: { _ in [] }, trackOf: { _ in nil })
        let islands = IslandStore(directory: dir, state: StateValues(get: { _ in nil }, set: { _, _ in }))
        let help = AssistantHelp(host: host, cache: cache, islands: islands, atlas: FixtureAtlas(), dna: dna, clock: { 1_000 })
        return Rig(help: help, cache: cache, dna: dna, allowed: allowed, mayAsk: mayAsk, asked: asked, allowedIds: genres, directory: dir)
    }

    private func untaggedRow(_ rid: Int64) -> TrackDnaRow {
        TrackDnaRow(rid: rid, artistIds: "7", title: "A Song \(rid)", artistDisplay: "An Artist", fetchedMask: answered)
    }

    private func answerFor(_ ids: [Int]) -> @Sendable (String) -> String? {
        // Index 0 gets one id from its own shortlist and one that is not on it (which must be dropped).
        let good = ids[0], bad = ids.max()! + 1_000
        return { _ in "{\"tracks\":[{\"i\":0,\"tags\":[{\"id\":\(good),\"c\":0.8},{\"id\":\(bad),\"c\":0.9}]}]}" }
    }

    @Test func nothingIsAskedWhileTheSwitchIsOff() async throws {
        let r = try await rig(answer: { _ in nil })
        defer { try? FileManager.default.removeItem(at: r.directory) }
        await r.dna.upsert(track: untaggedRow(1), artist: nil)
        r.allowed.value = false
        let report = await r.help.run(playing: { false })
        #expect(r.asked.all.isEmpty)
        #expect(report.calls == 0 && report.tracksTagged == 0)
    }

    @Test func nothingIsAskedWhenTheAssistantsOwnDoorIsClosed() async throws {
        let r = try await rig(answer: { _ in nil })
        defer { try? FileManager.default.removeItem(at: r.directory) }
        await r.dna.upsert(track: untaggedRow(1), artist: nil)
        r.mayAsk.value = false
        _ = await r.help.run(playing: { false })
        #expect(r.asked.all.isEmpty)
        // And never while music is playing.
        r.mayAsk.value = true
        _ = await r.help.run(playing: { true })
        #expect(r.asked.all.isEmpty)
    }

    @Test func aTrackNoSourceKnowsGetsOnlyGenresFromItsOwnShortlistAndTheSameTrackIsNotAskedTwice() async throws {
        let ids = playedGenres(KnowledgeFixtures.atlas)
        let r = try await rig(answer: answerFor(ids))
        defer { try? FileManager.default.removeItem(at: r.directory) }
        await r.dna.upsert(track: untaggedRow(1), artist: nil)
        let first = await r.help.run(playing: { false })
        #expect(first.calls == 1 && first.tracksTagged == 1, "report: \(first)")
        let call = try #require(r.asked.all.first)
        #expect(call.maxTokens == AssistantHelp.maxTokensTags)
        #expect(call.prompt.contains("A Song 1 - An Artist"))
        let row = try #require(await r.dna.track(1))
        // The claim is kept beside the other sources' (it is the weakest source: whether it tips the merged tags is `Tags.merge`'s own rule).
        let claims = DnaAssembler.decodeClaims([UInt8](row.tagInputs)).filter { $0.provider == DnaAssembler.pAssistant }
        #expect(claims.map(\.atlasId) == [ids[0]], "an id off the shortlist is dropped, never written")
        #expect(claims.first?.conf == 204)
        // The same input is answered from the cache: no second call, even after the row was tagged by the job.
        let second = await r.help.run(playing: { false })
        #expect(second.calls == 0)
        #expect(r.asked.all.count == 1)
        let stored = await r.cache.read()
        #expect(stored.tagRids == [1])
    }

    @Test func anAnswerThatIsNotJsonIsStoredAsAskedWithNothingUsable() async throws {
        let r = try await rig(answer: { _ in "I could not do that." })
        defer { try? FileManager.default.removeItem(at: r.directory) }
        await r.dna.upsert(track: untaggedRow(1), artist: nil)
        let first = await r.help.run(playing: { false })
        #expect(first.calls == 1 && first.tracksTagged == 0)
        #expect(try #require(await r.dna.track(1)).tags.isEmpty)
        let again = await r.help.run(playing: { false })
        #expect(again.calls == 0, "an answer that did not validate is not asked for again")
    }

    @Test func turningTheSwitchOffTakesTheWrittenGenresBackOut() async throws {
        let ids = playedGenres(KnowledgeFixtures.atlas)
        let r = try await rig(answer: answerFor(ids))
        defer { try? FileManager.default.removeItem(at: r.directory) }
        await r.dna.upsert(track: untaggedRow(1), artist: nil)
        _ = await r.help.run(playing: { false })
        let before = DnaAssembler.decodeClaims([UInt8](try #require(await r.dna.track(1)).tagInputs))
        #expect(before.contains { $0.provider == DnaAssembler.pAssistant })
        r.allowed.value = false
        let off = await r.help.run(playing: { false })
        #expect(off.tagsTakenBack == 1)
        let row = try #require(await r.dna.track(1))
        #expect(DnaAssembler.decodeClaims([UInt8](row.tagInputs)).allSatisfy { $0.provider != DnaAssembler.pAssistant }, "the assistant's claims left with the switch")
        #expect(row.tags.isEmpty)
        #expect(await r.cache.read().tagRids.isEmpty)
        #expect(r.asked.all.count == 1, "turning it off asks nothing")
    }

    @Test func theCacheGivesNothingWhileTheSwitchIsOffAndOnlyWhatWasWrittenForTheSameGenres() async throws {
        let dir = BrainStage2bM2Tests.tempDirectory("assist-cache")
        defer { try? FileManager.default.removeItem(at: dir) }
        let on = Flag(true)
        let cache = AssistCache(file: dir.appendingPathComponent(AssistCache.fileName), modelId: "m1", allowed: { on.value })
        let key = await cache.keyOf("island", AssistCache.islandInput(id: 3, genreNames: ["Trap", "Rap"]))
        await cache.update { $0.islands[key] = AssistCache.IslandAnswer(name: "Late trap", line: "Slow and dark.") }
        #expect(await cache.islandName(id: 3, genreNames: ["Trap", "Rap"]) == "Late trap")
        #expect(await cache.islandName(id: 3, genreNames: ["Trap", "Soul"]) == nil, "written for other genres")
        #expect(await cache.islandName(id: 4, genreNames: ["Trap", "Rap"]) == nil)
        on.value = false
        #expect(await cache.islandName(id: 3, genreNames: ["Trap", "Rap"]) == nil, "the switch is off")
        #expect(await cache.suggestedRows().isEmpty)
        // A saved file comes back; a different model asks again.
        on.value = true
        let reopened = AssistCache(file: dir.appendingPathComponent(AssistCache.fileName), modelId: "m1", allowed: { on.value })
        #expect(await reopened.islandName(id: 3, genreNames: ["Trap", "Rap"]) == "Late trap")
        let otherModel = AssistCache(file: dir.appendingPathComponent(AssistCache.fileName), modelId: "m2", allowed: { on.value })
        #expect(await otherModel.islandName(id: 3, genreNames: ["Trap", "Rap"]) == nil)
    }

    @Test func theInstructionsNeverNameTheVendorOrAProduct() {
        for text in [AssistantHelp.islandSystem, AssistantHelp.tagSystem, AssistantHelp.askSystem, WeeklyNoteService.system] {
            let lower = text.lowercased()
            for word in ["claude", "anthropic", "lossless", "hi-res", "dolby", "atmos", "binilyrics", "enhanced"] {
                #expect(!lower.contains(word), "an instruction says \(word)")
            }
        }
    }

    @Test func theRemoteSwitchTurnsTheJobsOffOnlyWhenItSaysFalse() {
        #expect(BrainRemoteConfig.assistAllowed(configText: nil))
        #expect(BrainRemoteConfig.assistAllowed(configText: ""))
        #expect(BrainRemoteConfig.assistAllowed(configText: "not json"))
        #expect(BrainRemoteConfig.assistAllowed(configText: "{\"brain\":{\"refresh\":{\"enabled\":false}}}"))
        #expect(BrainRemoteConfig.assistAllowed(configText: "{\"brain\":{\"assist\":{\"enabled\":true}}}"))
        #expect(!BrainRemoteConfig.assistAllowed(configText: "{\"brain\":{\"assist\":{\"enabled\":false}}}"))
    }
}
