import Foundation

/// A tag edit kept in the library (`TagOverrideRecord.fieldsJSON`): every non-nil field replaces what the file says.
/// Overrides apply on every scan, before artist splitting and album grouping, so an edited artist splits and groups
/// exactly like a tagged one. Media-library songs can only be overridden (their files are not ours to rewrite).
nonisolated struct TagOverrideFields: Sendable, Codable, Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int?

    init(title: String? = nil, artist: String? = nil, album: String? = nil, albumArtist: String? = nil,
         genre: String? = nil, trackNumber: Int? = nil, discNumber: Int? = nil, year: Int? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
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

    /// Applies the override to a track read from a file or the media library (idempotent).
    func apply(to track: inout ScannedTrack) {
        if let title, !title.isEmpty { track.title = title }
        if let artist, !artist.isEmpty { track.artist = artist }
        if let album, !album.isEmpty { track.album = album }
        if let albumArtist { track.albumArtist = albumArtist.isEmpty ? nil : albumArtist }
        if let genre { track.genre = genre.isEmpty ? nil : genre }
        if let trackNumber { track.trackNumber = trackNumber }
        if let discNumber { track.discNumber = discNumber > 0 ? discNumber : nil }
        if let year { track.year = year }
    }
}
