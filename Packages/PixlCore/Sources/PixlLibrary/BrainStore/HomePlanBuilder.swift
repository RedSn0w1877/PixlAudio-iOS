// Plans the Home page (docs/brain-spec.md, 8.1, stage 2) in the background: it builds the made-for-you lists and every shelf of
// the table in the fixed order, lets `HomePlanner` apply the page rules, and saves the result as `home_plan.json`. A port of
// Android's `HomePlanBuilder.kt`.
//
// Triggers (2.3 step 8): the first Home after 04:00 or a new daypart, a change to the listener's taste adjustments, and a saved
// plan that is missing. Never at app start and never on every Home start: `isDue` is a comparison of two numbers.
//
// Everything here reads the files and the caches the refresh left; nothing asks the network. A shelf whose music is not known
// yet is left out, and a plan with no shelf at all is still a plan (Jump back in and the library rows carry the page).

import Foundation
import PixlModel

public actor HomePlanBuilder {
    static let albumWindowMs: Int64 = 14 * 24 * 60 * 60 * 1000

    private let mixes: BrainMixes
    private let homeRows: BrainHomeRows?
    private let genre: GenreStations?
    private let store: HomePlanStore
    private let clock: @Sendable () -> Int64
    /// Stage 3: the context table (the daypart shelf) and the shelf bandit (the order of the page). Nil leaves the page as stage 2 made it.
    private let context: ContextStore?
    private let shelfStore: ShelfStore?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(mixes: BrainMixes, homeRows: BrainHomeRows?, genre: GenreStations?, store: HomePlanStore,
                context: ContextStore? = nil, shelfStore: ShelfStore? = nil,
                clock: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        self.context = context
        self.shelfStore = shelfStore
        self.mixes = mixes
        self.homeRows = homeRows
        self.genre = genre
        self.store = store
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

    /// True when the saved plan is for another day or daypart, or was made under other taste adjustments.
    public func isDue(_ plan: HomePlan?, nowMs: Int64, taste: String) async -> Bool {
        guard let plan else { return true }
        if !BrainKey.sameBytes(plan.taste, taste) { return true }
        // The islands were fitted again since this plan was made: its Daily Mix cards number islands that may have moved.
        if let set = await mixes.parts?.islands.current(), set.fitAtMs != plan.islandFitAtMs { return true }
        let tz = mixes.sources.tzOffsetMin(nowMs)
        return plan.planKey != HomePlanner.planKey(nowMs: nowMs, tzOffsetMin: tz)
    }

    /// Builds and saves the plan; nil when the brain does not own Home (switched off, or nothing to rank by yet).
    public func build() async -> HomePlan? {
        await lock()
        defer { unlock() }
        if BrainEngineChoice.clamp(await mixes.sources.engine()) != BrainEngineChoice.brain { return nil }
        if !(await mixes.hasState()) { return nil }
        let started = clock()
        var plan = await plan(clock())
        // Over the file's limit: fewer songs a shelf, and again with fewer, before giving up on saving it. A plan that is not
        // saved is shown this session but would be rebuilt (and Home would first paint a stale day) at every launch.
        var saved = await store.write(plan)
        if !saved {
            for maxItems in [10, 8, HomePlanner.minTracks] {
                let smaller = plan.shrunk(maxItems: maxItems)
                if await store.write(smaller) {
                    plan = smaller
                    saved = true
                    mixes.sources.timing("brain_home_plan_trimmed_\(maxItems)", 0)
                    break
                }
            }
            if !saved { mixes.sources.timing("brain_home_plan_not_saved", 0) }
        }
        mixes.sources.timing("brain_home_plan", max(clock() - started, 0))
        return plan
    }

    private func nameHash(_ name: String?) -> Int64 {
        guard let name, !BrainText.isBlank(name) else { return 0 }
        return BrainHash.id(BrainHash.fnv1a64(BrainText.fold(name)))
    }

    private func cardOf(_ view: MixView) -> PlanMix {
        var covers: [String] = []
        for song in view.songs {
            if let art = song.albumArtUriString, !art.isEmpty, !covers.contains(art) { covers.append(art) }
            if covers.count >= 3 { break }
        }
        return PlanMix(mixId: view.spec.surfaceId, kind: view.spec.kind, number: view.number, subtitle: view.subtitle,
                       count: view.songs.count, covers: covers, builtAtMs: view.builtAtMs)
    }

    private func libraryItems(_ view: MixView, arm: Int32) -> [PlanItem] {
        view.songs.enumerated().map { slot, song in
            PlanItem(rid: view.rids[song.id] ?? 0, aid: nameHash(BrainLibraryIndex.primaryArtistName(song)), songId: song.id, arm: arm, slot: slot)
        }
    }

    private func plan(_ now: Int64) async -> HomePlan {
        let tz = mixes.sources.tzOffsetMin(now)
        let constraints = await mixes.sources.constraints()
        let taste = constraints.signature
        // The islands first (weekly): the Daily Mixes are one per island.
        let islands = await mixes.parts?.builder.ensure()
        // The made-for-you lists, in the order that gives each its own music: a track is in one of them a day (6.4).
        var specs: [MixSpec] = [MixSpec(kind: MixKinds.firstListen)]
        if let islands, islands.hasMany {
            for island in islands.dailyIslands() { specs.append(MixSpec(kind: MixKinds.daily, islandId: island.id)) }
        } else {
            specs.append(MixSpec(kind: MixKinds.daily))
        }
        specs.append(MixSpec(kind: MixKinds.your))
        specs.append(MixSpec(kind: MixKinds.justDropped))
        var built: [MixView] = []
        // On Repeat is what the listener plays now: it takes its tracks first, so the lists drawn from the most played do not leave it short.
        let repeatView = await mixes.todayOf(MixSpec(kind: MixKinds.onRepeat))
        for spec in specs {
            if let view = await mixes.todayOf(spec) { built.append(view) }
        }
        let rediscoverView = await mixes.todayOf(MixSpec(kind: MixKinds.rediscover))
        let cards = built.map(cardOf)

        // New releases of the artists the listener loves, and the hero chosen from the page's inputs before any shelf is made:
        // a track is on the page once, so the release the hero shows is taken out of the shelf of releases.
        let allSongs = await mixes.sources.library()
        var releaseCards: [NewReleaseRules.Card] = []
        if let releases = await mixes.parts?.newReleases {
            releaseCards = await releases.cards(blocked: constraints.blocked, adjustments: constraints.adjustments,
                                                library: BrainLibraryIndex(songs: allSongs))
        }
        let dailyCards = cards.filter { $0.kind == MixKinds.daily }
        let topRelease = await topArtistRelease(now, cards: releaseCards)
        let salt = await mixes.engine.salt()
        let hero = HomePlanner.hero(hasFirstListen: cards.contains { $0.kind == MixKinds.firstListen },
                                    hasTopRelease: topRelease != nil, dailyCount: dailyCards.count, nowMs: now, tzOffsetMin: tz, salt: salt)
        let heroRid: Int64? = hero.kind == HomePlanner.heroRelease ? topRelease?.rid : nil

        var shelves: [PlanShelf] = []
        var inputs: [HomePlanner.ShelfIn] = []
        func addShelf(_ shelf: PlanShelf) {
            let index = shelves.count
            shelves.append(shelf)
            let items: [HomePlanner.Item]
            if !shelf.mixes.isEmpty {
                items = shelf.mixes.indices.map { HomePlanner.Item(rid: 0, aid: 0, key: $0) }
            } else if !shelf.stations.isEmpty {
                items = shelf.stations.indices.map { HomePlanner.Item(rid: 0, aid: 0, key: $0) }
            } else {
                items = shelf.items.enumerated().map { HomePlanner.Item(rid: $1.rid, aid: $1.aid, key: $0) }
            }
            inputs.append(HomePlanner.ShelfIn(type: shelf.type, id: "\(index):\(shelf.id)", items: items))
        }

        // Made for you: the lists as cards.
        if !cards.isEmpty {
            addShelf(PlanShelf(type: HomePlanner.madeForYou, id: "made_for_you", titleKey: "made_for_you", mixes: cards))
        }
        // Because you listened to X (at most two, the newest anchors by different artists): their saved rows.
        if let homeRows {
            for row in await homeRows.cached().prefix(2) {
                let items = row.items.enumerated().map { slot, item -> PlanItem in
                    let artist = item.track.artists.first?.name
                    let artistMore = item.arm == Arm.artist && !(artist.map(BrainText.isBlank) ?? true)
                    return PlanItem(rid: item.track.rid, aid: nameHash(artist),
                                    row: StoredRadioRow(row: item.track.toRadioRow(), rid: item.track.rid), arm: item.arm,
                                    whyKey: artistMore ? WhyLine.artistMore : WhyLine.radioFans,
                                    whyName: artistMore ? (artist ?? "") : row.anchor.primaryArtist, slot: slot,
                                    explore: item.explore)
                }
                addShelf(PlanShelf(type: HomePlanner.becauseListened, id: row.id, titleKey: "because_listened",
                                   titleArg: row.anchor.title, subtitleKey: "because_listened_subtitle", items: items, recId: row.recId,
                                   control: row.control, model: row.model))
            }
        }
        // Your weekday nights (stage 3): the island that fits this time of the week, only once the bucket has 50 plays (5.10).
        if let shelf = await daypartShelf(now, tz: tz, islands: islands) { addShelf(shelf) }
        // New from artists you love: the saved releases (not the one the hero plays).
        let shelfCards = releaseCards.filter { $0.stored.rid != heroRid }
        if !shelfCards.isEmpty {
            let items = shelfCards.enumerated().map { slot, c in
                PlanItem(rid: c.stored.rid, aid: nameHash(c.stored.row.artists.first?.name), row: c.stored, arm: Arm.new,
                         whyKey: WhyLine.newRelease, whyName: c.release.artistName, slot: slot)
            }
            let found = shelfCards.map { $0.release.foundAtMs }.max() ?? now
            addShelf(PlanShelf(type: HomePlanner.newFromLoved, id: "new_from_loved", titleKey: "new_from_loved",
                               subtitleKey: "new_from_loved_subtitle", items: items, recId: BrainReleaseRow.recId(builtAtMs: found)))
        }
        if let repeatView {
            addShelf(PlanShelf(type: HomePlanner.onRepeat, id: "on_repeat", titleKey: "on_repeat", subtitleKey: "on_repeat_subtitle",
                               items: libraryItems(repeatView, arm: Arm.fav), recId: repeatView.recId))
        }
        if let rediscoverView {
            addShelf(PlanShelf(type: HomePlanner.rediscover, id: "rediscover", titleKey: "rediscover", subtitleKey: "rediscover_subtitle",
                               items: libraryItems(rediscoverView, arm: Arm.fav), recId: rediscoverView.recId))
        }
        // Stations for you: genres and moods of the listener's own songs, plus one genre next to them.
        let adjacent = await mixes.adjacentGenres()
        if let genre {
            let stationCards = await genre.cards(nowMs: now, adjacent: adjacent)
            if !stationCards.isEmpty {
                addShelf(PlanShelf(type: HomePlanner.stations, id: "stations", titleKey: "stations", subtitleKey: "stations_subtitle",
                                   stations: stationCards.map { PlanStation(kind: $0.kind, atlasId: $0.atlasId, name: $0.name, count: $0.count, covers: $0.covers) }))
            }
        }
        if let shelf = await stepSideways(now, adjacent: adjacent) { addShelf(shelf) }
        if let shelf = await moreLikeAlbum(now, allSongs: allSongs, constraints: constraints) { addShelf(shelf) }

        // The shelf bandit's order (5.10), drawn once per daypart; with no data, or while the gate has the prior on, stage 2's fixed
        // order stays.
        var ordered = inputs
        if let shelfStore {
            var fixedTypes: [Int32] = []
            for input in inputs where !fixedTypes.contains(input.type) { fixedTypes.append(input.type) }
            if let drawn = await shelfStore.order(types: fixedTypes, planKey: HomePlanner.planKey(nowMs: now, tzOffsetMin: tz),
                                               daypart: Int(HomePlanner.daypart(nowMs: now, tzOffsetMin: tz)), salt: salt, nowMs: now) {
                ordered = HomePlanner.reorder(inputs, typeOrder: drawn)
            }
        }
        // The page rules.
        let chosen = HomePlanner.plan(ordered)
        var out: [PlanShelf] = []
        out.reserveCapacity(chosen.count)
        for s in chosen {
            guard let colon = s.id.firstIndex(of: ":"), let index = Int(s.id[s.id.startIndex..<colon]), index < shelves.count else { continue }
            var source = shelves[index]
            let keep = s.items.map(\.key)
            if !source.mixes.isEmpty {
                source.mixes = keep.map { source.mixes[$0] }
            } else if !source.stations.isEmpty {
                source.stations = keep.map { source.stations[$0] }
            } else {
                source.items = keep.map { source.items[$0] }
            }
            out.append(source)
        }

        // The hero (chosen above): First Listen on Mondays, a release from a top-5 artist, else a Daily Mix.
        var planHero: PlanHero?
        switch hero.kind {
        case HomePlanner.heroFirstListen: planHero = PlanHero(kind: hero.kind, mixId: "first")
        case HomePlanner.heroDaily: planHero = PlanHero(kind: hero.kind, mixId: dailyCards[hero.index].mixId)
        case HomePlanner.heroRelease: planHero = topRelease.map { PlanHero(kind: hero.kind, item: $0, artistName: $0.whyName) }
        default: planHero = nil
        }
        return HomePlan(generatedAtMs: now, planKey: HomePlanner.planKey(nowMs: now, tzOffsetMin: tz), taste: taste,
                        daypart: HomePlanner.daypart(nowMs: now, tzOffsetMin: tz), weekday: HomePlanner.weekday(nowMs: now, tzOffsetMin: tz),
                        hero: planHero, mixes: cards, shelves: out, islandFitAtMs: islands?.fitAtMs ?? 0)
    }

    /// "Your weekday nights": the daypart mix of the island that leads this bucket of the week. Absent until the bucket has
    /// `ContextLift.minPlays` plays with an island, and while the listener has one island only (nothing leads).
    private func daypartShelf(_ now: Int64, tz: Int32, islands: IslandSet?) async -> PlanShelf? {
        guard let context, let islands, islands.hasMany, let table = await context.table(nowMs: now) else { return nil }
        let bucket = ContextLift.bucket(now, tzOffsetMin: tz)
        if !table.hasLift(bucket) { return nil }
        let leader = table.leader(bucket, islands.dailyIslands().map { (id: $0.id, weight: $0.weight) })
        if leader < 0 { return nil }
        guard let view = await mixes.todayOf(MixSpec(kind: MixKinds.daypart, islandId: leader, part: bucket)) else { return nil }
        var byRid: [Int64: StoredMixItem] = [:]
        byRid.reserveCapacity(view.storedItems.count * 2)
        for item in view.storedItems { byRid[item.rid] = item }
        var items: [PlanItem] = []
        items.reserveCapacity(view.songs.count)
        for song in view.songs {
            guard let rid = view.rids[song.id], let stored = byRid[rid] else { continue }
            let row = view.novelIds.contains(song.id) ? stored.row : nil
            items.append(PlanItem(rid: rid, aid: nameHash(row != nil ? row?.row.artists.first?.name : BrainLibraryIndex.primaryArtistName(song)),
                                  songId: row == nil ? song.id : nil, row: row, arm: stored.arm, slot: items.count, explore: stored.explore))
        }
        if items.count < HomePlanner.minTracks { return nil }
        return PlanShelf(type: HomePlanner.daypartMix, id: "daypart:\(bucket)", titleKey: "your_daypart", titleArg: String(bucket),
                         subtitleKey: "your_daypart_subtitle", items: items, recId: view.recId, control: view.control, model: view.model)
    }

    /// A release by one of the listener's five most played artists, or nil.
    private func topArtistRelease(_ now: Int64, cards: [NewReleaseRules.Card]) async -> PlanItem? {
        if cards.isEmpty { return nil }
        let names = cards.map { $0.stored.row.artists.first?.name ?? "" }
        let aids = await mixes.repository.resolveArtistNames(names)
        let top: Set<Int64> = await mixes.engine.readAffinity { st in
            var weights: [Int64: Double] = [:]
            let keys = st.sortedKeys(Family.artist)
            for k in keys { weights[k] = Affinity.weight(st, family: Family.artist, key: k, nowMs: now) }
            let ordered = keys.sorted { weights[$0]! != weights[$1]! ? weights[$0]! > weights[$1]! : $0 < $1 }
            return Set(ordered.prefix(5))
        }
        for i in cards.indices where top.contains(aids[i]) {
            let c = cards[i]
            return PlanItem(rid: c.stored.rid, aid: nameHash(names[i]), row: c.stored, arm: Arm.new, whyKey: WhyLine.newRelease,
                            whyName: c.release.artistName, slot: 0)
        }
        return nil
    }

    /// "A step sideways": one genre next to what the listener plays, with songs of it they have not played. The card says so.
    private func stepSideways(_ now: Int64, adjacent: [Int]) async -> PlanShelf? {
        if adjacent.isEmpty { return nil }
        guard let atlas = await mixes.parts?.atlas.atlas() else { return nil }
        let byGenre = await mixes.edgeByGenre(now)
        var best: (genre: Int, tracks: [LibraryTrack])?
        for g in byGenre where best == nil || g.tracks.count > best!.tracks.count { best = g }
        guard let best, best.tracks.count >= HomePlanner.minTracks, let name = AtlasNames.genreName(atlas, best.genre) else { return nil }
        let items = best.tracks.prefix(HomePlanner.itemsPerShelf * 2).enumerated().map { slot, t in
            PlanItem(rid: t.rid, aid: nameHash(BrainLibraryIndex.primaryArtistName(t.song)), songId: t.song.id, arm: Arm.edge,
                     whyKey: WhyLine.adjacentGenre, slot: slot)
        }
        return PlanShelf(type: HomePlanner.stepSideways, id: "step_sideways:\(best.genre)", titleKey: "step_sideways", titleArg: name,
                         subtitleKey: "step_sideways_subtitle", items: Array(items))
    }

    /// "More like <album>": an album the listener finished three songs of lately, as a station of its radios (the cached ones of up
    /// to three of its songs, merged by co-occurrence, 6.2). Nothing is fetched: an album none of whose radios are cached gets no shelf.
    private func moreLikeAlbum(_ now: Int64, allSongs: [Song], constraints: MixConstraints) async -> PlanShelf? {
        guard let parts = await mixes.parts else { return nil }
        let events = await mixes.engine.recentEvents(sinceMs: now - Self.albumWindowMs)
        let recent = BrainEventQueries.recentCompleted(events, sinceMs: now - Self.albumWindowMs, limit: 80)
        if recent.isEmpty { return nil }
        let library = await parts.libraryRids.all(nowMs: now)
        var byRid: [Int64: LibraryTrack] = [:]
        byRid.reserveCapacity(library.count * 2)
        for t in library where byRid[t.rid] == nil { byRid[t.rid] = t }
        struct Group { var album: String; var tracks: [LibraryTrack]; var newest: Int64 }
        var groups: [Group] = []
        for row in recent {
            guard let track = byRid[row.rid] else { continue }
            let album = track.song.album
            if BrainText.isBlank(album) || album.lowercased() == "unknown album" { continue }
            if let i = groups.firstIndex(where: { BrainKey.sameBytes($0.album, album) }) {
                if !groups[i].tracks.contains(where: { $0.rid == track.rid }) { groups[i].tracks.append(track) }
            } else {
                groups.append(Group(album: album, tracks: [track], newest: row.lastMs))
            }
        }
        let ignored = await mixes.engine.ignoredRids(nowMs: now)
        let index = BrainLibraryIndex(songs: allSongs)
        for g in groups.filter({ $0.tracks.count >= 3 }).sorted(by: { $0.newest > $1.newest }) {
            var seeds: [MixSeed] = []
            for t in g.tracks.prefix(3) {
                guard let list = await mixes.repository.cachedRadio(seedRid: t.rid) else { continue }
                seeds.append(MixSeed(rid: t.rid, aid: t.aid, title: t.song.title, artistName: BrainLibraryIndex.primaryArtistName(t.song), list: list))
            }
            if seeds.isEmpty { continue }
            var names: [String] = []
            var seenNames = Set<BrainKey>()
            for s in seeds {
                for r in s.list?.rows ?? [] {
                    if let n = r.row.artists.first?.name, seenNames.insert(BrainKey(n)).inserted { names.append(n) }
                }
            }
            let nameAids = await mixes.repository.resolveArtistNames(names)
            var aidByName: [BrainKey: Int64] = [:]
            for i in names.indices { aidByName[BrainKey(names[i])] = nameAids[i] }
            let pool = MixPoolBuilder.build(library: [], seeds: seeds, index: index, constraints: constraints, ignoredRids: ignored) {
                aidByName[BrainKey($0)] ?? 0
            }
            if pool.novel.count < HomePlanner.minTracks { continue }
            let seedLists = pool.seedLists
            let cooc: [Int64: Retrieval.Entry] = await mixes.engine.readAffinity { st in
                Retrieval.cooc(seedLists, affinity: st, nowMs: now, p0: Affinity.p0(st, nowMs: now))
            }
            let ranked = pool.novel.values.sorted { a, b in
                let ka = BrainMath.orderKey(cooc[a.stored.rid]?.cooc ?? 0.0)
                let kb = BrainMath.orderKey(cooc[b.stored.rid]?.cooc ?? 0.0)
                if ka != kb { return ka > kb }
                return a.stored.rid < b.stored.rid
            }
            let items = ranked.prefix(HomePlanner.itemsPerShelf * 2).enumerated().map { slot, n in
                PlanItem(rid: n.stored.rid, aid: nameHash(n.stored.row.artists.first?.name), row: n.stored, arm: Arm.radio,
                         whyKey: WhyLine.radioFans, whyName: n.seedArtist, slot: slot)
            }
            return PlanShelf(type: HomePlanner.moreLikeAlbum, id: "more_like_album", titleKey: "more_like_album", titleArg: g.album,
                             subtitleKey: "more_like_album_subtitle", items: Array(items))
        }
        return nil
    }
}
