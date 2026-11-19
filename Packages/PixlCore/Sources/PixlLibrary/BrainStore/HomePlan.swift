// The Home plan (docs/brain-spec.md, 8.1, stage 2): what Home shows, decided in the background, saved as `home_plan.json` (under
// 50 KB) and read at launch before anything else. Home never waits for the brain: with no plan it shows Jump back in and the
// library rows. A port of Android's `HomePlan.kt`. Titles are keys and arguments, never finished text, so the words stay in
// the app (decision D16).

import Foundation
import PixlModel

public struct PlanItem: Codable, Sendable, Equatable {
    public var rid: Int64
    /// A hash of the folded primary artist name: only for the page rules (an artist at most twice a shelf).
    public var aid: Int64
    /// The library song id; nil for a track from outside the library, which has `row`.
    public var songId: String?
    public var row: StoredRadioRow?
    public var arm: Int32
    public var whyKey: Int32
    public var whyName: String
    public var slot: Int

    public init(rid: Int64, aid: Int64 = 0, songId: String? = nil, row: StoredRadioRow? = nil, arm: Int32 = Arm.none,
                whyKey: Int32 = WhyLine.none, whyName: String = "", slot: Int = -1) {
        self.rid = rid
        self.aid = aid
        self.songId = songId
        self.row = row
        self.arm = arm
        self.whyKey = whyKey
        self.whyName = whyName
        self.slot = slot
    }
}

/// A made-for-you list as a card; the list itself is a `served_list` row, read by `MixSpec.of(surfaceId:)` with `mixId`.
public struct PlanMix: Codable, Sendable, Equatable {
    public var mixId: String
    public var kind: Int32
    /// 1..K for a Daily Mix of an island, else 0.
    public var number: Int
    public var subtitle: String
    public var count: Int
    /// Up to three album arts.
    public var covers: [String]
    public var builtAtMs: Int64

    public init(mixId: String, kind: Int32, number: Int = 0, subtitle: String = "", count: Int, covers: [String] = [],
                builtAtMs: Int64 = 0) {
        self.mixId = mixId
        self.kind = kind
        self.number = number
        self.subtitle = subtitle
        self.count = count
        self.covers = covers
        self.builtAtMs = builtAtMs
    }
}

public struct PlanStation: Codable, Sendable, Equatable {
    /// `GenreStations.kindGenre` or `kindMood`.
    public var kind: Int
    public var atlasId: Int
    public var name: String
    public var count: Int
    public var covers: [String]

    public init(kind: Int, atlasId: Int, name: String, count: Int, covers: [String] = []) {
        self.kind = kind
        self.atlasId = atlasId
        self.name = name
        self.count = count
        self.covers = covers
    }
}

public struct PlanShelf: Codable, Sendable, Equatable {
    /// A `HomePlanner` shelf type.
    public var type: Int32
    public var id: String
    /// "because_listened", "new_from_loved", "on_repeat", ...: the key of the title; the sentence is in the app.
    public var titleKey: String
    public var titleArg: String
    public var subtitleKey: String
    public var items: [PlanItem]
    public var mixes: [PlanMix]
    public var stations: [PlanStation]
    public var recId: Int64

    public init(type: Int32, id: String, titleKey: String, titleArg: String = "", subtitleKey: String = "", items: [PlanItem] = [],
                mixes: [PlanMix] = [], stations: [PlanStation] = [], recId: Int64 = 0) {
        self.type = type
        self.id = id
        self.titleKey = titleKey
        self.titleArg = titleArg
        self.subtitleKey = subtitleKey
        self.items = items
        self.mixes = mixes
        self.stations = stations
        self.recId = recId
    }
}

public struct PlanHero: Codable, Sendable, Equatable {
    /// A `HomePlanner` hero kind.
    public var kind: Int32
    /// For a mix hero: its id.
    public var mixId: String
    /// For a release hero: the track.
    public var item: PlanItem?
    public var artistName: String

    public init(kind: Int32, mixId: String = "", item: PlanItem? = nil, artistName: String = "") {
        self.kind = kind
        self.mixId = mixId
        self.item = item
        self.artistName = artistName
    }
}

public struct HomePlan: Codable, Sendable, Equatable {
    public static let version = 1

    public var planVersion: Int
    public var generatedAtMs: Int64
    /// `HomePlanner.planKey`: the local day (04:00) and daypart it was planned for.
    public var planKey: Int64
    /// What the taste adjustments looked like then: a change plans again.
    public var taste: String
    public var daypart: Int32
    public var weekday: Int32
    public var hero: PlanHero?
    /// The made-for-you cards, in order (also the hero's pool).
    public var mixes: [PlanMix]
    public var shelves: [PlanShelf]
    /// When the islands this plan was made from were fitted (0 for none, or a plan from before this field): a refit makes the
    /// plan due, so a card never numbers an island the plan does not hold.
    public var islandFitAtMs: Int64

    public init(generatedAtMs: Int64, planKey: Int64, taste: String = "", daypart: Int32 = 0, weekday: Int32 = 0, hero: PlanHero? = nil,
                mixes: [PlanMix] = [], shelves: [PlanShelf] = [], islandFitAtMs: Int64 = 0) {
        planVersion = Self.version
        self.generatedAtMs = generatedAtMs
        self.planKey = planKey
        self.taste = taste
        self.daypart = daypart
        self.weekday = weekday
        self.hero = hero
        self.mixes = mixes
        self.shelves = shelves
        self.islandFitAtMs = islandFitAtMs
    }

    /// True when the plan has something to show: a hero, a made-for-you card or a shelf. A plan with none is still saved (so
    /// it is not rebuilt at every Home), but it does not own the page: the library rows carry it.
    public var hasContent: Bool { hero != nil || !mixes.isEmpty || !shelves.isEmpty }

    /// The same plan with at most `maxItems` in each shelf of songs and no more than two covers a card, for a plan over the
    /// file's size limit.
    public func shrunk(maxItems: Int) -> HomePlan {
        var out = self
        for i in out.shelves.indices {
            if out.shelves[i].items.count > maxItems { out.shelves[i].items = Array(out.shelves[i].items.prefix(maxItems)) }
            for k in out.shelves[i].mixes.indices where out.shelves[i].mixes[k].covers.count > 2 {
                out.shelves[i].mixes[k].covers = Array(out.shelves[i].mixes[k].covers.prefix(2))
            }
        }
        for k in out.mixes.indices where out.mixes[k].covers.count > 2 { out.mixes[k].covers = Array(out.mixes[k].covers.prefix(2)) }
        return out
    }

    private enum CodingKeys: String, CodingKey {
        case planVersion, generatedAtMs, planKey, taste, daypart, weekday, hero, mixes, shelves, islandFitAtMs
    }

    // Every field a later version adds is read with a default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        planVersion = try c.decodeIfPresent(Int.self, forKey: .planVersion) ?? Self.version
        generatedAtMs = try c.decode(Int64.self, forKey: .generatedAtMs)
        planKey = try c.decode(Int64.self, forKey: .planKey)
        taste = try c.decodeIfPresent(String.self, forKey: .taste) ?? ""
        daypart = try c.decodeIfPresent(Int32.self, forKey: .daypart) ?? 0
        weekday = try c.decodeIfPresent(Int32.self, forKey: .weekday) ?? 0
        hero = try c.decodeIfPresent(PlanHero.self, forKey: .hero)
        mixes = try c.decodeIfPresent([PlanMix].self, forKey: .mixes) ?? []
        shelves = try c.decodeIfPresent([PlanShelf].self, forKey: .shelves) ?? []
        islandFitAtMs = try c.decodeIfPresent(Int64.self, forKey: .islandFitAtMs) ?? 0
    }
}

/// Reads and writes `home_plan.json`. One small file, atomic writes: Home reads it before anything else. A file that cannot be
/// read is no plan, and a stage 1 or 2a install has none.
public actor HomePlanStore {
    public static let fileName = "home_plan.json"
    /// The spec asks for under 50 KB.
    public static let maxBytes = 50_000

    private let url: URL

    public init(directory: URL) { url = directory.appendingPathComponent(Self.fileName, isDirectory: false) }

    public func read() -> HomePlan? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty, data.count <= Self.maxBytes,
              let plan = try? JSONDecoder().decode(HomePlan.self, from: data), plan.planVersion == HomePlan.version else { return nil }
        return plan
    }

    /// False when the plan is over the limit or could not be written.
    @discardableResult
    public func write(_ plan: HomePlan) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(plan), data.count <= Self.maxBytes else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    public func clear() { try? FileManager.default.removeItem(at: url) }
}

// MARK: - Jump back in

/// One thing the listener played from, not one song: a playlist, an album or other queue, a mix or a station (8.1 "Jump back in").
public struct RecentContext: Codable, Sendable, Equatable {
    public static let playlist = 0
    public static let mix = 1
    public static let station = 2
    public static let queue = 3

    public var key: String
    public var kind: Int
    public var title: String
    public var art: String?
    /// The library songs it held when it started (at most `RecentContexts.maxSongs`), to play it again.
    public var songIds: [String]
    /// For a made-for-you mix: its id, so a tap opens the mix instead.
    public var mixId: String
    public var atMs: Int64

    public init(key: String, kind: Int, title: String, art: String? = nil, songIds: [String] = [], mixId: String = "", atMs: Int64 = 0) {
        self.key = key
        self.kind = kind
        self.title = title
        self.art = art
        self.songIds = songIds
        self.mixId = mixId
        self.atMs = atMs
    }
}

/// The last distinct contexts the listener started playing (docs/brain-spec.md, 8.1 "Jump back in": the last 6 distinct contexts,
/// not songs). Written once per started queue, kept in one small file. Reading it is a file read; nothing here touches the
/// brain's files or the network.
public actor RecentContexts {
    public static let fileName = "recent_contexts.json"
    public static let keep = 12
    public static let maxSongs = 60
    static let ignored: Set<String> = ["None", "Recently Played", "Just Added", "Shuffle All", "Taizo"]

    private let url: URL
    private var memory: [RecentContext]?

    public init(directory: URL) { url = directory.appendingPathComponent(Self.fileName, isDirectory: false) }

    /// The context a started queue is, or nil for one that is not a place to jump back to.
    public static func contextOf(queueName: String, playlistId: String?, surface: String?, surfaceId: String?, songIds: [String],
                                 art: String?, nowMs: Int64) -> RecentContext? {
        if songIds.isEmpty || BrainText.isBlank(queueName) || ignored.contains(queueName) { return nil }
        let ids = Array(songIds.prefix(maxSongs))
        if let playlistId, !BrainText.isBlank(playlistId) {
            return RecentContext(key: "p:\(playlistId)", kind: RecentContext.playlist, title: queueName, art: art, songIds: ids, atMs: nowMs)
        }
        if surface == "dailyMix" || surface == "yourMix" || surface == "namedMix" {
            let id = surfaceId ?? ""
            return RecentContext(key: "m:\(id)", kind: RecentContext.mix, title: queueName, art: art, songIds: ids, mixId: id, atMs: nowMs)
        }
        if queueName == "Your Mix" {
            return RecentContext(key: "m:your", kind: RecentContext.mix, title: queueName, art: art, songIds: ids, mixId: "your", atMs: nowMs)
        }
        if queueName.hasPrefix("Daily Mix") {
            return RecentContext(key: "m:daily", kind: RecentContext.mix, title: queueName, art: art, songIds: ids, mixId: "daily", atMs: nowMs)
        }
        if surface == "station" {
            return RecentContext(key: "s:\(surfaceId ?? "")", kind: RecentContext.station, title: queueName, art: art, songIds: ids, atMs: nowMs)
        }
        return RecentContext(key: "q:\(queueName)", kind: RecentContext.queue, title: queueName, art: art, songIds: ids, atMs: nowMs)
    }

    private func load() -> [RecentContext] {
        if let memory { return memory }
        var list: [RecentContext] = []
        if let data = try? Data(contentsOf: url), data.count <= 200_000,
           let read = try? JSONDecoder().decode([RecentContext].self, from: data) { list = read }
        memory = list
        return list
    }

    /// A queue started: it goes first, and an older entry with the same key goes.
    public func note(_ context: RecentContext) {
        var list = load()
        list.removeAll { BrainKey.sameBytes($0.key, context.key) }
        list.insert(context, at: 0)
        list = Array(list.prefix(Self.keep))
        memory = list
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(list) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// The newest `n` contexts, newest first.
    public func last(_ n: Int) -> [RecentContext] { Array(load().prefix(n)) }

    /// The tiles of Jump back in: the first `count` distinct contexts.
    public func tiles(count: Int = 6) -> [RecentContext] {
        let list = load()
        return HomePlanner.distinctContexts(list.map(\.key), count: count).map { list[$0] }
    }
}
