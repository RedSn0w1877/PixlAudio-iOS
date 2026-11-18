import Foundation
import PixlModel

/// Which library songs play with no network (docs/brain-spec.md, 7.1): a file on this phone, a finished download,
/// or a complete copy in the audio cache. Autoplay asks only when the phone is offline, about the few songs its
/// library pool would hold, off the main actor. A song that streams would fail to load, one after another, where
/// the queue used to end.
nonisolated enum AutoplayOffline {
    @concurrent
    static func playable(_ songs: [Song], persistence: PersistenceActor?, cache: StreamCache?) async -> Set<String> {
        let downloaded = DownloadFiles.downloadedIds()
        var out = Set<String>()
        for song in songs {
            if LibraryIdentity.isManaged(song.id) {
                out.insert(song.id)
                continue
            }
            // The audio ids the song can play under: its own (a `yt:` song), or for a Spotify song its stored match
            // and the id it plays under when YouTube has no match.
            var videoIds: [String] = []
            if let own = YouTubeSongIdentity.videoId(for: song) {
                videoIds.append(own)
            } else if let spotifyId = AutoplayController.spotifyId(of: song) {
                if let matched = try? await persistence?.matchedVideoId(spotifyId: spotifyId) { videoIds.append(matched) }
                videoIds.append(SpotiFLACTrackRegistry.syntheticVideoId(forSpotifyId: spotifyId))
            }
            for videoId in videoIds {
                if downloaded.contains(videoId) {
                    out.insert(song.id)
                    break
                }
                if let cache, await cache.isComplete(videoId) {
                    out.insert(song.id)
                    break
                }
            }
        }
        return out
    }
}
