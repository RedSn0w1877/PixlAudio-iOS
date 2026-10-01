import Foundation
import PixlModel

/// Saves and loads the play queue across launches under Android's key `playback_queue_snapshot_v1` (the
/// `PlaybackQueueSnapshot` JSON, same field names). Saves are coalesced: at most one write per second while things
/// change, and an immediate one on pause / backgrounding.
@MainActor
final class QueueSnapshotStore {
    static let saveDelay: Duration = .seconds(1)

    private let defaults: UserDefaults
    private let key: String
    private var pendingSave: Task<Void, Never>?
    /// Produces the snapshot to save (nil clears it).
    var makeSnapshot: () -> PlaybackQueueSnapshot? = { nil }

    init(defaults: UserDefaults = .standard, key: String = PreferenceKeys.playbackQueueSnapshot) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> PlaybackQueueSnapshot? {
        guard let text = defaults.string(forKey: key), let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PlaybackQueueSnapshot.self, from: data)
    }

    func scheduleSave() {
        guard pendingSave == nil else { return }
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard let self, !Task.isCancelled else { return }
            self.pendingSave = nil
            self.saveNow()
        }
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let snapshot = makeSnapshot() else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(snapshot), let text = String(data: data, encoding: .utf8) else {
            return
        }
        defaults.set(text, forKey: key)
    }

    func clear() {
        pendingSave?.cancel()
        pendingSave = nil
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
