// One play attempt, live or imported (docs/brain-spec.md, 4.1), with the codes the event log stores. A
// transliteration of the Android `:brain` module's `PlayEvent.kt`. Codes and flag bits are part of the event log:
// never renumber, never move a bit.

/// Where a play row came from (4.1 `origin`).
public enum Origin {
    public static let live: Int32 = 0
    public static let importSpotify: Int32 = 1
    public static let importYtm: Int32 = 2
    public static let migratedHistory: Int32 = 3

    static let names = ["live", "importSpotify", "importYtm", "migratedHistory"]

    public static func nameOf(_ code: Int32) -> String {
        code >= 0 && Int(code) < names.count ? names[Int(code)] : names[Int(live)]
    }

    public static func isImport(_ code: Int32) -> Bool { code == importSpotify || code == importYtm }
}

/// How a play started (4.1 `startReason`).
public enum StartReason {
    public static let tap: Int32 = 0
    public static let next: Int32 = 1
    public static let prev: Int32 = 2
    public static let autoAdvance: Int32 = 3
    public static let autoplay: Int32 = 4
    public static let restore: Int32 = 5
    public static let remote: Int32 = 6
    public static let unknown: Int32 = 7

    static let names = ["tap", "next", "prev", "autoAdvance", "autoplay", "restore", "remote", "unknown"]

    public static func nameOf(_ code: Int32) -> String {
        code >= 0 && Int(code) < names.count ? names[Int(code)] : names[Int(unknown)]
    }

    /// True when the listener did something to start this play (it breaks a passive run).
    public static func isTouch(_ code: Int32) -> Bool { code == tap || code == next || code == prev || code == remote }
}

/// How a play ended (4.1 `endReason`).
public enum EndReason {
    public static let trackDone: Int32 = 0
    public static let next: Int32 = 1
    public static let prev: Int32 = 2
    public static let pickedOther: Int32 = 3
    public static let stopped: Int32 = 4
    public static let queueEdit: Int32 = 5
    public static let error: Int32 = 6
    public static let killed: Int32 = 7
    public static let unknown: Int32 = 8

    static let names = ["trackDone", "next", "prev", "pickedOther", "stopped", "queueEdit", "error", "killed", "unknown"]

    public static func nameOf(_ code: Int32) -> String {
        code >= 0 && Int(code) < names.count ? names[Int(code)] : names[Int(unknown)]
    }
}

/// The audio route of a play (4.1 `route`).
public enum Route {
    public static let speaker: Int32 = 0
    public static let wired: Int32 = 1
    public static let bluetooth: Int32 = 2
    public static let car: Int32 = 3
    public static let cast: Int32 = 4
    public static let connect: Int32 = 5
    public static let unknown: Int32 = 6
}

/// The bits of `play_event.flags` (4.1).
public enum EventFlags {
    public static let shuffle: Int32 = 1
    public static let repeatOne: Int32 = 1 << 1
    public static let offline: Int32 = 1 << 2
    public static let neverAudible: Int32 = 1 << 3
    public static let exploreSlot: Int32 = 1 << 4
    public static let controlSession: Int32 = 1 << 5
    public static let likedDuring: Int32 = 1 << 6
    public static let savedDuring: Int32 = 1 << 7
    public static let addedToPlaylist: Int32 = 1 << 8
    public static let seekBack: Int32 = 1 << 9
    public static let replayed: Int32 = 1 << 10
    public static let notForMe: Int32 = 1 << 11
    public static let learnExcluded: Int32 = 1 << 12
}

/// One play attempt. Raw facts only: reward and trust are derived by `Reward.grade`, so their definition can change
/// and be replayed.
public struct PlayEvent: Sendable {
    public static let schemaVersion: Int32 = 1
    public static let maxOtherAids = 4
    public static let maxSurfaceIdLength = 40
    /// `tzOffsetMin` of a row that does not know its offset. Never a real offset (those are within +-900).
    public static let tzUnknown: Int32 = -32768

    /// `(startedAtMs << 16) | seq`; time-ordered; see `mintId`.
    public var eventId: Int64
    public var origin: Int32
    public var rid: Int64
    public var primaryAid: Int64
    /// The other credited artists, at most `maxOtherAids`.
    public var otherAids: [Int64]
    /// The key that was resolved, for audit and re-resolution.
    public var keyAtWrite: String
    /// UTC. For imported and migrated rows: the end time minus what was heard.
    public var startedAtMs: Int64
    /// Minutes east of UTC at play time; `tzUnknown` for imports.
    public var tzOffsetMin: Int32
    /// Audible milliseconds; -1 when unknown (an imported play without `ms_played`).
    public var playedMs: Int32
    /// 0 when unknown.
    public var durationMs: Int32
    public var startReason: Int32
    public var endReason: Int32
    public var flags: Int32
    public var surface: Int32
    public var surfaceId: String
    public var recId: Int64
    public var slot: Int32
    public var arm: Int32
    public var sessionId: Int64
    public var posInSession: Int32
    public var passiveRun: Int32
    public var route: Int32
    public var retrQ: Int32
    public var radioRank: Int32
    public var pServedQ: Int32
    public var modelVersion: Int32
    public var schema: Int32

    public init(eventId: Int64, origin: Int32, rid: Int64, primaryAid: Int64, otherAids: [Int64] = [],
                keyAtWrite: String = "", startedAtMs: Int64, tzOffsetMin: Int32 = PlayEvent.tzUnknown, playedMs: Int32,
                durationMs: Int32 = 0, startReason: Int32 = StartReason.unknown, endReason: Int32 = EndReason.unknown,
                flags: Int32 = 0, surface: Int32 = Surface.unknown, surfaceId: String = "", recId: Int64 = 0,
                slot: Int32 = -1, arm: Int32 = Arm.none, sessionId: Int64 = 0, posInSession: Int32 = 0,
                passiveRun: Int32 = 0, route: Int32 = Route.unknown, retrQ: Int32 = -1, radioRank: Int32 = -1,
                pServedQ: Int32 = 0, modelVersion: Int32 = 0, schema: Int32 = PlayEvent.schemaVersion) {
        self.eventId = eventId
        self.origin = origin
        self.rid = rid
        self.primaryAid = primaryAid
        self.otherAids = otherAids
        self.keyAtWrite = keyAtWrite
        self.startedAtMs = startedAtMs
        self.tzOffsetMin = tzOffsetMin
        self.playedMs = playedMs
        self.durationMs = durationMs
        self.startReason = startReason
        self.endReason = endReason
        self.flags = flags
        self.surface = surface
        self.surfaceId = surfaceId
        self.recId = recId
        self.slot = slot
        self.arm = arm
        self.sessionId = sessionId
        self.posInSession = posInSession
        self.passiveRun = passiveRun
        self.route = route
        self.retrQ = retrQ
        self.radioRank = radioRank
        self.pServedQ = pServedQ
        self.modelVersion = modelVersion
        self.schema = schema
    }

    public func has(_ flag: Int32) -> Bool { flags & flag != 0 }

    /// The time the play ended, as far as the row knows: start plus what was heard.
    public var endedAtMs: Int64 { startedAtMs &+ (playedMs > 0 ? Int64(playedMs) : 0) }

    /// One canonical JSON line (no newline). Keys in the order of the table in 4.1.
    public func encode() -> String {
        var w = BrainJson.Writer()
        w.beginObject()
        w.long("eventId", eventId)
        w.int("schema", schema)
        w.int("origin", origin)
        w.long("rid", rid)
        w.long("primaryAid", primaryAid)
        w.longs("otherAids", otherAids)
        w.string("keyAtWrite", keyAtWrite)
        w.long("startedAtMs", startedAtMs)
        if tzOffsetMin == PlayEvent.tzUnknown { w.nullValue("tzOffsetMin") } else { w.int("tzOffsetMin", tzOffsetMin) }
        w.int("playedMs", playedMs)
        w.int("durationMs", durationMs)
        w.int("startReason", startReason)
        w.int("endReason", endReason)
        w.int("flags", flags)
        w.int("surface", surface)
        w.string("surfaceId", surfaceId)
        w.long("recId", recId)
        w.int("slot", slot)
        w.int("arm", arm)
        w.long("sessionId", sessionId)
        w.int("posInSession", posInSession)
        w.int("passiveRun", passiveRun)
        w.int("route", route)
        w.int("retrQ", retrQ)
        w.int("radioRank", radioRank)
        w.int("pServedQ", pServedQ)
        w.int("modelVersion", modelVersion)
        w.endObject()
        return w.text
    }

    /// Decodes `encode`'s output. A field a later schema added is ignored; a missing one takes its default. Nil when
    /// the line is not a JSON object.
    public static func decode(_ line: String) -> PlayEvent? {
        guard let value = try? BrainJson.parse(line) else { return nil }
        return decode(value)
    }

    /// Decodes an already parsed object.
    public static func decode(_ m: BrainJson.Value) -> PlayEvent? {
        guard case .object = m else { return nil }
        func long(_ k: String, _ d: Int64 = 0) -> Int64 { m[k]?.longValue ?? d }
        func int(_ k: String, _ d: Int32 = 0) -> Int32 {
            guard let v = m[k]?.bareLong else { return d }
            return Int32(truncatingIfNeeded: v)
        }
        var aids: [Int64] = []
        for other in m["otherAids"]?.arrayValue ?? [] { aids.append(other.longValue ?? 0) }
        return PlayEvent(
            eventId: long("eventId"),
            origin: int("origin"),
            rid: long("rid"),
            primaryAid: long("primaryAid"),
            otherAids: aids,
            keyAtWrite: m["keyAtWrite"]?.stringValue ?? "",
            startedAtMs: long("startedAtMs"),
            tzOffsetMin: int("tzOffsetMin", tzUnknown),
            playedMs: int("playedMs", -1),
            durationMs: int("durationMs"),
            startReason: int("startReason", StartReason.unknown),
            endReason: int("endReason", EndReason.unknown),
            flags: int("flags"),
            surface: int("surface", Surface.unknown),
            surfaceId: m["surfaceId"]?.stringValue ?? "",
            recId: long("recId"),
            slot: int("slot", -1),
            arm: int("arm", Arm.none),
            sessionId: long("sessionId"),
            posInSession: int("posInSession"),
            passiveRun: int("passiveRun"),
            route: int("route", Route.unknown),
            retrQ: int("retrQ", -1),
            radioRank: int("radioRank", -1),
            pServedQ: int("pServedQ"),
            modelVersion: int("modelVersion"),
            schema: int("schema", schemaVersion)
        )
    }

    /// What makes two rows the same play: the origin and the key that was resolved.
    public static func identityOf(origin: Int32, keyAtWrite: String) -> String { Origin.nameOf(origin) + "|" + keyAtWrite }

    /// The event id of a play (4.1): `(startedAtMs << 16) | seq`, with `seq` the low 16 bits of
    /// `fnv1a64(utf8(origin + "|" + keyAtWrite))`. Deterministic, so copying the same legacy row twice gives the same
    /// id. `identityAt` returns the identity (`identityOf`) of the row already stored under an id, or nil when the id
    /// is free; an id taken by a DIFFERENT play moves on to `seq + 1` modulo 65,536.
    public static func mintId(startedAtMs: Int64, origin: Int32, keyAtWrite: String,
                              identityAt: (Int64) -> String?) -> Int64 {
        let identity = identityOf(origin: origin, keyAtWrite: keyAtWrite)
        let base = Int64(bitPattern: UInt64(bitPattern: startedAtMs) << 16)
        var seq = Int64(BrainHash.fnv1a64(identity) & 0xFFFF)
        var tries = 0
        while tries < 65536 {
            let id = base | seq
            let taken = identityAt(id)
            // Strings are never compared as strings in the core (10.3, rule 13): bytes, one by one.
            if taken == nil || BrainKey.sameBytes(taken!, identity) { return id }
            seq = (seq + 1) & 0xFFFF
            tries += 1
        }
        return base | seq
    }
}
