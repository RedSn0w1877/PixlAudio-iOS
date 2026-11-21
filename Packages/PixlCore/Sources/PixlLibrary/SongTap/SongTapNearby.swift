// The nearby phones list of the Song Drop picker, and the sender's "Song drop to X?" prompt (Song Tap, spec 5). A
// transliteration of `SongTapNearby.kt`; the golden `nearby.jsonl` proves both agree.
//
// Both come from advertisements only: no connection is made to list a phone. A phone is listed when its smoothed signal is
// inside the broad list gate (`SongTapTuning.listEnterDbm` to enter, `listExitDbm` to leave, so it does not flicker) and it was
// heard in the last `staleMs`. Connecting to it and beaming still need the near gate (`SongTapTuning.nearEnterDbm`); the
// prompt appears only for a phone that is inside it.
//
// Pure and integer only: the transport feeds `update` with every scan result and calls `visible` / `promptFor` when it
// publishes; the clock enters as an argument. Entries are by peer number (the transport's number for an address), so one
// phone is one entry however often it advertises.

public struct SongTapNearbyEntry: Sendable, Equatable {
    public var id: Int
    public var name: String
    public var role: SongTapRole
    /// The smoothed signal, whole dBm.
    public var dbm: Int
    public var lastSeenMs: Int64
    /// Inside the list gate (with hysteresis).
    public var listed: Bool
    /// Inside the strict near gate (with hysteresis).
    public var near: Bool
}

public struct SongTapNearbyBook: Sendable {
    /// A row disappears when its phone has not advertised for this long.
    public static let staleMs: Int64 = 4_000

    /// Two same-name rows whose last sightings are this far apart are one phone that changed address.
    public static let samePhoneGapMs: Int64 = 1_500

    /// How long "No" silences the prompt for that phone.
    public static let ignoreMs: Int64 = 60_000

    private var entries: [Int: SongTapNearbyEntry] = [:]
    private var ignoredUntil: [Int: Int64] = [:]

    public init() {}

    /// One scan result of phone `id`: its signal smoothed by the detector's fast average (`fastQ`, dBm times 256).
    public mutating func update(id: Int, name: String, role: SongTapRole, fastQ: Int, near: Bool, nowMs: Int64) {
        let dbm = SongTapDetector.floorDiv(fastQ, songTapRssiScale)
        let before = entries[id]
        let listed: Bool
        if let before, before.listed {
            listed = dbm >= SongTapTuning.listExitDbm
        } else {
            listed = dbm >= SongTapTuning.listEnterDbm
        }
        entries[id] = SongTapNearbyEntry(id: id, name: name, role: role, dbm: dbm, lastSeenMs: nowMs, listed: listed, near: near)
    }

    public mutating func remove(_ id: Int) {
        entries[id] = nil
        ignoredUntil[id] = nil
    }

    public mutating func clear() {
        entries.removeAll()
        ignoredUntil.removeAll()
    }

    /// The picker's rows for phones of `role`: listed, heard within `staleMs`, strongest first (ties by number), and one row
    /// per phone: when two rows have the same name and one was last heard more than `samePhoneGapMs` after the other, it is the
    /// same phone under a new random address and only the newer shows.
    public func visible(role: SongTapRole, nowMs: Int64) -> [SongTapNearbyEntry] {
        var live: [SongTapNearbyEntry] = []
        for e in entries.values where e.role == role && e.listed && nowMs - e.lastSeenMs <= Self.staleMs { live.append(e) }
        var keep: [SongTapNearbyEntry] = []
        for e in live {
            var superseded = false
            for o in live where o.id != e.id && o.name == e.name && o.lastSeenMs - e.lastSeenMs > Self.samePhoneGapMs {
                superseded = true
                break
            }
            if !superseded { keep.append(e) }
        }
        keep.sort { $0.dbm != $1.dbm ? $0.dbm > $1.dbm : $0.id < $1.id }
        return keep
    }

    /// "No" on the prompt: phone `id` is not asked about for `ignoreMs`.
    public mutating func ignore(_ id: Int, nowMs: Int64) {
        ignoredUntil[id] = nowMs + Self.ignoreMs
    }

    public mutating func isIgnored(_ id: Int, nowMs: Int64) -> Bool {
        guard let until = ignoredUntil[id] else { return false }
        if nowMs >= until {
            ignoredUntil[id] = nil
            return false
        }
        return true
    }

    /// The phone to ask "Song drop to X?" about: of `role`, inside the near gate, heard within `staleMs`, not ignored; the
    /// strongest, ties by number. Nil when none.
    public mutating func promptFor(role: SongTapRole, nowMs: Int64) -> SongTapNearbyEntry? {
        for e in visible(role: role, nowMs: nowMs) where e.near && !isIgnored(e.id, nowMs: nowMs) { return e }
        return nil
    }

    /// The entry of `id` as it stands, regardless of the list gate; nil when unknown.
    public func entry(_ id: Int) -> SongTapNearbyEntry? { entries[id] }
}
