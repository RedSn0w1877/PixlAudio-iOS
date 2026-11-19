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
    public struct IslandRow: Sendable, Equatable {
        public let id: Int
        public let name: String?
        public let permille: Int
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
        public let decades: [YourSound.Decade]
        public let dayparts: [DaypartRow]
        public let months: [MonthRow]
        public let novelty: YourSound.Novelty?
        public let model: ModelVoice.State
        public let control: Control?
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

    private let engine: BrainEngine
    private let mixes: BrainMixes
    private let parts: Stage2bParts
    private let clock: @Sendable () -> Int64
    private var cached: State?
    /// The island names of one `compute` pass.
    private var nameCache: [Int: String?] = [:]

    public init(engine: BrainEngine, mixes: BrainMixes, parts: Stage2bParts,
                clock: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        self.engine = engine
        self.mixes = mixes
        self.parts = parts
        self.clock = clock
    }

    /// The figures, from the cache when they are under `cacheMs` old.
    public func load(force: Bool = false) async -> State {
        let now = clock()
        if !force, let cached, now - cached.computedAtMs >= 0, now - cached.computedAtMs < Self.cacheMs { return cached }
        let state = await compute(now)
        cached = state
        return state
    }

    /// "Reset what I've learned": the weights go back to the prior; the log, the taste changes and the exclusions stay (8.6).
    public func resetLearned() async {
        await engine.resetLearned()
        cached = nil
    }

    /// What one pass over the log gives: the counted plays and the control-session completion counts.
    struct LogPass: Sendable {
        var rids: [Int64] = []
        var aids: [Int64] = []
        var starts: [Int64] = []
        var tzs: [Int32] = []
        var controlPlays = 0
        var controlFinished = 0
        var learnedPlays = 0
        var learnedFinished = 0
    }

    /// A counted play is a real listen (not excluded, not silent, and heard to the end or for 30 s). Pure; run off the actor.
    static func pass(_ events: [PlayEvent]) -> LogPass {
        var out = LogPass()
        for e in events {
            if e.has(EventFlags.learnExcluded) || e.has(EventFlags.neverAudible) { continue }
            let listened = e.endReason == EndReason.trackDone || e.playedMs < 0 || e.playedMs >= listenMs
            if listened {
                out.rids.append(e.rid)
                out.aids.append(e.primaryAid)
                out.starts.append(e.startedAtMs)
                out.tzs.append(e.tzOffsetMin == PlayEvent.tzUnknown ? 0 : e.tzOffsetMin)
            }
            if Reward.isEngineSurface(e.surface) && e.origin == Origin.live {
                let g = Reward.grade(e, Reward.Context())
                if g.c > 0.0 {
                    let finished = g.r >= Reward.completionR
                    if e.has(EventFlags.controlSession) {
                        out.controlPlays += 1
                        if finished { out.controlFinished += 1 }
                    } else if e.modelVersion == BrainEngine.modelLearned {
                        out.learnedPlays += 1
                        if finished { out.learnedFinished += 1 }
                    }
                }
            }
        }
        return out
    }

    private func compute(_ now: Int64) async -> State {
        // The model's own figures first: they come from the replay's graded plays, not from this screen's counting.
        let figures = await engine.learnerFigures()
        let model = ModelVoice.of(figures.summary, useLearned: figures.useLearned, modelUpdates: figures.updates)

        // The log, in order. The file is read here and decoded and counted off this actor.
        let payloads = await engine.eventPayloads()
        let log = await Task.detached(priority: .utility) { Self.pass(BrainEventLog.decodeSorted(payloads)) }.value
        let plays = YourSound.withFirsts(rids: log.rids, aids: log.aids, startedAtMs: log.starts, tzOffsetMin: log.tzs)
        let set = await parts.islands.current()
        let memberOf = set?.memberOf ?? [:]
        let islandOf: (Int64) -> Int = { memberOf[$0] ?? -1 }
        let atlas = await parts.atlas.atlas()

        // Island names: the same words the Daily Mixes carry (an island is named only when enough of it has a genre).
        nameCache = [:]

        var islandRows: [IslandRow] = []
        for share in YourSound.islands(plays, islandOf: islandOf, nowMs: now) {
            islandRows.append(IslandRow(id: share.islandId, name: await nameOf(share.islandId, set, now), permille: share.permille))
        }
        var dayparts: [DaypartRow] = []
        for d in YourSound.dayparts(plays, islandOf: islandOf) {
            dayparts.append(DaypartRow(daypart: d.daypart, plays: d.plays,
                                       leadingIsland: d.leadingIslandId >= 0 ? await nameOf(d.leadingIslandId, set, now) : nil))
        }
        var months: [MonthRow] = []
        for m in YourSound.months(plays, islandOf: islandOf) {
            var shares: [MonthIsland] = []
            for s in m.islandPermille.prefix(3) { shares.append(MonthIsland(name: await nameOf(s.islandId, set, now), permille: s.permille)) }
            months.append(MonthRow(month: m.month, plays: m.plays, islands: shares))
        }

        // Genres and years: what the track facts hold for the recordings played; unknown stays unknown.
        var topTag: [Int64: Int] = [:]
        var year: [Int64: Int] = [:]
        if let dna = parts.dna {
            let distinct = Array(Set(log.rids)).sorted()
            var from = 0
            while from < distinct.count {
                let to = min(from + Self.dnaChunk, distinct.count)
                for row in await dna.tracks(Array(distinct[from..<to])) {
                    let v = Tags.decode(Array(row.tags))
                    if !v.isEmpty { topTag[row.rid] = v.top }
                    if row.firstYear > 0 { year[row.rid] = row.firstYear }
                }
                from = to
            }
        }
        var genreRows: [GenreRow] = []
        if let atlas {
            for g in YourSound.genres(plays, topTagOf: { topTag[$0] ?? GenreAtlas.none }) {
                if let name = AtlasNames.genreName(atlas, g.atlasId) {
                    genreRows.append(GenreRow(atlasId: g.atlasId, name: name, permille: g.permille))
                }
            }
        }
        let decades = YourSound.decades(plays, yearOf: { year[$0] ?? 0 })
        let novelty = YourSound.novelty(plays, nowMs: now)

        var control: Control?
        if log.controlPlays + log.learnedPlays > 0 {
            control = Control(
                controlPlays: log.controlPlays,
                controlPermille: Gate.shownRate(finished: log.controlFinished, total: log.controlPlays).map { Int($0 * 1000.0 + 0.5) },
                learnedPlays: log.learnedPlays,
                // The learned rate is shown only next to a control rate that has enough plays.
                learnedPermille: log.controlPlays >= Gate.controlMinPlays && log.learnedPlays > 0
                    ? Int(Double(log.learnedFinished) / Double(log.learnedPlays) * 1000.0 + 0.5) : nil)
        }
        return State(plays: plays.count, islands: islandRows, genres: genreRows, decades: decades, dayparts: dayparts,
                     months: months, novelty: novelty.plays > 0 ? novelty : nil, model: model, control: control, computedAtMs: now)
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

    static func facts(_ atlas: GenreAtlas, _ id: Int) -> GenreFacts? {
        guard let page = GenrePage.of(atlas, id), AtlasNames.isShown(page.name) else { return nil }
        func links(_ ids: [Int]) -> [Link] { ids.compactMap { other in AtlasNames.genreName(atlas, other).map { Link(id: other, name: $0) } } }
        return GenreFacts(id: id, name: page.name,
                          description: page.description.flatMap { AtlasNames.isShown($0) ? $0 : nil }, origin: page.origin,
                          parents: links(page.parents), children: links(page.children), related: links(page.related),
                          influences: links(page.influences))
    }
}
