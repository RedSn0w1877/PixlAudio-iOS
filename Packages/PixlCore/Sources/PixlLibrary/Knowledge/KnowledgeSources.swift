// The five open-data clients (docs/brain-spec.md, 3.3 B): Deezer, MusicBrainz, ListenBrainz, Wikidata and iTunes Search.
// Ports of Android's `DeezerSource.kt`, `MusicBrainzSource.kt`, `ListenBrainzSource.kt`, `WikidataSource.kt` and
// `ITunesSource.kt`. Every request goes through `KnowledgeHttp`, the one door (switch, budget, ledger, spacing, back-off).
// Each host has its own off switch; none of them is a Plus feature.

import Foundation
import PixlFoundation

enum SourceSupport {
    /// Java's `URLEncoder.encode(s, "UTF-8")` with a space as `%20`: letters, digits and `-_.*` stay, the rest is `%XX`.
    static func enc(_ s: String) -> String {
        var out = ""
        let hex = Array("0123456789ABCDEF")
        for b in s.utf8 {
            let c = Character(Unicode.Scalar(b))
            let plain = (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
                || b == 0x2D || b == 0x5F || b == 0x2E || b == 0x2A
            if plain {
                out.append(c)
            } else {
                out.append("%")
                out.append(hex[Int(b >> 4)])
                out.append(hex[Int(b & 15)])
            }
        }
        return out
    }

    /// HTTP status to a `Lookup`: not asked or a server error is `unavailable`; "no such thing" is `notFound`.
    static func classify<T: Sendable>(_ reply: KnowledgeReply?, _ parse: (String?) -> T?) -> Lookup<T> {
        guard let reply else { return .unavailable }
        if reply.code == 404 { return .notFound }
        if !reply.ok { return .unavailable }
        guard let value = parse(reply.body) else { return .notFound }
        return .found(value)
    }
}

/// Deezer: track identity by ISRC (16 of 16 found in the probe) or by a name search, then the track's popularity rank,
/// release date, tempo and loudness, and its album's genres. Errors arrive as HTTP 200 with an `error` object; code 4 is
/// the quota (back off), 800 is "no data". Deezer's API terms are non-commercial: the off switch is `KnowledgeHost.deezer`.
public struct DeezerSource: Sendable {
    public static let quotaBackoffMs: Int64 = 60_000
    private let http: any KnowledgeHttp
    private let host = KnowledgeHost.deezer

    public init(http: any KnowledgeHttp) { self.http = http }

    private func lookup<T: Sendable>(_ reply: KnowledgeReply?, _ parse: (String?) -> DeezerReply<T>) async -> Lookup<T> {
        guard let reply, reply.ok else { return reply?.code == 404 ? .notFound : .unavailable }
        let r = parse(reply.body)
        if r.quota {
            await http.backOff(host, forMs: Self.quotaBackoffMs)
            return .unavailable
        }
        if r.errorCode != 0 && r.errorCode != 800 { return .unavailable }
        guard let v = r.value else { return .notFound }
        return .found(v)
    }

    /// `GET /track/isrc:{ISRC}`.
    public func trackByIsrc(_ isrc: String) async -> Lookup<DeezerTrack> {
        await lookup(await http.get(host, url: "https://api.deezer.com/track/isrc:\(SourceSupport.enc(isrc))"), KnowledgeParsers.deezerTrack)
    }

    /// `GET /track/{id}`.
    public func track(_ id: Int64) async -> Lookup<DeezerTrack> {
        await lookup(await http.get(host, url: "https://api.deezer.com/track/\(id)"), KnowledgeParsers.deezerTrack)
    }

    /// `GET /search?q={artist} {title}`: the first hit whose title and primary artist match and whose length is within
    /// 3 s. (Field-qualified search returns nothing today.)
    public func search(_ want: TrackMatch.Want) async -> Lookup<DeezerTrackRef> {
        let reply = await http.get(host, url: "https://api.deezer.com/search?q=\(SourceSupport.enc(want.artist + " " + want.title))&limit=5")
        switch await lookup(reply, KnowledgeParsers.deezerSearch) {
        case .found(let rows):
            let hit = rows.first {
                TrackMatch.titleMatches(want, $0.title) && TrackMatch.artistMatches(want, [$0.artistName])
                    && TrackMatch.durationClose(wantMs: want.durationMs, gotMs: $0.durationSec * 1000)
            }
            return hit.map { .found($0) } ?? .notFound
        case .notFound: return .notFound
        case .unavailable: return .unavailable
        }
    }

    /// `GET /album/{id}`: its genres.
    public func album(_ id: Int64) async -> Lookup<DeezerAlbum> {
        await lookup(await http.get(host, url: "https://api.deezer.com/album/\(id)"), KnowledgeParsers.deezerAlbum)
    }
}

/// MusicBrainz: the recording behind an ISRC (its earliest `first-release-date` is the year the brain believes first), a
/// recording found by name when there is no ISRC, and an artist's genres. One request per 1.1 s and about one call in
/// three answers 503 at that rate, which the HTTP layer backs off from. Core data is CC0; tag votes are CC BY-NC-SA, so
/// they are used at run time only: the off switch is `KnowledgeHost.musicbrainz`.
public struct MusicBrainzSource: Sendable {
    public static let minSearchScore = 85
    private let http: any KnowledgeHttp
    private let host = KnowledgeHost.musicbrainz

    public init(http: any KnowledgeHttp) { self.http = http }

    /// `GET /ws/2/isrc/{ISRC}?inc=artists`: the best recording of the ISRC the listener's track can be. Of those that
    /// pass the title, artist and version checks, the one with the earliest first release date (a remix that shares an
    /// ISRC is refused unless the listener's track is a remix too).
    public func recordingByIsrc(_ isrc: String, _ want: TrackMatch.Want) async -> Lookup<MbRecordingHit> {
        let reply = await http.get(host, url: "https://musicbrainz.org/ws/2/isrc/\(SourceSupport.enc(isrc))?inc=artists&fmt=json")
        return pick(reply, want, requireScore: false)
    }

    /// `GET /ws/2/recording?query=recording:"{title}" AND artist:"{artist}"`: for a track with no ISRC.
    public func searchRecording(_ want: TrackMatch.Want) async -> Lookup<MbRecordingHit> {
        let q = "recording:\"\(want.title.replacingOccurrences(of: "\"", with: ""))\" AND artist:\"\(want.artist.replacingOccurrences(of: "\"", with: ""))\""
        let reply = await http.get(host, url: "https://musicbrainz.org/ws/2/recording?query=\(SourceSupport.enc(q))&fmt=json&limit=5")
        return pick(reply, want, requireScore: true)
    }

    private func pick(_ reply: KnowledgeReply?, _ want: TrackMatch.Want, requireScore: Bool) -> Lookup<MbRecordingHit> {
        switch SourceSupport.classify(reply, { KnowledgeParsers.mbRecordings($0) }) {
        case .found(let all):
            let kept = all
                .filter { !requireScore || $0.score >= Self.minSearchScore }
                .filter { TrackMatch.titleMatches(want, $0.title) }
                .filter { $0.artistNames.isEmpty || TrackMatch.artistMatches(want, $0.artistNames) }
                .filter { TrackMatch.durationClose(wantMs: want.durationMs, gotMs: $0.lengthMs) }
                .filter { !TrackMatch.disambiguationRefuses(want, $0.disambiguation) }
            // The earliest release first; a stable pick when two share a date (the first listed).
            var best: MbRecordingHit?
            for hit in kept {
                let d = hit.firstReleaseDate ?? "9999"
                if let b = best, !(Array(d.utf8).lexicographicallyPrecedes(Array((b.firstReleaseDate ?? "9999").utf8))) { continue }
                best = hit
            }
            return best.map { .found($0) } ?? .notFound
        case .notFound: return .notFound
        case .unavailable: return .unavailable
        }
    }

    /// `GET /ws/2/artist/{mbid}?inc=genres+tags`: the artist's genres with their vote counts, and the country.
    public func artist(_ mbid: String) async -> Lookup<MbArtist> {
        SourceSupport.classify(await http.get(host, url: "https://musicbrainz.org/ws/2/artist/\(SourceSupport.enc(mbid))?inc=genres+tags&fmt=json")) {
            KnowledgeParsers.mbArtist($0)
        }
    }
}

/// ListenBrainz: recording and artist genre tags with MusicBrainz genre ids, for a batch of recordings in one request
/// (the batch size is 16; larger sizes are unverified), and a popularity score as the number of listeners (last resort;
/// it scores Vietnamese pop far too low). One request per second, 150 a day.
public struct ListenBrainzSource: Sendable {
    public static let batch = 16
    private let http: any KnowledgeHttp
    private let host = KnowledgeHost.listenbrainz

    public init(http: any KnowledgeHttp) { self.http = http }

    private static func array(_ mbids: [String]) -> JSONValue { .array(mbids.prefix(batch).map { .string($0) }) }

    /// `POST /1/metadata/recording/ {"recording_mbids": [...], "inc": "artist tag release"}`.
    public func recordings(_ mbids: [String]) async -> Lookup<[String: LbRecording]> {
        if mbids.isEmpty { return .notFound }
        let body = JSONWriter.write(.object(JSONObject([("recording_mbids", Self.array(mbids)), ("inc", .string("artist tag release"))])))
        return SourceSupport.classify(await http.post(host, url: "https://api.listenbrainz.org/1/metadata/recording/", body: body,
                                                      contentType: "application/json", accept: "application/json")) {
            let m = KnowledgeParsers.lbRecordings($0)
            return m.isEmpty ? nil : m
        }
    }

    /// `POST /1/popularity/recording {"recording_mbids": [...]}`.
    public func popularity(_ mbids: [String]) async -> Lookup<[String: LbPopularity]> {
        if mbids.isEmpty { return .notFound }
        let body = JSONWriter.write(.object(JSONObject([("recording_mbids", Self.array(mbids))])))
        return SourceSupport.classify(await http.post(host, url: "https://api.listenbrainz.org/1/popularity/recording", body: body,
                                                      contentType: "application/json", accept: "application/json")) {
            let m = KnowledgeParsers.lbPopularity($0)
            return m.isEmpty ? nil : m
        }
    }
}

/// Wikidata: the genres of artists known by MusicBrainz id, one SPARQL query per 100 artists (15 of 16 test artists were on
/// Wikidata, 14 with genres). One query per 6 s and 3 a day: the host answered 429 at 2 s spacing. CC0.
public struct WikidataSource: Sendable {
    public static let batch = 100
    private let http: any KnowledgeHttp
    private let host = KnowledgeHost.wikidata

    public init(http: any KnowledgeHttp) { self.http = http }

    public func artists(_ mbids: [String]) async -> Lookup<[WdArtist]> {
        var seen: Set<BrainKey> = []
        var ids: [String] = []
        for id in mbids where id.utf8.count == 36 && id.utf8.allSatisfy({ $0 == 0x2D || ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) {
            if seen.insert(BrainKey(id)).inserted { ids.append(id) }
        }
        ids = Array(ids.prefix(Self.batch))
        if ids.isEmpty { return .notFound }
        let values = ids.map { "\"\($0)\"" }.joined(separator: " ")
        let query = "SELECT ?mbid ?a (GROUP_CONCAT(DISTINCT ?gm; separator=\"|\") AS ?gmbids) (GROUP_CONCAT(DISTINCT ?gl; separator=\"|\") AS ?glabels) "
            + "WHERE { VALUES ?mbid { \(values) } ?a wdt:P434 ?mbid . OPTIONAL { ?a wdt:P136 ?g . ?g wdt:P8052 ?gm . ?g rdfs:label ?gl FILTER(LANG(?gl) = \"en\") } } "
            + "GROUP BY ?mbid ?a"
        let reply = await http.post(host, url: "https://query.wikidata.org/sparql", body: "query=" + SourceSupport.enc(query),
                                    contentType: "application/x-www-form-urlencoded", accept: "application/sparql-results+json")
        if let reply, reply.code == 429 { await http.backOff(host, forMs: Int64(max(reply.retryAfterSec, 60)) * 1000) }
        return SourceSupport.classify(reply) {
            let l = KnowledgeParsers.wikidataArtists($0)
            return l.isEmpty ? nil : l
        }
    }
}

/// iTunes Search: a song's `primaryGenreName` and release date, found by name. One request per 3.5 s, 60 a day; 403 means
/// slow down. A genre string here is mapped through the atlas's "itunes" table (about 80 names that matter), and a
/// string the table does not know stays unknown.
public struct ITunesSource: Sendable {
    private let http: any KnowledgeHttp
    private let host = KnowledgeHost.itunes

    public init(http: any KnowledgeHttp) { self.http = http }

    public func search(_ want: TrackMatch.Want) async -> Lookup<ITunesSong> {
        let reply = await http.get(host, url: "https://itunes.apple.com/search?term=\(SourceSupport.enc(want.artist + " " + want.title))&entity=song&limit=5")
        switch SourceSupport.classify(reply, { KnowledgeParsers.itunes($0) }) {
        case .found(let all):
            let hit = all.first {
                TrackMatch.titleMatches(want, $0.trackName) && TrackMatch.artistMatches(want, [$0.artistName])
                    && TrackMatch.durationClose(wantMs: want.durationMs, gotMs: $0.durationMs)
            }
            return hit.map { .found($0) } ?? .notFound
        case .notFound: return .notFound
        case .unavailable: return .unavailable
        }
    }
}
