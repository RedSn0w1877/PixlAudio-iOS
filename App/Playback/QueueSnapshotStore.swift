import Foundation
import PixlModel

/// Saves and loads the play queue across launches under Android's key `playback_queue_snapshot_v1` (the
/// `PlaybackQueueSnapshot` JSON, same field names). Saves are coalesced: at most one write per second while things
/// change, and an immediate one on backgrounding.
///
/// The queue can hold the whole library (playing from Library › Songs, Shuffle All): mapping thousands of entries
/// and JSON-encoding them took tens of milliseconds, so it no longer runs on the main actor. The main actor only
/// captures the queue (a copy-on-write value) and the position; the mapping and encoding run in a `@concurrent`
/// function, and the result is written back on the main actor in save order — a slow older encode never overwrites
/// a newer snapshot. Only app termination still saves synchronously (the process ends when its handler returns).
@MainActor
final class QueueSnapshotStore {
    static let saveDelay: Duration = .seconds(1)

    private let defaults: UserDefaults
    private let key: String
    private var pendingSave: Task<Void, Never>?
    /// Every save takes a number; a finished encode is written only if nothing newer was written first.
    private var issued = 0
    private var written = 0
    /// Produces the snapshot to save (nil clears it). Used by the synchronous `saveNow()`.
    var makeSnapshot: () -> PlaybackQueueSnapshot? = { nil }
    /// Captures what a save needs, cheaply, on the main actor (nil clears it). When set, scheduled and background
    /// saves encode off the main actor.
    var makeCapture: (() -> QueueSnapshotCapture?)?

    init(defaults: UserDefaults = .standard, key: String = PreferenceKeys.playbackQueueSnapshot) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> PlaybackQueueSnapshot? {
        guard let text = defaults.string(forKey: key) else { return nil }
        return QueueSnapshotCoding.decodeNow(text)
    }

    /// `load()` with the JSON decoded off the main actor (launch restore).
    func loadInBackground() async -> PlaybackQueueSnapshot? {
        guard let text = defaults.string(forKey: key) else { return nil }
        return await QueueSnapshotCoding.decode(text)
    }

    func scheduleSave() {
        guard pendingSave == nil else { return }
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard let self, !Task.isCancelled else { return }
            self.pendingSave = nil
            self.saveInBackground()
        }
    }

    /// Captures the queue now and encodes it off the main actor; `completion` runs on the main actor once the
    /// snapshot is written (or dropped because a newer one was written first).
    func saveInBackground(completion: (@MainActor @Sendable () -> Void)? = nil) {
        pendingSave?.cancel()
        pendingSave = nil
        guard let makeCapture else {
            saveNow()
            completion?()
            return
        }
        issued += 1
        let token = issued
        guard let capture = makeCapture() else {
            written = token
            defaults.removeObject(forKey: key)
            completion?()
            return
        }
        Task { [weak self] in
            let text = await QueueSnapshotCoding.encode(capture)
            if let self, let text, token > self.written {
                self.written = token
                self.defaults.set(text, forKey: self.key)
            }
            completion?()
        }
    }

    /// Saves synchronously on the main actor (app termination; tests).
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        issued += 1
        written = issued
        guard let snapshot = makeSnapshot() else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let text = QueueSnapshotCoding.encodeNow(snapshot) else { return }
        defaults.set(text, forKey: key)
    }

    func clear() {
        pendingSave?.cancel()
        pendingSave = nil
        issued += 1
        written = issued
        defaults.removeObject(forKey: key)
    }

    /// The snapshot's items as songs: library songs where the id is known, otherwise songs rebuilt from the
    /// snapshot's own metadata (so a queue of not-yet-imported items still restores).
    static func songs(for snapshot: PlaybackQueueSnapshot, lookup: (String) -> Song?) -> [Song] {
        snapshot.items.map { item in
            if let song = lookup(item.mediaId) { return song }
            return Song(id: item.mediaId, title: item.title ?? "", artist: item.artist ?? "", artistId: -1,
                        album: item.albumTitle ?? "", albumId: -1, path: "", contentUriString: item.uri,
                        albumArtUriString: item.artworkUri, duration: item.durationMs ?? 0, mimeType: nil,
                        bitrate: nil, sampleRate: nil)
        }
    }
}

/// What a queue save needs, captured on the main actor: the queue is a copy-on-write value, so this is cheap.
nonisolated struct QueueSnapshotCapture: Sendable {
    var queue: PlaybackQueue
    var positionMs: Int64
    var playWhenReady: Bool
    var shuffleEnabled: Bool
    var nowMs: Int64

    /// The queue as Android persists it (`PlaybackQueueSnapshot`); nil for an empty queue.
    func makeSnapshot() -> PlaybackQueueSnapshot? {
        guard !queue.isEmpty else { return nil }
        let items = queue.entries.map { entry in
            PlaybackQueueItemSnapshot(mediaId: entry.song.id, uri: entry.song.contentUriString,
                                      title: entry.song.title, artist: entry.song.displayArtist,
                                      albumTitle: entry.song.album, artworkUri: entry.song.albumArtUriString,
                                      durationMs: entry.song.duration)
        }
        return PlaybackQueueSnapshot(items: items, currentMediaId: queue.current?.song.id,
                                     currentIndex: queue.currentIndex ?? 0, currentPositionMs: positionMs,
                                     playWhenReady: playWhenReady, repeatMode: queue.repeatMode.rawValue,
                                     shuffleEnabled: shuffleEnabled, savedAtEpochMs: nowMs)
    }
}

/// The snapshot's JSON (the same bytes either way: one `JSONEncoder` with default settings).
nonisolated enum QueueSnapshotCoding {
    @concurrent
    static func encode(_ capture: QueueSnapshotCapture) async -> String? {
        guard let snapshot = capture.makeSnapshot() else { return nil }
        return encodeNow(snapshot)
    }

    @concurrent
    static func decode(_ text: String) async -> PlaybackQueueSnapshot? {
        decodeNow(text)
    }

    static func encodeNow(_ snapshot: PlaybackQueueSnapshot) -> String? {
        guard let data = try? JSONEncoder().encode(snapshot) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeNow(_ text: String) -> PlaybackQueueSnapshot? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PlaybackQueueSnapshot.self, from: data)
    }
}
