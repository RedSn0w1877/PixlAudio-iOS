// "Your sound" (docs/brain-spec.md, 8.6) and a genre page (8.7) as the app reads them: what the listener's own plays say,
// worked out on the phone from the event log, the islands and the track facts, and what the model may honestly claim about
// itself (`ModelVoice`). Off the main thread, when the screen is opened, cached in memory for a few minutes; nothing here runs
// at app start. A section with nothing to say is empty and the screen leaves it out. Every figure is decided in `YourSound`,
// `ModelVoice` and `GenrePage` (the pure core); this file only gathers the rows and the names. The iOS twin of Android's
// `YourSoundRepository` and `GenrePageViewModel`.

import Foundation
import PixlModel

/// Reads Your sound and the genre pages.
public actor YourSoundReader {
    /// One island of "Right now": its share, and what tapping it shows (8.6 point 1): its top artists and songs by name (a name the brain
    /// does not know is left out), and the genre More / Less and "Play station" act on (`genreId` is -1 when the island has no genre
    /// the app may name).
    public struct IslandRow: Sendable, Equatable, Identifiable {
        public let id: Int
        public let name: String?
        public let permille: Int
        public let topArtists: [String]
        public let topSongs: [String]
        public let genreId: Int
        public let genreName: String?

        public init(id: Int, name: String?, permille: Int, topArtists: [String] = [], topSongs: [String] = [], genreId: Int = -1,
                    genreName: String? = nil) {
            self.id = id
            self.name = name
            self.permille = permille
            self.topArtists = topArtists
            self.topSongs = topSongs
            self.genreId = genreId
            self.genreName = genreName
        }
    }

    /// A family of the genre tree with the genres played inside it (8.6 point 2).
    public struct GenreFamilyRow: Sendable, Equatable {
        public let rootId: Int
        public let name: String
        public let permille: Int
        public let children: [GenreRow]
    }

    /// "Lately" (8.6 point 8): the names whose affinity moved most in 14 days.
    public struct Lately: Sendable, Equatable {
        public let up: [String]
        public let down: [String]
        public var isEmpty: Bool { up.isEmpty && down.isEmpty }
        public static let none = Lately(up: [], down: [])
    }

    /// "You and this genre" (8.7): when it was first played, how much of the listening it is, the tracks played most.
    public struct You: Sendable, Equatable {
        public let firstPlayedMs: Int64
        public let permille: Int
        public let plays: Int
        public let topSongs: [String]
    }

    /// What a genre page says beyond the atlas's own facts, all of it from the listener's own data (8.7).
    public struct GenreExtras: Sendable, Equatable {
        public let keyArtists: [String]
        public let libraryArtists: [String]
        public let you: You?
        public static let none = GenreExtras(keyArtists: [], libraryArtists: [], you: nil)
    }

    public struct GenreRow: Sendable, Equatable {
        public let atlasId: Int
        public let name: String
        public let permille: Int
    }

    public struct DaypartRow: Sendable, Equatable {
        public let daypart: Int
        public let plays: Int
        public let leadingIsland: String?
    }

    public struct MonthIsland: Sendable, Equatable {
        public let name: String?
        public let permille: Int
    }

    public struct MonthRow: Sendable, Equatable {
        public let month: Int
        public let plays: Int
        public let islands: [MonthIsland]
    }

    /// The completion rate of the picks ranked with the prior in control sessions, next to the learned weights' (5.12 point 8).
    public struct Control: Sendable, Equatable {
        public let controlPlays: Int
        public let controlPermille: Int?
        public let learnedPlays: Int
        public let learnedPermille: Int?
    }

    public struct State: Sendable {
        public let plays: Int
        public let islands: [IslandRow]
        public let genres: [GenreRow]
        public let genreTree: [GenreFamilyRow]
        public let lately: Lately
        public let decades: [YourSound.Decade]
        public let dayparts: [DaypartRow]
        public let months: [MonthRow]
        public let novelty: YourSound.Novelty?
        public let model: ModelVoice.State
        public let control: Control?
        /// Plays that moved the weights since they were last at the prior; "Reset what I've learned" is offered only above 0.
        public let modelUpdates: Int64
        public let computedAtMs: Int64

        public var isEmpty: Bool { plays == 0 }
    }

    /// One name of a genre page's links.
    public struct Link: Sendable, Equatable {
        public let id: Int
        public let name: String
    }

    /// A genre page's facts, with the names of its links (a link whose name the app does not say is dropped).
    public struct GenreFacts: Sendable {
        public let id: Int
        public let name: String
        public let description: String?
        public let origin: String?
        public let parents: [Link]
        public let children: [Link]
        public let related: [Link]
        public let influences: [Link]
    }

    static let cacheMs: Int64 = 5 * 60_000
    static let listenMs: Int32 = 30_000
    static let dnaChunk = 800
    /// A genre page's extras are worked out once and kept this long.
    static let extrasCacheMs: Int64 = 5 * 60_000

    private let engine: BrainEngine
    private let mixes: BrainMixes
    private let parts: Stage2bParts
    /// Stage 3: the genre stations (a genre page's "From your library") and the shelf bandit (cleared by a reset). Nil leaves them out.
    private let genre: GenreStations?
    private let shelves: ShelfStore?
    /// The saved Home rows and the Home plan: lists the learned weights ranked go with a reset (they are built again at the next visit).
    private let homeRows: BrainHomeRows?
    private let homePlans: HomePlanStore?
    /// Deezer, MusicBrainz and ListenBrainz all switched on: only then does a genre page name key artists (their tag votes).
    private let tagVotesAllowed: @Sendable () async -> Bool
    private let clock: @Sendable () -> Int64
    private var cached: State?
    /// Bumped by a reset: a figure that was being worked out before it is not kept (it would still show the old weights).
    private var generation = 0
    private var extrasCache: [Int: (atMs: Int64, value: GenreExtras)] = [:]
    /// The island names of one `compute` pass.
    private var nameCache: [Int: String?] = [:]

    public init(engine: BrainEngine, mixes: BrainMixes, parts: Stage2bParts, genre: GenreStations? = nil, shelves: ShelfStore? = nil,
                homeRows: BrainHomeRows? = nil, homePlans: HomePlanStore? = nil,
                tagVotesAllowed: @escaping @Sendable () async -> Bool = { true },
                clock: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        self.genre = genre
        self.shelves = shelves
        self.homeRows = homeRows
        self.homePlans = homePlans
        self.tagVotesAllowed = tagVotesAllowed
        self.engine = engine
        self.mixes = mixes
        self.parts = parts
        self.clock = clock
    }

    /// The figures, from the cache when they are under `cacheMs` old and no learner changed since.
    public func load(force: Bool = false) async -> State {
        let now = clock()
        let learnerNow = await engine.learnerGeneration()
        if !force, let cached, now - cached.computedAtMs >= 0, now - cached.computedAtMs < Self.cacheMs,
           cachedLearnerGeneration == learnerNow { return cached }
        let before = generation
        let beforeLearner = learnerNow
        let state = await compute(now)
        // A figure worked out while the weights were reset or a new learner was adopted still describes the old ones: it is shown once
        // and not kept.
        if before == generation, await engine.learnerGeneration() == beforeLearner {
            cached = state
            cachedLearnerGeneration = beforeLearner
        }
        return state
    }

    private var cachedLearnerGeneration = 0

    /// "Reset what I've learned": the weights go back to the prior; the log, the taste changes and the exclusions stay (8.6). The lists
    /// the learned weights ranked go with them: the saved Home rows and the Home plan are built again with the standard recipe (a saved
    /// mix notices by itself, see `BrainMixes`).
    public func resetLearned() async {
        generation += 1
        await engine.resetLearned()
        await shelves?.reset()
        await homeRows?.dropLearned()
        await homePlans?.clear()
        generation += 1
        cached = nil
        extrasCache = [:]
    }

    /// What one pass over the plays gives: the counted plays and the finish rates of the two kinds of picks.
    struct LogPass: Sendable {
        var rids: [Int64] = []
        var aids: [Int64] = []
        var starts: [Int64] = []
        var tzs: [Int32] = []
        /// The finish of each engine pick, by time, so the control and the learned picks are compared over the same weeks (5.12 point 8).
        var controlStarts: [Int64] = []
        var controlFinished: [Bool] = []
        var learnedStarts: [Int64] = []
        var learnedFinished: [Bool] = []
        /// "Lately" (8.6 point 8): the tables as they are now and as they stood 14 days ago, both made from the plays in order, and the
        /// plays that tags are added from once the track facts are read. Empty unless `pass` was given `lately`.
        var nowTables = Affinity.State()
        var earlierTables = Affinity.State()
        /// Plays from before the 14-day mark: "up" needs something to be up from.
        var beforeCutoffPlays = 0
        var tagRids: [Int64] = []
        var tagTimes: [Int64] = []
        var tagR: [Double] = []
        var tagC: [Double] = []
    }

    /// A counted play is a real listen (not excluded, not silent, and heard to the end or for 30 s). Pure; run off the actor. `events` is
    /// the log and the imported history as one stream in event order (`BrainEngine.mergedPlays`). A play with no timezone (an imported
    /// one, or a live one from before the offset was recorded) is read in the device's offset then (`deviceOffsetMin`), as the spec says
    /// for dayparts and months.
    static func pass(_ events: [PlayEvent], lately nowMs: Int64? = nil,
                     deviceOffsetMin: @Sendable (Int64) -> Int32 = { _ in 0 }) -> LogPass {
        var out = LogPass()
        var tracker = GradeTracker()
        let cutoff = (nowMs ?? 0) - Int64(YourSound.latelyDays) * BrainMath.dayMs
        for e in events {
            let excluded = e.has(EventFlags.learnExcluded) || e.has(EventFlags.neverAudible)
            if let nowMs {
                let t = e.startedAtMs > nowMs ? nowMs : e.startedAtMs
                let graded = tracker.grade(e, completions: out.nowTables.completions)
                if !excluded {
                    Affinity.applyEvent(&out.nowTables, e, graded, tMs: t)
                    if t <= cutoff {
                        Affinity.applyEvent(&out.earlierTables, e, graded, tMs: t)
                        out.beforeCutoffPlays += 1
                    }
                    out.tagRids.append(e.rid)
                    out.tagTimes.append(t)
                    out.tagR.append(graded.r)
                    out.tagC.append(graded.cOther)
                }
            }
            if excluded { continue }
            let listened = e.endReason == EndReason.trackDone || e.playedMs < 0 || e.playedMs >= listenMs
            if listened {
                out.rids.append(e.rid)
                out.aids.append(e.primaryAid)
                out.starts.append(e.startedAtMs)
                out.tzs.append(e.tzOffsetMin == PlayEvent.tzUnknown ? deviceOffsetMin(e.startedAtMs) : e.tzOffsetMin)
            }
            if Reward.isEngineSurface(e.surface) && e.origin == Origin.live {
                let g = Reward.grade(e, Reward.Context())
                if g.c > 0.0 {
                    let finished = g.r >= Reward.completionR
                    if e.has(EventFlags.controlSession) {
                        out.controlStarts.append(e.startedAtMs)
                        out.controlFinished.append(finished)
                    } else if e.modelVersion == BrainEngine.modelLearned {
                        out.learnedStarts.append(e.startedAtMs)
                        out.learnedFinished.append(finished)
                    }
                }
            }
        }
        return out
    }

    /// The two finish rates, compared over the same weeks: from the first play ranked with the learned weights (those exist only while
    /// the gate has them on), and only when BOTH sides have at least `Gate.controlMinPlays` plays in that span. Otherwise no rate is
    /// shown. Nil when neither side has a play.
    static func control(_ log: LogPass) -> Control? {
        if log.controlStarts.isEmpty && log.learnedStarts.isEmpty { return nil }
        let since = log.learnedStarts.min() ?? Int64.max
        var controlPlays = 0
        var controlFinished = 0
        for i in log.controlStarts.indices where log.controlStarts[i] >= since {
            controlPlays += 1
            if log.controlFinished[i] { controlFinished += 1 }
        }
        let learnedPlays = log.learnedStarts.count
        let learnedFinished = log.learnedFinished.filter { $0 }.count
        let enough = controlPlays >= Gate.controlMinPlays && learnedPlays >= Gate.controlMinPlays
        return Control(controlPlays: controlPlays,
                       controlPermille: enough ? Int(Double(controlFinished) / Double(controlPlays) * 1000.0 + 0.5) : nil,
                       learnedPlays: learnedPlays,
                       learnedPermille: enough ? Int(Double(learnedFinished) / Double(learnedPlays) * 1000.0 + 0.5) : nil)
    }

    private nonisolated static func deviceOffset(_ atMs: Int64) -> Int32 {
        Int32(TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(atMs) / 1000)) / 60)
    }

    private func compute(_ now: Int64) async -> State {
        // The model's own figures first: they come from the replay's graded plays, not from this screen's counting.
        let figures = await engine.learnerFigures()
        let model = ModelVoice.of(figures.summary, useLearned: figures.useLearned, modelUpdates: figures.updates)

        // The log and the imported history as one stream, in order, with merged recordings mapped to their survivor (as a rebuild reads
        // them). The merge and the counting run off every actor.
        let events = await engine.mergedPlays()
        let log = await Task.detached(priority: .utility) { Self.pass(events, lately: now, deviceOffsetMin: Self.deviceOffset) }.value
        let plays = YourSound.withFirsts(rids: log.rids, aids: log.aids, startedAtMs: log.starts, tzOffsetMin: log.tzs)
        let set = await parts.islands.current()
        let memberOf = set?.memberOf ?? [:]
        let islandOf: (Int64) -> Int = { memberOf[$0] ?? -1 }
        let atlas = await parts.atlas.atlas()

        // Island names: the same words the Daily Mixes carry (an island is named only when enough of it has a genre). Each island is
        // named once (a nil answer is remembered too: naming walks the library).
        nameCache = [:]

        // The track facts of every recording played: tags (genres), years, titles. Unknown stays unknown.
        var topTag: [Int64: Int] = [:]
        var tagVectors: [Int64: Tags.Vector] = [:]
        var year: [Int64: Int] = [:]
        var title: [Int64: String] = [:]
        if let dna = parts.dna {
            let distinct = Array(Set(log.rids).union(log.tagRids)).sorted()
            var from = 0
            while from < distinct.count {
                let to = min(from + Self.dnaChunk, distinct.count)
                for row in await dna.tracks(Array(distinct[from..<to])) {
                    let v = Tags.decode(Array(row.tags))
                    if !v.isEmpty {
                        topTag[row.rid] = v.top
                        tagVectors[row.rid] = v
                    }
                    if row.firstYear > 0 { year[row.rid] = row.firstYear }
                    if !BrainText.isBlank(row.title) {
                        title[row.rid] = BrainText.isBlank(row.artistDisplay) ? row.title : "\(row.title) · \(row.artistDisplay)"
                    }
                }
                from = to
            }
        }

        let islandShares = YourSound.islands(plays, islandOf: islandOf, nowMs: now, minPlays: YourSound.islandsMinPlays,
                                             minCoveragePermille: YourSound.islandsMinCoveragePermille)
        // Artist names, for the islands' top artists and for "Lately": the names the brain knows (an unknown one is left out).
        var artistNames: [Int64: String] = [:]
        var wanted: [Int64] = []
        for share in islandShares { for aid in share.topAids where !wanted.contains(aid) { wanted.append(aid) } }
        artistNames.merge(await namesOf(artists: wanted)) { _, new in new }

        var islandRows: [IslandRow] = []
        for share in islandShares {
            let island = set?.islands.first { $0.id == share.islandId }
            var genreId = -1
            if let island, let atlas {
                genreId = island.topTags.first { AtlasNames.genreName(atlas, $0) != nil } ?? -1
            }
            islandRows.append(IslandRow(
                id: share.islandId, name: await nameOf(share.islandId, set, now), permille: share.permille,
                topArtists: share.topAids.compactMap { artistNames[$0] }, topSongs: share.topRids.compactMap { title[$0] },
                genreId: genreId, genreName: genreId >= 0 ? atlas.flatMap { AtlasNames.genreName($0, genreId) } : nil))
        }
        var dayparts: [DaypartRow] = []
        for d in YourSound.dayparts(plays, minPlays: YourSound.daypartMinPlays, islandOf: islandOf) {
            dayparts.append(DaypartRow(daypart: d.daypart, plays: d.plays,
                                       leadingIsland: d.leadingIslandId >= 0 ? await nameOf(d.leadingIslandId, set, now) : nil))
        }
        var months: [MonthRow] = []
        for m in YourSound.months(plays, minPlays: YourSound.monthMinPlays, islandOf: islandOf) {
            var shares: [MonthIsland] = []
            for s in m.islandPermille.prefix(3) { shares.append(MonthIsland(name: await nameOf(s.islandId, set, now), permille: s.permille)) }
            months.append(MonthRow(month: m.month, plays: m.plays, islands: shares))
        }

        var genreRows: [GenreRow] = []
        var genreTree: [GenreFamilyRow] = []
        if let atlas {
            for g in YourSound.genres(plays, minPlays: YourSound.genresMinPlays, minCoveragePermille: YourSound.genresMinCoveragePermille,
                                      topTagOf: { topTag[$0] ?? GenreAtlas.none }) {
                if let name = AtlasNames.genreName(atlas, g.atlasId) {
                    genreRows.append(GenreRow(atlasId: g.atlasId, name: name, permille: g.permille))
                }
            }
            // The atlas tree: families (roots) with the genres played inside them. A family or genre the app does not name is absent.
            var rootCache: [Int: Int] = [:]
            let rootOf: (Int) -> Int = { id in
                if let known = rootCache[id] { return known }
                var best = id
                for ancestor in atlas.ancestors(id) where (atlas.genre(ancestor)?.depth ?? 1) == 0 {
                    best = ancestor
                    break
                }
                rootCache[id] = best
                return best
            }
            for family in YourSound.genreTree(plays, top: 8, topTagOf: { topTag[$0] ?? GenreAtlas.none }, rootOf: rootOf,
                                              minPlays: YourSound.genresMinPlays,
                                              minCoveragePermille: YourSound.genresMinCoveragePermille) {
                guard let name = AtlasNames.genreName(atlas, family.rootId) else { continue }
                let children = family.children.compactMap { child in
                    AtlasNames.genreName(atlas, child.atlasId).map { GenreRow(atlasId: child.atlasId, name: $0, permille: child.permille) }
                }
                genreTree.append(GenreFamilyRow(rootId: family.rootId, name: name, permille: family.permille, children: children))
            }
        }
        let decades = YourSound.decades(plays, minPlays: YourSound.erasMinPlays, yearOf: { year[$0] ?? 0 })
        let rawNovelty = YourSound.novelty(plays, nowMs: now)
        let novelty: YourSound.Novelty? = rawNovelty.plays >= YourSound.noveltyMinPlays ? rawNovelty : nil

        // "Lately": add the tags to the two sets of tables, then read the largest moves. "Up" needs something to be up from: with fewer
        // than `latelyMinBaselinePlays` plays from before the cutoff there is no baseline, and nothing is said.
        var nowTables = log.nowTables
        var earlierTables = log.earlierTables
        let cutoff = now - Int64(YourSound.latelyDays) * BrainMath.dayMs
        var lately = Lately.none
        if let atlas, log.beforeCutoffPlays >= YourSound.latelyMinBaselinePlays {
            for i in log.tagRids.indices {
                guard let v = tagVectors[log.tagRids[i]] else { continue }
                let t = log.tagTimes[i]
                for tg in v.tags {
                    let part = Double(tg.q) / 255.0
                    Affinity.apply(&nowTables, family: Family.tag, key: Int64(tg.atlasId), r: log.tagR[i], c: log.tagC[i], part: part, tMs: t)
                    if t <= cutoff {
                        Affinity.apply(&earlierTables, family: Family.tag, key: Int64(tg.atlasId), r: log.tagR[i], c: log.tagC[i], part: part, tMs: t)
                    }
                }
            }
            let moves = YourSound.lately(before: earlierTables, after: nowTables, beforeMs: cutoff, nowMs: now)
            artistNames.merge(await namesOf(artists: moves.filter { $0.family == Family.artist }.map(\.key))) { _, new in new }
            var up: [String] = []
            var down: [String] = []
            for m in moves {
                let name = m.family == Family.artist ? artistNames[m.key] : AtlasNames.genreName(atlas, Int(m.key))
                guard let name else { continue }
                if m.delta > 0.0 { up.append(name) } else { down.append(name) }
            }
            lately = Lately(up: up, down: down)
        }

        return State(plays: plays.count, islands: islandRows, genres: genreRows, genreTree: genreTree, lately: lately,
                     decades: decades, dayparts: dayparts, months: months, novelty: novelty, model: model,
                     control: Self.control(log), modelUpdates: figures.updates, computedAtMs: now)
    }

    /// The names the brain knows for `aids`: an artist it holds no row for, or whose name the app does not say, is absent.
    private func namesOf(artists aids: [Int64]) async -> [Int64: String] {
        guard let dna = parts.dna else { return [:] }
        var out: [Int64: String] = [:]
        var from = 0
        while from < aids.count {
            let to = min(from + Self.dnaChunk, aids.count)
            for row in await dna.artists(Array(aids[from..<to])) where !BrainText.isBlank(row.name) && AtlasNames.isShown(row.name) {
                out[row.aid] = row.name
            }
            from = to
        }
        return out
    }

    /// An island's name, the same words the Daily Mixes carry (an island is named only when enough of it has a genre).
    private func nameOf(_ id: Int, _ set: IslandSet?, _ now: Int64) async -> String? {
        if let known = nameCache[id] { return known }
        var found: String?
        if let island = set?.islands.first(where: { $0.id == id }) {
            let text = await mixes.islandSubtitle(island, nowMs: now)
            found = BrainText.isBlank(text) ? nil : text
        }
        nameCache[id] = .some(found)
        return found
    }

    // MARK: A genre page (8.7)

    /// The atlas's facts for `id` with the names of its links; nil when the atlas has no such genre, cannot be read, or the
    /// app does not say its name.
    public func genrePage(_ id: Int) async -> GenreFacts? {
        guard let atlas = await parts.atlas.atlas() else { return nil }
        return Self.facts(atlas, id)
    }

    /// What a genre page says beyond the atlas's own facts (8.7), all of it from the listener's own data: the artists the brain
    /// knows with the most of this genre in them (only while the three open-data sources that vote on tags are on), the artists of the
    /// listener's library under it, and "You and this genre". Nothing is guessed: an artist with no known genre is absent, and the "you"
    /// part does not exist for a genre the listener never played. Worked out once per genre and kept for a few minutes; the scans run
    /// off every actor.
    public func genreExtras(_ id: Int) async -> GenreExtras {
        let now = clock()
        if let hit = extrasCache[id], now - hit.atMs >= 0, now - hit.atMs < Self.extrasCacheMs { return hit.value }
        guard let atlas = await parts.atlas.atlas() else { return .none }
        let before = generation
        let keys = await tagVotesAllowed() ? await keyArtists(atlas, id) : []
        let extras = GenreExtras(keyArtists: keys, libraryArtists: await libraryArtists(id), you: await youAndGenre(atlas, id))
        if before == generation { extrasCache[id] = (now, extras) }
        return extras
    }

    static let keyArtistCount = 8

    /// Whether a tag is the genre or one of its descendants.
    static func under(_ atlas: GenreAtlas, _ tag: Int, _ id: Int) -> Bool { tag == id || atlas.ancestors(tag).contains(id) }

    /// The artists the brain holds a genre vector for, the largest weight under `id` first (ties: the smaller id). The ancestors of each
    /// tag are worked out once, and the pass over every artist runs off the actor.
    private func keyArtists(_ atlas: GenreAtlas, _ id: Int) async -> [String] {
        guard let dna = parts.dna else { return [] }
        let rows = await dna.artistsWithTags()
        return await Task.detached(priority: .utility) { () -> [String] in
            var underCache: [Int: Bool] = [:]
            var scored: [(aid: Int64, best: Int, name: String)] = []
            for row in rows {
                let v = Tags.decode(Array(row.tags))
                var best = 0
                for t in v.tags where Int(t.q) > best {
                    let inside: Bool
                    if let known = underCache[t.atlasId] { inside = known } else {
                        inside = Self.under(atlas, t.atlasId, id)
                        underCache[t.atlasId] = inside
                    }
                    if inside { best = Int(t.q) }
                }
                if best <= 0 || !AtlasNames.isShown(row.name) { continue }
                scored.append((row.aid, best, row.name))
            }
            scored.sort { $0.best != $1.best ? $0.best > $1.best : $0.aid < $1.aid }
            return scored.prefix(Self.keyArtistCount).map(\.name)
        }.value
    }

    /// The artists of the listener's own songs under the genre, the one with the most of them first.
    private func libraryArtists(_ id: Int) async -> [String] {
        guard let genre else { return [] }
        let songs = await genre.songsFor(kind: StationCard.kindGenre, atlasId: id, nowMs: clock())
        var counts: [BrainKey: Int] = [:]
        var order: [String] = []
        for song in songs {
            let name = BrainFeedback.artistOf(song)
            if BrainText.isBlank(name) || !AtlasNames.isShown(name) { continue }
            if counts[BrainKey(name)] == nil { order.append(name) }
            counts[BrainKey(name), default: 0] += 1
        }
        let indexed = order.enumerated().map { (index: $0.offset, name: $0.element, count: counts[BrainKey($0.element)] ?? 0) }
        return indexed.sorted { $0.count != $1.count ? $0.count > $1.count : $0.index < $1.index }
            .prefix(Self.keyArtistCount).map(\.name)
    }

    private func youAndGenre(_ atlas: GenreAtlas, _ id: Int) async -> You? {
        guard let dna = parts.dna else { return nil }
        let events = await engine.mergedPlays()
        let log = await Task.detached(priority: .utility) { Self.pass(events, deviceOffsetMin: Self.deviceOffset) }.value
        if log.rids.isEmpty { return nil }
        var belongs = Set<Int64>()
        var title: [Int64: String] = [:]
        let distinct = Array(Set(log.rids)).sorted()
        var from = 0
        while from < distinct.count {
            let to = min(from + Self.dnaChunk, distinct.count)
            for row in await dna.tracks(Array(distinct[from..<to])) {
                let v = Tags.decode(Array(row.tags))
                if v.tags.contains(where: { Self.under(atlas, $0.atlasId, id) }) {
                    belongs.insert(row.rid)
                    if !BrainText.isBlank(row.title) {
                        title[row.rid] = BrainText.isBlank(row.artistDisplay) ? row.title : "\(row.title) · \(row.artistDisplay)"
                    }
                }
            }
            from = to
        }
        let plays = YourSound.withFirsts(rids: log.rids, aids: log.aids, startedAtMs: log.starts, tzOffsetMin: log.tzs)
        guard let h = YourSound.genreHistory(plays, top: 5, belongs: { belongs.contains($0) }) else { return nil }
        return You(firstPlayedMs: h.firstPlayedMs, permille: h.permille, plays: h.plays, topSongs: h.topRids.compactMap { title[$0] })
    }

    static func facts(_ atlas: GenreAtlas, _ id: Int) -> GenreFacts? {
        guard let page = GenrePage.of(atlas, id), AtlasNames.isShown(page.name) else { return nil }
        func links(_ ids: [Int]) -> [Link] { ids.compactMap { other in AtlasNames.genreName(atlas, other).map { Link(id: other, name: $0) } } }
        return GenreFacts(id: id, name: page.name,
                          description: page.description.flatMap { AtlasNames.isShown($0) ? $0 : nil }, origin: page.origin,
                          parents: links(page.parents), children: links(page.children), related: links(page.related),
                          influences: links(page.influences))
    }
}
