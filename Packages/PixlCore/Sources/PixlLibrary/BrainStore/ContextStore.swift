// The context table of docs/brain-spec.md, 5.10: how much of what the listener plays at each of eight times of the week belongs to
// each of their islands, from the event log. A port of Android's `ContextStore.kt`.
//
// Worked out in the background when the Home plan needs it (a daypart boundary at most), read once through the log (the file's bytes
// on the engine, decoded and counted off every actor) and kept in memory for a few minutes; never at app start and never on the main
// actor. The table is a pure function of the plays and of now (`build`), so nothing needs its own persistence.
//
// An imported play carries no timezone: its hour is read with the device's offset now (the spec's default when the listener has set
// no home timezone), and so is a live play from before the offset was recorded.

import Foundation
import PixlModel

public actor ContextStore {
    static let cacheMs: Int64 = 30 * 60_000

    private struct Cached {
        let atMs: Int64
        let islandFitAtMs: Int64
        let table: ContextLift.Table
    }

    private let engine: BrainEngine
    private let islands: IslandStore
    private let tzOffsetMin: @Sendable (Int64) -> Int32
    private let clock: @Sendable () -> Int64
    private var cached: Cached?

    public init(engine: BrainEngine, islands: IslandStore, tzOffsetMin: @escaping @Sendable (Int64) -> Int32,
                clock: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        self.engine = engine
        self.islands = islands
        self.tzOffsetMin = tzOffsetMin
        self.clock = clock
    }

    /// The table for `nowMs`; nil while there are no islands to count plays of.
    public func table(nowMs: Int64? = nil) async -> ContextLift.Table? {
        let now = nowMs ?? clock()
        guard let set = await islands.current(), !set.isEmpty else { return nil }
        if let cached, now - cached.atMs >= 0, now - cached.atMs < Self.cacheMs, cached.islandFitAtMs == set.fitAtMs { return cached.table }
        let payloads = await engine.eventPayloads()
        let memberOf = set.memberOf
        let device = tzOffsetMin(now)
        let table = await Task.detached(priority: .utility) {
            Self.build(BrainEventLog.decodeSorted(payloads), memberOf: memberOf, deviceTzOffsetMin: device, nowMs: now)
        }.value
        cached = Cached(atMs: now, islandFitAtMs: set.fitAtMs, table: table)
        return table
    }

    /// The table of `events` (pure): every graded play of an island that counted, in the bucket of its local time.
    static func build(_ events: [PlayEvent], memberOf: [Int64: Int], deviceTzOffsetMin: Int32, nowMs: Int64) -> ContextLift.Table {
        var builder = ContextLift.Builder(nowMs: nowMs)
        for e in events {
            if e.has(EventFlags.learnExcluded) || e.has(EventFlags.neverAudible) { continue }
            guard let island = memberOf[e.rid] else { continue }
            let g = Reward.grade(e, Reward.Context())
            builder.add(islandId: island, startedAtMs: e.startedAtMs,
                        tzOffsetMin: e.tzOffsetMin == PlayEvent.tzUnknown ? deviceTzOffsetMin : e.tzOffsetMin, c: g.c, r: g.r)
        }
        return builder.build()
    }
}
