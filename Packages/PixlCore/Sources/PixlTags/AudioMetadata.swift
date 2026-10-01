// Android's `AudioMetadataReader` field mapping: which property keys become title, artist, album artist, track,
// disc, year, lyrics, ReplayGain and artwork. Audio properties (duration, bitrate, sample rate) come from
// AVFoundation on iOS and are not part of this port.

import Foundation
import PixlFoundation

/// Embedded artwork (Android `AudioMetadataArtwork`).
public struct TagArtwork: Sendable, Hashable {
    public var bytes: Data
    public var mimeType: String?

    public init(bytes: Data, mimeType: String?) {
        self.bytes = bytes
        self.mimeType = mimeType
    }
}

/// The tag half of Android's `AudioMetadata`.
public struct TagMetadata: Sendable, Hashable {
    public var title: String?
    public var artist: String?
    public var albumArtist: String?
    public var album: String?
    public var genre: String?
    public var composer: String?
    public var lyrics: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    public var artwork: TagArtwork?
    public var replayGainTrackGainDb: Float?
    public var replayGainAlbumGainDb: Float?

    public init(title: String? = nil, artist: String? = nil, albumArtist: String? = nil, album: String? = nil,
                genre: String? = nil, composer: String? = nil, lyrics: String? = nil, trackNumber: Int? = nil,
                discNumber: Int? = nil, year: Int? = nil, artwork: TagArtwork? = nil,
                replayGainTrackGainDb: Float? = nil, replayGainAlbumGainDb: Float? = nil) {
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.genre = genre
        self.composer = composer
        self.lyrics = lyrics
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.artwork = artwork
        self.replayGainTrackGainDb = replayGainTrackGainDb
        self.replayGainAlbumGainDb = replayGainAlbumGainDb
    }
}

public enum AudioMetadataMapper {
    /// `AudioMetadataReader.read` over a TagLib property map and picture list (the TagLib half; the JAudioTagger
    /// fallback has no counterpart because these readers already handle the frames TagLib missed on Android).
    public static func metadata(properties map: TagProperties, pictures: [TagPicture], readArtwork: Bool = true) -> TagMetadata {
        func value(_ key: String) -> String? {
            guard let v = map[key]?.first, !v.isKotlinBlank else { return nil }
            return v
        }
        var m = TagMetadata()
        m.title = value("TITLE")
        m.artist = value("ARTIST")
        m.albumArtist = value("ALBUMARTIST") ?? value("ALBUM ARTIST") ?? value("BAND")
        m.album = value("ALBUM")
        m.genre = value("GENRE")
        m.composer = value("COMPOSER") ?? value("TCOM")
        m.lyrics = value("LYRICS") ?? value("UNSYNCEDLYRICS")
        let trackString = value("TRACKNUMBER") ?? value("TRACK")
        m.trackNumber = trackString.flatMap { KotlinText.toIntOrNull(KotlinText.substringBeforeSlash($0)) }
        let discString = value("DISCNUMBER") ?? value("DISC")
        m.discNumber = discString.flatMap { KotlinText.toIntOrNull(KotlinText.substringBeforeSlash($0)) }
        m.year = value("DATE").flatMap { KotlinText.toIntOrNull(KotlinText.take($0, 4)) }
            ?? value("YEAR").flatMap { KotlinText.toIntOrNull($0) }
        m.replayGainTrackGainDb = ReplayGainTags.extractReplayGainDb(map, keys: ReplayGainTags.trackGainKeys)
        m.replayGainAlbumGainDb = ReplayGainTags.extractReplayGainDb(map, keys: ReplayGainTags.albumGainKeys)
        if readArtwork, let picture = pictures.first, !picture.data.isEmpty,
           ImageSniffing.isLikelyDecodableImage(picture.data) {
            let mime = picture.mimeType.isKotlinBlank ? ImageSniffing.guessContentType(picture.data) : picture.mimeType
            m.artwork = TagArtwork(bytes: picture.data, mimeType: mime)
        }
        return m
    }

    /// Reads a complete file and maps its tags.
    public static func read(_ data: Data, readArtwork: Bool = true) throws -> TagMetadata {
        let tags = try AudioTagReader.read(data)
        return metadata(properties: tags.properties, pictures: tags.pictures, readArtwork: readArtwork)
    }
}
