// Builds the payload for the song that is playing (Song Tap, the sending side). The video id is the one the song plays
// from; the Spotify id goes along only when it is a real one (a made-up id of a song saved from YouTube means nothing
// to anyone else). No account, no device and no listener name is ever read here. A port of `SongTapSender.kt`.

import PixlModel

/// The ids the sender's library knows for a song, behind a small interface so the rules can be tested.
public protocol SongTapSongIds: Sendable {
    /// The video the song plays from: its own (a YouTube song) or the one matched to its Spotify id; nil when it has none yet.
    func videoId(for song: Song) async -> String?
    /// The recording code of a Spotify track, when known.
    func isrc(forSpotifyId spotifyId: String) async -> String?
    /// True when `spotifyId` is the made-up id a song saved from `videoId` carries.
    func isSyntheticId(_ spotifyId: String, forVideo videoId: String) -> Bool
}

public struct SongTapSender: Sendable {
    private let ids: any SongTapSongIds

    public init(ids: any SongTapSongIds) {
        self.ids = ids
    }

    /// Nil when the song has neither a video nor a Spotify id (it cannot be named to another phone).
    public func payload(for song: Song, nowMs: Int64) async -> SongTapPayload? {
        let own = song.spotifyId
        let video = await ids.videoId(for: song)
        if own == nil && video == nil { return nil }
        var real: String?
        if let own, video == nil || !ids.isSyntheticId(own, forVideo: video ?? "") { real = own }
        var isrc: String?
        if let real { isrc = await ids.isrc(forSpotifyId: real) }
        return SongTapPayloads.make(nowMs: nowMs, ytVideoId: video, spotifyId: real, isrc: isrc, title: song.title, artist: song.artist,
                                    durationMs: song.duration, artUrl: song.albumArtUriString)
    }
}
