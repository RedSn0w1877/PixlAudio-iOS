import Foundation
import PixlModel
import PixlNet
import PixlTags

/// The platform pieces of Spotify Connect output: the resolution cache file and the ISRC read from local tags.
nonisolated enum SpotifyConnectPlatform {
    /// `Application Support/spotify-connect-resolutions.json`.
    static func cacheURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("spotify-connect-resolutions.json")
    }

    /// What resolution needs from a queue entry: a local file's URL rides along so its ISRC can be read on a cache
    /// miss (media-library and streamed songs have none).
    static func song(_ song: Song) -> SpotifyConnectSong {
        let url = DefaultPlayableURLResolver.url(for: song)
        return SpotifyConnectSong(key: song.id, spotifyId: song.spotifyId, title: song.title, artist: song.displayArtist,
                                  durationMs: song.duration, fileURL: url?.isFileURL == true ? url?.absoluteString : nil)
    }

    /// The `ISRC` tag of a local file (ID3v2 `TSRC`, Vorbis `ISRC`, MP4 `----:com.apple.iTunes:ISRC`), read from
    /// the tag region only, off the main actor.
    static let isrc: SpotifyConnectResolver.ISRCLookup = { song in
        guard let string = song.fileURL, let url = URL(string: string), url.isFileURL,
              let region = TagRegionReader.read(url: url), let tags = try? AudioTagReader.read(region),
              let value = tags.properties.first("ISRC") else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The resolution cache as a JSON file, written atomically off the main actor.
nonisolated struct SpotifyConnectFileStorage: SpotifyConnectResolutionStorage {
    let url: URL

    func load() async -> Data? { try? Data(contentsOf: url) }

    func save(_ data: Data) async {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
