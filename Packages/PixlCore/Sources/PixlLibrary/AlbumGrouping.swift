// Port of `data/worker/AlbumGroupingUtils.kt` and the pure part of `SyncWorker.preProcessAndDeduplicateWithMultiArtist`
// (multi-artist split, artist ids, album grouping keys, album display artist). The scanner feeds `ScannedSong`s
// (the fields of Android's `SongEntity` that grouping reads) and stores the result.

import Foundation
import PixlFoundation
import PixlModel

/// The fields of a scanned track that artist splitting and album grouping read (Android `SongEntity`).
public struct ScannedSong: Sendable, Hashable {
    public var id: String
    public var title: String
    /// The raw artist tag (may name several artists).
    public var artistName: String
    public var artistId: Int64
    public var albumArtist: String?
    public var albumName: String
    public var albumId: Int64
    public var contentUriString: String
    public var albumArtUriString: String?
    /// The folder containing the file (empty for non-file sources).
    public var parentDirectoryPath: String
    public var dateAdded: Int64
    public var year: Int

    public init(id: String, title: String, artistName: String, artistId: Int64, albumArtist: String? = nil,
                albumName: String, albumId: Int64, contentUriString: String, albumArtUriString: String? = nil,
                parentDirectoryPath: String, dateAdded: Int64 = 0, year: Int = 0) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.artistId = artistId
        self.albumArtist = albumArtist
        self.albumName = albumName
        self.albumId = albumId
        self.contentUriString = contentUriString
        self.albumArtUriString = albumArtUriString
        self.parentDirectoryPath = parentDirectoryPath
        self.dateAdded = dateAdded
        self.year = year
    }
}

/// An album row as stored (Android `AlbumEntity`), including the display artist's id.
public struct LibraryAlbum: Sendable, Hashable {
    public var id: Int64
    public var title: String
    public var artistName: String
    public var artistId: Int64
    public var albumArtUriString: String?
    public var songCount: Int
    public var dateAdded: Int64
    public var year: Int
    public var albumArtist: String?

    public init(id: Int64, title: String, artistName: String, artistId: Int64, albumArtUriString: String?,
                songCount: Int, dateAdded: Int64, year: Int, albumArtist: String? = nil) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.artistId = artistId
        self.albumArtUriString = albumArtUriString
        self.songCount = songCount
        self.dateAdded = dateAdded
        self.year = year
        self.albumArtist = albumArtist
    }

    /// The PixlModel value for lists.
    public var album: Album {
        Album(id: id, title: title, artist: artistName, year: year, dateAdded: dateAdded,
              albumArtUriString: albumArtUriString, songCount: songCount, albumArtist: albumArtist)
    }
}

/// Which album a track belongs to: a normalised title plus an identity (album artist, folder, artwork or id).
public struct AlbumGroupingKey: Hashable, Sendable {
    public var normalizedTitle: String
    public var identity: String

    public init(normalizedTitle: String, identity: String) {
        self.normalizedTitle = normalizedTitle
        self.identity = identity
    }

    public static func == (lhs: AlbumGroupingKey, rhs: AlbumGroupingKey) -> Bool {
        KotlinText.equals(lhs.normalizedTitle, rhs.normalizedTitle) && KotlinText.equals(lhs.identity, rhs.identity)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(KotlinKey(normalizedTitle))
        hasher.combine(KotlinKey(identity))
    }
}

public enum AlbumGrouping {
    static let unknownAlbum = "Unknown Album"
    static let unknownArtist = "Unknown Artist"

    /// `resolveAlbumArtist`: the embedded album artist, else the index's, ignoring blank and `<unknown>`.
    public static func resolveAlbumArtist(rawAlbumArtist: String?, metadataAlbumArtist: String?) -> String? {
        for candidate in [metadataAlbumArtist, rawAlbumArtist] {
            if let normalized = MetadataText.normalize(candidate), !normalized.isKotlinBlank,
               !KotlinText.equalsIgnoreCase(normalized, "<unknown>") {
                return normalized
            }
        }
        return nil
    }

    /// `LocalArtworkUri.isLikelyLocalMedia`: everything except the removed remote sources' URI schemes.
    public static func isLikelyLocalMedia(_ contentUriString: String) -> Bool {
        let normalized = KotlinText.lowercase(contentUriString)
        return !["telegram://", "netease://", "qqmusic://", "navidrome://", "jellyfin://", "gdrive://"]
            .contains { normalized.utf8.starts(with: $0.utf8) }
    }

    /// `buildAlbumGroupingKey(song)`.
    public static func groupingKey(for song: ScannedSong) -> AlbumGroupingKey {
        groupingKey(albumName: song.albumName, albumArtist: song.albumArtist, albumArtUriString: song.albumArtUriString,
                    parentDirectoryPath: song.parentDirectoryPath, fallbackAlbumId: song.albumId,
                    preferStableLocalIdentity: isLikelyLocalMedia(song.contentUriString))
    }

    /// `buildAlbumGroupingKeys(album)`: every key an existing album row answers to.
    public static func groupingKeys(for album: LibraryAlbum) -> [AlbumGroupingKey] {
        var keys: [AlbumGroupingKey] = []
        keys.append(groupingKey(albumName: album.title, albumArtist: album.artistName,
                                albumArtUriString: album.albumArtUriString, parentDirectoryPath: nil,
                                fallbackAlbumId: album.id))
        let title = normalizedTitle(album.title)
        keys.append(AlbumGroupingKey(normalizedTitle: title, identity: "media:\(album.id)"))
        if let art = album.albumArtUriString, !art.isKotlinBlank {
            keys.append(AlbumGroupingKey(normalizedTitle: title, identity: "art:\(art.kotlinTrimmed())"))
        }
        var seen = Set<AlbumGroupingKey>()
        return keys.filter { seen.insert($0).inserted }
    }

    static func normalizedTitle(_ title: String) -> String {
        let normalized = MetadataText.normalizeOrEmpty(title)
        return KotlinText.lowercase(normalized.isKotlinBlank ? unknownAlbum : normalized)
    }

    static func groupingKey(albumName: String, albumArtist: String?, albumArtUriString: String?,
                            parentDirectoryPath: String?, fallbackAlbumId: Int64,
                            preferStableLocalIdentity: Bool = false) -> AlbumGroupingKey {
        let title = normalizedTitle(albumName)
        let directory = parentDirectoryPath.flatMap { $0.isKotlinBlank ? nil : $0 }
        let stableLocalIdentity = directory.map { "dir:\(KotlinText.lowercase($0.kotlinTrimmed()))" }
            ?? "media:\(fallbackAlbumId)"
        let identity: String
        if let albumArtist, !albumArtist.isKotlinBlank {
            identity = "artist:\(KotlinText.lowercase(MetadataText.normalizeOrEmpty(albumArtist)))"
        } else if preferStableLocalIdentity {
            identity = stableLocalIdentity
        } else if let art = albumArtUriString, !art.isKotlinBlank {
            identity = "art:\(art.kotlinTrimmed())"
        } else if let directory {
            identity = "dir:\(KotlinText.lowercase(directory.kotlinTrimmed()))"
        } else {
            identity = "media:\(fallbackAlbumId)"
        }
        return AlbumGroupingKey(normalizedTitle: title, identity: identity)
    }

    /// `chooseAlbumDisplayArtist`: the album artist when grouping by album artist (and one is tagged), else the
    /// most common primary track artist, else the album artist, else "Unknown Artist".
    public static func chooseAlbumDisplayArtist(songs: [ScannedSong], preferAlbumArtist: Bool,
                                                artistDelimiters: [String] = [], wordDelimiters: [String] = []) -> String {
        if songs.isEmpty { return unknownArtist }
        let albumArtist = mostCommonValue(songs.compactMap { song in
            MetadataText.normalize(song.albumArtist).flatMap { $0.isKotlinBlank ? nil : $0 }
        })
        let splitter = ArtistSplitter(delimiters: artistDelimiters, wordDelimiters: wordDelimiters)
        let trackArtist = mostCommonValue(songs.map { song in
            MetadataText.normalizeOrEmpty(splitter.collectArtistNames(rawArtistName: song.artistName, title: song.title,
                                                                      extractFromTitle: true).first)
        })
        if preferAlbumArtist, let albumArtist { return albumArtist }
        if let trackArtist { return trackArtist }
        if let albumArtist { return albumArtist }
        return unknownArtist
    }

    /// `resolveAlbumDisplayArtistId`.
    public static func resolveAlbumDisplayArtistId(displayArtist: String, songs: [ScannedSong],
                                                   artistNameToId: OrderedStringMap<Int64>,
                                                   artistDelimiters: [String], wordDelimiters: [String] = []) -> Int64 {
        if let id = artistNameToId[displayArtist.kotlinTrimmed()] { return id }
        if let primary = ArtistParsing.split(displayArtist, delimiters: artistDelimiters,
                                             wordDelimiters: wordDelimiters).first?.kotlinTrimmed(),
           !primary.isEmpty, let id = artistNameToId[primary] {
            return id
        }
        return songs.first?.artistId ?? 0
    }

    /// The most frequent trimmed non-empty value; ties go to the shorter value, then the first seen.
    static func mostCommonValue(_ values: [String]) -> String? {
        var counts = OrderedStringMap<Int>()
        for value in values.map({ $0.kotlinTrimmed() }) where !value.isEmpty { counts[value] = (counts[value] ?? 0) + 1 }
        var best: (key: String, value: Int)?
        for entry in counts.entries {
            guard let current = best else { best = entry; continue }
            let c = chain(cmp(current.value, entry.value), cmp(entry.key.utf16.count, current.key.utf16.count))
            if c < 0 { best = entry }
        }
        return best?.key
    }
}

// MARK: - Library assembly (SyncWorker.preProcessAndDeduplicateWithMultiArtist)

/// One song → artist link.
public struct SongArtistLink: Sendable, Hashable {
    public var songId: String
    public var artistId: Int64
    public var isPrimary: Bool

    public init(songId: String, artistId: Int64, isPrimary: Bool) {
        self.songId = songId
        self.artistId = artistId
        self.isPrimary = isPrimary
    }
}

/// A scanned song after artist splitting and album grouping.
public struct AssembledSong: Sendable, Hashable {
    /// The input with `artistId` set to the primary artist's id and `albumId` to the grouped album's id.
    public var song: ScannedSong
    /// The split artists, primary first (Android `artistsJson`).
    public var artists: [ArtistRef]
}

public struct LibraryAssembly: Sendable {
    public var songs: [AssembledSong]
    public var albums: [LibraryAlbum]
    public var artists: [Artist]
    public var links: [SongArtistLink]
    /// The artist name → id map after assembly (existing entries plus new ones, in insertion order).
    public var artistIds: OrderedStringMap<Int64>
}

public enum LibraryAssembler {
    /// Splits every song's artists, assigns artist ids (new names get `initialMaxArtistId + 1, +2, …`), groups
    /// songs into albums (reusing existing album ids whose keys match) and builds the album and artist rows.
    public static func assemble(songs: [ScannedSong], artistDelimiters: [String], wordDelimiters: [String] = [],
                                extractFromTitle: Bool = true, groupByAlbumArtist: Bool,
                                existingArtistMetadata: [Int64: (imageUrl: String?, customImageUri: String?)] = [:],
                                existingAlbums: [LibraryAlbum] = [], existingArtistIds: OrderedStringMap<Int64> = .init(),
                                initialMaxArtistId: Int64) -> LibraryAssembly {
        var nextArtistId = initialMaxArtistId + 1
        var artistNameToId = existingArtistIds
        var links: [SongArtistLink] = []
        var trackCounts: [Int64: Int] = [:]
        var albumMap: [AlbumGroupingKey: Int64] = [:]
        var splitCache: [KotlinKey: [String]] = [:]
        let splitter = ArtistSplitter(delimiters: artistDelimiters, wordDelimiters: wordDelimiters)
        var corrected: [AssembledSong] = []
        corrected.reserveCapacity(songs.count)

        for album in existingAlbums.kotlinSorted(by: { cmp($0.id, $1.id) }) {
            for key in AlbumGrouping.groupingKeys(for: album) where albumMap[key] == nil { albumMap[key] = album.id }
        }

        for song in songs {
            let raw = song.artistName
            let cacheKey = KotlinKey("\(raw)\u{0}\(song.title)\u{0}\(extractFromTitle)")
            let allArtists: [String]
            if let cached = splitCache[cacheKey] { allArtists = cached } else {
                allArtists = splitter.collectArtistNames(rawArtistName: raw, title: song.title,
                                                         extractFromTitle: extractFromTitle)
                splitCache[cacheKey] = allArtists
            }
            for name in allArtists {
                let normalized = name.kotlinTrimmed()
                if !normalized.isEmpty, artistNameToId[normalized] == nil {
                    artistNameToId[normalized] = nextArtistId
                    nextArtistId += 1
                }
            }
            let primaryName = allArtists.first.map { $0.kotlinTrimmed() }.flatMap { $0.isEmpty ? nil : $0 }
                ?? raw.kotlinTrimmed()
            let primaryId = artistNameToId[primaryName] ?? song.artistId
            for (index, name) in allArtists.enumerated() {
                if let artistId = artistNameToId[name.kotlinTrimmed()] {
                    links.append(SongArtistLink(songId: song.id, artistId: artistId, isPrimary: index == 0))
                    trackCounts[artistId, default: 0] += 1
                }
            }
            let key = AlbumGrouping.groupingKey(for: song)
            let finalAlbumId: Int64
            if let existing = albumMap[key] { finalAlbumId = existing } else {
                albumMap[key] = song.albumId
                finalAlbumId = song.albumId
            }
            let refs = allArtists.enumerated().map { index, name -> ArtistRef in
                let normalized = name.kotlinTrimmed()
                return ArtistRef(id: artistNameToId[normalized] ?? 0, name: normalized, isPrimary: index == 0)
            }.filter { !$0.name.isEmpty }
            var updated = song
            updated.artistId = primaryId
            updated.albumId = finalAlbumId
            corrected.append(AssembledSong(song: updated, artists: refs))
        }

        let artists = artistNameToId.entries.map { name, id -> Artist in
            let metadata = existingArtistMetadata[id]
            return Artist(id: id, name: name, songCount: trackCounts[id] ?? 0, imageUrl: metadata?.imageUrl,
                          customImageUri: metadata?.customImageUri)
        }

        var albumOrder: [Int64] = []
        var songsByAlbum: [Int64: [ScannedSong]] = [:]
        for item in corrected {
            if songsByAlbum[item.song.albumId] == nil { albumOrder.append(item.song.albumId) }
            songsByAlbum[item.song.albumId, default: []].append(item.song)
        }
        let albums = albumOrder.map { albumId -> LibraryAlbum in
            let inAlbum = songsByAlbum[albumId]!
            let first = inAlbum[0]
            let displayArtist = AlbumGrouping.chooseAlbumDisplayArtist(
                songs: inAlbum, preferAlbumArtist: groupByAlbumArtist, artistDelimiters: artistDelimiters,
                wordDelimiters: wordDelimiters)
            let displayArtistId = AlbumGrouping.resolveAlbumDisplayArtistId(
                displayArtist: displayArtist, songs: inAlbum, artistNameToId: artistNameToId,
                artistDelimiters: artistDelimiters, wordDelimiters: wordDelimiters)
            var tagCounts = OrderedStringMap<Int>()
            for song in inAlbum {
                if let tag = song.albumArtist, !tag.isKotlinBlank { tagCounts[tag] = (tagCounts[tag] ?? 0) + 1 }
            }
            var metadataAlbumArtist: (key: String, value: Int)?
            for entry in tagCounts.entries where metadataAlbumArtist == nil || entry.value > metadataAlbumArtist!.value {
                metadataAlbumArtist = entry
            }
            return LibraryAlbum(id: albumId, title: first.albumName, artistName: displayArtist, artistId: displayArtistId,
                                albumArtUriString: inAlbum.lazy.compactMap(\.albumArtUriString).first,
                                songCount: inAlbum.count, dateAdded: first.dateAdded, year: first.year,
                                albumArtist: metadataAlbumArtist?.key)
        }
        return LibraryAssembly(songs: corrected, albums: albums, artists: artists, links: links,
                               artistIds: artistNameToId)
    }
}
