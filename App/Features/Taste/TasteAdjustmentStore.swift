import Foundation
import Observation
import PixlLibrary
import PixlModel

/// Ask Taizo's taste changes (spec taizo-taste §2): the explicit boosts, reductions, mutes and blocks that sit above the
/// learned signals in the recommendation engine. Taizo's tools change them (`adjust_taste`, `remove_taste_adjustment`);
/// Settings › Library & storage › Ask Taizo's taste changes lists, removes and clears them. The rules (strengths, caps,
/// expiry, one change per target) are PixlLibrary's `TasteAdjustmentList`; this store keeps it in memory, publishes it to
/// the UI and writes it to `taste_adjustments.json` in Application Support off the main thread. Nothing here ever touches
/// a song or the history.
@Observable
final class TasteAdjustmentStore {
    /// The changes in force, newest first (what Settings lists).
    private(set) var items: [TasteAdjustment] = []
    /// Bumped on every change: Home re-plans and Taizo's cached taste profile is dropped.
    private(set) var revision = 0

    @ObservationIgnored private var list = TasteAdjustmentList()
    @ObservationIgnored private var isLoaded: Bool
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let file: URL?

    /// `file == nil` keeps everything in memory (UI tests); `seed` fills it for a demo screen.
    init(file: URL?, seed: TasteAdjustmentList = .empty) {
        self.file = file
        isLoaded = file == nil
        if file == nil {
            list = seed
            items = Self.newestFirst(seed.items)
        }
    }

    static func defaultURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("taste_adjustments.json")
    }

    static func make(launch: LaunchConfiguration) -> TasteAdjustmentStore {
        if launch.isUITest {
            let seed = launch.screen == .tasteChanges ? DemoTasteChanges.list(nowMs: HomeClock.uiTest.nowMs()) : .empty
            return TasteAdjustmentStore(file: nil, seed: seed)
        }
        return TasteAdjustmentStore(file: defaultURL())
    }

    private static func newestFirst(_ items: [TasteAdjustment]) -> [TasteAdjustment] {
        items.sorted { $0.createdMs != $1.createdMs ? $0.createdMs > $1.createdMs : $0.id < $1.id }
    }

    var count: Int { items.count }

    // MARK: Loading

    /// Reads the file once, off the main thread.
    func ensureLoaded() async {
        if isLoaded { return }
        if let loadTask { return await loadTask.value }
        let file = self.file
        let task = Task { [weak self] in
            let stored = await Self.read(file)
            guard let self, !self.isLoaded else { return }
            // Changes made while the file was loading win over the stored ones with the same id.
            var merged = stored ?? .empty
            for item in self.list.items {
                if let index = merged.items.firstIndex(where: { $0.id == item.id }) {
                    merged.items[index] = item
                } else {
                    merged.items.append(item)
                }
            }
            merged.prune(nowMs: currentTimeMillis())
            self.list = merged
            self.items = Self.newestFirst(merged.items)
            self.isLoaded = true
        }
        loadTask = task
        await task.value
    }

    @concurrent
    private nonisolated static func read(_ file: URL?) async -> TasteAdjustmentList? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return TasteAdjustmentList.decode(data)
    }

    // MARK: Reading

    /// The engine's view of the changes in force (empty before the file is read: callers `ensureLoaded()` first).
    func activeSet(nowMs: Int64) -> TasteAdjustmentSet { list.set(nowMs: nowMs) }

    // MARK: Changing

    /// Applies the changes in order and returns what each did. One save and one revision bump for the whole call.
    func apply(_ changes: [TasteChange]) async -> [TasteChangeOutcome] {
        await ensureLoaded()
        let now = currentTimeMillis()
        let outcomes = changes.map { list.apply($0, nowMs: now) }
        let touched = outcomes.contains { outcome in
            switch outcome {
            case .set, .removed: true
            case .nothingToRemove, .listFull: false
            }
        }
        if touched { changed() }
        return outcomes
    }

    /// Settings › Remove (and `remove_taste_adjustment` with an id). False when it was already gone.
    @discardableResult
    func remove(id: String) -> Bool {
        guard list.remove(id: id) else { return false }
        changed()
        return true
    }

    /// Settings › Clear all (and `remove_taste_adjustment` with `all`). Returns how many went.
    @discardableResult
    func removeAll() -> Int {
        let count = list.removeAll()
        if count > 0 { changed() }
        return count
    }

    private func changed() {
        list.prune(nowMs: currentTimeMillis())
        items = Self.newestFirst(list.items)
        revision &+= 1
        save()
    }

    private func save() {
        guard let file, isLoaded else { return }
        let snapshot = list
        Task.detached(priority: .utility) {
            let data = snapshot.encoded()
            guard !data.isEmpty else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}

/// A few changes for the Settings screen's screenshot (UI tests).
nonisolated enum DemoTasteChanges {
    static func list(nowMs: Int64) -> TasteAdjustmentList {
        let day: Int64 = 86_400_000
        var list = TasteAdjustmentList()
        list.apply(TasteChange(action: .boost, targetType: .artist, key: TasteKey.of("Luma Fields"), label: "Luma Fields", strength: 3,
                               reason: "You asked for more of them"), nowMs: nowMs - 2 * day)
        list.apply(TasteChange(action: .reduce, targetType: .genre, key: TasteKey.of("Synthwave"), label: "Synthwave", strength: 1,
                               reason: "Too much of it lately", expiresDays: 30), nowMs: nowMs - day)
        list.apply(TasteChange(action: .mute, targetType: .song, key: "pixelparade|latenightdrive", label: "Late Night Drive — Pixel Parade",
                               reason: "Heard it too many times", source: .user), nowMs: nowMs - 3_600_000)
        list.apply(TasteChange(action: .block, targetType: .artist, key: TasteKey.of("Hollow Pines"), label: "Hollow Pines",
                               reason: "Not for me"), nowMs: nowMs - 600_000)
        return list
    }
}
