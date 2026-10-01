// The pure halves of the Android AMLL (`AmllLyricsSource.kt`), NetEase (`NeteaseLyricsSource.kt`) and shared HTTP
// (`LyricsHttp.kt`) lyric sources: request parameters, response validation, recording matching and conversion.
// PixlNet performs the requests and feeds the decoded JSON objects in. A thrown `LyricsCatalogError` is where the
// Android source's catch-all would end the whole lookup with no result; a nil return is a clean miss/skip.

import Foundation
import PixlFoundation
import PixlModel

/// A response shape the Android source would have thrown on (the lookup ends with no lyrics).
public struct LyricsCatalogError: Error, Sendable, Equatable {
    public let message: String
}

/// `LyricsHttp.kt`: bounded JSON bodies for lyric catalogs.
public enum LyricsHTTP {
    /// Largest accepted body.
    public static let maxResponseBytes = 1_048_576
    /// The Android client's User-Agent for catalog requests.
    public static let userAgent = "PixelPlay/0.7.6 (lyrics lookup)"

    /// The JSON object in a successful response body. nil when the body is (declared) too large or not bounded
    /// JSON — clean misses; throws when the body is not a JSON object.
    public static func decodeBody(_ body: [UInt8], declaredContentLength: Int64? = nil) throws(LyricsCatalogError) -> JSONObject? {
        if let declaredContentLength, declaredContentLength > Int64(maxResponseBytes) { return nil }
        if body.count > maxResponseBytes { throw LyricsCatalogError(message: "Lyrics response too large") }
        let raw = String(decoding: body, as: UTF8.self)
        if !LyricsDocCodec.isBoundedJson(raw) { return nil }
        do {
            return try GsonJSON.object(try GsonJSON.parse(raw))
        } catch {
            throw LyricsCatalogError(message: error.message)
        }
    }
}

/// `AmllLyricsSource` (official keyless AMLL API, `https://api.amll.dev/v1/`).
public enum AmllLyricsMatching {
    public static let baseURL = "https://api.amll.dev/v1/"

    /// The Spotify id to look up directly (`lyrics/get?spotifyId=`), when it is a 22-character base62 id.
    public static func spotifyLookupId(_ song: Song) -> String? {
        guard let id = song.spotifyId, id.unicodeScalars.count == 22,
              id.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || ParseKit.isAsciiDigit($0)) })
        else { return nil }
        return id
    }

    /// The response's `data` object.
    public static func data(from response: JSONObject) throws(LyricsCatalogError) -> JSONObject? {
        do { return try GsonJSON.optionalObject(response, "data") } catch { throw LyricsCatalogError(message: error.message) }
    }

    /// Lyrics from a `lyrics/get?spotifyId=` data object — only when it lists that Spotify id.
    public static func lyrics(fromSpotifyLookup data: JSONObject, song: Song, spotifyId: String) throws(LyricsCatalogError) -> Lyrics? {
        guard try strings(data, "spotifyIds").contains(where: { $0.isIdentical(to: spotifyId) }) else { return nil }
        return try lyrics(from: data, song: song)
    }

    /// Search parameters (`lyrics/search`); nil without an album (the endpoint has no duration to check).
    public static func searchParameters(song: Song) -> [(name: String, value: String)]? {
        if ParseKit.isBlank(song.album) { return nil }
        return [("musicName", song.title), ("artistName", song.artist), ("pageSize", "10")]
    }

    /// The id to fetch (`lyrics/get?id=`): exactly one search item must match title, artist and album.
    public static func matchingId(searchData: JSONObject, song: Song) throws(LyricsCatalogError) -> String? {
        let items: [JSONValue]
        do { items = try GsonJSON.optionalArray(searchData, "items") ?? [] } catch { throw LyricsCatalogError(message: error.message) }
        var matches: [JSONObject] = []
        for item in items {
            guard case .object(let o) = item else { continue }
            let titles = try strings(o, "musicNames")
            let artists = try strings(o, "artistNames")
            let albums = try strings(o, "albumNames")
            if matchesMetadata(song: song, titles: titles, artists: artists, albums: albums) { matches.append(o) }
        }
        guard matches.count == 1, let id = matches[0]["id"] else { return nil }
        do { return try GsonJSON.string(id) } catch { throw LyricsCatalogError(message: error.message) }
    }

    /// `parse`: TTML lyrics with real word timing, none beyond the song's end (+1.5 s).
    public static func lyrics(from data: JSONObject, song: Song,
                              romanization: any CJKRomanizationProvider = NoCJKRomanization()) throws(LyricsCatalogError) -> Lyrics? {
        do {
            if let format = data["format"] {
                guard try GsonJSON.string(format) == "ttml" else { return nil }
            } else {
                return nil
            }
            guard let textValue = data["lyrics"] else { return nil }
            let text = try GsonJSON.string(textValue)
            var parsed = LyricsUtils.parseLyrics(text, romanization: romanization)
            let words = (parsed.synced ?? []).flatMap { $0.words ?? [] }
            if words.isEmpty || !words.contains(where: { $0.time > 0 }) { return nil }
            if song.duration > 0 && words.contains(where: { Int64($0.time) > song.duration + 1500 }) { return nil }
            parsed.areFromRemote = true
            return parsed
        } catch {
            throw LyricsCatalogError(message: error.message)
        }
    }

    /// Exact title, artist and (non-blank) album after NFKD folding.
    public static func matchesMetadata(song: Song, titles: [String], artists: [String], albums: [String]) -> Bool {
        let title = CatalogText.normalized(song.title), artist = CatalogText.normalized(song.artist)
        let album = CatalogText.normalized(song.album)
        return titles.contains { CatalogText.normalized($0).isIdentical(to: title) }
            && artists.contains { CatalogText.normalized($0).isIdentical(to: artist) }
            && !ParseKit.isBlank(song.album) && albums.contains { CatalogText.normalized($0).isIdentical(to: album) }
    }

    /// `data.getAsJsonArray(key)?.map { it.asString }.orEmpty()`.
    static func strings(_ data: JSONObject, _ key: String) throws(LyricsCatalogError) -> [String] {
        do {
            return try (GsonJSON.optionalArray(data, key) ?? []).map { item throws(GsonError) in try GsonJSON.string(item) }
        } catch {
            throw LyricsCatalogError(message: error.message)
        }
    }
}

/// `NeteaseLyricsSource` (public read-only endpoints, `https://music.163.com/api/`).
public enum NeteaseLyricsMatching {
    public static let baseURL = "https://music.163.com/api/"

    /// `search/get` parameters; nil without a duration, title or artist.
    public static func searchParameters(song: Song) -> [(name: String, value: String)]? {
        if song.duration <= 0 || ParseKit.isBlank(song.title) || ParseKit.isBlank(song.artist) { return nil }
        return [("type", "1"), ("offset", "0"), ("limit", "10"), ("s", recordingTitle(song.title) + " " + song.artist)]
    }

    /// `song/lyric/v1` parameters for a track id.
    public static func lyricParameters(trackId: String) -> [(name: String, value: String)] {
        [("id", trackId), ("kv", "0"), ("yv", "0"), ("rv", "0"), ("tv", "0")]
    }

    /// Responses count only with `"code": 200`.
    public static func isSuccess(_ response: JSONObject) throws(LyricsCatalogError) -> Bool {
        guard let code = response["code"] else { return false }
        do { return try GsonJSON.int(code) == 200 } catch { throw LyricsCatalogError(message: error.message) }
    }

    /// The tracks to try (at most two, read their ids with `trackId` one at a time): matching recordings, closest
    /// duration first. nil for an opaque `result`.
    public static func candidateTracks(searchResponse: JSONObject, song: Song) throws(LyricsCatalogError) -> [JSONObject]? {
        guard let resultValue = searchResponse["result"], case .object(let result) = resultValue else { return nil }
        do {
            let songs = try (GsonJSON.optionalArray(result, "songs") ?? []).map { item throws(GsonError) in try GsonJSON.object(item) }
            let matches = songs.filter { matchesRecording(song: song, track: $0) }
            var keyed: [(Int, Int64, JSONObject)] = []
            for (index, track) in matches.enumerated() {
                keyed.append((index, abs(try GsonJSON.long(track["duration"]) &- song.duration), track))
            }
            keyed.sort { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
            return keyed.prefix(2).map { $0.2 }
        } catch {
            throw LyricsCatalogError(message: error.message)
        }
    }

    /// A candidate track's id for `lyricParameters`.
    public static func trackId(_ track: JSONObject) throws(LyricsCatalogError) -> String {
        do { return try GsonJSON.string(track["id"]) } catch { throw LyricsCatalogError(message: error.message) }
    }

    /// Lyrics from a `song/lyric/v1` response (already checked with `isSuccess`): word-timed YRC whose lines all
    /// end within the song (+1.5 s). nil means "try the next candidate".
    public static func lyrics(fromLyricResponse data: JSONObject, song: Song) throws(LyricsCatalogError) -> Lyrics? {
        do {
            guard let yrc = try GsonJSON.optionalObject(data, "yrc"), let lyricValue = yrc["lyric"] else { return nil }
            let raw = try GsonJSON.string(lyricValue)
            guard let doc = WordSyncTranspilers.yrc(raw, metadata: LyricsMetadata(title: song.title, artist: song.artist,
                                                                                  album: song.album, source: "NetEase"))
            else { return nil }
            if !doc.lines.contains(where: { !$0.syllables.isEmpty }) || doc.lines.contains(where: { $0.endMs > song.duration + 1500 }) {
                return nil
            }
            var lyrics = doc.toLyrics()
            lyrics.areFromRemote = true
            return lyrics
        } catch {
            throw LyricsCatalogError(message: error.message)
        }
    }

    /// Same title (featured credits ignored) and artists, every featured credit an artist, duration within 1.5 s,
    /// and the album when the song has one. Malformed tracks never match.
    public static func matchesRecording(song: Song, track: JSONObject) -> Bool {
        do {
            let name = try GsonJSON.string(track["name"])
            guard CatalogText.normalized(recordingTitle(name)).isIdentical(to: CatalogText.normalized(recordingTitle(song.title)))
            else { return false }
            let artists = try GsonJSON.array(track["artists"]).map { item throws(GsonError) in
                try GsonJSON.string(try GsonJSON.object(item)["name"])
            }
            guard matchesArtists(song.artist, artists) else { return false }
            for credit in featuredCredits(song.title) where !matchesArtists(credit, artists) { return false }
            guard abs(try GsonJSON.long(track["duration"]) &- song.duration) <= 1500 else { return false }
            if ParseKit.isBlank(song.album) { return true }
            let album = try GsonJSON.object(track["album"])
            return CatalogText.normalized(try GsonJSON.string(album["name"])).isIdentical(to: CatalogText.normalized(song.album))
        } catch {
            return false
        }
    }

    /// The title without `(feat. …)`/`[with …]` credits.
    public static func recordingTitle(_ value: String) -> String {
        let s = Array(value.unicodeScalars)
        var out = String.UnicodeScalarView()
        var last = 0
        for match in featuredCreditMatches(s) {
            out.append(contentsOf: s[last..<match.range.lowerBound])
            last = match.range.upperBound
        }
        out.append(contentsOf: s[last...])
        return ParseKit.trim(String(out))
    }

    static func featuredCredits(_ title: String) -> [String] {
        let s = Array(title.unicodeScalars)
        return featuredCreditMatches(s).map { ParseKit.string(s[$0.credit]) }
    }

    static func matchesArtists(_ artist: String, _ candidates: [String]) -> Bool {
        let expected = CatalogText.normalized(artist)
        if candidates.contains(where: { CatalogText.normalized($0).isIdentical(to: expected) }) { return true }
        if CatalogText.normalized(candidates.joined(separator: ", ")).isIdentical(to: expected) { return true }
        // Split only when every resulting credit is an exact catalog artist.
        let credits = splitCredits(artist)
        return credits.count > 1 && credits.allSatisfy { credit in
            candidates.contains { CatalogText.normalized($0).isIdentical(to: CatalogText.normalized(credit)) }
        }
    }

    /// `(?i)\s*[\(\[](?:(?:feat\.?|ft\.?|featuring|with)\s+)([^\)\]]+)[\)\]]` matches.
    static func featuredCreditMatches(_ s: [Unicode.Scalar]) -> [(range: Range<Int>, credit: Range<Int>)] {
        var out: [(range: Range<Int>, credit: Range<Int>)] = []
        var i = 0
        while i < s.count {
            // `\s*` is greedy from the leftmost position; a match starting at whitespace includes the whole run.
            var j = i
            while j < s.count, ParseKit.isRegexSpace(s[j]) { j += 1 }
            if j < s.count, s[j] == "(" || s[j] == "[", let match = creditBody(s, j + 1) {
                out.append((i..<match.end, match.credit))
                i = match.end
                continue
            }
            i += 1
        }
        return out
    }

    private static func creditBody(_ s: [Unicode.Scalar], _ at: Int) -> (credit: Range<Int>, end: Int)? {
        // Alternatives in regex order; each must be followed by at least one whitespace.
        for (word, optionalDot) in [("feat", true), ("ft", true), ("featuring", false), ("with", false)] {
            guard matchesIgnoringCase(s, at, word) else { continue }
            var ends = [at + word.unicodeScalars.count]
            if optionalDot, ends[0] < s.count, s[ends[0]] == "." { ends.insert(ends[0] + 1, at: 0) }
            for e in ends {
                var j = e
                while j < s.count, ParseKit.isRegexSpace(s[j]) { j += 1 }
                guard j > e else { continue }
                // `\s+` is greedy but may give back whitespace to `[^\)\]]+`; the credit then starts at the first
                // character the greedy run left, which is the same text either way up to leading spaces.
                var k = j
                while k < s.count, s[k] != ")" && s[k] != "]" { k += 1 }
                if k < s.count, k > j {
                    return (j..<k, k + 1)
                }
                if k < s.count, k == j, j - e >= 2 {
                    // Give one whitespace back so the credit is non-empty.
                    return ((j - 1)..<k, k + 1)
                }
            }
        }
        return nil
    }

    private static func matchesIgnoringCase(_ s: [Unicode.Scalar], _ at: Int, _ word: String) -> Bool {
        var j = at
        for c in word.unicodeScalars {
            guard j < s.count, s[j].isASCII, ParseKit.lowerASCII(UInt8(s[j].value)) == UInt8(c.value) else { return false }
            j += 1
        }
        return true
    }

    /// `artist.split(Regex("\\s*(?:,|;| feat\\. | ft\\. | featuring )\\s*", IGNORE_CASE))`.
    static func splitCredits(_ artist: String) -> [String] {
        let s = Array(artist.unicodeScalars)
        var parts: [String] = []
        var last = 0
        var i = 0
        while i < s.count {
            var j = i
            while j < s.count, ParseKit.isRegexSpace(s[j]) { j += 1 }
            var delimiterEnd: Int?
            if j < s.count, s[j] == "," || s[j] == ";" {
                delimiterEnd = j + 1
            } else {
                for word in [" feat. ", " ft. ", " featuring "] where matchesIgnoringCase(s, j, word) {
                    delimiterEnd = j + word.unicodeScalars.count
                    break
                }
                // The leading space of " feat. " may have been eaten by `\s*`: retry from the last whitespace.
                if delimiterEnd == nil, j > i {
                    for word in [" feat. ", " ft. ", " featuring "] where matchesIgnoringCase(s, j - 1, word) {
                        delimiterEnd = j - 1 + word.unicodeScalars.count
                        break
                    }
                }
            }
            if var end = delimiterEnd {
                while end < s.count, ParseKit.isRegexSpace(s[end]) { end += 1 }
                parts.append(ParseKit.string(s[last..<i]))
                last = end
                i = end
                continue
            }
            i += 1
        }
        parts.append(ParseKit.string(s[last...]))
        return parts
    }
}

/// Catalog text folding shared by AMLL and NetEase: lower case, NFKD, marks removed, non-letters/digits → space.
enum CatalogText {
    static func normalized(_ value: String) -> String {
        let folded = ParseKit.lowercased(value).decomposedStringWithCompatibilityMapping
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if ParseKit.isMark(scalar) { continue }
            if ParseKit.isLetter(scalar) || ParseKit.isNumber(scalar) {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        // `trim()` after the replacement: a leading/trailing separator never survives.
        return String(out)
    }
}
