// The listening-history files people download (spec B2): Spotify's extended streaming history
// (`Streaming_History_Audio_*.json`, older `endsong_*.json`), Spotify's basic "Account data" history
// (`StreamingHistory_music_*.json`, older `StreamingHistory0.json`) and Google Takeout's YouTube `watch-history.json`.
// Each is a JSON array; the files run to tens of MB, so the array is walked element by element and each element is
// parsed on its own (memory stays at one element, not the whole tree).

import Foundation
import PixlFoundation
import PixlModel

/// Which history file a name or its content is.
public enum ListeningHistoryFileKind: String, Sendable, Hashable {
    case spotifyExtended
    case spotifyBasic
    case takeoutWatchHistory
    /// A history file we know but don't read (podcasts, videos, searches).
    case ignored
    case unknown

    /// From the file name alone (`unknown` when the name says nothing).
    public static func fromName(_ name: String) -> ListeningHistoryFileKind {
        let base = (name.split(separator: "/").last.map(String.init) ?? name).lowercased()
        guard base.hasSuffix(".json") else {
            return base.hasSuffix(".html") && base.contains("watch-history") ? .ignored : .unknown
        }
        if base.contains("streaming_history_video") || base.contains("podcast") { return .ignored }
        if base.contains("streaming_history_audio") || base.hasPrefix("endsong") { return .spotifyExtended }
        if base.hasPrefix("streaminghistory") { return .spotifyBasic }
        if base == "watch-history.json" { return .takeoutWatchHistory }
        if base.contains("search-history") || base.contains("search_history") { return .ignored }
        return .unknown
    }

    /// From the first element's keys.
    public static func sniff(_ bytes: [UInt8]) -> ListeningHistoryFileKind {
        var kind = ListeningHistoryFileKind.unknown
        JSONArrayScanner.forEachElement(bytes) { element, _ in
            guard case .object(let object)? = try? JSONParser(mode: .strict, maxDepth: 32).parse(utf8: Array(element)) else {
                return false
            }
            if object["ms_played"] != nil { kind = .spotifyExtended }
            else if object["msPlayed"] != nil { kind = .spotifyBasic }
            else if object["titleUrl"] != nil || object["header"] != nil { kind = .takeoutWatchHistory }
            return false
        }
        return kind
    }
}

/// Walks a top-level JSON array, handing each element's bytes to `body` (return false to stop).
public enum JSONArrayScanner {
    /// - Parameter body: the element's bytes and the fraction of the input read so far.
    public static func forEachElement(_ bytes: [UInt8], _ body: (ArraySlice<UInt8>, Double) -> Bool) {
        var i = 0
        let n = bytes.count
        // Skip a UTF-8 BOM and whitespace up to the opening bracket.
        if n >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }
        while i < n, bytes[i] != UInt8(ascii: "[") {
            guard isSpace(bytes[i]) else { return }
            i += 1
        }
        guard i < n else { return }
        i += 1
        var start = -1
        var depth = 0
        var inString = false
        var escaped = false
        while i < n {
            let b = bytes[i]
            if inString {
                if escaped { escaped = false }
                else if b == UInt8(ascii: "\\") { escaped = true }
                else if b == UInt8(ascii: "\"") { inString = false }
            } else {
                switch b {
                case UInt8(ascii: "\""):
                    inString = true
                    if start < 0 { start = i }
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    if start < 0 { start = i }
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    if depth == 0 {
                        // The array's own closing bracket.
                        if start >= 0, !body(bytes[start..<i], 1.0) { return }
                        return
                    }
                    depth -= 1
                case UInt8(ascii: ","):
                    if depth == 0 {
                        if start >= 0, !body(bytes[start..<i], Double(i) / Double(n)) { return }
                        start = -1
                    }
                default:
                    if start < 0, !isSpace(b) { start = i }
                }
            }
            i += 1
        }
    }

    private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 }
}

/// The plays read from one file.
public struct ListeningHistoryFileParse: Sendable {
    public var kind: ListeningHistoryFileKind
    public var plays: [ImportedPlay]
    /// Entries that were not songs (podcasts, removed videos, plain YouTube) or could not be read.
    public var skipped: Int

    public init(kind: ListeningHistoryFileKind, plays: [ImportedPlay] = [], skipped: Int = 0) {
        self.kind = kind
        self.plays = plays
        self.skipped = skipped
    }
}

public enum ListeningHistoryParsers {
    /// Parses one file: the name decides the kind, else its first element does.
    public static func parse(fileName: String, bytes: [UInt8], progress: ((Double) -> Void)? = nil) -> ListeningHistoryFileParse {
        var kind = ListeningHistoryFileKind.fromName(fileName)
        if kind == .unknown { kind = ListeningHistoryFileKind.sniff(bytes) }
        switch kind {
        case .spotifyExtended: return parseSpotifyExtended(bytes, progress: progress)
        case .spotifyBasic: return parseSpotifyBasic(bytes, progress: progress)
        case .takeoutWatchHistory: return parseTakeout(bytes, progress: progress)
        case .ignored, .unknown: return ListeningHistoryFileParse(kind: kind)
        }
    }

    private static func eachObject(_ bytes: [UInt8], progress: ((Double) -> Void)?,
                                   _ body: (JSONObject) -> Bool) -> Int {
        var unreadable = 0
        var count = 0
        let parser = JSONParser(mode: .strict, maxDepth: 32)
        JSONArrayScanner.forEachElement(bytes) { element, fraction in
            count += 1
            if count % 2_000 == 0 { progress?(fraction) }
            guard case .object(let object)? = try? parser.parse(utf8: Array(element)) else {
                unreadable += 1
                return true
            }
            if !body(object) { unreadable += 1 }
            return true
        }
        progress?(1)
        return unreadable
    }

    private static func string(_ object: JSONObject, _ key: String) -> String? {
        guard let value = object[key]?.stringValue else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func long(_ object: JSONObject, _ key: String) -> Int64? {
        guard let value = object[key] else { return nil }
        if let n = value.int64Value { return n }
        if let d = value.doubleValue { return Int64(d) }
        return value.stringValue.flatMap { Int64($0) }
    }

    // MARK: Spotify extended

    /// `Streaming_History_Audio_*.json`: one object per stream; podcast episodes (no track name) are skipped.
    public static func parseSpotifyExtended(_ bytes: [UInt8], progress: ((Double) -> Void)? = nil) -> ListeningHistoryFileParse {
        var plays: [ImportedPlay] = []
        let skipped = eachObject(bytes, progress: progress) { o in
            guard let title = string(o, "master_metadata_track_name"),
                  let ts = string(o, "ts").flatMap(ListeningHistoryTime.parse) else { return false }
            let artist = string(o, "master_metadata_album_artist_name") ?? ""
            let uri = string(o, "spotify_track_uri")
            let trackId = uri.flatMap(spotifyTrackId(fromURI:))
            plays.append(ImportedPlay(source: .spotifyExport, timestampMs: ts, title: title, artist: artist,
                                      album: string(o, "master_metadata_album_album_name"), spotifyTrackId: trackId,
                                      msPlayed: max(long(o, "ms_played") ?? 0, 0), skipped: o["skipped"]?.boolValue,
                                      reasonStart: string(o, "reason_start"), reasonEnd: string(o, "reason_end"),
                                      shuffle: o["shuffle"]?.boolValue))
            return true
        }
        return ListeningHistoryFileParse(kind: .spotifyExtended, plays: plays, skipped: skipped)
    }

    /// `spotify:track:<22 base62>` → the id.
    public static func spotifyTrackId(fromURI uri: String) -> String? {
        let prefix = "spotify:track:"
        guard uri.hasPrefix(prefix) else { return nil }
        let id = String(uri.dropFirst(prefix.count))
        guard id.utf8.count == 22, id.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) })
        else { return nil }
        return id
    }

    // MARK: Spotify basic

    /// `StreamingHistory_music_*.json`: `endTime` ("2024-03-01 12:34", UTC), `artistName`, `trackName`, `msPlayed`.
    public static func parseSpotifyBasic(_ bytes: [UInt8], progress: ((Double) -> Void)? = nil) -> ListeningHistoryFileParse {
        var plays: [ImportedPlay] = []
        let skipped = eachObject(bytes, progress: progress) { o in
            guard let title = string(o, "trackName"), title != "Unknown Track",
                  let ts = string(o, "endTime").flatMap(ListeningHistoryTime.parse) else { return false }
            plays.append(ImportedPlay(source: .spotifyExport, timestampMs: ts, title: title,
                                      artist: string(o, "artistName") ?? "", msPlayed: max(long(o, "msPlayed") ?? 0, 0)))
            return true
        }
        return ListeningHistoryFileParse(kind: .spotifyBasic, plays: plays, skipped: skipped)
    }

    // MARK: Google Takeout

    /// `watch-history.json`. YouTube Music entries (`header` "YouTube Music") are kept; plain YouTube entries only when
    /// the channel is plainly a music one (an auto-generated "Artist - Topic" channel or a VEVO channel). Removed videos
    /// and ads (no `titleUrl` / no channel) are skipped.
    public static func parseTakeout(_ bytes: [UInt8], progress: ((Double) -> Void)? = nil) -> ListeningHistoryFileParse {
        var plays: [ImportedPlay] = []
        let skipped = eachObject(bytes, progress: progress) { o in
            guard let rawTitle = string(o, "title"), let url = string(o, "titleUrl"),
                  let ts = string(o, "time").flatMap(ListeningHistoryTime.parse) else { return false }
            if o["details"] != nil { return false } // "From Google Ads"
            let header = string(o, "header") ?? ""
            let channel = o["subtitles"]?.arrayValue?.first?.objectValue.flatMap { string($0, "name") }
            guard let channel else { return false }
            let isMusic = header == "YouTube Music"
            let topic = channel.hasSuffix(" - Topic")
            let vevo = channel.uppercased().hasSuffix("VEVO")
            guard isMusic || topic || vevo else { return false }
            var title = takeoutTitle(rawTitle)
            var artist = topic ? String(channel.dropLast(" - Topic".count)) : channel
            if vevo || (!topic && !isMusic) {
                // "Artist - Song (Official Video)" on a VEVO channel.
                if let dash = title.range(of: " - ") {
                    artist = String(title[..<dash.lowerBound])
                    title = String(title[dash.upperBound...])
                } else if vevo {
                    artist = String(channel.dropLast(4)).trimmingCharacters(in: .whitespaces)
                }
            }
            guard !title.isEmpty else { return false }
            plays.append(ImportedPlay(source: .takeout, timestampMs: ts, title: title, artist: artist,
                                      videoId: videoId(fromURL: url)))
            return true
        }
        return ListeningHistoryFileParse(kind: .takeoutWatchHistory, plays: plays, skipped: skipped)
    }

    /// "Watched Song" → "Song" (English exports; other languages keep their prefix).
    static func takeoutTitle(_ raw: String) -> String {
        let prefix = "Watched "
        let title = raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
        return title.trimmingCharacters(in: .whitespaces)
    }

    /// The `v=` parameter of a watch URL.
    public static func videoId(fromURL url: String) -> String? {
        guard let q = url.range(of: "v=") else { return nil }
        let before = url[..<q.lowerBound].last
        guard before == "?" || before == "&" else { return nil }
        let id = url[q.upperBound...].prefix { $0 != "&" && $0 != "#" }
        return id.count == 11 ? String(id) : nil
    }
}
