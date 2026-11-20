// The Home shelf bandit's side of the app (docs/brain-spec.md, 5.10, 8.1): the compact impressions of each visit to the page, the
// cascade bandit's posteriors, and the order the Home planner takes from it. A port of Android's `ShelfStore.kt` and its
// `ImpressionDao`.
//
// Nothing here runs on the main actor or at app start. The page reports what happened (shown, a shelf on screen for a second,
// something started from a shelf); a visit is given to the bandit later (`settle`), when it is over and the log shows whether what
// the listener started was played for 30 seconds. The order is used only while the gate has the learned weights on, and "Reset
// what I've learned" clears all of it.
//
// Storage (iOS: append-only record files, not SQL): `impression.pbl` holds one record per shelf of a visit, `visitId|position` ->
// `[v, visitId, position, shelf, daypart, shownAtMs, seen, activatedAtMs, settled]` (v is the format version; a record of a version
// this code does not know is ignored, and a file from before stage 3 is simply absent); `shelf_bandit.pbl` holds the posteriors
// (`ShelfBanditCodec`) under one key. A missing or unreadable posterior state starts again from the priors.

import Foundation
import PixlModel

/// One shelf of one visit to the Home page. Raw facts only; nothing in a row names a track or the listener.
public struct Impression: Sendable, Equatable {
    /// The time the page was shown, in ms; one value per visit.
    public var visitId: Int64
    /// The shelf's place on the page, 0 at the top.
    public var position: Int
    /// `HomePlanner` shelf type (or the daypart mix).
    public var shelf: Int
    /// `HomePlanner.daypart` of the visit.
    public var daypart: Int
    public var shownAtMs: Int64
    /// True when the shelf was on screen for at least a second.
    public var seen: Bool
    /// When the listener started something from it; 0 for never.
    public var activatedAtMs: Int64
    /// True once the visit has been given to the bandit.
    public var settled: Bool

    public init(visitId: Int64, position: Int, shelf: Int, daypart: Int, shownAtMs: Int64, seen: Bool = false,
                activatedAtMs: Int64 = 0, settled: Bool = false) {
        self.visitId = visitId
        self.position = position
        self.shelf = shelf
        self.daypart = daypart
        self.shownAtMs = shownAtMs
        self.seen = seen
        self.activatedAtMs = activatedAtMs
        self.settled = settled
    }
}

/// The impression records on disk. Not thread-safe: `ShelfStore` (an actor) owns it.
final class ImpressionFile {
    /// The record's format version, its first number: a reader ignores a record of a version it does not know.
    static let version: Int64 = 1
    static let keepVisits = 200
    static let keepDays: Int64 = 90

    private let impressions: KeyedLogStore
    private let bandit: KeyedLogStore
    private static let banditKey = "state"

    init(directory: URL, compactionFloorBytes: Int = 32 * 1024) {
        impressions = KeyedLogStore(url: directory.appendingPathComponent("impression.pbl", isDirectory: false),
                                    compactionFloorBytes: compactionFloorBytes)
        bandit = KeyedLogStore(url: directory.appendingPathComponent("shelf_bandit.pbl", isDirectory: false),
                               compactionFloorBytes: compactionFloorBytes)
    }

    static func key(_ visitId: Int64, _ position: Int) -> String { "\(visitId)|\(position)" }

    static func encode(_ r: Impression) -> [UInt8] {
        let numbers: [Int64] = [version, r.visitId, Int64(r.position), Int64(r.shelf), Int64(r.daypart), r.shownAtMs,
                                r.seen ? 1 : 0, r.activatedAtMs, r.settled ? 1 : 0]
        return Array("[\(numbers.map(String.init).joined(separator: ","))]".utf8)
    }

    static func decode(_ payload: ArraySlice<UInt8>) -> Impression? {
        guard payload.count >= 2, payload.first == 0x5B, payload.last == 0x5D else { return nil }
        var n: [Int64] = []
        for part in payload.dropFirst().dropLast().split(separator: 0x2C, omittingEmptySubsequences: false) {
            guard let value = Int64(String(decoding: part, as: UTF8.self)) else { return nil }
            n.append(value)
        }
        guard n.count >= 9, n[0] == version else { return nil }
        return Impression(visitId: n[1], position: Int(n[2]), shelf: Int(n[3]), daypart: Int(n[4]), shownAtMs: n[5],
                          seen: n[6] == 1, activatedAtMs: n[7], settled: n[8] == 1)
    }

    /// Every stored impression, by visit and position.
    func load() -> [Impression] {
        var out: [Impression] = []
        impressions.open { _, payload in
            if let row = Self.decode(payload) { out.append(row) }
        }
        out.sort { $0.visitId != $1.visitId ? $0.visitId < $1.visitId : $0.position < $1.position }
        return out
    }

    func put(_ rows: [Impression]) {
        if rows.isEmpty { return }
        impressions.put(rows.map { (Self.key($0.visitId, $0.position), Self.encode($0)) })
    }

    func remove(_ rows: [Impression]) {
        if rows.isEmpty { return }
        impressions.remove(rows.map { Self.key($0.visitId, $0.position) })
    }

    func readBandit() -> String? {
        bandit.open()
        return bandit.payload(for: Self.banditKey).map { String(decoding: $0, as: UTF8.self) }
    }

    func writeBandit(_ text: String?) {
        if let text { bandit.put(Self.banditKey, Array(text.utf8)) } else { bandit.remove([Self.banditKey]) }
    }
}

/// The shelf bandit's state and the impressions behind it.
public actor ShelfStore {
    /// A page left alone this long is a finished visit; the same page shown again within it is the same visit.
    public static let sameVisitMs: Int64 = 30 * 60_000

    /// A play the listener starts within this long of a tap is the one the tap started (a card opens a page first, then play is pressed).
    public static let playWindowMs: Int64 = 10 * 60_000
    static let firstEvents = 8

    private let file: ImpressionFile
    private let engine: BrainEngine
    private let clock: @Sendable () -> Int64
    private let tzOffsetMin: @Sendable (Int64) -> Int32
    private var rows: [Impression]?
    private var state: ShelfBandit.State?

    /// The visit on screen now: its id, the shelf ids by position and the deepest position known to be seen.
    private var visitId: Int64 = 0
    private var visitShelves: [String] = []
    private var seenDepth = -1
    private var activated = Set<Int>()
    /// When the page last reported anything. A visit is over after `sameVisitMs` without a signal, not that long after it began.
    private var lastTouchMs: Int64 = 0
    /// Bumped by a reset: a settle that was working while it happened writes nothing.
    private var epoch = 0

    public init(directory: URL, engine: BrainEngine, tzOffsetMin: @escaping @Sendable (Int64) -> Int32,
                clock: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        file = ImpressionFile(directory: directory)
        self.engine = engine
        self.tzOffsetMin = tzOffsetMin
        self.clock = clock
    }

    private func loadedRows() -> [Impression] {
        if let rows { return rows }
        let loaded = file.load()
        rows = loaded
        return loaded
    }

    private func loadedState() -> ShelfBandit.State {
        if let state { return state }
        // The saved posteriors; when they are missing or cannot be read they start from their priors, as on Android. The impressions do
        // not hold the reward (it comes from the log at settling), so they cannot make the state again; a few weeks of visits do.
        let value = file.readBandit().flatMap(ShelfBanditCodec.decode) ?? ShelfBandit.newState()
        state = value
        return value
    }

    private func save(_ s: ShelfBandit.State) { file.writeBandit(ShelfBanditCodec.encode(s)) }

    private func update(_ changed: [Impression]) {
        var all = loadedRows()
        for row in changed {
            if let i = all.firstIndex(where: { $0.visitId == row.visitId && $0.position == row.position }) { all[i] = row } else { all.append(row) }
        }
        all.sort { $0.visitId != $1.visitId ? $0.visitId < $1.visitId : $0.position < $1.position }
        rows = all
        file.put(changed)
    }

    /// The page was shown with `types` (the shelf type of each shelf, in page order) whose ids are `ids`. The same page shown again
    /// within `sameVisitMs` of the last signal is the same visit. Gives earlier visits to the bandit afterwards.
    public func onPlanShown(ids: [String], types: [Int32], daypart: Int) async {
        if ids.isEmpty || ids.count != types.count { return }
        let now = clock()
        if visitId != 0 && now - lastTouchMs >= 0 && now - lastTouchMs < Self.sameVisitMs && visitShelves == ids {
            lastTouchMs = now
            return
        }
        // The new visit is in place before anything is awaited: a second page shown meanwhile sees it, not a half-made one.
        visitId = now
        lastTouchMs = now
        visitShelves = ids
        seenDepth = -1
        activated.removeAll()
        update(ids.indices.map { Impression(visitId: now, position: $0, shelf: Int(types[$0]), daypart: daypart, shownAtMs: now) })
        prune(now)
        await settleLocked(now)
    }

    /// At most `keepVisits` visits and `keepDays` days.
    private func prune(_ now: Int64) {
        var all = loadedRows()
        let cutoff = now - ImpressionFile.keepDays * BrainMath.dayMs
        var doomed = all.filter { $0.shownAtMs < cutoff }
        all.removeAll { $0.shownAtMs < cutoff }
        let visits = Array(Set(all.map(\.visitId))).sorted()
        if visits.count > ImpressionFile.keepVisits {
            let drop = Set(visits.prefix(visits.count - ImpressionFile.keepVisits))
            doomed.append(contentsOf: all.filter { drop.contains($0.visitId) })
            all.removeAll { drop.contains($0.visitId) }
        }
        if doomed.isEmpty { return }
        rows = all
        file.remove(doomed)
    }

    /// The shelf `shelfId` was on screen for at least a second: the page was looked at down to it.
    public func onShelfSeen(_ shelfId: String) {
        guard let position = visitShelves.firstIndex(of: shelfId), visitId != 0, position > seenDepth else { return }
        seenDepth = position
        lastTouchMs = clock()
        markSeenThrough(position)
    }

    private func markSeenThrough(_ position: Int) {
        let changed = loadedRows().filter { $0.visitId == visitId && $0.position <= position && !$0.seen }.map { row -> Impression in
            var r = row
            r.seen = true
            return r
        }
        if !changed.isEmpty { update(changed) }
    }

    /// Something was started from the shelf `shelfId` (a card or a song): it is the shelf of this visit, unless the visit already
    /// has one.
    public func onShelfActivated(_ shelfId: String) {
        guard visitId != 0, let position = visitShelves.firstIndex(of: shelfId), activated.insert(position).inserted else { return }
        lastTouchMs = clock()
        if var row = loadedRows().first(where: { $0.visitId == visitId && $0.position == position }), row.activatedAtMs == 0 {
            row.activatedAtMs = lastTouchMs
            update([row])
        }
        if position > seenDepth {
            seenDepth = position
            markSeenThrough(position)
        }
    }

    /// Gives every finished visit to the bandit. Safe to call any time (the refresh worker calls it).
    public func settle(nowMs: Int64? = nil) async { await settleLocked(nowMs ?? clock()) }

    /// The unsettled visits that are over, each one's rows in page order. A visit is over once nothing has happened on it for
    /// `sameVisitMs`: it was shown, a shelf was started from it, or (for the page on screen now) the page reported anything. A tap
    /// keeps the visit open for that long too, so a song started from a shelf has been heard, and its play recorded, before the visit is
    /// given to the bandit.
    private func finishedVisits(_ nowMs: Int64) -> [[Impression]] {
        let pending = loadedRows().filter { !$0.settled }
        var out: [[Impression]] = []
        var i = 0
        while i < pending.count {
            var j = i
            while j < pending.count && pending[j].visitId == pending[i].visitId { j += 1 }
            let group = Array(pending[i..<j])
            i = j
            var activity = group.map { max($0.shownAtMs, $0.activatedAtMs) }.max() ?? group[0].visitId
            if group[0].visitId == visitId { activity = max(activity, lastTouchMs) }
            if nowMs - activity >= Self.sameVisitMs { out.append(group) }
        }
        return out
    }

    private func settleLocked(_ nowMs: Int64) async {
        let finished = finishedVisits(nowMs)
        if finished.isEmpty { return }
        let epochAtStart = epoch
        // First everything that needs a wait (the plays a tap started are read from the log); nothing of the bandit's state is held
        // across it, so a reset or an order drawn meanwhile is not overwritten by an older copy.
        var claimed = Set<Int64>()
        var results: [(group: [Impression], lastSeen: Int, used: Int)] = []
        for group in finished {
            var lastSeen = -1
            var used = -1
            for k in group.indices {
                if group[k].seen { lastSeen = k }
                if group[k].activatedAtMs > 0 && used < 0, await wasPlayedThirtySeconds(group[k].activatedAtMs, claimed: &claimed) { used = k }
                // Started but not played for 30 seconds: the listener looked at it, no reward.
                if group[k].activatedAtMs > 0 && k > lastSeen { lastSeen = k }
            }
            results.append((group, lastSeen, used))
        }
        // From here to the end nothing suspends.
        if epoch != epochAtStart { return }
        let stillOpen = Set(loadedRows().filter { !$0.settled }.map(\.visitId))
        var s = loadedState()
        var moved = false
        var settled: [Impression] = []
        for r in results where stillOpen.contains(r.group[0].visitId) {
            let at = r.group[0].shownAtMs
            let today = BrainMath.localDay(at, tzOffsetMin: tzOffsetMin(at))
            if ShelfBandit.visit(&s, daypart: r.group[0].daypart, shown: r.group.map { Int32($0.shelf) }, lastSeen: r.lastSeen,
                                 used: r.used, today: today) > 0 { moved = true }
            settled.append(contentsOf: r.group.map { row -> Impression in
                var copy = row
                copy.settled = true
                return copy
            })
        }
        state = s
        // The posteriors are saved BEFORE the visits are marked as given: a stop between the two counts a visit twice at worst, never
        // loses one for good.
        if moved { save(s) }
        update(settled)
    }

    /// True when the first play the listener's tap started within `playWindowMs` of `activatedAtMs` was heard for at least 30 seconds
    /// (or to its end).
    private func wasPlayedThirtySeconds(_ activatedAtMs: Int64, claimed: inout Set<Int64>) async -> Bool {
        Self.reward(events: await engine.recentEvents(sinceMs: activatedAtMs), activatedAtMs: activatedAtMs, claimed: &claimed)
    }

    /// The rule of the reward, on the plays that started at or after the tap, oldest first (pure, tested). Plays that count for nothing
    /// (private, silent) are skipped, and so are the ones the queue moved on to by itself (auto advance, autoplay, a restored queue):
    /// they are not what the tap started. A play rewards one shelf only (`claimed`). The play is not matched to the shelf's own list: the
    /// event carries a surface and a list id, but a shelf and a list do not share ids yet.
    static func reward(events: [PlayEvent], activatedAtMs: Int64, claimed: inout Set<Int64>) -> Bool {
        for e in events.prefix(firstEvents) {
            if e.startedAtMs < activatedAtMs { continue }
            if e.startedAtMs > activatedAtMs + playWindowMs { return false }
            if e.has(EventFlags.learnExcluded) || e.has(EventFlags.neverAudible) { continue }
            if e.startReason == StartReason.autoAdvance || e.startReason == StartReason.autoplay || e.startReason == StartReason.restore { continue }
            if !claimed.insert(e.eventId).inserted { continue }
            return e.endReason == EndReason.trackDone || Int64(e.playedMs) >= ShelfBandit.rewardPlayMs
        }
        return false
    }

    static func reward(events: [PlayEvent], activatedAtMs: Int64) -> Bool {
        var claimed = Set<Int64>()
        return reward(events: events, activatedAtMs: activatedAtMs, claimed: &claimed)
    }

    /// The shelf types `types` (in stage 2's fixed order) in the order the bandit draws for this daypart, or nil to keep the fixed
    /// order: no data yet, or the gate has the prior on. The draw is frozen for the daypart (`ShelfBandit.order`).
    public func order(types: [Int32], planKey: Int64, daypart: Int, salt: Int64, nowMs: Int64) async -> [Int32]? {
        if !(await engine.usesLearned()) { return nil }
        var s = loadedState()
        let today = BrainMath.localDay(nowMs, tzOffsetMin: tzOffsetMin(nowMs))
        let before = s.frozenKey
        let order = ShelfBandit.order(&s, planKey: planKey, daypart: daypart, types: types,
                                      seed: Ranker.listSeed(salt: salt, listId: "shelves:\(planKey)", localDay: today), today: today)
        state = s
        if s.frozenKey != before { save(s) }
        return order
    }

    /// "Reset what I've learned": the posteriors go back to their priors and the impressions are forgotten.
    public func reset() {
        epoch += 1
        file.remove(loadedRows())
        rows = []
        state = ShelfBandit.newState()
        file.writeBandit(nil)
        visitId = 0
        lastTouchMs = 0
        visitShelves = []
        seenDepth = -1
        activated.removeAll()
    }

    /// The posteriors, for a screen that wants to show them and for tests.
    public func snapshot() -> ShelfBandit.State { loadedState() }

    /// How many impression records are stored (tests; the size of the file is bounded by `keepVisits`).
    public func impressionCount() -> Int { loadedRows().count }
}
