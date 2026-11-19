// Daily Mix and Your Mix with new music (docs/brain-spec.md, 6.1, 6.2, 8.2, stage 2a). A port of Android's
// `BrainMixes.kt`.
//
// The pool is a library shortlist plus the cached radios of the listener's own tracks; the order is the brain scorer
// (`MixPlanner`, weights `M0`); the list is saved in the served log, so it is the same all day and comes back after a
// restart, and the repetition budget reads it back (no track in two mixes on one day, a penalty for what was served
// often). Nothing here touches the network: new music comes from lists that listening and the refresh left in the cache.
//
// Every call is off the main actor and bounded: one pass over the library for a shortlist of about 500 tracks, a few
// file reads, one planner run. Nothing here runs at app start: the callers wait until the app has settled.

import Foundation
import PixlModel

public actor BrainMixes {
    public static let picks = 300
    public static let favourites = 150
    public static let deep = 100
    /// A saved mix with fewer songs left than this is not a mix: the caller builds a new one.
    public static let minSongs = 10
    public static let topArtists = 20
    static let rebuildMinAgeMs: Int64 = 10 * 60 * 1000

    private let engine: BrainEngine
    private let repository: BrainRepository
    private let served: ServedListStore
    private let sources: MixSources
    private let clock: @Sendable () -> Int64

    // One build at a time: a mutex that survives the awaits inside it (an actor alone does not).
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private var sliceKey = ""
    private var slice: [LibraryTrack] = []

    public init(directory: URL, repository: BrainRepository, engine: BrainEngine, sources: MixSources,
                clock: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        served = ServedListStore(directory: directory)
        self.repository = repository
        self.engine = engine
        self.sources = sources
        self.clock = clock
    }

    private func lock() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func unlock() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    public static func surfaceIdOf(kind: Int32) -> String { kind == MixPlanner.kindYour ? "your" : "daily" }

    static func nuQ(of mix: StoredMix) -> Int32 {
        Int32(truncatingIfNeeded: BrainMath.floorToLong(MixPlanner.nuOf(mix.kind, multiplier: Novelty.factor(mix.novelty)) * 1000.0))
    }

    // MARK: Who owns the mixes

    /// True when the brain scorer builds the mixes: switched on, and there is state to rank by. Loads the state.
    public func ownsMixes() async -> Bool {
        if BrainEngineChoice.clamp(await sources.engine()) != BrainEngineChoice.brain { return false }
        return await engine.hasState()
    }

    /// True when the brain has played tracks to rank by. Loads the state on first use.
    public func hasState() async -> Bool { await engine.hasState() }

    // MARK: What the screens ask for

    /// Both of today's mixes when the brain owns them (docs/brain-spec.md, 14: the switch is on and the brain has
    /// played tracks to rank by); nil means "the legacy mixes build as they always did". Today's saved mixes are read
    /// back first and need no brain state, so a restart shows them at once. With `regenerate` both are drawn again.
    /// Daily Mix is built first: Your Mix may not hold a track the Daily Mix of the same day holds.
    public func publish(regenerate: Bool = false) async -> (daily: MixView, your: MixView)? {
        if BrainEngineChoice.clamp(await sources.engine()) != BrainEngineChoice.brain { return nil }
        var daily = regenerate ? nil : await saved(kind: MixPlanner.kindDaily)
        var your = regenerate ? nil : await saved(kind: MixPlanner.kindYour)
        if daily == nil || your == nil {
            if !(await engine.hasState()) { return nil }
            if daily == nil { daily = await today(kind: MixPlanner.kindDaily, regenerate: regenerate) }
            if your == nil { your = await today(kind: MixPlanner.kindYour, regenerate: regenerate) }
        }
        guard let daily, let your else { return nil }
        return (daily, your)
    }

    /// Your Mix's regenerate button: another list, and the served log counts the one it replaces (8.2). Nil when the
    /// brain does not own the mixes (the legacy regenerate runs instead).
    public func regenerateYourMix() async -> MixView? {
        guard await ownsMixes() else { return nil }
        return await today(kind: MixPlanner.kindYour, regenerate: true)
    }

    // MARK: Reading and building

    /// Today's saved mix of `kind`, read back without building anything and without loading the brain's state: one
    /// small read of the served log. Nil when there is none, when it is too empty to show, or when it was built without
    /// new music and radios are cached now (see `isStale`).
    public func saved(kind: Int32) async -> MixView? {
        await lock()
        defer { unlock() }
        let now = clock()
        let tz = sources.tzOffsetMin(now)
        guard let stored = served.todays(surface: MixPlanner.surfaceOf(kind), nowMs: now, tzOffsetMin: tz) else { return nil }
        if await isStale(stored, now: now) { return nil }
        return await materialize(stored, now: now)
    }

    /// The listener removed a song from today's mix: it stays out when the mix is read back.
    public func removeItem(kind: Int32, songId: String) async {
        await lock()
        defer { unlock() }
        let now = clock()
        let surface = MixPlanner.surfaceOf(kind)
        guard var stored = served.todays(surface: surface, nowMs: now, tzOffsetMin: sources.tzOffsetMin(now)) else { return }
        let before = stored.items.count
        stored.items.removeAll { item in
            if let id = item.songId { return BrainKey.sameBytes(id, songId) }
            return item.row.map { BrainKey.sameBytes(EngineTrack(row: $0.row, rid: $0.rid).songId, songId) } ?? false
        }
        if stored.items.count == before { return }
        served.put(surface: surface, surfaceId: Self.surfaceIdOf(kind: kind), mix: stored, nuQ: Self.nuQ(of: stored), nowMs: now)
    }

    /// Today's mix of `kind`: the saved one when there is one for today's local day, otherwise a new one (which is then
    /// saved). With `regenerate` a new list is drawn whatever is saved. Nil when there is nothing to build a mix from
    /// (an empty library and no cached radios).
    public func today(kind: Int32, regenerate: Bool = false) async -> MixView? {
        await lock()
        defer { unlock() }
        let now = clock()
        let tz = sources.tzOffsetMin(now)
        let surface = MixPlanner.surfaceOf(kind)
        if !regenerate, let saved = served.todays(surface: surface, nowMs: now, tzOffsetMin: tz) {
            let stale = await isStale(saved, now: now)
            if !stale, let view = await materialize(saved, now: now) { return view }
        }
        let drawn: Int32 = regenerate ? served.buildsToday(surface: surface, nowMs: now, tzOffsetMin: tz) : 0
        let started = clock()
        guard let stored = await build(kind: kind, now: now, tz: tz, regenerate: drawn) else { return nil }
        sources.timing("brain_mix_build", max(clock() - started, 0))
        // The brain has been used: now (and not at app start) the one background job is scheduled.
        sources.mixBuilt()
        let recId = served.put(surface: surface, surfaceId: Self.surfaceIdOf(kind: kind), mix: stored,
                               nuQ: Self.nuQ(of: stored), nowMs: now)
        return await materialize(stored, now: now, recIdKnown: recId)
    }

    /// A mix built when no radio was cached holds no new music. Once lists are in the cache it is built again, once:
    /// the listener should not wait a day for the first new music. A mix with new music is the day's mix and stays.
    private func isStale(_ saved: StoredMix, now: Int64) async -> Bool {
        if saved.seedLists > 0 || saved.novelCount > 0 { return false }
        if now - saved.builtAtMs < Self.rebuildMinAgeMs { return false }
        return await repository.radiosFetchedSince(0) > 0
    }

    // MARK: Building

    private func build(kind: Int32, now: Int64, tz: Int32, regenerate: Int32) async -> StoredMix? {
        await repository.backfillEdgesOnce(nowMs: now)
        let surface = MixPlanner.surfaceOf(kind)
        let taste = await sources.constraints()
        let level = Novelty.clamp(await sources.noveltyLevel())
        let salt = await engine.salt()
        let all = await sources.library()
        let library = await shortlist(all, now: now, tz: tz, salt: salt, taste: taste)
        let ignored = await engine.ignoredRids(nowMs: now)
        let log = served.recent(nowMs: now)
        let taken = Repetition.takenOnDay(log, nowMs: now, tzOffsetMin: tz, exceptSurface: surface)
        let times = Repetition.timesServed(log, nowMs: now)

        var byRid: [Int64: LibraryTrack] = [:]
        byRid.reserveCapacity(library.count * 2)
        for track in library where byRid[track.rid] == nil { byRid[track.rid] = track }
        let picked = await pickSeeds(now: now, tz: tz, salt: salt, byRid: byRid, taste: taste)
        var seeds: [MixSeed] = []
        seeds.reserveCapacity(picked.count)
        for p in picked {
            let list = await repository.cachedRadio(seedRid: p.rid)
            let artistRows = await repository.cachedArtistRadio(seedRid: p.rid)
            if list == nil && artistRows.isEmpty { continue }
            seeds.append(MixSeed(rid: p.rid, aid: p.aid, title: p.title, artistName: p.artist, list: list, artistRows: artistRows))
        }
        if library.isEmpty && seeds.isEmpty { return nil }

        var names: [String] = []
        var seenNames: Set<BrainKey> = []
        func note(_ rows: [StoredRadioRow]) {
            for r in rows {
                if let n = r.row.artists.first?.name, seenNames.insert(BrainKey(n)).inserted { names.append(n) }
            }
        }
        for s in seeds {
            note(s.list?.rows ?? [])
            note(s.artistRows)
        }
        let nameAids = await repository.resolveArtistNames(names)
        var aidByName: [BrainKey: Int64] = [:]
        for i in names.indices { aidByName[BrainKey(names[i])] = nameAids[i] }

        let index = BrainLibraryIndex(songs: all)
        let pool = MixPoolBuilder.build(library: library, seeds: seeds, index: index, constraints: taste,
                                        ignoredRids: ignored) { aidByName[BrainKey($0)] ?? 0 }
        if pool.candidates.isEmpty { return nil }

        var edgeNodes = seeds.map(\.rid)
        edgeNodes.append(contentsOf: pool.novel.keys.sorted())
        let edges = await repository.edgesFor(edgeNodes)
        let request = MixPlanner.Request(
            kind: kind, candidates: pool.candidates, seeds: pool.seedLists, nowMs: now, tzOffsetMin: tz,
            nuMultiplier: Novelty.factor(level), salt: salt, regenerate: regenerate,
            excludedRids: taken.union(ignored), servedTimes: times, edges: edges)
        let plan = await engine.planMix(request)
        if plan.picks.isEmpty { return nil }

        var items: [StoredMixItem] = []
        items.reserveCapacity(plan.picks.count)
        for pick in plan.picks {
            let whyName = Self.whyNameOf(key: pick.whyKey, arg: pick.whyArg, pool: pool)
            let whyKey = (whyName.isEmpty && pick.whyKey != WhyLine.onRepeat) ? WhyLine.none : pick.whyKey
            if let novel = pool.novel[pick.rid] {
                items.append(StoredMixItem(rid: pick.rid, row: novel.stored, arm: pick.arm, slot: items.count,
                                           whyKey: whyKey, whyArg: pick.whyArg, whyName: whyName, retrQ: Int(pick.retrQ),
                                           radioRank: novel.radioRank > 0 ? novel.radioRank : -1))
            } else if let track = pool.library[pick.rid] {
                items.append(StoredMixItem(rid: pick.rid, songId: track.song.id, arm: pick.arm, slot: items.count,
                                           whyKey: whyKey, whyArg: pick.whyArg, whyName: whyName, retrQ: Int(pick.retrQ),
                                           radioRank: Int(pick.radioRank)))
            }
        }
        if items.isEmpty { return nil }
        return StoredMix(kind: kind, builtAtMs: now, seed: MixPlanner.tieSeedOf(request), regenerate: regenerate,
                         novelty: level, tasteSignature: taste.signature,
                         seedLists: seeds.filter { $0.list != nil }.count, items: items)
    }

    /// The name a reason is about, or "" when the sentence would have none (it is then not shown).
    static func whyNameOf(key: Int32, arg: Int64, pool: MixPool) -> String {
        if key == WhyLine.radioFans || key == WhyLine.artistMore { return pool.artistNames[arg] ?? "" }
        return ""
    }

    // MARK: The shortlist

    /// About 500 library tracks the mixes may pick: the legacy ranking's best 300 (it knows the library's own
    /// engagement counters), the favourites, and a day-seeded handful of the rest so deep cuts get a chance. Each gets
    /// its recording id; the whole library is not resolved.
    private func shortlist(_ all: [Song], now: Int64, tz: Int32, salt: Int64, taste: MixConstraints) async -> [LibraryTrack] {
        let day = Repetition.mixDay(now, tzOffsetMin: tz)
        let key = "\(all.count):\(day):\(taste.signature)"
        if BrainKey.sameBytes(key, sliceKey) && !slice.isEmpty { return slice }
        var chosen: [Song] = []
        var chosenIds: Set<BrainKey> = []
        func add(_ song: Song) -> Bool {
            if chosenIds.insert(BrainKey(song.id)).inserted {
                chosen.append(song)
                return true
            }
            return false
        }
        for song in await sources.legacyPicks(all, Self.picks, now, day) { _ = add(song) }
        for song in all where (taste.favoriteIds.contains(song.id) || song.isFavorite) && chosen.count < Self.picks + Self.favourites {
            _ = add(song)
        }
        let ids = all.map { Int64(bitPattern: BrainHash.fnv1a64($0.id)) }
        let order = Seeds.pseudoRandomOrder(ids, salt: salt, day: day)
        var bySongHash: [Int64: Song] = [:]
        bySongHash.reserveCapacity(all.count * 2)
        for i in all.indices { bySongHash[ids[i]] = all[i] }
        var deep = 0
        for h in order {
            if deep >= Self.deep { break }
            guard let song = bySongHash[h] else { continue }
            if add(song) { deep += 1 }
        }
        let allowed = chosen.filter { taste.allows($0) }
        var requests: [TrackRequest] = []
        var kept: [Song] = []
        requests.reserveCapacity(allowed.count)
        for song in allowed {
            guard let facts = TrackCatalog.facts(of: song) else { continue }
            requests.append(TrackRequest(keys: facts.keys, durationMs: Int32(clamping: max(song.duration, 0))))
            kept.append(song)
        }
        let rids = await repository.resolveTracks(requests)
        let aids = await repository.resolveArtistNames(kept.map { BrainLibraryIndex.primaryArtistName($0) })
        var out: [LibraryTrack] = []
        out.reserveCapacity(kept.count)
        for i in kept.indices where rids[i] != 0 {
            let song = kept[i]
            out.append(LibraryTrack(song: song, rid: rids[i], aid: aids[i],
                                    liked: song.isFavorite || taste.favoriteIds.contains(song.id), boostLn: taste.boostLn(song)))
        }
        sliceKey = key
        slice = out
        return out
    }

    // MARK: Seeds for the refresh (3.6, 3.7)

    /// Lane 1 of the refresh (3.7): the day's radio seeds, at most 24, two per artist, only tracks the listener chose
    /// (5.12 rule 10). Reads the library and the event log; never the network.
    public func seedsForRefresh() async -> [PickedSeed] {
        let now = clock()
        let tz = sources.tzOffsetMin(now)
        let taste = await sources.constraints()
        let all = await sources.library()
        let salt = await engine.salt()
        let library = await shortlist(all, now: now, tz: tz, salt: salt, taste: taste)
        var byRid: [Int64: LibraryTrack] = [:]
        for t in library where byRid[t.rid] == nil { byRid[t.rid] = t }
        return await pickSeeds(now: now, tz: tz, salt: salt, byRid: byRid, taste: taste)
    }

    /// Lane 2 of the refresh (3.7): one track for each of the listener's top `limit` artists (by artist affinity above
    /// `StationPlanner.artistArmAff` and enough plays), so the artist's top songs and radio are cached for the ARTIST arm
    /// of the mixes. The track is the artist's most played library track in the shortlist.
    public func topArtistSeeds(limit: Int = BrainMixes.topArtists) async -> [PickedSeed] {
        let now = clock()
        let tz = sources.tzOffsetMin(now)
        let taste = await sources.constraints()
        let all = await sources.library()
        let salt = await engine.salt()
        let library = await shortlist(all, now: now, tz: tz, salt: salt, taste: taste)
        return await engine.readAffinity { state in
            let p0 = Affinity.p0(state, nowMs: now)
            var best: [Int64: LibraryTrack] = [:]
            var bestWeight: [Int64: Double] = [:]
            for t in library where t.aid != 0 {
                let w = Affinity.weight(state, family: Family.track, key: t.rid, nowMs: now)
                if let old = bestWeight[t.aid], old >= w { continue }
                best[t.aid] = t
                bestWeight[t.aid] = w
            }
            var weights: [Int64: Double] = [:]
            var artists: [Int64] = []
            for aid in state.sortedKeys(Family.artist) where best[aid] != nil {
                if Affinity.aff(state, family: Family.artist, key: aid, nowMs: now, p0: p0) <= StationPlanner.artistArmAff { continue }
                let w = Affinity.weight(state, family: Family.artist, key: aid, nowMs: now)
                if w < StationPlanner.artistArmWeight { continue }
                weights[aid] = w
                artists.append(aid)
            }
            artists.sort { weights[$0]! != weights[$1]! ? weights[$0]! > weights[$1]! : $0 < $1 }
            return artists.prefix(limit).map { aid -> PickedSeed in
                let t = best[aid]!
                return PickedSeed(rid: t.rid, aid: aid, title: t.song.title,
                                  artist: BrainLibraryIndex.primaryArtistName(t.song), song: t.song)
            }
        }
    }

    /// The day's seeds (3.6): the four groups, at most 24, two per artist, the listener's own choices only.
    private func pickSeeds(now: Int64, tz: Int32, salt: Int64, byRid: [Int64: LibraryTrack],
                           taste: MixConstraints) async -> [PickedSeed] {
        let events = await engine.recentEvents(sinceMs: now - Seeds.savedWindowMs)
        let recent = SeedQueries.recentChosen(events, sinceMs: now - Seeds.recentWindowMs, limit: 40)
        let saved = SeedQueries.recentlySaved(events, sinceMs: now - Seeds.savedWindowMs, limit: 20)
        let day = Repetition.mixDay(now, tzOffsetMin: tz)
        let (top, random) = await engine.readAffinity { state -> ([Int64], [Int64]) in
            let p0 = Affinity.p0(state, nowMs: now)
            let keys = state.sortedKeys(Family.track)
            var weights: [Int64: Double] = [:]
            weights.reserveCapacity(keys.count)
            for k in keys { weights[k] = Affinity.weight(state, family: Family.track, key: k, nowMs: now) }
            let topRids = keys.sorted { weights[$0]! != weights[$1]! ? weights[$0]! > weights[$1]! : $0 < $1 }.prefix(40)
            let nonNegative = byRid.keys.filter { Affinity.aff(state, family: Family.track, key: $0, nowMs: now, p0: p0) >= 0.0 }
            return (Array(topRids), Seeds.pseudoRandomOrder(Array(nonNegative), salt: salt, day: day))
        }
        // Tracks outside the shortlist: the ones the engine has played and kept (`playable`), by recording.
        var playables: [Int64: EngineTrack] = [:]
        var wanted: Set<Int64> = Set(top)
        for row in recent { wanted.insert(row.rid) }
        for row in saved { wanted.insert(row.rid) }
        wanted = wanted.filter { byRid[$0] == nil }
        if !wanted.isEmpty {
            for track in await repository.engineTracks() where track.rid != 0 && wanted.contains(track.rid) {
                if playables[track.rid] == nil { playables[track.rid] = track }
            }
        }
        var aidRows: [Int64: Int64] = [:]
        for row in recent + saved where row.aid != 0 && aidRows[row.rid] == nil { aidRows[row.rid] = row.aid }
        let outsideRids = playables.keys.sorted().filter { playables[$0]?.artists.first != nil }
        if !outsideRids.isEmpty {
            let aids = await repository.resolveArtistNames(outsideRids.map { playables[$0]!.artists[0].name })
            for i in outsideRids.indices where aidRows[outsideRids[i]] == nil && aids[i] != 0 { aidRows[outsideRids[i]] = aids[i] }
        }
        let knownAids = aidRows
        let knownPlayables = playables
        func aidOf(_ rid: Int64) -> Int64 { byRid[rid]?.aid ?? knownAids[rid] ?? 0 }
        func source(_ row: RecentTrack) -> SeedGroups.Source {
            SeedGroups.Source(rid: row.rid, aid: row.aid != 0 ? row.aid : aidOf(row.rid))
        }
        let groups = SeedGroups.groups(
            recent: recent.map(source),
            top: top.map { SeedGroups.Source(rid: $0, aid: aidOf($0)) },
            saved: saved.map(source),
            randomRids: random,
            aidOf: aidOf,
            usable: { rid in
                if rid == 0 { return false }
                if let track = byRid[rid] { return taste.allows(track.song) }
                if let track = knownPlayables[rid] { return taste.allows(track.song()) }
                return false
            })
        return Seeds.select(groups).map { s in
            if let track = byRid[s.rid] {
                return PickedSeed(rid: s.rid, aid: s.aid, title: track.song.title,
                                  artist: BrainLibraryIndex.primaryArtistName(track.song), song: track.song)
            }
            let row = knownPlayables[s.rid]
            return PickedSeed(rid: s.rid, aid: s.aid, title: row?.title ?? "", artist: row?.artists.first?.name ?? "",
                              playable: row)
        }
    }

    // MARK: Reading a saved mix back

    /// The songs of a saved mix. A library song that left the library or that the listener has since sent away is
    /// dropped; a track from outside the library is registered in `playable` so that it plays. Nil when too little is
    /// left to call it a mix: the caller builds a new one.
    private func materialize(_ stored: StoredMix, now: Int64, recIdKnown: Int64 = 0) async -> MixView? {
        let taste = await sources.constraints()
        let libraryIds = stored.items.compactMap(\.songId)
        let library = libraryIds.isEmpty ? [:] : await sources.librarySongs(libraryIds)
        let surface = MixPlanner.surfaceOf(stored.kind)
        let recId = recIdKnown != 0 ? recIdKnown : ServedListStore.recIdOf(builtAtMs: stored.builtAtMs, surface: surface)
        var songs: [Song] = []
        songs.reserveCapacity(stored.items.count)
        var tracks: [EngineTrack] = []
        var reasons: [String: MixReason] = [:]
        var tags: [String: BrainItemTag] = [:]
        tags.reserveCapacity(stored.items.count * 2)
        var novel: Set<String> = []
        for item in stored.items {
            let song: Song
            var track: EngineTrack?
            if let id = item.songId {
                guard let found = library[id] else { continue }
                song = found
            } else {
                guard let row = item.row else { continue }
                let engineTrack = EngineTrack(row: row.row, rid: row.rid)
                track = engineTrack
                song = sources.song(engineTrack)
            }
            if !taste.allows(song) { continue }
            if let track {
                tracks.append(track)
                novel.insert(song.id)
            }
            songs.append(song)
            let keyName = WhyLine.nameOf(item.whyKey)
            if item.whyKey != WhyLine.none && (item.whyKey == WhyLine.onRepeat || !item.whyName.isEmpty) {
                reasons[song.id] = MixReason(key: keyName, arg: item.whyName)
            }
            tags[song.id] = BrainItemTag(
                surface: Surface.nameOf(surface), surfaceId: Self.surfaceIdOf(kind: stored.kind), recId: recId,
                slot: item.slot, arm: Arm.nameOf(item.arm), whyArg: item.whyName.isEmpty ? nil : item.whyName,
                radioRank: item.radioRank, retrQ: item.retrQ, whyKey: item.whyKey != WhyLine.none ? keyName : nil,
                primaryArtist: BrainLibraryIndex.primaryArtistName(song),
                // The listener chose to play the mix: its tracks are theirs, like a playlist's.
                chosen: true)
        }
        if songs.count < Self.minSongs { return nil }
        if !tracks.isEmpty { await repository.registerPlayable(tracks, nowMs: now) }
        return MixView(kind: stored.kind, builtAtMs: stored.builtAtMs, recId: recId, songs: songs, reasons: reasons,
                       tags: tags, novelIds: novel, engineTracks: tracks, seedLists: stored.seedLists)
    }
}
