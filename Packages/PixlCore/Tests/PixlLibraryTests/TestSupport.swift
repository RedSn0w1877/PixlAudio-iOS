import Foundation
import PixlFoundation
import PixlModel
import Testing
@testable import PixlLibrary

/// Loads a JSON-lines golden fixture written by `tools/android-reference/LibGen.java`.
func goldenLines(_ name: String) throws -> [JSONValue] {
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    let url = try #require(Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Fixtures"))
    let text = try String(contentsOf: url, encoding: .utf8)
    let parser = JSONParser(mode: .strict, maxDepth: 64)
    return try text.split(separator: "\n", omittingEmptySubsequences: true).map { try parser.parse(String($0)) }
}

extension JSONValue {
    var str: String { stringValue ?? "" }
    var optStr: String? { isNull ? nil : stringValue }
    var int: Int { Int(int64Value ?? 0) }
    var i64: Int64 { int64Value ?? 0 }
    var bool: Bool { boolValue ?? false }
    var arr: [JSONValue] { arrayValue ?? [] }
    var strings: [String] { arr.map(\.str) }
    /// A double written as its IEEE-754 bit pattern ("0x…").
    var bitsDouble: Double {
        let s = str.hasPrefix("0x") ? String(str.dropFirst(2)) : str
        return Double(bitPattern: UInt64(s, radix: 16) ?? 0)
    }
}

/// Builds a Song from a fixture object.
func fixtureSong(_ v: JSONValue) -> Song {
    let artists = v["artists"]!.arr.map { ArtistRef(id: $0.arr[0].i64, name: $0.arr[1].str, isPrimary: $0.arr[2].bool) }
    return Song(id: v["id"]!.str, title: v["title"]!.str, artist: v["artist"]!.str, artistId: v["artistId"]!.i64,
                artists: artists, album: v["album"]!.str, albumId: v["albumId"]!.i64, path: v["path"]!.str,
                contentUriString: v["contentUri"]!.str, albumArtUriString: v["albumArt"]!.optStr,
                duration: v["duration"]!.i64, genre: v["genre"]!.optStr, isFavorite: v["isFavorite"]!.bool,
                trackNumber: v["track"]!.int, discNumber: v["disc"]!.isNull ? nil : v["disc"]!.int,
                year: v["year"]!.int, dateAdded: v["dateAdded"]!.i64, dateModified: v["dateModified"]!.i64,
                mimeType: "audio/mpeg", bitrate: 0, sampleRate: 0, spotifyId: v["spotifyId"]!.optStr)
}

/// A minimal song for hand-written tests (Android `Song.emptySong().copy(...)`).
func testSong(_ id: String, title: String? = nil, artist: String? = nil, duration: Int64 = 180_000,
              genre: String? = nil, isFavorite: Bool = false, dateAdded: Int64 = 0, dateModified: Int64 = 0,
              album: String = "", spotifyId: String? = nil, artists: [ArtistRef] = [], trackNumber: Int = 0,
              discNumber: Int? = nil, year: Int = 0) -> Song {
    var s = Song.emptySong()
    s.id = id
    s.title = title ?? "Song \(id)"
    s.artist = artist ?? "Artist \(id)"
    s.duration = duration
    s.genre = genre
    s.isFavorite = isFavorite
    s.dateAdded = dateAdded
    s.dateModified = dateModified
    s.album = album
    s.spotifyId = spotifyId
    s.artists = artists
    s.trackNumber = trackNumber
    s.discNumber = discNumber
    s.year = year
    return s
}
