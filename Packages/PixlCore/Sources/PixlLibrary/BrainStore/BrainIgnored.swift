// "A new song you ignored three times stays away for 60 days" (docs/brain-spec.md, 6.1, and promise 2 of section 1).
// Android answers it with one query over `play_event`; here the event log is a record file with no query, so the
// few numbers the rule needs are kept beside it, one small record per recording the engine ever served, updated
// when such a play is recorded. Pure value plus a codec; `BrainEventLog` owns the file.

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

    /// True when `event` counts for the rule: served by the engine (it has an arm) and of a known length heard.
    public static func counts(_ event: PlayEvent) -> Bool {
        event.arm != Arm.none && event.rid != 0 && event.playedMs >= 0
    }

    /// Folds one play in. Returns the row to store, or nil when the play does not count or changed nothing.
    @discardableResult
    public mutating func note(_ event: PlayEvent) -> Row? {
        guard Self.counts(event) else { return nil }
        var row = rows[event.rid] ?? Row()
        let before = row
        if event.playedMs >= Self.longPlayMs {
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

    /// Recordings with three or more short plays since `nowMs - windowMs` and no long one in that time.
    public func ignored(nowMs: Int64) -> Set<Int64> {
        let since = nowMs &- Self.windowMs
        var out: Set<Int64> = []
        for (rid, row) in rows {
            if row.longAtMs >= since && row.longAtMs != 0 { continue }
            if row.shorts.count >= Self.needed && row.shorts[row.shorts.count - Self.needed] >= since { out.insert(rid) }
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
