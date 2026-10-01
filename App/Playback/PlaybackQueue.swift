import Foundation
import PixlLibrary
import PixlModel

/// One queued song. The id is unique per queue position (the same song can be queued twice), so decks, items and the
/// UI can follow an entry through moves and removals.
nonisolated struct QueueEntry: Hashable, Sendable, Identifiable {
    let id: Int
    let song: Song
}

/// The play queue with Android's semantics (Media3 playlist + `QueueStateHolder`): an order that may be shuffled
/// (anchored Fisher–Yates from PixlLibrary's `QueueUtils`, the original order kept for un-shuffling), the current
/// index, and Media3's next/previous rules for each repeat mode. A value type with no I/O — `DualDeckEngine` drives it.
nonisolated struct PlaybackQueue: Sendable {
    /// Media3 `maxSeekToPreviousPositionMs`: previous restarts the song when more than this far in.
    static let restartThresholdMs: Int64 = 3000

    private(set) var entries: [QueueEntry] = []
    /// The unshuffled order while shuffle is on (Android `originalQueueOrder`).
    private(set) var originalOrder: [QueueEntry]?
    private(set) var currentIndex: Int?
    var repeatMode: RepeatMode = .off
    private var nextId = 1

    init() {}

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }
    var isShuffled: Bool { originalOrder != nil }
    var songs: [Song] { entries.map(\.song) }

    var current: QueueEntry? {
        guard let currentIndex, entries.indices.contains(currentIndex) else { return nil }
        return entries[currentIndex]
    }

    func index(ofEntry id: Int) -> Int? { entries.firstIndex { $0.id == id } }

    func entry(at index: Int) -> QueueEntry? { entries.indices.contains(index) ? entries[index] : nil }

    private mutating func makeEntries(_ songs: [Song]) -> [QueueEntry] {
        songs.map { song in
            defer { nextId += 1 }
            return QueueEntry(id: nextId, song: song)
        }
    }

    // MARK: Replace / shuffle

    /// Replaces the queue (Android `playSongs`). With `shuffle`, the start song keeps its position and the rest is
    /// shuffled around it (`prepareShuffledQueueWithStart` → `buildAnchoredShuffleQueue`).
    mutating func replace<R: ShuffleRandom>(with songs: [Song], startIndex: Int, shuffle: Bool, random: inout R) {
        let fresh = makeEntries(songs)
        guard !fresh.isEmpty else {
            entries = []
            originalOrder = nil
            currentIndex = nil
            return
        }
        let start = min(max(startIndex, 0), fresh.count - 1)
        if shuffle {
            originalOrder = fresh
            entries = QueueUtils.buildAnchoredShuffleQueue(fresh, anchorIndex: start, random: &random)
        } else {
            originalOrder = nil
            entries = fresh
        }
        currentIndex = start
    }

    mutating func replace(with songs: [Song], startIndex: Int, shuffle: Bool) {
        var random = SystemShuffleRandom()
        replace(with: songs, startIndex: startIndex, shuffle: shuffle, random: &random)
    }

    /// Restores a saved queue as it was (no reshuffle). `originalSongs` is the unshuffled order when shuffled.
    mutating func restore(songs: [Song], currentIndex index: Int, originalSongs: [Song]?) {
        entries = makeEntries(songs)
        originalOrder = originalSongs.map { makeEntries($0) }
        currentIndex = entries.isEmpty ? nil : min(max(index, 0), entries.count - 1)
    }

    /// Shuffle on: anchored shuffle around the current entry (it keeps its index). Shuffle off: back to the original
    /// order with the current entry at its original index (Android `toggleShuffle`).
    mutating func setShuffle<R: ShuffleRandom>(_ enabled: Bool, random: inout R) {
        if enabled {
            guard originalOrder == nil, !entries.isEmpty else { return }
            originalOrder = entries
            let anchor = currentIndex ?? 0
            entries = QueueUtils.buildAnchoredShuffleQueue(entries, anchorIndex: anchor, random: &random)
        } else {
            guard let original = originalOrder else { return }
            originalOrder = nil
            let currentId = current?.id
            // Entries added while shuffled are kept, after the original ones.
            let originalIds = Set(original.map(\.id))
            let present = Set(entries.map(\.id))
            entries = original.filter { present.contains($0.id) } + entries.filter { !originalIds.contains($0.id) }
            currentIndex = currentId.flatMap { id in entries.firstIndex { $0.id == id } } ?? (entries.isEmpty ? nil : 0)
        }
    }

    mutating func setShuffle(_ enabled: Bool) {
        var random = SystemShuffleRandom()
        setShuffle(enabled, random: &random)
    }

    // MARK: Navigation (Media3 rules)

    /// The index that follows the current one when the song ends on its own: the same index under repeat-one, the
    /// next one, wrapping under repeat-all; nil at the end with repeat off.
    var nextIndexForAutoAdvance: Int? {
        guard let currentIndex, !entries.isEmpty else { return nil }
        switch repeatMode {
        case .one: return currentIndex
        case .all: return currentIndex + 1 < entries.count ? currentIndex + 1 : 0
        case .off: return currentIndex + 1 < entries.count ? currentIndex + 1 : nil
        }
    }

    /// `seekToNext`: the next index ignoring repeat-one, wrapping under repeat-all; nil at the end with repeat off
    /// (Media3 then does nothing).
    var nextIndexForSkip: Int? {
        guard let currentIndex, !entries.isEmpty else { return nil }
        if currentIndex + 1 < entries.count { return currentIndex + 1 }
        return repeatMode == .all ? 0 : nil
    }

    /// `seekToPrevious` target when the position is within the restart threshold: the previous index, wrapping to the
    /// last one under repeat-all; nil means "restart the current song".
    var previousIndex: Int? {
        guard let currentIndex, !entries.isEmpty else { return nil }
        if currentIndex > 0 { return currentIndex - 1 }
        return repeatMode == .all && entries.count > 1 ? entries.count - 1 : nil
    }

    /// The crossfade target (`CrossfadeScheduler.nextTargetIndex`: no wrap-around).
    var crossfadeTargetIndex: Int? {
        guard let currentIndex else { return nil }
        let target = repeatMode == .one ? currentIndex : currentIndex + 1
        return target < entries.count ? target : nil
    }

    mutating func setCurrentIndex(_ index: Int?) {
        guard let index else { currentIndex = nil; return }
        currentIndex = entries.indices.contains(index) ? index : currentIndex
    }

    // MARK: Editing

    /// Inserts songs right after the current entry ("Play next").
    mutating func playNext(_ songs: [Song]) {
        let fresh = makeEntries(songs)
        guard !fresh.isEmpty else { return }
        guard let currentIndex else {
            entries = fresh
            self.currentIndex = 0
            return
        }
        entries.insert(contentsOf: fresh, at: currentIndex + 1)
        originalOrder?.append(contentsOf: fresh)
    }

    /// Appends songs at the end ("Add to queue").
    mutating func append(_ songs: [Song]) {
        let fresh = makeEntries(songs)
        guard !fresh.isEmpty else { return }
        entries.append(contentsOf: fresh)
        originalOrder?.append(contentsOf: fresh)
        if currentIndex == nil { currentIndex = 0 }
    }

    /// Moves the entry at `from` to `to` (both positions in the current order), keeping the current entry current.
    mutating func move(from: Int, to: Int) {
        guard entries.indices.contains(from), entries.indices.contains(to), from != to else { return }
        let currentId = current?.id
        let entry = entries.remove(at: from)
        entries.insert(entry, at: to)
        if let currentId { currentIndex = entries.firstIndex { $0.id == currentId } }
    }

    /// Removes the entry at `index`. Removing the current entry makes the following one current (or the new last).
    /// Returns true when the current entry changed.
    @discardableResult
    mutating func remove(at index: Int) -> Bool {
        guard entries.indices.contains(index) else { return false }
        let removed = entries.remove(at: index)
        originalOrder?.removeAll { $0.id == removed.id }
        guard let currentIndex else { return false }
        if entries.isEmpty {
            self.currentIndex = nil
            originalOrder = nil
            return true
        }
        if index < currentIndex {
            self.currentIndex = currentIndex - 1
            return false
        }
        if index == currentIndex {
            self.currentIndex = min(currentIndex, entries.count - 1)
            return true
        }
        return false
    }

    /// Removes everything after the current entry.
    mutating func clearUpcoming() {
        guard let currentIndex, currentIndex + 1 < entries.count else { return }
        let dropped = Set(entries[(currentIndex + 1)...].map(\.id))
        entries.removeSubrange((currentIndex + 1)...)
        originalOrder?.removeAll { dropped.contains($0.id) }
    }
}
