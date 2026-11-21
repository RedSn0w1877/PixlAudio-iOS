// Turns a validated beam into a library song (Song Tap, the receiving side). The rules live here, over a small port
// the app implements with the importer Search's Save uses, so they are tested without a library. A port of the
// Android `SongTapReceiver.kt` and `SongTapLibrary` interface.
//
// It touches the library only. Nothing here is a listening event: no play is recorded, the music brain is not told,
// and no "saved while playing" flag is set (a beamed song is not playing on this phone), so a private session needs no
// special case on the receiving side.

/// The title, artist and art the card shows, plus the key to undo and the library id to play.
public struct SongTapCard: Sendable, Equatable {
    public var videoId: String
    public var songId: String
    public var title: String
    public var artist: String
    public var artUrl: String?

    public init(videoId: String, songId: String, title: String, artist: String, artUrl: String?) {
        self.videoId = videoId
        self.songId = songId
        self.title = title
        self.artist = artist
        self.artUrl = artUrl
    }
}

/// What the receiver's card shows after a beam.
public enum SongTapSaveResult: Sendable, Equatable {
    /// The song as the card shows it: the validated beam text, never anything the beam could use to run code.
    case saved(SongTapCard)
    /// It was in the library already: nothing added, nothing to undo.
    case alreadyHad(SongTapCard)
    /// No video could be found for it here: nothing saved.
    case notFound
    case failed
}

/// What a beamed song needs from the library, as small calls the receiver's rules can be tested against.
public protocol SongTapLibrary: Sendable {
    /// A song with this video is already in the library, under whatever row or id it came in.
    func hasVideo(_ videoId: String) async -> Bool
    /// A library row with this Spotify id exists (synced from the listener's own Spotify, or imported).
    func hasSpotifyId(_ spotifyId: String) async -> Bool
    /// The video for a song that came without one: the app's own title, artist and duration search and scoring. Nil when
    /// nothing matches.
    func findVideo(title: String, artist: String, durationMs: Int64, isrc: String?, spotifyId: String?) async throws -> String?
    /// Puts the song in the library; true when it was not there before.
    func importSong(videoId: String, title: String, artist: String, durationMs: Int64, artUrl: String?) async throws -> Bool
    /// Takes back what `importSong` added; false when it cannot be taken back.
    func remove(videoId: String) async throws -> Bool
    /// The library's id for the song with this video, so the card can play it.
    func songId(videoId: String) async -> String
    /// The library's id for the song with this Spotify id.
    func songId(spotifyId: String) async -> String
}

public struct SongTapReceiver: Sendable {
    private let library: any SongTapLibrary

    public init(library: any SongTapLibrary) {
        self.library = library
    }

    public func save(_ p: SongTapPayload) async -> SongTapSaveResult {
        do {
            return try await resolveAndSave(p)
        } catch {
            return .failed
        }
    }

    private func resolveAndSave(_ p: SongTapPayload) async throws -> SongTapSaveResult {
        let spotifyId = p.spotifyId
        let videoId: String
        if let own = p.ytVideoId {
            videoId = own
        } else {
            // No video came with it: the Spotify row the listener already has is enough.
            if let spotifyId, await library.hasSpotifyId(spotifyId) {
                return .alreadyHad(card(p, videoId: "", songId: await library.songId(spotifyId: spotifyId)))
            }
            guard let found = try await library.findVideo(title: p.title, artist: p.artist, durationMs: Int64(p.durationMs),
                                                           isrc: p.isrc, spotifyId: spotifyId),
                  SongTapPayloads.isVideoId(found) else { return .notFound }
            videoId = found
        }
        let hasSpotify: Bool
        if let spotifyId { hasSpotify = await library.hasSpotifyId(spotifyId) } else { hasSpotify = false }
        if await library.hasVideo(videoId) || hasSpotify {
            return .alreadyHad(card(p, videoId: videoId, songId: await library.songId(videoId: videoId)))
        }
        let added = try await library.importSong(videoId: videoId, title: p.title, artist: p.artist, durationMs: Int64(p.durationMs),
                                                 artUrl: p.artUrl)
        let card = card(p, videoId: videoId, songId: await library.songId(videoId: videoId))
        return added ? .saved(card) : .alreadyHad(card)
    }

    private func card(_ p: SongTapPayload, videoId: String, songId: String) -> SongTapCard {
        SongTapCard(videoId: videoId, songId: songId, title: p.title, artist: p.artist, artUrl: p.artUrl)
    }

    /// Undo within the card's window: removes what `save` added.
    public func undo(videoId: String) async -> Bool {
        do {
            return try await library.remove(videoId: videoId)
        } catch {
            return false
        }
    }
}
