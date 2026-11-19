// The saved-mix format (docs/brain-spec.md, 8.2, stage 2a): a mix that can hold tracks from outside the library. It is
// one `served_list` record; this is what its `mix` holds. A port of Android's `MixModel.kt`.
//
// A library track is kept as its song id (the library row is the truth about it, and a song that has left the library
// is simply dropped when the mix is read back). A track from outside the library carries its parsed radio row, so the
// mix is complete in itself: it is registered in `playable` from this row whenever it is shown or played, and a
// restart needs no network and no radio cache.
//
// Versioned: every record says `v`, a field a later stage adds is read with a default, and a record of a version this
// code does not know is not a mix (the caller builds a fresh list).

import Foundation
import PixlModel

public struct StoredMixItem: Sendable, Hashable, Codable {
    public var rid: Int64
    /// The library song id; nil for a track from outside the library, which has `row`.
    public var songId: String?
    public var row: StoredRadioRow?
    public var arm: Int32
    public var slot: Int
    public var whyKey: Int32
    public var whyArg: Int64
    /// The name the reason is about ("Fans of X also play this"); display only.
    public var whyName: String
    public var retrQ: Int
    public var radioRank: Int

    public init(rid: Int64, songId: String? = nil, row: StoredRadioRow? = nil, arm: Int32 = Arm.none, slot: Int = -1,
                whyKey: Int32 = WhyLine.none, whyArg: Int64 = 0, whyName: String = "", retrQ: Int = -1,
                radioRank: Int = -1) {
        self.rid = rid
        self.songId = songId
        self.row = row
        self.arm = arm
        self.slot = slot
        self.whyKey = whyKey
        self.whyArg = whyArg
        self.whyName = whyName
        self.retrQ = retrQ
        self.radioRank = radioRank
    }

    public var isOutsideLibrary: Bool { songId == nil }

    private enum CodingKeys: String, CodingKey {
        case rid, songId, row, arm, slot, whyKey, whyArg, whyName, retrQ, radioRank
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rid = try c.decode(Int64.self, forKey: .rid)
        songId = try c.decodeIfPresent(String.self, forKey: .songId)
        row = try c.decodeIfPresent(StoredRadioRow.self, forKey: .row)
        arm = try c.decodeIfPresent(Int32.self, forKey: .arm) ?? Arm.none
        slot = try c.decodeIfPresent(Int.self, forKey: .slot) ?? -1
        whyKey = try c.decodeIfPresent(Int32.self, forKey: .whyKey) ?? WhyLine.none
        whyArg = try c.decodeIfPresent(Int64.self, forKey: .whyArg) ?? 0
        whyName = try c.decodeIfPresent(String.self, forKey: .whyName) ?? ""
        retrQ = try c.decodeIfPresent(Int.self, forKey: .retrQ) ?? -1
        radioRank = try c.decodeIfPresent(Int.self, forKey: .radioRank) ?? -1
    }
}

public struct StoredMix: Sendable, Hashable, Codable {
    public static let formatVersion = 1

    public var v: Int
    /// `MixPlanner.kindDaily` or `kindYour`.
    public var kind: Int32
    public var builtAtMs: Int64
    /// The tie seed the list was drawn with.
    public var seed: Int64
    /// How many times the listener asked for another list that day (0 for the list of the day).
    public var regenerate: Int32
    /// The Familiar / Blend / Discover position it was built with.
    public var novelty: Int
    /// What the taste adjustments and blocked artists looked like then: a change rebuilds the day's mix.
    public var tasteSignature: String
    /// How many seed lists the pool had; a mix built with none is built again once radios are cached.
    public var seedLists: Int
    public var items: [StoredMixItem]
    /// Stage 2b: which of the made-for-you lists this is (see `MixSpec.surfaceId`); empty for a list saved by stage 2a.
    public var mixId: String
    /// The island's stable id for a Daily Mix 1..K; 0 otherwise.
    public var islandId: Int
    /// The island's number, 1..K, in the order of the stable ids; 0 for the other lists.
    public var number: Int
    /// "Soft pop & R&B · Sabrina Carpenter, Chappell Roan": real genres and artists, never invented; empty when nothing is known.
    public var subtitle: String

    public init(kind: Int32, builtAtMs: Int64, seed: Int64, regenerate: Int32 = 0, novelty: Int = Novelty.blend,
                tasteSignature: String = "", seedLists: Int = 0, items: [StoredMixItem], mixId: String = "",
                islandId: Int = 0, number: Int = 0, subtitle: String = "") {
        self.mixId = mixId
        self.islandId = islandId
        self.number = number
        self.subtitle = subtitle
        v = Self.formatVersion
        self.kind = kind
        self.builtAtMs = builtAtMs
        self.seed = seed
        self.regenerate = regenerate
        self.novelty = novelty
        self.tasteSignature = tasteSignature
        self.seedLists = seedLists
        self.items = items
    }

    public var novelCount: Int { items.filter(\.isOutsideLibrary).count }

    private enum CodingKeys: String, CodingKey {
        case v, kind, builtAtMs, seed, regenerate, novelty, tasteSignature, seedLists, items, mixId, islandId, number, subtitle
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        kind = try c.decode(Int32.self, forKey: .kind)
        builtAtMs = try c.decode(Int64.self, forKey: .builtAtMs)
        seed = try c.decodeIfPresent(Int64.self, forKey: .seed) ?? 0
        regenerate = try c.decodeIfPresent(Int32.self, forKey: .regenerate) ?? 0
        novelty = try c.decodeIfPresent(Int.self, forKey: .novelty) ?? Novelty.blend
        tasteSignature = try c.decodeIfPresent(String.self, forKey: .tasteSignature) ?? ""
        seedLists = try c.decodeIfPresent(Int.self, forKey: .seedLists) ?? 0
        items = try c.decode([StoredMixItem].self, forKey: .items)
        mixId = try c.decodeIfPresent(String.self, forKey: .mixId) ?? ""
        islandId = try c.decodeIfPresent(Int.self, forKey: .islandId) ?? 0
        number = try c.decodeIfPresent(Int.self, forKey: .number) ?? 0
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
    }
}

/// What the screens read of a mix: songs in order (library and outside it), reasons, and what a play carries.
public struct MixReason: Sendable, Hashable {
    /// `WhyLine.nameOf` of the key.
    public var key: String
    /// The name the reason is about; "" for "on repeat lately".
    public var arg: String

    public init(key: String, arg: String) {
        self.key = key
        self.arg = arg
    }
}

public struct MixView: Sendable {
    public var kind: Int32
    public var builtAtMs: Int64
    public var recId: Int64
    public var songs: [Song]
    /// By song id; only for rows that have a true sentence to show.
    public var reasons: [String: MixReason]
    /// By song id: the surface, the list, the pick's arm and reason, for the event log and the queue.
    public var tags: [String: BrainItemTag]
    /// Song ids of the tracks the listener does not have.
    public var novelIds: Set<String>
    /// The tracks from outside the library, so the app can register them with the engine.
    public var engineTracks: [EngineTrack]
    public var seedLists: Int
    /// Stage 2b: which list this is, its island's number (1..K) and its subtitle.
    public var spec: MixSpec
    public var number: Int
    public var subtitle: String
    /// By song id: the recording id of each row (the Home page rules and the plan read it).
    public var rids: [String: Int64]

    public var isEmpty: Bool { songs.isEmpty }

    public init(kind: Int32, builtAtMs: Int64, recId: Int64, songs: [Song], reasons: [String: MixReason],
                tags: [String: BrainItemTag], novelIds: Set<String>, engineTracks: [EngineTrack], seedLists: Int,
                spec: MixSpec? = nil, number: Int = 0, subtitle: String = "", rids: [String: Int64] = [:]) {
        self.spec = spec ?? MixSpec(kind: kind)
        self.number = number
        self.subtitle = subtitle
        self.rids = rids
        self.kind = kind
        self.builtAtMs = builtAtMs
        self.recId = recId
        self.songs = songs
        self.reasons = reasons
        self.tags = tags
        self.novelIds = novelIds
        self.engineTracks = engineTracks
        self.seedLists = seedLists
    }
}

/// The made-for-you lists (docs/brain-spec.md, 8.2). `MixPlanner.kindDaily`, `kindYour` and `kindFirstListen` come from the pure core.
public enum MixKinds {
    public static let daily = MixPlanner.kindDaily
    public static let your = MixPlanner.kindYour
    public static let firstListen = MixPlanner.kindFirstListen
    public static let justDropped: Int32 = 3
    public static let onRepeat: Int32 = 4
    public static let rediscover: Int32 = 5

    /// Planned by `StationPlanner`; the others are `ListMixes`.
    public static func usesPlanner(_ kind: Int32) -> Bool { kind == daily || kind == your || kind == firstListen }
}

/// One list to build or read: its kind and, for a Daily Mix of an island, which island.
public struct MixSpec: Sendable, Hashable {
    public var kind: Int32
    public var islandId: Int

    public init(kind: Int32, islandId: Int = 0) {
        self.kind = kind
        self.islandId = islandId
    }

    /// The `served_list.surfaceId`; "daily" and "your" are what stage 2a wrote.
    public var surfaceId: String {
        switch kind {
        case MixKinds.daily: return islandId > 0 ? "daily:\(islandId)" : "daily"
        case MixKinds.your: return "your"
        case MixKinds.firstListen: return "first"
        case MixKinds.justDropped: return "dropped"
        case MixKinds.onRepeat: return "repeat"
        default: return "rediscover"
        }
    }

    /// The `Surface` code its plays are logged under.
    public var surface: Int32 {
        switch kind {
        case MixKinds.daily: return Surface.dailyMix
        case MixKinds.your: return Surface.yourMix
        default: return Surface.namedMix
        }
    }

    /// The spec of a saved id, or nil for one this version does not know.
    public static func of(surfaceId: String) -> MixSpec? {
        if surfaceId == "daily" { return MixSpec(kind: MixKinds.daily) }
        if surfaceId.hasPrefix("daily:") { return Int(surfaceId.dropFirst(6)).map { MixSpec(kind: MixKinds.daily, islandId: $0) } }
        switch surfaceId {
        case "your": return MixSpec(kind: MixKinds.your)
        case "first": return MixSpec(kind: MixKinds.firstListen)
        case "dropped": return MixSpec(kind: MixKinds.justDropped)
        case "repeat": return MixSpec(kind: MixKinds.onRepeat)
        case "rediscover": return MixSpec(kind: MixKinds.rediscover)
        default: return nil
        }
    }
}
