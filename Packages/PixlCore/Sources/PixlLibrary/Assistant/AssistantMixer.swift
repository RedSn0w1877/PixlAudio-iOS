// The engine's answer to a `recommend` or `build_mix` request (docs/brain-spec.md, 9.3): the SAME pool, scorer and list builder a Your Mix
// uses (`MixPlanner`, `M0` or the learned weights while the gate has them on), over a pool the request shapes, with the request's filters
// applied to what the data knows. The assistant only fills the request; nothing here is a model's opinion. A port of Android's
// `AssistantMixer.kt`, as an extension of `BrainMixes` (which owns the pool's sources).
//
// The pool: the library shortlist, plus the cached (and, within the YouTube budget, fetched) radios of the seeds the request names, or of
// the day's own seeds when it names none. A filter the data cannot answer at all is not applied and is reported
// (`AssistantRules.unsupportedFilters`); a candidate whose own value is unknown never passes a filter on that value (unknown is absent,
// never guessed). Off the main thread: it runs on the actors that own the stores; the planner is tens of milliseconds.

import Foundation
import PixlModel

/// What the mixer needs to know about a seed ref: the track, its identity, and what a radio request is asked with.
public struct AssistantSeed: Sendable {
    public var ref: String
    public var rid: Int64
    public var aid: Int64
    public var title: String
    public var primaryArtist: String
    public var song: Song
    public var track: EngineTrack?
    public var radioSeed: RadioSeed?

    public init(ref: String, rid: Int64, aid: Int64, title: String, primaryArtist: String, song: Song, track: EngineTrack?,
                radioSeed: RadioSeed?) {
        self.ref = ref
        self.rid = rid
        self.aid = aid
        self.title = title
        self.primaryArtist = primaryArtist
        self.song = song
        self.track = track
        self.radioSeed = radioSeed
    }
}

/// One pick the engine made for an assistant request, with everything a play of it must carry.
public struct AssistantPickData: Sendable {
    public var rid: Int64
    public var song: Song
    public var track: EngineTrack?
    public var arm: Int32
    public var whyKey: Int32
    public var whyName: String
    public var retrQ: Int32
    public var radioRank: Int32
    public var explore: Bool
    public var servedX: [UInt8]?
    public var year: Int
    public var genreIds: [Int]
}

public struct AssistantPlan: Sendable {
    public var picks: [AssistantPickData]
    public var unsupported: [String]
    public var coldStart: Bool
    public var control: Bool
    public var modelVersion: Int
    public var seedListCount: Int
    /// False when no candidate of the pool has a tempo (or an energy) on record: a chip for that filter changes nothing and is not offered.
    public var tempoKnown: Bool = true
    public var energyKnown: Bool = true
    /// The refs of the seeds the request named that the plan could not use (no radio on the phone and none could be fetched).
    public var seedsNotUsed: [String] = []
}

extension BrainMixes {
    static let assistantIgnoredWindowMs: Int64 = 60 * 24 * 60 * 60 * 1000
    static let assistantDnaChunk = 800

    /// A stable small number from a request, so the same request on the same day is the same list and another request is another.
    public static func assistantRegen(of query: AssistantRules.Query, bump: Int) -> Int32 {
        var text = query.title + "|" + query.seedRefs.joined(separator: ",") + "|" + query.genreIds.map(String.init).joined(separator: ",")
        text += "|" + query.moodIds.map(String.init).joined(separator: ",") + "|\(query.yearFrom)-\(query.yearTo)|"
        text += query.energy + query.tempo + query.novelty + "\(query.noveltySharePct)|"
        text += query.excludeArtistRefs.joined(separator: ",") + "|" + query.excludeGenreIds.map(String.init).joined(separator: ",")
        return Int32(truncatingIfNeeded: 1000 + Int(BrainHash.fnv1a64(text) >> 40) + bump)
    }

    public func setAssistSuggestions(_ rows: (@Sendable () async -> [StoredRadioRow])?) { assistSuggestions = rows }

    /// Plans `query`. Nil when there is nothing to build from (no library and no cached radio).
    public func assistantPlan(_ query: AssistantRules.Query, seeds: [AssistantSeed], excludedArtists: [String],
                              regen: Int32) async -> AssistantPlan? {
        let now = clock()
        let tz = sources.tzOffsetMin(now)
        let taste = await sources.constraints()
        let salt = await engine.salt()
        let all = await sources.library()
        let library = await shortlist(all, now: now, tz: tz, salt: salt, taste: taste)
        let ignored = await engine.ignoredRids(nowMs: now)
        var byRid: [Int64: LibraryTrack] = [:]
        byRid.reserveCapacity(library.count * 2)
        for t in library where byRid[t.rid] == nil { byRid[t.rid] = t }

        // The seeds the request named; none named means the day's own seeds (the ones a Your Mix uses), from the cache only.
        var mixSeeds: [MixSeed] = []
        var notUsed: [String] = []
        for s in seeds {
            var list = await repository.cachedRadio(seedRid: s.rid)
            if list == nil, let radioSeed = s.radioSeed { list = await repository.radioFor(seed: radioSeed, allowNetwork: true) }
            let artistRows = await repository.cachedArtistRadio(seedRid: s.rid)
            if list == nil && artistRows.isEmpty {
                // Nothing similar to this seed can be had right now (offline, the day's lookups spent, a failed fetch): said, never hidden.
                notUsed.append(s.ref)
                continue
            }
            mixSeeds.append(MixSeed(rid: s.rid, aid: s.aid, title: s.title, artistName: s.primaryArtist, list: list, artistRows: artistRows))
        }
        if mixSeeds.isEmpty {
            for p in await pickSeeds(now: now, tz: tz, salt: salt, byRid: byRid, taste: taste) {
                let list = await repository.cachedRadio(seedRid: p.rid)
                let artistRows = await repository.cachedArtistRadio(seedRid: p.rid)
                if list == nil && artistRows.isEmpty { continue }
                mixSeeds.append(MixSeed(rid: p.rid, aid: p.aid, title: p.title, artistName: p.artist, list: list, artistRows: artistRows))
            }
        }
        // "Let Taizo help the engine" (off by default): songs the assistant suggested by artists the listener likely does not know join the pool
        // as an artist list, so they are candidates like any other (arm ASK, scored by the same ranker); a request for familiar music or for no
        // new music leaves them out.
        if query.novelty != AssistantRules.familiar && query.noveltySharePct != 0, let suggestions = assistSuggestions {
            let rows = await suggestions()
            if !rows.isEmpty { mixSeeds.append(MixSeed(rid: 0, aid: 0, title: "", artistName: "", list: nil, artistRows: rows)) }
        }
        let cold = !(await hasState())
        if library.isEmpty && mixSeeds.isEmpty { return nil }

        var names: [String] = []
        var seenNames: Set<BrainKey> = []
        func note(_ rows: [StoredRadioRow]) {
            for r in rows {
                if let n = r.row.artists.first?.name, seenNames.insert(BrainKey(n)).inserted { names.append(n) }
            }
        }
        for s in mixSeeds {
            note(s.list?.rows ?? [])
            note(s.artistRows)
        }
        let nameAids = await repository.resolveArtistNames(names)
        var aidByName: [BrainKey: Int64] = [:]
        for i in names.indices { aidByName[BrainKey(names[i])] = nameAids[i] }

        let index = BrainLibraryIndex(songs: all)
        let pool = MixPoolBuilder.build(library: library, seeds: mixSeeds, index: index, constraints: taste, ignoredRids: ignored) {
            aidByName[BrainKey($0)] ?? 0
        }
        if pool.candidates.isEmpty { return nil }

        // What the data says about every candidate: year, genres (ancestors included), tempo, energy, moods.
        let atlas = await parts?.atlas.atlas()
        var dna: [Int64: TrackDnaRow] = [:]
        if let repo = parts?.dna {
            let rids = pool.candidates.map(\.rid)
            var from = 0
            while from < rids.count {
                let chunk = Array(rids[from..<min(from + Self.assistantDnaChunk, rids.count)])
                for row in await repo.tracks(chunk) { dna[row.rid] = row }
                from += Self.assistantDnaChunk
            }
        }
        let candidateRids = pool.candidates.map(\.rid)
        let heard: Set<Int64> = await engine.readAffinity { st in
            Set(candidateRids.filter { Affinity.isHeard(st, family: Family.track, key: $0) })
        }
        var facts: [Int64: AssistantRules.Facts] = [:]
        var genresOf: [Int64: [Int]] = [:]
        facts.reserveCapacity(pool.candidates.count * 2)
        for c in pool.candidates {
            let libTrack = pool.library[c.rid]
            let novelEntry = pool.novel[c.rid]
            let row = dna[c.rid]
            let artist = libTrack.map { BrainLibraryIndex.primaryArtistName($0.song) } ?? (novelEntry?.track.artists.first?.name ?? "")
            var year = 0
            if let y = row?.firstYear, y > 0 { year = y } else if let y = libTrack?.song.year, y > 0 { year = y } else if let y = novelEntry?.stored.row.year { year = y }
            let genres = Self.assistantGenres(atlas, row)
            genresOf[c.rid] = genres
            let bpmX10 = row?.tempoBpmX10 ?? 0
            let energy = row.map { $0.energy >= 0 ? $0.energy : -1 } ?? -1
            let moods = (row?.moods ?? Data()).map { Int($0) + 1 }
            facts[c.rid] = AssistantRules.Facts(year: year, genreIds: genres, novel: !heard.contains(c.rid), bpm: bpmX10 > 0 ? bpmX10 / 10 : 0,
                                                artistKey: BrainText.fold(artist), energy: energy, moodIds: moods)
        }
        var seedEnergies: [Int] = []
        for s in seeds { if let e = dna[s.rid]?.energy, e >= 0 { seedEnergies.append(e) } }
        let energyRef = seedEnergies.isEmpty ? AssistantRules.energyMiddle : seedEnergies.reduce(0, +) / seedEnergies.count
        let ctx = AssistantRules.FilterContext(
            tempoKnown: facts.values.contains { $0.bpm > 0 }, energyKnown: facts.values.contains { $0.energy >= 0 },
            moodKnown: facts.values.contains { !$0.moodIds.isEmpty }, energyRef: energyRef, excludedArtists: excludedArtists)
        var kept: [Candidate] = []
        kept.reserveCapacity(pool.candidates.count)
        for c in pool.candidates { if let f = facts[c.rid], AssistantRules.passes(query, f, ctx) { kept.append(c) } }
        let unsupported = AssistantRules.unsupportedFilters(query, ctx)
        if kept.isEmpty {
            var empty = AssistantPlan(picks: [], unsupported: unsupported, coldStart: cold, control: false, modelVersion: 0,
                                      seedListCount: mixSeeds.filter { $0.list != nil }.count)
            empty.seedsNotUsed = notUsed
            return empty
        }

        var edgeNodes = mixSeeds.map(\.rid)
        edgeNodes.append(contentsOf: pool.novel.keys.sorted())
        let edges = await repository.edgesFor(edgeNodes)
        var candidates = kept
        var known = CandidateDna.Known(tags: [:], embeddings: nil)
        if let dnaParts = parts?.candidateDna {
            let enriched = await dnaParts.enrich(kept)
            candidates = enriched.candidates
            known = enriched.known
        }
        let level = Novelty.clamp(await sources.noveltyLevel())
        var request = MixPlanner.Request(
            kind: MixPlanner.kindYour, candidates: candidates, seeds: pool.seedLists, nowMs: now, tzOffsetMin: tz,
            nuMultiplier: Novelty.factor(level), salt: salt,
            // A different request draws another list; the same request on the same day draws the same one.
            regenerate: regen, excludedRids: ignored, servedTimes: [:], edges: edges, count: query.count,
            embeddings: known.embeddings, tagsByRid: known.tags)
        request.nuOverride = AssistantRules.noveltyShare(query, base: MixPlanner.nu0 * Novelty.factor(level))
        // Stage 5: the mix steps smoothly in tempo, loudness and energy (6.5).
        request.flowFacts = known.flowFacts
        let plan = await engine.planMix(request)

        var out: [AssistantPickData] = []
        out.reserveCapacity(plan.picks.count)
        for pick in plan.picks {
            let novel = pool.novel[pick.rid]
            let libTrack = pool.library[pick.rid]
            let song: Song
            if let n = novel { song = sources.song(n.track) } else if let l = libTrack { song = l.song } else { continue }
            let whyName: String
            if pick.whyKey == WhyLine.radioFans || pick.whyKey == WhyLine.artistMore { whyName = pool.artistNames[pick.whyArg] ?? "" } else { whyName = "" }
            out.append(AssistantPickData(
                rid: pick.rid, song: song, track: novel?.track,
                // Music the listener does not have is what the assistant "asked for" (arm ASK); their own songs keep the arm that found
                // them, so the ASK arm's record is about asking for new music, not about their library.
                arm: novel != nil ? Arm.ask : pick.arm, whyKey: pick.whyKey, whyName: whyName, retrQ: pick.retrQ,
                radioRank: (novel?.radioRank ?? 0) > 0 ? Int32(novel!.radioRank) : pick.radioRank, explore: pick.explore,
                servedX: pick.servedX, year: facts[pick.rid]?.year ?? 0, genreIds: genresOf[pick.rid] ?? []))
        }
        var result = AssistantPlan(picks: out, unsupported: unsupported, coldStart: cold, control: plan.control,
                                   modelVersion: Int(plan.modelVersion), seedListCount: mixSeeds.filter { $0.list != nil }.count)
        result.tempoKnown = ctx.tempoKnown
        result.energyKnown = ctx.energyKnown
        result.seedsNotUsed = notUsed
        return result
    }

    /// The atlas ids of a track's genres, ancestors included, or none when the DNA has no tags. Unknown stays unknown.
    static func assistantGenres(_ atlas: GenreAtlas?, _ row: TrackDnaRow?) -> [Int] {
        guard let atlas, let row else { return [] }
        let tags = row.tagVector
        if tags.isEmpty { return [] }
        var out: [Int] = []
        var seen: Set<Int> = []
        for t in tags.tags {
            if seen.insert(t.atlasId).inserted { out.append(t.atlasId) }
            for a in atlas.ancestors(t.atlasId) where seen.insert(a).inserted { out.append(a) }
        }
        return out
    }
}
