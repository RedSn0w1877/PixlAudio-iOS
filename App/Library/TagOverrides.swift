import Foundation

/// A tag edit kept in the library (`TagOverrideRecord.fieldsJSON`): every non-nil field replaces what the library
/// row says. Nothing is written into a file — the app is Spotify-only, so a song has no tags of its own to rewrite;
/// the override is what the song editor saves and what a backup carries.
nonisolated struct TagOverrideFields: Sendable, Codable, Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int?
    /// A replaced cover (stage 8's song editor): a `file://` URL of the saved image, or "" for "no cover".
    var artworkUri: String?

    init(title: String? = nil, artist: String? = nil, album: String? = nil, albumArtist: String? = nil,
         genre: String? = nil, trackNumber: Int? = nil, discNumber: Int? = nil, year: Int? = nil,
         artworkUri: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.artworkUri = artworkUri
    }

    var isEmpty: Bool { self == TagOverrideFields() }

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    static func decode(_ json: String) -> TagOverrideFields? {
        try? JSONDecoder().decode(TagOverrideFields.self, from: Data(json.utf8))
    }
}
