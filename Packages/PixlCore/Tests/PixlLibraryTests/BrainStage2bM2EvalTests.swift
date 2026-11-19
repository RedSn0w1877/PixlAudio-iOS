import Foundation
import Testing
@testable import PixlLibrary

/// Stage 2b, milestone 2: the pure core of embeddings, retrieval, islands, the arms, the simple mixes, the island-aware planner
/// and the Home page rules (docs/brain-spec.md, 5.3, 5.4, 6.1, 6.2, 8.1, 11). A port of Android's `Stage2bM2Test`, with the
/// same synthetic listeners (taste clusters planted in them) and the same expected numbers: "the islands recover the clusters"
/// is a thing a test can say, and it says it with the same purity on both platforms.
@Suite("Brain stage 2b milestone 2: eval (the same numbers as Android)")
struct BrainStage2bM2EvalTests {
    typealias S = BrainStage2bGoldenTests

    struct Planted {
        var tracks: [Islands.Track]
        var cluster: [Int]

        /// For each planted cluster, the share of its tracks that sit in its most common island.
        func purity(_ fit: Islands.Fit) -> Double {
            var byCluster: [Int: [Int: Int]] = [:]
            for (i, t) in tracks.enumerated() { byCluster[cluster[i], default: [:]][fit.islandOf(t.rid), default: 0] += 1 }
            var good = 0
            var total = 0
            for counts in byCluster.values {
                good += counts.values.max() ?? 0
                total += counts.values.reduce(0, +)
            }
            return Double(good) / Double(total)
        }
    }

    /// Tracks drawn around planted centres: each cluster has its own embedding direction and two atlas genres. The same
    /// sequence of random draws as Android's `Stage2bM2Golden.planted`.
    static func planted(_ atlas: GenreAtlas, _ seed: String, _ clusters: Int, _ perCluster: Int, _ noise: Int) -> Planted {
        var rng = BrainHash.Rng(seed: BrainHash.fnv1a64(seed))
        func int(_ n: Int) -> Int { let v = Int(rng.uniform() * Double(n)); return v >= n ? n - 1 : v }
        var centres: [[Int]] = []
        for _ in 0..<clusters { centres.append((0..<Embeddings.dim).map { _ in int(255) - 127 }) }
        let ids = atlas.allIds
        var genres: [[Int]] = []
        for _ in 0..<clusters { let a = ids[int(ids.count)]; let b = ids[int(ids.count)]; genres.append([a, b]) }
        var tracks: [Islands.Track] = []
        var owner: [Int] = []
        for c in 0..<clusters {
            for k in 0..<perCluster {
                var emb = [UInt8](repeating: 0, count: Embeddings.dim)
                for j in 0..<Embeddings.dim {
                    var v = centres[c][j] + int(2 * noise + 1) - noise
                    if v > 127 { v = 127 }
                    if v < -127 { v = -127 }
                    emb[j] = UInt8(bitPattern: Int8(v))
                }
                let g0 = genres[c][0]
                let g1 = genres[c][1]
                let first = Tags.Tag(atlasId: min(g0, g1), q: 200 + int(40))
                let second = Tags.Tag(atlasId: max(g0, g1), q: 60 + int(60))
                let vec = Tags.Vector(first.atlasId == second.atlasId ? [first] : [first, second])
                let rid = BrainHash.id(BrainHash.fnv1a64("n:planted \(seed) \(c) \(k)"))
                let w = 1.0 + Double(int(40)) * 0.25
                let recent = rng.uniform() < 0.4 ? w * 0.5 : 0.0
                tracks.append(Islands.Track(rid: rid, aid: BrainHash.id(BrainHash.fnv1a64("n:artist \(seed) \(c) \(k % 14)")),
                                            weight: w, recentWeight: recent, emb: emb, tags: vec))
                owner.append(c)
            }
        }
        return Planted(tracks: tracks, cluster: owner)
    }

    // MARK: FastRP and PageRank

    private func twoCommunities() -> (Graph, [[Int64]]) {
        let a = (0..<20).map { BrainHash.id(BrainHash.fnv1a64("n:a \($0)")) }
        let b = (0..<20).map { BrainHash.id(BrainHash.fnv1a64("n:b \($0)")) }
        var builder = Graph.Builder()
        for group in [a, b] {
            for i in group.indices {
                for k in 1...4 { builder.addEdge(group[i], group[(i + k) % group.count], weight: 0.5 + 0.05 * Double(k % 3)) }
            }
        }
        // One thin bridge.
        builder.addEdge(a[0], b[0], weight: 0.1)
        return (builder.build(), [a, b])
    }

    @Test func fastRpPutsNeighboursCloserThanStrangersAndIsDeterministic() {
        let (graph, groups) = twoCommunities()
        let e1 = FastRp.embed(graph)
        let e2 = FastRp.embed(graph)
        #expect(e1.dataCopy() == e2.dataCopy())
        var within = 0.0, across = 0.0
        var nW = 0, nA = 0
        for i in 0..<20 {
            for j in (i + 1)..<20 {
                within += e1.cos(groups[0][i], groups[0][j]); nW += 1
                across += e1.cos(groups[0][i], groups[1][j]); nA += 1
            }
        }
        #expect(within / Double(nW) > across / Double(nA) + 0.2, "within \(within / Double(nW)) across \(across / Double(nA))")
        for v in e1.dataCopy() { #expect(Int8(bitPattern: v) >= -127) }
    }

    @Test func fastRpOfAGraphWithNoNodesIsEmptyAndAnUnknownIdHasNoVector() {
        let e = FastRp.embed(Graph.empty)
        #expect(e.size == 0)
        #expect(e.cos(1, 2) == 0.0)
    }

    @Test func personalisedPageRankFavoursTheSeedsOwnSideAndDividesByDegree() {
        let (graph, groups) = twoCommunities()
        let seeds = [groups[0][0], groups[0][1], groups[0][2]]
        let r = Ppr.run(graph, seedIds: seeds, seedWeights: [3.0, 2.0, 1.0], top: 40)
        #expect(r.size > 0)
        let sideA = Set(groups[0])
        let top = r.ids.prefix(15)
        #expect(top.filter { sideA.contains($0) }.count >= 12, "the first 15 should be mostly side A")
        for i in 1..<max(r.size, 1) where i < r.size { #expect(BrainMath.orderKey(r.scores[i - 1]) >= BrainMath.orderKey(r.scores[i])) }
        #expect(Ppr.run(graph, seedIds: [], seedWeights: []).size == 0)
    }

    // MARK: Islands

    @Test func islandsRecoverTheClustersPlantedInASyntheticListener() throws {
        let atlas = try S.atlas()
        for (clusters, per) in [(3, 70), (4, 100), (5, 120), (6, 150)] {
            let p = Self.planted(atlas, "test:recover:\(clusters)", clusters, per, 6)
            let fit = Islands.fit(p.tracks)
            #expect(fit.islands.count == clusters, "islands for \(clusters) planted clusters")
            #expect(p.purity(fit) >= 0.95, "purity \(p.purity(fit)) for \(clusters) clusters")
            #expect(fit.memberRids.count == p.tracks.count, "every placed track belongs to one island")
        }
    }

    @Test func fewerThanSixtyTracksMakeOneIslandAndUnplaceableTracksAreLeftOut() throws {
        let atlas = try S.atlas()
        let few = Self.planted(atlas, "test:few", 3, 15, 6)
        #expect(Islands.fit(few.tracks).islands.count == 1)
        let blind = [Islands.Track(rid: 1, aid: 1, weight: 5.0, recentWeight: 0.0, emb: nil, tags: nil),
                     Islands.Track(rid: 2, aid: 1, weight: 4.0, recentWeight: 0.0, emb: nil, tags: Tags.Vector.empty)]
        #expect(Islands.fit(blind).islands.count == 0, "a track with no embedding and no tag cannot be placed")
    }

    @Test func anIslandKeepsItsIdWhenTheTasteMovesALittleAndANewIslandGetsANewOne() throws {
        let atlas = try S.atlas()
        let p = Self.planted(atlas, "test:stable", 4, 100, 6)
        let before = Islands.fit(p.tracks)
        let drifted = p.tracks.enumerated().filter { $0.offset % 7 != 0 }.map { _, t in
            Islands.Track(rid: t.rid, aid: t.aid, weight: t.weight * 0.8, recentWeight: t.recentWeight, emb: t.emb, tags: t.tags)
        }
        let after = Islands.fit(drifted, previous: before.islands, lastId: before.maxId)
        #expect(before.islands.map { $0.id }.sorted() == after.islands.map { $0.id }.sorted())
        for island in after.islands {
            let old = try #require(before.islands.first { $0.id == island.id })
            #expect(Islands.dot(old.centroid, island.centroid) > 0.9)
        }
        let extra = Self.planted(atlas, "test:stable:extra", 1, 100, 6)
        let grown = Islands.fit(drifted + extra.tracks, previous: after.islands, lastId: after.maxId)
        #expect(grown.islands.count == 5)
        #expect(grown.islands.filter { $0.id > before.maxId }.count == 1)
        #expect(grown.maxId > before.maxId)
    }

    @Test func anIslandIsNamedFromTheGenresOfItsTracksAndATrackWithNoGenreGivesNoName() throws {
        let atlas = try S.atlas()
        let p = Self.planted(atlas, "test:names", 3, 80, 6)
        let fit = Islands.fit(p.tracks)
        for island in fit.islands {
            #expect(!island.liftTags.isEmpty)
            for id in island.liftTags { #expect(atlas.genre(id) != nil, "every tag id is a real atlas genre") }
            #expect(!island.topArtists.isEmpty)
        }
        let noTags = p.tracks.map { Islands.Track(rid: $0.rid, aid: $0.aid, weight: $0.weight, recentWeight: $0.recentWeight, emb: $0.emb, tags: nil) }
        for island in Islands.fit(noTags).islands { #expect(island.liftTags.isEmpty, "unknown genres stay absent") }
    }

    // MARK: The island features and the planner

    @Test func theIslandFeaturesAreLiveWithIslandsAndExactlyZeroWithout() throws {
        let atlas = try S.atlas()
        let p = Self.planted(atlas, "test:features", 3, 40, 6)
        let fit = Islands.fit(p.tracks)
        let t = p.tracks[0]
        let c = Candidate(rid: t.rid, aid: t.aid, tags: t.tags, emb: t.emb, popPermille: 800, fresh: true)
        var x = [Double](repeating: 0.0, count: Features.d)
        let affinity = Affinity.State()
        Features.compute(c, arm: Arm.radio, retrieval: 0.0, bestRank: 0, affinity: affinity, session: SessionState(), graph: Graph.empty,
                         nowMs: 1_000, p0: 0.5, allNovel: false, out: &x)
        #expect(x[Features.islandSim] == 0.0 && x[Features.islandWeight] == 0.0 && x[Features.noveltyDist] == 0.0)
        #expect(abs(x[Features.pop] - 0.3) < 1e-12)
        #expect(x[Features.fresh] == 1.0)
        Features.compute(c, arm: Arm.radio, retrieval: 0.0, bestRank: 0, affinity: affinity, session: SessionState(), graph: Graph.empty,
                         nowMs: 1_000, p0: 0.5, allNovel: false, out: &x, islands: IslandContext(fit.islands))
        #expect(x[Features.islandSim] > 0.5, "the track sits in its own island: \(x[Features.islandSim])")
        #expect(x[Features.islandWeight] > 0.0)
        // An unheard track: its novelty distance is how far it is from every island.
        #expect(abs(x[Features.noveltyDist] - (1.0 - x[Features.islandSim])) < 1e-12)
    }

    private func candidatesOf(_ p: Planted) -> [Candidate] {
        p.tracks.enumerated().map { k, t in
            Candidate(rid: t.rid, aid: t.aid, albumKey: BrainHash.id(BrainHash.fnv1a64("alb \(t.rid / 9)")), inLibrary: k % 3 != 0,
                      tags: t.tags, emb: t.emb, artistNew: k % 3 == 0 && k % 2 == 0)
        }
    }

    private func planOf(_ p: Planted, kind: Int32, island: Int, fit: Islands.Fit, now: Int64 = 1_760_000_000_000) -> StationPlanner.Plan {
        let request = MixPlanner.Request(kind: kind, candidates: candidatesOf(p), seeds: [], nowMs: now, tzOffsetMin: 0, salt: 5,
                                         islands: IslandContext(fit.islands), islandIdx: island)
        return MixPlanner.plan(request, affinity: Affinity.State())
    }

    @Test func aDailyMixOfAnIslandHoldsOnlyTracksCloseToThatIslandAndEachIslandHasItsOwnList() throws {
        let atlas = try S.atlas()
        let p = Self.planted(atlas, "test:daily", 4, 100, 6)
        let fit = Islands.fit(p.tracks)
        var byRid: [Int64: Islands.Track] = [:]
        for t in p.tracks { byRid[t.rid] = t }
        var rids: [Set<Int64>] = []
        for k in fit.islands.indices {
            let plan = planOf(p, kind: MixPlanner.kindDaily, island: k, fit: fit)
            #expect(plan.picks.count >= 20, "mix \(k) has \(plan.picks.count)")
            for pick in plan.picks {
                let t = try #require(byRid[pick.rid])
                let sim = Islands.similarity(fit.islands[k], try #require(Islands.point(t.emb, t.tags)))
                #expect(sim >= MixPlanner.islandFloor, "island sim \(sim)")
            }
            rids.append(Set(plan.picks.map { $0.rid }))
        }
        // Different islands give different lists.
        for i in rids.indices {
            for j in (i + 1)..<max(rids.count, i + 1) { #expect(rids[i].intersection(rids[j]).count <= 3, "islands \(i) and \(j) share") }
        }
        #expect(fit.islands.count == 4)
    }

    @Test func yourMixAcrossIslandsKeepsTheListenersMixOfIslands() throws {
        let atlas = try S.atlas()
        let p = Self.planted(atlas, "test:your", 4, 100, 6)
        let fit = Islands.fit(p.tracks)
        let plan = planOf(p, kind: MixPlanner.kindYour, island: -1, fit: fit)
        var counts = [Int](repeating: 0, count: fit.islands.count)
        for pick in plan.picks {
            let id = fit.islandOf(pick.rid)
            if let i = fit.islands.firstIndex(where: { $0.id == id }) { counts[i] += 1 }
        }
        for c in counts { #expect(c >= 3, "every island is in the mix: \(counts)") }
        let total = Double(counts.reduce(0, +))
        let cal = Calibration(fit.islands.map { $0.weight })
        for i in counts.indices { for _ in 0..<counts[i] { cal.add(i) } }
        #expect(cal.divergence() < 0.15, "calibration KL \(cal.divergence()) (test 5 asks at most 0.15), shares \(counts.map { Double($0) / total })")
    }

    @Test func calibrationPullsAnUnderRepresentedIslandUp() {
        let cal = Calibration([100.0, 100.0, 100.0])
        for _ in 0..<9 { cal.add(0) }
        #expect(cal.gain(1) > cal.gain(0))
        #expect(cal.gain(-1) == 0.0)
    }

    @Test func firstListenIsUnheardMusicWithAtMostTwoPerArtistAndSomeArtistsTheListenerNeverPlayed() throws {
        let atlas = try S.atlas()
        let p = Self.planted(atlas, "test:first", 4, 60, 6)
        let fit = Islands.fit(p.tracks)
        var affinity = Affinity.State()
        // The listener has heard a quarter of the tracks.
        let heard = p.tracks.enumerated().filter { $0.offset % 4 == 0 }.map(\.element)
        for (n, t) in heard.enumerated() {
            Affinity.apply(&affinity, family: Family.track, key: t.rid, r: 1.0, c: 1.0, part: 1.0, tMs: 1_700_000_000_000 + Int64(n) * 1000)
        }
        let cands = p.tracks.enumerated().map { k, t in
            Candidate(rid: t.rid, aid: t.aid, albumKey: BrainHash.id(BrainHash.fnv1a64("alb \(t.rid / 9)")), inLibrary: false,
                      tags: t.tags, emb: t.emb, artistNew: k % 2 == 0)
        }
        let request = MixPlanner.Request(kind: MixPlanner.kindFirstListen, candidates: cands, seeds: [], nowMs: 1_760_000_000_000,
                                         tzOffsetMin: 0, islands: IslandContext(fit.islands))
        let plan = MixPlanner.plan(request, affinity: affinity)
        #expect(plan.picks.count >= 25, "picks \(plan.picks.count)")
        let heardRids = Set(heard.map { $0.rid })
        #expect(plan.picks.allSatisfy { !heardRids.contains($0.rid) }, "no heard track")
        var byRid: [Int64: Islands.Track] = [:]
        for t in p.tracks { byRid[t.rid] = t }
        var perArtist: [Int64: Int] = [:]
        for pick in plan.picks { perArtist[byRid[pick.rid]!.aid, default: 0] += 1 }
        #expect(perArtist.values.allSatisfy { $0 <= 2 }, "at most 2 per artist: \(perArtist)")
        let newShare = Double(plan.picks.filter { pick in cands.first { $0.rid == pick.rid }!.artistNew }.count) / Double(plan.picks.count)
        #expect(newShare >= 0.4, "new-artist share \(newShare)")
    }

    // MARK: The arms and the simple lists

    @Test func backNeedsFiveCompletionsAYearOfSilenceAndATrackOutsideTheLibrary() {
        let now: Int64 = 1_760_000_000_000
        let longAgo = now - 400 * 86_400_000
        #expect(ArmRules.isBack(completions: 5, lastPlayedMs: longAgo, nowMs: now, inLibrary: false))
        #expect(!ArmRules.isBack(completions: 4, lastPlayedMs: longAgo, nowMs: now, inLibrary: false))
        #expect(!ArmRules.isBack(completions: 9, lastPlayedMs: now - 100 * 86_400_000, nowMs: now, inLibrary: false))
        #expect(!ArmRules.isBack(completions: 9, lastPlayedMs: longAgo, nowMs: now, inLibrary: true))
        #expect(!ArmRules.isBack(completions: 9, lastPlayedMs: 0, nowMs: now, inLibrary: false))
    }

    @Test func adjacentGenresAreSiblingsOfLovedOnesTheListenerDoesNotPlayNeverTheLovedOneItself() throws {
        let atlas = try S.atlas()
        let loved = atlas.idForName("shoegaze")
        #expect(loved != GenreAtlas.none)
        let out = ArmRules.adjacentGenres(atlas, loved: [loved], share: { _ in 0.0 }, limit: 10)
        #expect(!out.isEmpty)
        #expect(!out.contains(loved))
        for id in out { #expect(atlas.genre(id) != nil) }
        // A genre the listener already plays is not adjacent.
        let played = ArmRules.adjacentGenres(atlas, loved: [loved], share: { $0 == out[0] ? 0.5 : 0.0 }, limit: 10)
        #expect(!played.contains(out[0]))
        // An atlas id that does not exist gives nothing.
        #expect(ArmRules.adjacentGenres(atlas, loved: [999_999], share: { _ in 0.0 }, limit: 10).isEmpty)
    }

    @Test func onRepeatIsWhatWasPlayedInTheLast30DaysAndRediscoverWhatWasLovedAndLeftFor90() {
        let now: Int64 = 1_760_000_000_000
        let day: Int64 = 86_400_000
        var affinity = Affinity.State()
        let rids = (0..<60).map { Int64(1000 + $0) }
        let aids = (0..<60).map { Int64(7000 + $0 / 3) }
        let albums = (0..<60).map { Int64(9000 + $0 / 2) }
        // 0..19: finished 3 times a week ago; 20..49: finished 5 times 120 days ago; 50..59: never played.
        for i in 0..<20 { for k in 0..<3 { Affinity.apply(&affinity, family: Family.track, key: rids[i], r: 1.0, c: 1.0, part: 1.0, tMs: now - Int64(7 + k) * day) } }
        for i in 20..<50 { for k in 0..<5 { Affinity.apply(&affinity, family: Family.track, key: rids[i], r: 1.0, c: 1.0, part: 1.0, tMs: now - Int64(120 + k) * day) } }
        let onRepeat = ListMixes.fill(ListMixes.onRepeat(affinity, rids: rids, aids: aids, albumKeys: albums, nowMs: now), count: 30, excluded: [], tieSeed: 1)
        #expect(!onRepeat.isEmpty && onRepeat.allSatisfy { Set(rids.prefix(20)).contains($0.rid) })
        let rediscover = ListMixes.fill(ListMixes.rediscover(affinity, rids: rids, aids: aids, albumKeys: albums, servedTimes: [:], nowMs: now),
                                        count: 30, excluded: [], tieSeed: 1)
        #expect(!rediscover.isEmpty && rediscover.allSatisfy { Set(rids[20..<50]).contains($0.rid) })
        // Served often in the last 30 days: steps aside for the ones that were not.
        var served: [Int64: Int32] = [:]
        for r in rids[20..<30] { served[r] = 4 }
        let rotated = ListMixes.fill(ListMixes.rediscover(affinity, rids: rids, aids: aids, albumKeys: albums, servedTimes: served, nowMs: now),
                                     count: 8, excluded: [], tieSeed: 1)
        #expect(rotated.allSatisfy { served[$0.rid] == nil }, "rotated list should not hold the ones just served")
        // Spacing: never the same artist within 4 slots.
        for i in 4..<max(onRepeat.count, 4) where i < onRepeat.count { for k in 1...4 { #expect(onRepeat[i].aid != onRepeat[i - k].aid) } }
        // Nothing another mix of the day holds.
        let skipped = Set(onRepeat.prefix(5).map { $0.rid })
        let again = ListMixes.fill(ListMixes.onRepeat(affinity, rids: rids, aids: aids, albumKeys: albums, nowMs: now), count: 30, excluded: skipped, tieSeed: 1)
        #expect(again.allSatisfy { !skipped.contains($0.rid) })
    }

    @Test func justDroppedPutsLovedArtistsFirstAndAtMostTwoAnArtist() {
        let n = 20
        let rids = (0..<n).map { Int64(100 + $0) }
        let aids = (0..<n).map { Int64(500 + $0 % 4) }
        let albums = (0..<n).map { Int64(800 + $0) }
        let aff = (0..<n).map { $0 % 4 == 0 ? 2.0 : -1.0 }
        let heard = (0..<n).map { $0 % 4 != 3 }
        let recency = (0..<n).map { Double($0) }
        let out = ListMixes.fill(ListMixes.justDropped(rids: rids, aids: aids, albumKeys: albums, artistAff: aff, artistHeard: heard, recency: recency),
                                 count: 30, excluded: [], tieSeed: 1, maxPerArtist: 2)
        #expect((1...8).contains(out.count))
        var perArtist: [Int64: Int] = [:]
        for o in out { perArtist[o.aid, default: 0] += 1 }
        #expect(perArtist.values.allSatisfy { $0 <= 2 })
        #expect(out[0].aid == 500, "the loved artist comes first")
    }

    // MARK: The Home page rules

    private func shelf(_ type: Int32, _ id: String, _ count: Int, artists: Int = 12, salt: Int64 = 0) -> HomePlanner.ShelfIn {
        let card = HomePlanner.isCardShelf(type)
        return HomePlanner.ShelfIn(type: type, id: id, items: (0..<count).map {
            HomePlanner.Item(rid: card ? 0 : 10_000 * Int64(type) + Int64($0) + salt, aid: 1 + Int64($0 % artists) + 100 * Int64(type), key: $0)
        })
    }

    @Test func aShelfWithTooFewPlayableItemsIsHiddenNotPadded() {
        let plan = HomePlanner.plan([
            shelf(HomePlanner.madeForYou, "mixes", 3), shelf(HomePlanner.onRepeat, "repeat", 5),
            shelf(HomePlanner.rediscover, "re", 9), shelf(HomePlanner.stations, "st", 3),
        ])
        #expect(plan.map { $0.type } == [HomePlanner.madeForYou, HomePlanner.rediscover])
    }

    @Test func noTrackTwiceOnThePageAndArtistsLimitedPerShelfAndPerPage() {
        // Every shelf offers the same recordings by the same few artists.
        let common = (0..<30).map { HomePlanner.Item(rid: Int64(500 + $0), aid: Int64(1 + $0 % 3), key: $0) }
        let plan = HomePlanner.plan([
            HomePlanner.ShelfIn(type: HomePlanner.onRepeat, id: "a", items: common),
            HomePlanner.ShelfIn(type: HomePlanner.rediscover, id: "b",
                                items: common + (0..<30).map { HomePlanner.Item(rid: Int64(900 + $0), aid: Int64(50 + $0 % 20), key: 100 + $0) }),
        ])
        var seen = Set<Int64>()
        var perArtist: [Int64: Int] = [:]
        for s in plan {
            var shelfArtists: [Int64: Int] = [:]
            for i in s.items {
                #expect(seen.insert(i.rid).inserted, "track \(i.rid) twice")
                shelfArtists[i.aid, default: 0] += 1
                perArtist[i.aid, default: 0] += 1
            }
            #expect(shelfArtists.values.allSatisfy { $0 <= HomePlanner.artistPerShelf })
        }
        #expect(perArtist.values.allSatisfy { $0 <= HomePlanner.artistPerPage })
    }

    @Test func thePageRulesHoldOnRandomPages() {
        let types: [Int32] = [HomePlanner.madeForYou, HomePlanner.becauseListened, HomePlanner.becauseListened, HomePlanner.newFromLoved,
                              HomePlanner.onRepeat, HomePlanner.rediscover, HomePlanner.stations, HomePlanner.stepSideways,
                              HomePlanner.moreLikeAlbum, HomePlanner.popular]
        for c in 0..<400 {
            var rng = BrainHash.Rng(seed: BrainHash.fnv1a64("page:\(c)"))
            var shelves: [HomePlanner.ShelfIn] = []
            for (s, type) in types.enumerated() {
                if rng.uniform() < 0.2 { continue }
                let count = Int(rng.uniform() * 22)
                let card = HomePlanner.isCardShelf(type)
                var items: [HomePlanner.Item] = []
                for k in 0..<count {
                    items.append(HomePlanner.Item(rid: card ? 0 : 1 + Int64(rng.uniform() * 70), aid: 1 + Int64(rng.uniform() * 10), key: k))
                }
                shelves.append(HomePlanner.ShelfIn(type: type, id: "s\(s)", items: items))
            }
            let plan = HomePlanner.plan(shelves)
            #expect(plan.count <= HomePlanner.maxShelves)
            var seen = Set<Int64>()
            var artists: [Int64: Int] = [:]
            for s in plan {
                #expect(s.items.count >= HomePlanner.minItems(s.type), "a shelf is never padded or short")
                #expect(s.items.count <= HomePlanner.itemsPerShelf)
                if !HomePlanner.isCardShelf(s.type) {
                    var shelfArtists: [Int64: Int] = [:]
                    for i in s.items {
                        #expect(seen.insert(i.rid).inserted)
                        shelfArtists[i.aid, default: 0] += 1
                        artists[i.aid, default: 0] += 1
                    }
                    #expect(shelfArtists.values.allSatisfy { $0 <= 2 })
                }
            }
            #expect(artists.values.allSatisfy { $0 <= 4 })
            for i in plan.indices.dropFirst() {
                #expect(!(HomePlanner.isAllNovel(plan[i].type) && HomePlanner.isAllNovel(plan[i - 1].type)), "two all-new shelves side by side")
            }
            if plan.contains(where: { !HomePlanner.isAllNovel($0.type) }) {
                #expect(plan.prefix(3).contains { !HomePlanner.isAllNovel($0.type) }, "a familiar shelf among the first three")
            }
        }
    }

    @Test func theHeroIsFirstListenOnMondaysThenAReleaseThenADailyMixThatRotates() {
        var ms: Int64 = 1_760_400_000_000
        while HomePlanner.weekday(nowMs: ms - 4 * 3_600_000, tzOffsetMin: 0) != 0 { ms += 86_400_000 }
        #expect(HomePlanner.hero(hasFirstListen: true, hasTopRelease: true, dailyCount: 3, nowMs: ms, tzOffsetMin: 0, salt: 1).kind == HomePlanner.heroFirstListen)
        #expect(HomePlanner.hero(hasFirstListen: false, hasTopRelease: true, dailyCount: 3, nowMs: ms, tzOffsetMin: 0, salt: 1).kind == HomePlanner.heroRelease)
        let daily = HomePlanner.hero(hasFirstListen: false, hasTopRelease: false, dailyCount: 3, nowMs: ms, tzOffsetMin: 0, salt: 1)
        #expect(daily.kind == HomePlanner.heroDaily)
        #expect((0...2).contains(daily.index))
        #expect(HomePlanner.hero(hasFirstListen: false, hasTopRelease: false, dailyCount: 0, nowMs: ms, tzOffsetMin: 0, salt: 1).kind == HomePlanner.heroNone)
        let again = HomePlanner.hero(hasFirstListen: false, hasTopRelease: false, dailyCount: 3, nowMs: ms, tzOffsetMin: 0, salt: 1)
        #expect(daily.index == again.index)
    }

    @Test func theDaypartsAndThePlanKeyChangeWhereTheyShould() {
        let base: Int64 = 1_760_400_000_000
        let a = HomePlanner.planKey(nowMs: base, tzOffsetMin: 0)
        #expect(a == HomePlanner.planKey(nowMs: base + 60_000, tzOffsetMin: 0))
        var changed = 0
        var last = a
        for h in 1...24 {
            let k = HomePlanner.planKey(nowMs: base + Int64(h) * 3_600_000, tzOffsetMin: 0)
            if k != last { changed += 1 }
            last = k
        }
        #expect((3...5).contains(changed), "a day has about four dayparts, saw \(changed) changes")
    }

    @Test func jumpBackInTakesTheLastDistinctContexts() {
        let idx = HomePlanner.distinctContexts(["a", "b", "a", "c", "b", "d", "e", "f", "g"], count: 6)
        #expect(idx == [0, 1, 3, 5, 6, 7])
    }
}
