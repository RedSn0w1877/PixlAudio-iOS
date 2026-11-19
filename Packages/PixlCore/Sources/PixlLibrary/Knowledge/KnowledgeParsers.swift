// Response text to plain rows, for the five open-data sources (docs/brain-spec.md, 3.3 B). A port of Android's
// `KnowledgeParsers.kt`, fixture-tested against the same responses (`Tests/PixlLibraryTests/Fixtures/knowledge/`).
// A parser never throws: a response it cannot read is "no data" (nil or empty), because these services change their
// layouts and a parse error must not take the refresh down.

import Foundation
import PixlFoundation

public enum KnowledgeParsers {
    private static let parser = JSONParser(mode: .kotlinx, maxDepth: 64)

    private static func parse(_ text: String?) -> JSONValue? {
        guard let text, !BrainText.isBlank(text) else { return nil }
        return try? parser.parse(text)
    }

    // The readers of kotlinx's `JsonPrimitive`: a number or a quoted number reads as a number, a number or a boolean reads
    // as its text.
    private static func str(_ v: JSONValue?) -> String? {
        switch v {
        case .string(let s)?: return s
        case .number(let l)?: return l
        case .bool(let b)?: return b ? "true" : "false"
        default: return nil
        }
    }

    private static func dbl(_ v: JSONValue?) -> Double? {
        switch v {
        case .number(let l)?: return Double(l)
        case .string(let s)?: return Double(s)
        default: return nil
        }
    }

    private static func long(_ v: JSONValue?) -> Int64? {
        let literal: String
        switch v {
        case .number(let l)?: literal = l
        case .string(let s)?: literal = s
        default: return nil
        }
        if let n = Int64(literal) { return n }
        guard let d = Double(literal), d.isFinite, abs(d) < 9.2e18 else { return nil }
        return Int64(d)
    }

    private static func int(_ v: JSONValue?) -> Int? {
        guard let l = long(v) else { return nil }
        if l > Int64(Int32.max) || l < Int64(Int32.min) { return l > 0 ? Int(Int32.max) : Int(Int32.min) }
        return Int(l)
    }

    private static func bool(_ v: JSONValue?) -> Bool? {
        switch v {
        case .bool(let b)?: return b
        case .string(let s)?: return s == "true" ? true : (s == "false" ? false : nil)
        default: return nil
        }
    }

    private static func obj(_ v: JSONValue?) -> JSONObject? { v?.objectValue }
    private static func arr(_ v: JSONValue?) -> [JSONValue] { v?.arrayValue ?? [] }
    private static func nonBlank(_ s: String?) -> String? {
        guard let s, !BrainText.isBlank(s) else { return nil }
        return s
    }

    // MARK: Deezer

    /// The `error` object of a Deezer answer, or 0. Deezer sends errors with HTTP 200.
    private static func deezerError(_ root: JSONValue) -> Int { int(root["error"]?["code"]) ?? 0 }

    public static func deezerSearch(_ text: String?) -> DeezerReply<[DeezerTrackRef]> {
        guard let root = parse(text), root.objectValue != nil else { return DeezerReply(nil, 0) }
        let err = deezerError(root)
        if err != 0 { return DeezerReply(nil, err) }
        var rows: [DeezerTrackRef] = []
        for e in arr(root["data"]) {
            guard e.objectValue != nil, let id = long(e["id"]) else { continue }
            rows.append(DeezerTrackRef(
                id: id, title: str(e["title"]) ?? "", artistName: str(e["artist"]?["name"]) ?? "",
                artistId: long(e["artist"]?["id"]) ?? 0, durationSec: int(e["duration"]) ?? 0, rank: long(e["rank"]) ?? 0,
                albumId: long(e["album"]?["id"]) ?? 0, isrc: nonBlank(str(e["isrc"]))))
        }
        return DeezerReply(rows, 0)
    }

    public static func deezerTrack(_ text: String?) -> DeezerReply<DeezerTrack> {
        guard let o = parse(text), o.objectValue != nil else { return DeezerReply(nil, 0) }
        let err = deezerError(o)
        if err != 0 { return DeezerReply(nil, err) }
        guard let id = long(o["id"]) else { return DeezerReply(nil, 0) }
        return DeezerReply(DeezerTrack(
            id: id, isrc: nonBlank(str(o["isrc"])), title: str(o["title"]) ?? "", durationSec: int(o["duration"]) ?? 0,
            rank: long(o["rank"]) ?? 0, releaseDate: nonBlank(str(o["release_date"])), bpm: dbl(o["bpm"]) ?? 0.0,
            gain: dbl(o["gain"]), explicit: bool(o["explicit_lyrics"]), albumId: long(o["album"]?["id"]) ?? 0,
            artistId: long(o["artist"]?["id"]) ?? 0, artistName: str(o["artist"]?["name"]) ?? ""))
    }

    public static func deezerAlbum(_ text: String?) -> DeezerReply<DeezerAlbum> {
        guard let o = parse(text), o.objectValue != nil else { return DeezerReply(nil, 0) }
        let err = deezerError(o)
        if err != 0 { return DeezerReply(nil, err) }
        guard let id = long(o["id"]) else { return DeezerReply(nil, 0) }
        let genres = arr(o["genres"]?["data"]).compactMap { str($0["name"]) }
        return DeezerReply(DeezerAlbum(id: id, genres: genres, releaseDate: nonBlank(str(o["release_date"]))))
    }

    // MARK: MusicBrainz

    private static func votes(_ e: JSONValue?) -> [MbGenreVote] {
        arr(e).compactMap { item in
            guard item.objectValue != nil, let name = str(item["name"]) else { return nil }
            return MbGenreVote(name: name, mbid: str(item["id"]) ?? "", count: int(item["count"]) ?? 0)
        }
    }

    private static func mbHit(_ o: JSONValue) -> MbRecordingHit? {
        guard let id = str(o["id"]) else { return nil }
        let credits = arr(o["artist-credit"]).filter { $0.objectValue != nil }
        var names: [String] = []
        for c in credits {
            if let n = str(c["name"]) { names.append(n) }
            if let n = str(c["artist"]?["name"]) { names.append(n) }
        }
        var distinct: [String] = []
        var seen: Set<BrainKey> = []
        for n in names where seen.insert(BrainKey(n)).inserted { distinct.append(n) }
        var artistMbid: String?
        for c in credits { if let m = str(c["artist"]?["id"]) { artistMbid = m; break } }
        return MbRecordingHit(
            mbid: id, score: int(o["score"]) ?? 0, title: str(o["title"]) ?? "", disambiguation: str(o["disambiguation"]) ?? "",
            lengthMs: int(o["length"]) ?? 0, artistNames: distinct, artistMbid: artistMbid,
            firstReleaseDate: nonBlank(str(o["first-release-date"])), isrcs: arr(o["isrcs"]).compactMap { str($0) })
    }

    /// `GET /ws/2/recording?query=...` and `GET /ws/2/isrc/{ISRC}?inc=artists` (the latter lists `recordings`).
    public static func mbRecordings(_ text: String?) -> [MbRecordingHit] {
        guard let root = parse(text) else { return [] }
        return arr(root["recordings"]).compactMap { $0.objectValue != nil ? mbHit($0) : nil }
    }

    /// `GET /ws/2/recording/{mbid}?inc=genres+tags`.
    public static func mbRecording(_ text: String?) -> MbRecording? {
        guard let o = parse(text), o.objectValue != nil, let id = str(o["id"]) else { return nil }
        return MbRecording(mbid: id, title: str(o["title"]) ?? "", firstReleaseDate: nonBlank(str(o["first-release-date"])),
                           genres: votes(o["genres"]), tags: votes(o["tags"]))
    }

    /// `GET /ws/2/artist/{mbid}?inc=genres+tags`.
    public static func mbArtist(_ text: String?) -> MbArtist? {
        guard let o = parse(text), o.objectValue != nil, let id = str(o["id"]) else { return nil }
        let country = str(arr(o["area"]?["iso-3166-1-codes"]).first) ?? str(o["country"]) ?? ""
        return MbArtist(mbid: id, name: str(o["name"]) ?? "", country: country, genres: votes(o["genres"]), tags: votes(o["tags"]))
    }

    // MARK: ListenBrainz

    /// `POST /1/metadata/recording/` with `{"recording_mbids": [...], "inc": "artist tag release"}`: a map by recording id.
    public static func lbRecordings(_ text: String?) -> [String: LbRecording] {
        guard let root = parse(text), let members = root.objectValue else { return [:] }
        var out: [String: LbRecording] = [:]
        for (mbid, e) in members {
            guard e.objectValue != nil else { continue }
            var tags: [LbTag] = []
            if let tagObj = obj(e["tag"]) {
                for (scope, list) in tagObj {
                    for t in arr(list) {
                        guard t.objectValue != nil, let tag = str(t["tag"]) else { continue }
                        tags.append(LbTag(tag: tag, count: int(t["count"]) ?? 0, genreMbid: str(t["genre_mbid"]) ?? "", scope: scope))
                    }
                }
            }
            let artist = str(arr(e["artist"]?["artists"]).first?["artist_mbid"])
            let first = nonBlank(str(e["recording"]?["first_release_date"]))
            out[mbid] = LbRecording(mbid: mbid, tags: tags, artistMbid: artist, firstReleaseDate: first,
                                    year: int(e["release"]?["year"]) ?? 0)
        }
        return out
    }

    /// `POST /1/popularity/recording`: a list; a recording nobody listened to has null counts.
    public static func lbPopularity(_ text: String?) -> [String: LbPopularity] {
        var out: [String: LbPopularity] = [:]
        guard let root = parse(text) else { return out }
        for e in arr(root) {
            guard e.objectValue != nil, let id = str(e["recording_mbid"]) else { continue }
            out[id] = LbPopularity(mbid: id, listens: long(e["total_listen_count"]) ?? 0, users: long(e["total_user_count"]) ?? 0)
        }
        return out
    }

    // MARK: Wikidata

    private static func split(_ text: String) -> [String] {
        text.split(separator: "|", omittingEmptySubsequences: true).map(String.init).filter { !BrainText.isBlank($0) }
    }

    /// The SPARQL result of `WikidataSource`'s query: one binding per artist, genres joined by `|`.
    public static func wikidataArtists(_ text: String?) -> [WdArtist] {
        guard let root = parse(text) else { return [] }
        return arr(root["results"]?["bindings"]).compactMap { b in
            guard b.objectValue != nil else { return nil }
            func v(_ k: String) -> String { str(b[k]?["value"]) ?? "" }
            let mbid = v("mbid")
            if BrainText.isBlank(mbid) { return nil }
            let a = v("a")
            let id = a.lastIndex(of: "/").map { String(a[a.index(after: $0)...]) } ?? a
            return WdArtist(mbid: mbid, wikidataId: id, genreMbids: split(v("gmbids")), genreLabels: split(v("glabels")))
        }
    }

    // MARK: iTunes

    public static func itunes(_ text: String?) -> [ITunesSong] {
        guard let root = parse(text) else { return [] }
        return arr(root["results"]).compactMap { e in
            guard e.objectValue != nil, str(e["kind"]) == "song", let name = str(e["trackName"]) else { return nil }
            let explicit: Bool?
            switch str(e["trackExplicitness"]) {
            case "explicit": explicit = true
            case "notExplicit": explicit = false
            default: explicit = nil
            }
            return ITunesSong(trackName: name, artistName: str(e["artistName"]) ?? "", durationMs: int(e["trackTimeMillis"]) ?? 0,
                              genre: str(e["primaryGenreName"]) ?? "", releaseDate: str(e["releaseDate"]), explicit: explicit)
        }
    }
}
