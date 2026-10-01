import Foundation
import MediaPlayer

/// The device music library (`MPMediaLibrary`): only items PixlAudio can actually play — downloaded, DRM-free
/// songs (`assetURL != nil && !hasProtectedAsset`). Cloud-only and protected items are skipped. Access is asked
/// for only when the user turns the source on (`requestAccess`), never at launch.
nonisolated enum MediaLibraryImporter {
    static var isAuthorized: Bool { MPMediaLibrary.authorizationStatus() == .authorized }

    /// Whether the system would still show the permission prompt.
    static var canRequestAccess: Bool { MPMediaLibrary.authorizationStatus() == .notDetermined }

    static func requestAccess() async -> Bool {
        await MPMediaLibrary.requestAuthorization() == .authorized
    }

    /// The library's last change (cheap; lets a scan skip re-reading the items when nothing changed).
    static var lastModified: Date? { isAuthorized ? MPMediaLibrary.default().lastModifiedDate : nil }

    /// Reads every playable song item into scanned tracks (synchronous; call it off the main actor).
    static func tracks() -> [ScannedTrack] {
        guard isAuthorized, let items = MPMediaQuery.songs().items else { return [] }
        var tracks: [ScannedTrack] = []
        tracks.reserveCapacity(items.count)
        for item in items {
            guard let assetURL = item.assetURL, !item.hasProtectedAsset else { continue }
            let id = LibraryIdentity.mediaLibrarySongID(persistentID: item.persistentID)
            let title = nonEmpty(item.title) ?? "Unknown Title"
            let added = Int64((item.dateAdded.timeIntervalSince1970 * 1000).rounded())
            let year = item.releaseDate.map { Calendar(identifier: .gregorian).component(.year, from: $0) } ?? 0
            let albumPersistentID = item.albumPersistentID
            tracks.append(ScannedTrack(
                id: id, title: title, artist: nonEmpty(item.artist) ?? "Unknown Artist",
                album: nonEmpty(item.albumTitle) ?? "Unknown Album",
                albumArtist: nonEmpty(item.albumArtist), genre: ScannedTrack.normalizeGenre(item.genre),
                trackNumber: item.albumTrackNumber, discNumber: item.discNumber > 0 ? item.discNumber : nil,
                year: year, durationMs: Int64((item.playbackDuration * 1000).rounded()),
                mimeType: AudioFileTypes.mimeType(assetURL.pathExtension), bitrate: nil, sampleRate: nil,
                contentUri: assetURL.absoluteString,
                artworkUri: item.artwork == nil ? nil : ScannedTrack.embeddedArtworkURI(assetURL),
                path: "", parentDirectory: "", dateAdded: added, dateModified: added,
                fallbackAlbumId: albumPersistentID == 0 ? nil
                    : Int64(bitPattern: albumPersistentID & 0x7FFF_FFFF_FFFF_FFFF)))
        }
        return tracks
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
