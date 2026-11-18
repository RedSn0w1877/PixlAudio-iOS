// "A new song you ignored three times stays away for 60 days" (docs/brain-spec.md, 6.1, and promise 2 of section 1).
// Android answers it with one query over `play_event`; here the event log is a record file with no query, so the
// few numbers the rule needs are kept beside it, one small record per recording the engine ever served, updated
// when such a play is recorded. Pure value plus a codec; `BrainEventLog` owns the file.
//
// The rule is Android's `PlayEventDao.ignoredThreeTimes` after its stage 1 review: an ignore is a pick that sounded
// and that the listener ended; the 60 days run from the last ignore; a play of 30 s or more clears the recording.

/// Per recording the engine served: its newest short plays and its newest long one.
public struct IgnoreTally: Sendable, Equatable {
    public static let windowMs: Int64 = 60 * 24 * 60 * 60 * 1000
    /// A play shorter than this was "ignored"; one this long or longer clears the recording.
    public static let longPlayMs: Int32 = 30_000
    public static let needed = 3

    public struct Row: Sendable, Equatable {
        /// When the newest short plays started, oldest first; `needed` at most.
        public var shorts: [Int64] = []
        /// When the newest play of 30 s or more started; 0 for none.
        public var longAtMs: Int64 = 0

        public init(shorts: [Int64] = [], longAtMs: Int64 = 0) {
            self.shorts = shorts
            self.longAtMs = longAtMs
        }
    }

    public private(set) var rows: [Int64: Row] = [:]

    public init() {}

    /// An ignore: a pick the engine served (it has an arm) that sounded for under 30 s and that the listener ended
    /// (next, picking something else, removing it from the queue). A play that never sounded, that failed, that
    /// was cut by the app being closed or by a stop is not one: the listener did not skip it.
    public static func isIgnore(_ event: PlayEvent) -> Bool {
        guard event.arm != Arm.none, event.rid != 0, event.playedMs > 0, event.playedMs < longPlayMs,
              !event.has(EventFlags.neverAudible) else { return false }
        return event.endReason == EndReason.next || event.endReason == EndReason.pickedOther
            || event.endReason == EndReason.queueEdit
    }

    /// True when `event` may change a row: an ignore, or a play of 30 s or more from anywhere.
    public static func counts(_ event: PlayEvent) -> Bool {
        event.rid != 0 && (isIgnore(event) || event.playedMs >= longPlayMs)
    }

    /// Folds one play in. Returns the row to store, or nil when the play does not count or changed nothing. A long
    /// play is written down for a recording the engine served (now or before); the tally keeps no row for music
    /// the engine never offered.
    @discardableResult
    public mutating func note(_ event: PlayEvent) -> Row? {
        guard Self.counts(event) else { return nil }
        var row = rows[event.rid] ?? Row()
        let before = row
        if event.playedMs >= Self.longPlayMs {
            if event.arm == Arm.none && rows[event.rid] == nil { return nil }
            if event.startedAtMs > row.longAtMs { row.longAtMs = event.startedAtMs }
        } else {
            // One play counts once, however often it is handed over.
            if row.shorts.contains(event.startedAtMs) { return nil }
            // Kept in ascending order, the newest `needed`.
            var at = row.shorts.count
            while at > 0 && row.shorts[at - 1] > event.startedAtMs { at -= 1 }
            row.shorts.insert(event.startedAtMs, at: at)
            if row.shorts.count > Self.needed { row.shorts.removeFirst(row.shorts.count - Self.needed) }
        }
        if row == before { return nil }
        rows[event.rid] = row
        return row
    }

    public mutating func load(rid: Int64, row: Row) { rows[rid] = row }

    /// Recordings ignored three times, the last time at or after `nowMs - windowMs`, and never heard for 30 s or
    /// more as far as the tally knows: a song stays away for the 60 days that follow its third skip.
    public func ignored(nowMs: Int64) -> Set<Int64> {
        let since = nowMs &- Self.windowMs
        var out: Set<Int64> = []
        for (rid, row) in rows {
            if row.longAtMs != 0 { continue }
            if row.shorts.count >= Self.needed, let last = row.shorts.last, last >= since { out.insert(rid) }
        }
        return out
    }

    /// Recordings whose every number is older than the window: their records can go.
    public func expired(nowMs: Int64) -> [Int64] {
        let since = nowMs &- Self.windowMs
        var out: [Int64] = []
        for (rid, row) in rows where row.longAtMs < since && (row.shorts.last ?? 0) < since { out.append(rid) }
        return out
    }

    public mutating func remove(_ rids: [Int64]) {
        for rid in rids { rows[rid] = nil }
    }

    /// `[long,short,short,short]` as text.
    public static func encode(_ row: Row) -> [UInt8] {
        var text = "[\(row.longAtMs)"
        for value in row.shorts { text += ",\(value)" }
        text += "]"
        return Array(text.utf8)
    }

    public static func decode(_ numbers: [Int64]) -> Row? {
        guard let long = numbers.first, numbers.count <= needed + 1 else { return nil }
        return Row(shorts: Array(numbers.dropFirst()), longAtMs: long)
    }
}
