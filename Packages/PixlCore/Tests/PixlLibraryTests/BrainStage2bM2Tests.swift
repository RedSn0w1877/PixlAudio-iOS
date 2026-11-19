import Foundation
import PixlFoundation
import PixlModel
import Testing
@testable import PixlLibrary

/// Stage 2b, milestone 2 (docs/brain-spec.md, 5.3, 5.4, 6.2, 8.1, 8.2): the island and embedding files, the island fit, the
/// made-for-you lists end to end over real record files, the Home plan, genre stations, the cold start and the setup of the
/// planner. A port of Android's `Stage2bMilestone2Test` and `Stage2bM2Test`. The pure functions are proven bit for bit by
/// `BrainStage2bM2GoldenTests`.
@Suite("Brain stage 2b milestone 2")
struct BrainStage2bM2Tests {
    typealias World = BrainMixesTests.World
    typealias Box<T: Sendable> = BrainMixesTests.Box<T>

    static func tempDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Valued state in memory: the stand-in for `brain_state`.
    final class Values: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: String] = [:]
        var state: StateValues {
            StateValues(get: { [self] key in lock.withLock { map[key] } }, set: { [self] key, value in lock.withLock { map[key] = value } })
        }
    }

    /// Tracks drawn around planted centres: each cluster has its own embedding direction and two atlas genres.
    static func planted(rids: [Int64], aids: [Int64], clusters: Int, seed: String, noise: Int = 8, interleaved: Bool = false) -> [Islands.Track] {
        var rng = BrainHash.Rng(seed: BrainHash.fnv1a64(seed))
        func int(_ n: Int) -> Int { min(Int(rng.uniform() * Double(n)), n - 1) }
        let centres: [[Int]] = (0..<clusters).map { _ in (0..<Embeddings.dim).map { _ in int(255) - 127 } }
        var out: [Islands.Track] = []
        for (k, rid) in rids.enumerated() {
            let c = interleaved ? k % clusters : k * clusters / rids.count
            let emb = (0..<Embeddings.dim).map { j -> UInt8 in
                var v = centres[c][j] + int(2 * noise + 1) - noise
                v = max(-127, min(127, v))
                return UInt8(bitPattern: Int8(v))
            }
            out.append(Islands.Track(rid: rid, aid: aids[k], weight: 1.0 + Double(int(40)) * 0.25, recentWeight: 0.0, emb: emb, tags: nil))
        }
        return out
    }

    // MARK: The files

    @Test func theIslandsAndTheEmbeddingsComeBackFromTheirFiles() async throws {
        let dir = Self.tempDirectory("islands")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rids = (0..<120).map { BrainHash.id(BrainHash.fnv1a64("rid \($0)")) }
        let aids = (0..<120).map { BrainHash.id(BrainHash.fnv1a64("aid \($0 % 9)")) }
        let tracks = Self.planted(rids: rids, aids: aids, clusters: 3, seed: "files")
        let fit = Islands.fit(tracks)
        #expect(fit.islands.count >= 2)
        let values = Values()
        let store = IslandStore(directory: dir, state: values.state)
        #expect(await store.current() == nil, "a stage 2a install has no islands")
        #expect(await store.save(fit, nowMs: 1_700_000_000_000))
        // A new store over the same files (a restart) reads the same islands, in the same order, with the same members.
        let again = IslandStore(directory: dir, state: values.state)
        let set = try #require(await again.current())
        #expect(set.islands.map(\.id) == fit.islands.map(\.id))
        #expect(set.islands.map(\.medoidRid) == fit.islands.map(\.medoidRid))
        #expect(set.islands[0].centroid == fit.islands[0].centroid, "the centroid survives bit for bit")
        #expect(set.islands.map(\.size) == fit.islands.map(\.size))
        #expect(set.fitAtMs == 1_700_000_000_000)
        #expect(set.memberOf[fit.memberRids[0]] == fit.memberIslandIds[0])
        #expect(set.memberOf.count == fit.memberRids.count)
        #expect(await again.lastId() == fit.maxId)
        // Embeddings: stored once, looked up for the ids asked for only.
        let graph = {
            var b = Graph.Builder()
            for i in 0..<119 { b.addEdge(rids[i], rids[i + 1], weight: 0.5); b.addEdge(rids[i], rids[(i * 7) % 120], weight: 0.4) }
            return b.build()
        }()
        let table = FastRp.embed(graph)
        await store.saveEmbeddings(table)
        let reopened = IslandStore(directory: dir, state: values.state)
        let some = try #require(await reopened.embeddingsFor([rids[3], rids[40], 12345]))
        #expect(some.size == 2 && some.vector(rids[3]) == table.vector(rids[3]) && some.vector(rids[40]) == table.vector(rids[40]))
        #expect(await reopened.embeddingCount() == table.size)
    }

    @Test func aFileThisCodeCannotReadIsNoIslandsAndNeverAnError() async throws {
        let dir = Self.tempDirectory("islands-bad")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("PEMB-not-a-table".utf8).write(to: dir.appendingPathComponent("node_embedding.bin"))
        try Data("garbage\n".utf8).write(to: dir.appendingPathComponent("island.pbl"))
        let store = IslandStore(directory: dir, state: Values().state)
        #expect(await store.current() == nil)
        #expect(await store.embeddingsFor([1, 2, 3]) == nil)
    }

    // MARK: The fit

    private func inputs(_ rids: [Int64], _ aids: [Int64], plays: Box<Int>, hasState: Bool = true, clock: Box<Int64>) -> IslandInputs {
        let songs = rids.indices.map { testSong("s\($0)", title: "Song \($0)", artist: "Artist \($0 % 9)") }
        let tracks = rids.indices.map { LibraryTrack(song: songs[$0], rid: rids[$0], aid: aids[$0], liked: false) }
        let planted = Self.planted(rids: rids, aids: aids, clusters: 3, seed: "builder")
        var edges: [MixPlanner.Edge] = []
        var rng = BrainHash.Rng(seed: BrainHash.fnv1a64("builder edges"))
        // Edges inside the planted clusters: the graph embedding then finds them.
        for c in 0..<3 {
            let members = rids.indices.filter { $0 * 3 / rids.count == c }
            for _ in 0..<members.count * 3 {
                let a = members[min(Int(rng.uniform() * Double(members.count)), members.count - 1)]
                let b = members[min(Int(rng.uniform() * Double(members.count)), members.count - 1)]
                if a != b { edges.append(MixPlanner.Edge(a: rids[a], b: rids[b], weight: 0.8)) }
            }
        }
        _ = planted
        let fixedEdges = edges
        return IslandInputs(
            library: { _ in tracks }, edges: { fixedEdges }, hasState: { hasState },
            weights: { asked, _ in
                var out: [Int64: [Double]] = [:]
                for (i, r) in rids.enumerated() where asked.contains(r) { out[r] = [2.0 + Double(i % 5), 0.0] }
                return out
            },
            qualifiedPlaysSince: { _ in plays.value }, tags: { _ in [:] }, clock: { clock.value })
    }

    @Test func theFitIsDueWeeklyOrAfterTwoHundredPlaysAndNeverWithoutState() async throws {
        let dir = Self.tempDirectory("builder")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rids = (0..<150).map { BrainHash.id(BrainHash.fnv1a64("b rid \($0)")) }
        let aids = (0..<150).map { BrainHash.id(BrainHash.fnv1a64("b aid \($0 % 15)")) }
        let plays = Box<Int>(0)
        let clock = Box<Int64>(1_700_000_000_000)
        let values = Values()
        let store = IslandStore(directory: dir, state: values.state)
        // No state: nothing is fitted.
        let off = IslandBuilder(store: store, inputs: inputs(rids, aids, plays: plays, hasState: false, clock: clock), state: values.state)
        #expect(await off.ensure() == nil)
        let builder = IslandBuilder(store: store, inputs: inputs(rids, aids, plays: plays, clock: clock), state: values.state)
        let first = try #require(await builder.ensure())
        #expect(!first.isEmpty)
        #expect(await store.embeddingCount() > 100, "the embeddings are saved with the islands")
        #expect(await values.state.get(IslandStore.keyFitAt) == String(clock.value))
        // Not due again at once; due after a week; due after 200 plays.
        #expect(await builder.isDue(nowMs: clock.value + 1000) == false)
        #expect(await builder.isDue(nowMs: clock.value + IslandBuilder.refitAgeMs + 1))
        plays.value = 200
        #expect(await builder.isDue(nowMs: clock.value + 1000))
        // A refit keeps the ids of the islands it finds again, and never reuses one.
        plays.value = 0
        clock.value += IslandBuilder.refitAgeMs + 10
        let second = try #require(await builder.ensure())
        let ids1 = Set(first.islands.map(\.id))
        let ids2 = Set(second.islands.map(\.id))
        #expect(ids1 == ids2, "the same listening keeps the same islands: \(ids1) then \(ids2)")
        #expect(second.fitAtMs == clock.value)
    }

    // MARK: Lists

    @Test func specsNameTheirListsAndSavedIdsReadBack() {
        #expect(MixSpec(kind: MixKinds.daily).surfaceId == "daily")
        #expect(MixSpec(kind: MixKinds.daily, islandId: 3).surfaceId == "daily:3")
        #expect(MixSpec.of(surfaceId: "daily:3") == MixSpec(kind: MixKinds.daily, islandId: 3))
        #expect(MixSpec.of(surfaceId: "your") == MixSpec(kind: MixKinds.your))
        for kind in [MixKinds.firstListen, MixKinds.justDropped, MixKinds.onRepeat, MixKinds.rediscover] {
            let spec = MixSpec(kind: kind)
            #expect(MixSpec.of(surfaceId: spec.surfaceId) == spec)
            #expect(spec.surface == Surface.namedMix)
        }
        #expect(MixSpec.of(surfaceId: "not a list") == nil)
        #expect(MixSpec(kind: MixKinds.daily, islandId: 2).surface == Surface.dailyMix)
        #expect(MixSpec(kind: MixKinds.your).surface == Surface.yourMix)
    }

    @Test func aStageTwoAMixRecordReadsWithoutTheNewFields() throws {
        let json = """
        {"v":1,"kind":0,"builtAtMs":5,"seed":1,"regenerate":0,"novelty":1,"tasteSignature":"","seedLists":2,"items":[]}
        """
        let mix = try JSONDecoder().decode(StoredMix.self, from: Data(json.utf8))
        #expect(mix.mixId == "" && mix.islandId == 0 && mix.number == 0 && mix.subtitle == "")
        #expect(MixSpec(kind: mix.kind, islandId: mix.islandId).surfaceId == "daily")
    }

    @Test func firstListenIsFixedForTheWeekAndTheServedLogTellsListsApartBySurfaceId() throws {
        let dir = Self.tempDirectory("served")
        defer { try? FileManager.default.removeItem(at: dir) }
        let served = ServedListStore(directory: dir)
        let monday: Int64 = 1_731_300_000_000 // Mon 2024-11-11 06:00 UTC
        func mix(_ at: Int64, _ rids: [Int64]) -> StoredMix {
            StoredMix(kind: MixKinds.firstListen, builtAtMs: at, seed: 1, items: rids.map { StoredMixItem(rid: $0, songId: "s\($0)") })
        }
        let first = MixSpec(kind: MixKinds.firstListen)
        served.put(surface: first.surface, surfaceId: first.surfaceId, mix: mix(monday, [1, 2, 3]), nuQ: 1000, nowMs: monday)
        let other = MixSpec(kind: MixKinds.justDropped)
        served.put(surface: other.surface, surfaceId: other.surfaceId, mix: mix(monday + 1, [9]), nuQ: 1000, nowMs: monday + 1)
        // Wednesday: the day's lists are gone, the week's First Listen is not; another list of the same surface is not it.
        let wednesday = monday + 2 * 86_400_000
        #expect(served.todays(surface: first.surface, nowMs: wednesday, tzOffsetMin: 0, surfaceId: first.surfaceId) == nil)
        let weekly = served.todays(surface: first.surface, nowMs: wednesday, tzOffsetMin: 0, surfaceId: first.surfaceId, weekly: true)
        #expect(weekly?.items.map(\.rid) == [1, 2, 3])
        #expect(served.todays(surface: first.surface, nowMs: wednesday, tzOffsetMin: 0, surfaceId: other.surfaceId, weekly: true)?.items.map(\.rid) == [9])
        // The next Monday it is another week.
        let nextMonday = monday + 7 * 86_400_000
        #expect(served.todays(surface: first.surface, nowMs: nextMonday, tzOffsetMin: 0, surfaceId: first.surfaceId, weekly: true) == nil)
        #expect(ServedListStore.weekStart(nowMs: wednesday, tzOffsetMin: 0) <= monday)
        // `takenOnDay` skips only the list being rebuilt when it is told which one.
        let log = served.recent(nowMs: monday + 100)
        #expect(Repetition.takenOnDay(log, nowMs: monday + 100, tzOffsetMin: 0, exceptSurface: first.surface, exceptId: "first") == [9])
        #expect(Repetition.takenOnDay(log, nowMs: monday + 100, tzOffsetMin: 0, exceptSurface: first.surface) == [])
    }

    /// The whole library resolved to recordings, and a plan of three planted islands saved as if the refresh had fitted them.
    private func world(_ world: World, songs: Int = 60, radios: Bool = true, spread: Bool = false)
        async -> (BrainRepository, BrainEngine, BrainMixes, IslandStore, Values, [Int64], [Int64]) {
        let repository = world.repository()
        if spread {
            // Twenty artists and thirty albums: a list of one island of twenty songs can keep the spacing rules of 6.4.
            world.libraryOverride.value = (0..<60).map { i in
                testSong("lib\(i)", title: "Library Song \(i)", artist: "Lib Artist \(i % 20)", duration: 200_000,
                         album: "Album \(i / 2)", spotifyId: "4iV5W9uYEdYUVa79Ax\(String(format: "%04d", i))")
            }
        }
        await world.listen(repository, songs: 0..<songs)
        if radios { await world.fetchRadios(repository, songs: 0..<30) }
        let engine = world.engine(repository)
        let mixes = world.mixes(repository, engine)
        let values = Values()
        let store = IslandStore(directory: world.directory, state: values.state)
        let lib = world.libraryOverride.value ?? world.library
        let requests = lib.map { TrackRequest(keys: TrackCatalog.facts(of: $0)!.keys, durationMs: 200_000) }
        let rids = await repository.resolveTracks(requests)
        let aids = await repository.resolveArtistNames(lib.map { BrainLibraryIndex.primaryArtistName($0) })
        return (repository, engine, mixes, store, values, rids, aids)
    }

    private func parts(_ world: World, _ repository: BrainRepository, _ mixes: BrainMixes, _ store: IslandStore, _ values: Values,
                       releases: NewReleases? = nil) -> Stage2bParts {
        let dna = DnaRepository(directory: world.directory)
        let override = world.libraryOverride
        let all = world.library
        let sources = MixSources(library: { override.value ?? all }, librarySongs: { _ in [:] })
        let plays = Box<Int>(0)
        let clock = world.clock
        let none = IslandInputs(library: { _ in [] }, edges: { [] }, hasState: { false }, weights: { _, _ in [:] },
                                qualifiedPlaysSince: { _ in plays.value }, tags: { _ in [:] }, clock: { clock.value })
        return Stage2bParts(islands: store, builder: IslandBuilder(store: store, inputs: none, state: values.state),
                            candidateDna: CandidateDna(store: store, dna: dna), libraryRids: LibraryRids(sources: sources, repository: repository),
                            atlas: CachedAtlasProvider(load: { nil }), newReleases: releases, dna: dna, picked: nil)
    }

    /// Sixty songs in three planted clusters (song i is in cluster i % 3), the embeddings and the fit saved as the refresh would.
    private struct Islanded {
        var mixes: BrainMixes
        var store: IslandStore
        var fit: Islands.Fit
        var rids: [Int64]
        var tracks: [Islands.Track]
    }

    private func islanded(_ w: World) async -> Islanded {
        let (repository, _, mixes, store, values, rids, aids) = await world(w, radios: false, spread: true)
        // Everything was played two to four days ago: nothing is inside the four hours a track rests after a play.
        w.clock.value += 4 * 86_400_000
        let tracks = Self.planted(rids: rids, aids: aids, clusters: 3, seed: "daily", interleaved: true)
        let fit = Islands.fit(tracks)
        await store.save(fit, nowMs: w.clock.value)
        var data: [UInt8] = []
        let sorted = tracks.sorted { $0.rid < $1.rid }
        for t in sorted { data.append(contentsOf: t.emb!) }
        await store.saveEmbeddings(Embeddings.of(version: 1, ids: sorted.map { $0.rid }, data: data))
        await mixes.configureStage2b(parts(w, repository, mixes, store, values))
        return Islanded(mixes: mixes, store: store, fit: fit, rids: rids, tracks: tracks)
    }

    @Test func eachIslandHasItsOwnDailyMixWithItsOwnMusicAndNoTrackIsInTwoOfThem() async throws {
        let w = World()
        defer { w.tidy() }
        let x = await islanded(w)
        #expect(x.fit.islands.count == 3, "three planted clusters, three islands: \(x.fit.islands.count)")
        let islandSet = try #require(await x.store.current())
        let daily = islandSet.dailyIslands().map { $0.id }
        #expect(daily.count == 3)
        var all: [Set<String>] = []
        for id in daily {
            w.clock.value += 5
            let view = try #require(await x.mixes.todayOf(MixSpec(kind: MixKinds.daily, islandId: id)), "Daily Mix of island \(id)")
            #expect(view.songs.count >= 12, "island \(id) holds \(view.songs.count) songs")
            #expect(view.spec == MixSpec(kind: MixKinds.daily, islandId: id) && view.number >= 1 && view.number <= 3)
            let tag = try #require(view.tags[view.songs[0].id])
            #expect(tag.surface == "dailyMix" && tag.surfaceId == "daily:\(id)")
            // Every track of an island's list is close to the island (6.2): by planting, it is one of its own 20 songs.
            let island = try #require(x.fit.islands.first { $0.id == id })
            for song in view.songs where song.id.hasPrefix("lib") {
                let rid = x.rids[Int(song.id.dropFirst(3))!]
                let t = try #require(x.tracks.first { $0.rid == rid })
                #expect(Islands.similarity(island, Islands.point(t.emb, nil)!) >= MixPlanner.islandFloor)
            }
            all.append(Set(view.songs.map { $0.id }))
        }
        #expect(all[0].isDisjoint(with: all[1]) && all[0].isDisjoint(with: all[2]) && all[1].isDisjoint(with: all[2]),
                "no track is in two mixes of one day")
        // The same list all day, read back without building.
        let again = try #require(await x.mixes.savedOf(MixSpec(kind: MixKinds.daily, islandId: daily[0])))
        let rebuilt = await x.mixes.todayOf(MixSpec(kind: MixKinds.daily, islandId: daily[0]))
        #expect(again.songs.map { $0.id } == rebuilt?.songs.map { $0.id })
        // The Daily Mix a screen that asks for "the" Daily Mix gets is Daily Mix 1: the island of the lowest id.
        let first = try #require(await x.mixes.today(kind: MixPlanner.kindDaily))
        #expect(first.spec.islandId == daily[0])
    }

    @Test func yourMixSpansTheIslandsInTheListenersProportions() async throws {
        let w = World()
        defer { w.tidy() }
        let x = await islanded(w)
        let your = try #require(await x.mixes.todayOf(MixSpec(kind: MixKinds.your)))
        #expect(your.songs.count >= 30, "Your Mix holds \(your.songs.count) songs")
        var perCluster: [Int: Int] = [:]
        for song in your.songs where song.id.hasPrefix("lib") { perCluster[Int(song.id.dropFirst(3))! % 3, default: 0] += 1 }
        #expect(perCluster.count == 3, "Your Mix holds every island: \(perCluster)")
        #expect((perCluster.values.min() ?? 0) >= 3)
    }

    @Test func firstListenIsMusicTheListenerNeverPlayedTwoAnArtistAtMostAndFixedAllWeek() async throws {
        let w = World()
        defer { w.tidy() }
        let (repository, _, mixes, store, values, _, _) = await world(w, songs: 30)
        await mixes.configureStage2b(parts(w, repository, mixes, store, values))
        let view = try #require(await mixes.todayOf(MixSpec(kind: MixKinds.firstListen)))
        #expect(view.songs.count >= 10)
        #expect(view.songs.allSatisfy { $0.id.hasPrefix("yt:") }, "unheard music only; no atlas, so no adjacent-genre library part")
        var perArtist: [String: Int] = [:]
        for song in view.songs { perArtist[song.artist, default: 0] += 1 }
        #expect((perArtist.values.max() ?? 0) <= 2)
        let tag = try #require(view.tags[view.songs[0].id])
        #expect(tag.surface == "namedMix" && tag.surfaceId == "first")
        // Built on a Friday: on Sunday it is the same list; on Monday after 04:00 it is another week.
        w.clock.value += 2 * 86_400_000
        let later = try #require(await mixes.savedOf(MixSpec(kind: MixKinds.firstListen)))
        #expect(later.songs.map(\.id) == view.songs.map(\.id))
        w.clock.value += 1 * 86_400_000
        #expect(await mixes.savedOf(MixSpec(kind: MixKinds.firstListen)) == nil)
        // No other list repeats this week's First Listen.
        w.clock.value = BrainMixesTests.start + 1000
        let your = try #require(await mixes.todayOf(MixSpec(kind: MixKinds.your)))
        let held = Set(view.songs.map(\.id))
        #expect(your.songs.allSatisfy { !held.contains($0.id) })
    }

    @Test func onRepeatHoldsTheMostPlayedSongsOfTheLastMonthAndRediscoverNothingWhenNothingIsOld() async throws {
        let w = World()
        defer { w.tidy() }
        let (repository, _, mixes, store, values, _, _) = await world(w, songs: 30)
        await mixes.configureStage2b(parts(w, repository, mixes, store, values))
        let onRepeat = try #require(await mixes.todayOf(MixSpec(kind: MixKinds.onRepeat)))
        #expect(onRepeat.songs.count >= 6 && onRepeat.songs.allSatisfy { $0.id.hasPrefix("lib") })
        #expect(onRepeat.reasons.isEmpty, "the list's own title says what the songs have in common")
        #expect(onRepeat.tags[onRepeat.songs[0].id]?.surfaceId == "repeat")
        // Everything was played three days ago: nothing is "not played in a while".
        #expect(await mixes.todayOf(MixSpec(kind: MixKinds.rediscover)) == nil)
        // Ninety-five days on, the loved songs are due and On Repeat is empty.
        w.clock.value += 95 * 86_400_000
        let rediscover = try #require(await mixes.todayOf(MixSpec(kind: MixKinds.rediscover)))
        #expect(rediscover.songs.count >= 6 && rediscover.tags[rediscover.songs[0].id]?.surfaceId == "rediscover")
        #expect(await mixes.todayOf(MixSpec(kind: MixKinds.onRepeat)) == nil)
    }

    @Test func justDroppedPutsTheArtistsTheListenerPlaysFirstAndSaysWhoIsNew() async throws {
        let w = World()
        defer { w.tidy() }
        let (repository, _, mixes, store, values, _, _) = await world(w, songs: 30)
        // Releases by a played artist ("Lib Artist 3") and by a stranger, ten fresh tracks of each.
        func row(_ i: Int, _ artist: String) -> StoredRadioRow {
            StoredRadioRow(row: RadioRow(videoId: "rel\(i)", title: "Release \(i)", artists: [RadioArtistRef(name: artist, channelId: "UC\(artist)")],
                                         album: "New Album \(i / 3)", durationSec: 200, kind: .atv), rid: BrainHash.id(BrainHash.fnv1a64("rel \(i)")))
        }
        let t0 = w.clock.value
        // Six artists, two tracks of each count: artists are spaced four slots apart, so a list needs five of them to fill.
        let found: [FoundRelease] = (0..<6).map { k in
            let artist = k == 0 ? "Lib Artist 3" : "Stranger \(k)"
            return FoundRelease(channelId: "UC\(artist)", artistName: artist, browseId: "MPREb_\(k)", title: "Album \(k)", year: 2025,
                                kind: .album, foundAtMs: t0 - 1000 + Int64(k), rows: (0..<3).map { row(k * 10 + $0, artist) })
        }
        let releaseStore = AtomicReleaseFileStore(directory: w.directory)
        releaseStore.write(NewReleaseFile(artists: [], found: found, requests: []))
        let releases = NewReleases(store: releaseStore, source: nil, repository: repository, clock: { w.clock.value },
                                   yearAndMonth: { _ in (2025, 1) })
        await mixes.configureStage2b(parts(w, repository, mixes, store, values, releases: releases))
        let view = try #require(await mixes.todayOf(MixSpec(kind: MixKinds.justDropped)))
        #expect(view.songs.count >= 6 && view.novelIds.count == view.songs.count)
        #expect(view.songs[0].artist == "Lib Artist 3", "the artist the listener plays comes first")
        let reason = try #require(view.reasons[view.songs[0].id])
        #expect(reason.key == WhyLine.nameOf(WhyLine.newRelease) && reason.arg == "Lib Artist 3")
        var perArtist: [String: Int] = [:]
        for song in view.songs { perArtist[song.artist, default: 0] += 1 }
        #expect((perArtist.values.max() ?? 0) <= 2, "two an artist at most")
    }

    // MARK: Home plan, Jump back in, genre stations, cold start

    @Test func aPlanIsSmallComesBackFromItsFileAndIsDueWhenTheDayTheDaypartOrTheTasteMoves() async throws {
        let dir = Self.tempDirectory("plan")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HomePlanStore(directory: dir)
        #expect(await store.read() == nil)
        // A full page: seven shelves of twelve outside tracks is about 25 KB on Android; it must fit under 50 KB here too.
        func item(_ i: Int) -> PlanItem {
            PlanItem(rid: Int64(i), aid: Int64(i % 10), row: StoredRadioRow(
                row: RadioRow(videoId: "videoid\(i)", title: "A song title of some length \(i)", artists: [RadioArtistRef(name: "Some Artist \(i % 10)", channelId: "UCchannelid\(i % 10)")],
                              album: "An album name \(i % 4)", durationSec: 200, thumbnailUrl: "https://lh3.googleusercontent.com/abcdefghijklmnop\(i)=w226-h226", kind: .atv), rid: Int64(i)),
                     arm: Arm.radio, whyKey: WhyLine.radioFans, whyName: "Some Artist", slot: i)
        }
        let shelves = (0..<7).map { s in
            PlanShelf(type: Int32(min(s + 1, 8)), id: "shelf\(s)", titleKey: "because_listened", titleArg: "Some song", subtitleKey: "because_listened_subtitle",
                      items: (0..<12).map { item(s * 12 + $0) })
        }
        let plan = HomePlan(generatedAtMs: 5, planKey: 100, taste: "t", daypart: 1, weekday: 2, hero: PlanHero(kind: HomePlanner.heroDaily, mixId: "daily:1"),
                            mixes: [PlanMix(mixId: "daily:1", kind: MixKinds.daily, number: 1, subtitle: "Pop · Artist", count: 30, covers: ["a", "b"])], shelves: shelves)
        #expect(await store.write(plan))
        let size = (try? Data(contentsOf: dir.appendingPathComponent(HomePlanStore.fileName)).count) ?? 0
        #expect(size > 0 && size < HomePlanStore.maxBytes, "the plan is \(size) bytes")
        #expect(await store.read() == plan)
        // A plan over the limit is not saved, and a file this code cannot read is no plan.
        let huge = HomePlan(generatedAtMs: 5, planKey: 1, shelves: (0..<40).map { PlanShelf(type: 1, id: "s\($0)", titleKey: "k", items: (0..<12).map { item($0 + 100 * $0) }) })
        #expect(await store.write(huge) == false)
        try Data("{not json".utf8).write(to: dir.appendingPathComponent(HomePlanStore.fileName))
        #expect(await store.read() == nil)
    }

    @Test func jumpBackInKeepsTheLastSixDistinctPlacesNotSongs() async throws {
        let dir = Self.tempDirectory("recent")
        defer { try? FileManager.default.removeItem(at: dir) }
        let recent = RecentContexts(directory: dir)
        func ctx(_ key: String, _ title: String, _ at: Int64) -> RecentContext { RecentContext(key: key, kind: RecentContext.playlist, title: title, songIds: ["a"], atMs: at) }
        for i in 0..<10 { await recent.note(ctx("p:\(i)", "Playlist \(i)", Int64(i))) }
        await recent.note(ctx("p:3", "Playlist 3 again", 99))
        let tiles = await recent.tiles(count: 6)
        #expect(tiles.map(\.key) == ["p:3", "p:9", "p:8", "p:7", "p:6", "p:5"])
        #expect(tiles[0].title == "Playlist 3 again", "a place is one tile, with its newest start")
        #expect(await recent.last(100).count == 10)
        for i in 20..<26 { await recent.note(ctx("p:\(i)", "Playlist \(i)", Int64(i))) }
        #expect(await recent.last(100).count == RecentContexts.keep, "the file keeps the newest twelve")
        // It comes back after a restart.
        let again = RecentContexts(directory: dir)
        #expect(await again.tiles(count: 2).map(\.key) == ["p:25", "p:24"])
        // What a started queue is.
        let mix = RecentContexts.contextOf(queueName: "Daily Mix 2", playlistId: nil, surface: "dailyMix", surfaceId: "daily:7", songIds: ["x"], art: nil, nowMs: 1)
        #expect(mix?.kind == RecentContext.mix && mix?.mixId == "daily:7" && mix?.key == "m:daily:7")
        #expect(RecentContexts.contextOf(queueName: "Recently Played", playlistId: nil, surface: nil, surfaceId: nil, songIds: ["x"], art: nil, nowMs: 1) == nil)
        #expect(RecentContexts.contextOf(queueName: "Chill", playlistId: "pl1", surface: nil, surfaceId: nil, songIds: [], art: nil, nowMs: 1) == nil)
        #expect(RecentContexts.contextOf(queueName: "Chill", playlistId: "pl1", surface: nil, surfaceId: nil, songIds: ["x"], art: "u", nowMs: 1)?.key == "p:pl1")
    }

    @Test func theColdStartFetchesEightRadiosAtMostTwoAtATimeAndSaysHowFarItIs() async throws {
        final class Work: RefreshWork, @unchecked Sendable {
            let lock = NSLock()
            var fetched: [String] = []
            var running = 0
            var peak = 0
            func radioSeeds() async -> [RefreshTarget] {
                (0..<12).map { RefreshTarget(seed: RadioSeed(mediaId: "m\($0)", videoId: "v\($0)", title: "t\($0)", primaryArtist: "a", durationMs: 1), rid: Int64($0 + 1), artistName: "a") }
            }
            func artistSeeds() async -> [RefreshTarget] { [] }
            func requestsLeft() async -> Int { 100 }
            func radio(_ target: RefreshTarget) async -> RefreshFetch {
                lock.withLock { running += 1; peak = max(peak, running) }
                try? await Task.sleep(for: .milliseconds(5))
                lock.withLock { running -= 1; fetched.append(target.seed.mediaId) }
                return .network
            }
            func artist(_ target: RefreshTarget) async -> RefreshFetch { .none }
        }
        let work = Work()
        let seen = Box<[ColdStart.Progress?]>([])
        let cold = ColdStart(work: work, healthyLists: { 0 }, allowed: { true })
        await cold.run { p in seen.value = seen.value + [p] }
        #expect(work.fetched.count == ColdStart.target)
        #expect(work.peak <= ColdStart.parallel)
        #expect(seen.value.first == .some(ColdStart.Progress(done: 0, total: 8)))
        #expect(seen.value.compactMap { $0 }.map(\.done).max() == 8)
        #expect(seen.value.last == .some(nil), "the strip goes when it is done")
        // Once eight lists are cached it does nothing; switched off, it does nothing.
        let done = ColdStart(work: Work(), healthyLists: { 8 }, allowed: { true })
        let none = Box<Int>(0)
        await done.run { if $0 != nil { none.value += 1 } }
        #expect(none.value == 0)
        let off = Work()
        await ColdStart(work: off, healthyLists: { 0 }, allowed: { false }).run { _ in }
        #expect(off.fetched.isEmpty)
    }
}
