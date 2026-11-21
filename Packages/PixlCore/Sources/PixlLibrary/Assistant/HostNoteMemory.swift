// The songs whose host note was shown or spoken in Endless Listening, newest last. The note window is made again at every track, so without
// a memory the current track would always be free for a note and one would land on almost every track; `HostNotes.tracksSinceNote` reads
// this to keep "at most one note per five tracks" true across index changes and rebuilt windows. One memory for the player card, the queue
// rows and the spoken line, so what is shown and what is said agree. A port of Android's `HostNoteMemory`. Holds a few ids only; safe from
// any thread.

import Foundation

public final class HostNoteMemory: @unchecked Sendable {
    /// Only the four tracks before the current one matter; a few more cover going back and forth.
    public static let capacity = 24

    private let lock = NSLock()
    private var order: [String] = []

    public init() {}

    /// The song `id` had its note shown or spoken. Idempotent.
    public func mark(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        if let at = order.firstIndex(of: id) { order.remove(at: at) }
        order.append(id)
        if order.count > Self.capacity { order.removeFirst(order.count - Self.capacity) }
    }

    /// True when `id` had its note shown or spoken.
    public func has(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return order.contains(id)
    }

    /// A copy of the ids, for the pure rule.
    public func snapshot() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(order)
    }

    /// Forgets everything (the station ended, or a new one began).
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        order.removeAll()
    }
}
