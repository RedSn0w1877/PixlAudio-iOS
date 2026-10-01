// Port of `data/playlist/M3uManager.kt`: importing an M3U/M3U8 playlist by matching its entries against the
// library (exact path, then file name, then the file name of the content URI) and exporting a playlist.

import Foundation
import PixlFoundation
import PixlModel

public enum M3U {
    /// The name used when the file name is unknown.
    public static let defaultPlaylistName = "Imported Playlist"

    /// `parseM3u`: the playlist name (the file name without `.m3u`/`.m3u8`) and the ids of the matched songs, in
    /// file order. Comment and blank lines are skipped; unmatched entries are dropped.
    public static func parse(_ text: String, fileName: String?, library: [Song]) -> (name: String, songIds: [String]) {
        var songsByPath: [KotlinKey: Song] = [:]
        var songsByFileName: [KotlinKey: Song] = [:]
        var songsByContentUriFileName: [KotlinKey: Song] = [:]
        for song in library {
            songsByPath[KotlinKey(song.path)] = song
            let fileKey = KotlinKey(KotlinText.substringAfterLast(song.path, "/"))
            if songsByFileName[fileKey] == nil { songsByFileName[fileKey] = song }
            let uriKey = KotlinKey(KotlinText.substringAfterLast(song.contentUriString, "/"))
            if songsByContentUriFileName[uriKey] == nil { songsByContentUriFileName[uriKey] = song }
        }
        var ids: [String] = []
        for line in readLines(text) {
            let trimmed = line.kotlinTrimmed()
            if trimmed.isEmpty || trimmed.unicodeScalars.first == "#" { continue }
            if let song = songsByPath[KotlinKey(trimmed)] {
                ids.append(song.id)
            } else {
                let name = KotlinKey(KotlinText.substringAfterLast(trimmed, "/"))
                if let song = songsByFileName[name] ?? songsByContentUriFileName[name] { ids.append(song.id) }
            }
        }
        let playlistName = fileName.map { KotlinText.removeSuffix(KotlinText.removeSuffix($0, ".m3u"), ".m3u8") }
            ?? defaultPlaylistName
        return (playlistName, ids)
    }

    /// Parses UTF-8 bytes (Java's `InputStreamReader`: invalid sequences become U+FFFD, a BOM is kept).
    public static func parse(utf8 data: [UInt8], fileName: String?, library: [Song]) -> (name: String, songIds: [String]) {
        parse(String(decoding: data, as: UTF8.self), fileName: fileName, library: library)
    }

    /// `generateM3u`: `#EXTM3U`, then `#EXTINF:<seconds>,<artist> - <title>` and the path for each song.
    public static func generate(songs: [Song]) -> String {
        var out = "#EXTM3U\n"
        for song in songs {
            out += "#EXTINF:\(song.duration / 1000),\(song.artist) - \(song.title)\n"
            out += "\(song.path)\n"
        }
        return out
    }

    /// `BufferedReader.readLine` splitting: `\n`, `\r` or `\r\n` end a line; no empty line after a final break.
    static func readLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var previousWasCR = false
        var pending = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if previousWasCR {
                    previousWasCR = false
                    continue
                }
                lines.append(String(current))
                current = String.UnicodeScalarView()
                pending = false
            } else if scalar == "\r" {
                lines.append(String(current))
                current = String.UnicodeScalarView()
                previousWasCR = true
                pending = false
            } else {
                previousWasCR = false
                current.append(scalar)
                pending = true
            }
        }
        if pending { lines.append(String(current)) }
        return lines
    }
}
