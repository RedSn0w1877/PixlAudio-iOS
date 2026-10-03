// The pure LRCLIB half of the Android `data/repository/LyricsRepositoryImpl.kt`: the response model, the search
// strategies each lookup runs, title/artist normalisation, variant (remix/live/…) compatibility, scoring and
// ranking, and turning a chosen response into stored/parsed lyrics. Networking is PixlNet's job: it runs the
// strategies (first non-empty batch wins) and hands the decoded responses back here.

import Foundation
import PixlFoundation
import PixlModel

// MARK: - Models

/// One LRCLIB record (`LrcLibResponse`; JSON keys as LRCLIB sends them).
public struct LrcLibResponse: Sendable, Hashable, Codable {
    public var id: Int
    public var name: String
    public var artistName: String
    public var albumName: String
    /// Seconds.
    public var duration: Double
    public var plainLyrics: String?
    public var syncedLyrics: String?
    /// Draft Lyricsfile YAML (`lyricsfile`).
    public var lyricsFile: String?

    public init(id: Int, name: String, artistName: String, albumName: String, duration: Double,
                plainLyrics: String? = nil, syncedLyrics: String? = nil, lyricsFile: String? = nil) {
        self.id = id
        self.name = name
        self.artistName = artistName
        self.albumName = albumName
        self.duration = duration
        self.plainLyrics = plainLyrics
        self.syncedLyrics = syncedLyrics
        self.lyricsFile = lyricsFile
    }

    enum CodingKeys: String, CodingKey {
        case id, name, artistName, albumName, duration, plainLyrics, syncedLyrics
        case lyricsFile = "lyricsfile"
    }

    /// Decodes one record as Gson does for the Retrofit service: integral `id`, finite `duration` (numbers or
    /// numeric strings), strings for the text fields (numbers/booleans become their literal). nil when a required
    /// field is missing or unusable — Android would fail on that record while ranking.
    public init?(json: JSONValue) {
        guard case .object(let o) = json,
              let id = Self.integer(o["id"]), let name = Self.text(o["name"]) ?? nil,
              let artistName = Self.text(o["artistName"]) ?? nil, let albumName = Self.text(o["albumName"]) ?? nil,
              let duration = Self.number(o["duration"]),
              let plain = Self.text(o["plainLyrics"]), let synced = Self.text(o["syncedLyrics"]),
              let file = Self.text(o["lyricsfile"]) else { return nil }
        self.init(id: id, name: name, artistName: artistName, albumName: albumName, duration: duration,
                  plainLyrics: plain, syncedLyrics: synced, lyricsFile: file)
    }

    /// A JSON array of records (`Array<LrcLibResponse>?`); nil when it is not an array or any record is unusable.
    public static func decodeList(_ json: JSONValue) -> [LrcLibResponse]? {
        guard case .array(let items) = json else { return nil }
        var out: [LrcLibResponse] = []
        out.reserveCapacity(items.count)
        for item in items {
            guard let response = LrcLibResponse(json: item) else { return nil }
            out.append(response)
        }
        return out
    }

    /// `.some(nil)` for absent/null, `.some(text)` for a primitive, nil for a collection.
    private static func text(_ value: JSONValue?) -> String?? {
        guard let value else { return .some(nil) }
        switch value {
        case .null: return .some(nil)
        case .string(let s): return .some(s)
        case .number(let n): return .some(n)
        case .bool(let b): return .some(b ? "true" : "false")
        default: return nil
        }
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard let value else { return nil }
        switch value {
        case .number(let s), .string(let s):
            if let l = ParseKit.toLong(s) { return Int32(exactly: l).map(Int.init) }
            guard let d = ParseKit.parseDouble(s), d.isFinite, d == d.rounded(.towardZero), let i = Int32(exactly: d) else { return nil }
            return Int(i)
        default: return nil
        }
    }

    private static func number(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        switch value {
        case .number(let s), .string(let s):
            guard let d = ParseKit.parseDouble(s), d.isFinite else { return nil }
            return d
        default: return nil
        }
    }

    /// Plain, synced or Lyricsfile text present.
    public var hasLyrics: Bool {
        !ParseKit.isBlank(plainLyrics ?? "") || !ParseKit.isBlank(syncedLyrics ?? "") || !ParseKit.isBlank(lyricsFile ?? "")
    }

    /// Synced or Lyricsfile text present.
    public var hasSyncedLyrics: Bool { !ParseKit.isBlank(syncedLyrics ?? "") || !ParseKit.isBlank(lyricsFile ?? "") }

    /// The raw lyrics to store: the Lyricsfile (re-encoded) when it parses, else the synced, else the plain text
    /// (`remoteRawLyrics`).
    public var rawLyrics: String? {
        if let parsed = LyricsfileParser.parse(lyricsFile), let raw = LyricsRepositoryLogic.lyricsToRawContent(parsed) {
            return raw
        }
        return syncedLyrics ?? plainLyrics
    }
}

/// A search hit with its parsed lyrics and the raw text to store (`LyricsSearchResult`).
public struct LyricsSearchResult: Sendable, Hashable {
    public var record: LrcLibResponse
    public var lyrics: Lyrics
    public var rawLyrics: String
    /// The catalog it came from ("LRCLIB", or "BiniLyrics" for its strict match offered first in the picker).
    public var source: String

    public init(record: LrcLibResponse, lyrics: Lyrics, rawLyrics: String, source: String = LyricsRepositoryLogic.lrclibSourceName) {
        self.record = record
        self.lyrics = lyrics
        self.rawLyrics = rawLyrics
        self.source = source
    }
}

/// How strict ranking is: `automatic` picks lyrics unattended, `candidate` lists choices for the user.
public enum RemoteLyricsMatchMode: Sendable, Hashable {
    case automatic
    case candidate
}

/// A ranked response.
public struct RemoteLyricsMatch: Sendable, Hashable {
    public var response: LrcLibResponse
    public var score: Int
}

/// One LRCLIB `api/search` request (`RemoteSearchStrategy`); nil parameters are not sent.
public struct LrcLibSearchRequest: Sendable, Hashable {
    public var name: String
    public var query: String?
    public var trackName: String?
    public var artistName: String?
    public var albumName: String?

    public init(name: String, query: String? = nil, trackName: String? = nil, artistName: String? = nil,
                albumName: String? = nil) {
        self.name = name
        self.query = query
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
    }

    /// Query items in LRCLIB's parameter names (`q`, `track_name`, `artist_name`, `album_name`).
    public var parameters: [(name: String, value: String)] {
        var out: [(name: String, value: String)] = []
        if let query { out.append(("q", query)) }
        if let trackName { out.append(("track_name", trackName)) }
        if let artistName { out.append(("artist_name", artistName)) }
        if let albumName { out.append(("album_name", albumName)) }
        return out
    }
}

// MARK: - Matching

public enum LrcLibMatching {

    static let timingVariantKeywords: Set<String> = [
        "remix", "mix", "mashup", "bootleg", "edit", "extended", "radio", "club", "vip", "dub", "live", "acoustic",
        "unplugged", "sped", "slowed", "nightcore", "instrumental", "karaoke", "cover", "demo", "version", "rework",
        "flip", "refix", "opening", "ending", "op", "ed", "theme", "tv", "size", "ver", "full", "movie", "ost",
        "soundtrack", "background", "bgm", "short", "long", "reprise", "intro", "outro", "medley", "bonus",
    ]
    static let titleDropQualifiers: Set<String> = [
        "explicit", "clean", "mono", "stereo", "official audio", "official video", "hi-res", "high-res", "mqa",
    ]
    static let unknownArtists: Set<String> = ["", "<unknown>", "unknown", "unknown artist", "various artists", "various"]
    static let artistConnectorTokens: Set<String> = ["feat", "featuring", "ft", "and", "with", "x", "vs", "the"]

    // MARK: Ranking

    /// Scores and orders responses for a song: score, then a Lyricsfile, then synced lyrics, then the closest
    /// duration. Responses that fail any gate are dropped; a song without a duration matches nothing.
    public static func rankRemoteLyricsMatches(song: Song, responses: [LrcLibResponse], mode: RemoteLyricsMatchMode,
                                               romanization: any CJKRomanizationProvider = NoCJKRomanization()) -> [RemoteLyricsMatch] {
        let songDurationSeconds = Double(song.duration) / 1000.0
        if songDurationSeconds <= 0 { return [] }
        let scored = responses.enumerated().compactMap { index, response -> (Int, RemoteLyricsMatch)? in
            guard let score = remoteLyricsMatchScore(song: song, response: response, mode: mode,
                                                     songDurationSeconds: songDurationSeconds, romanization: romanization)
            else { return nil }
            return (index, RemoteLyricsMatch(response: response, score: score))
        }
        return scored.sorted { a, b in
            let (ma, mb) = (a.1, b.1)
            if ma.score != mb.score { return ma.score > mb.score }
            let fa = !ParseKit.isBlank(ma.response.lyricsFile ?? ""), fb = !ParseKit.isBlank(mb.response.lyricsFile ?? "")
            if fa != fb { return fa }
            if ma.response.hasSyncedLyrics != mb.response.hasSyncedLyrics { return ma.response.hasSyncedLyrics }
            let da = abs(ma.response.duration - songDurationSeconds), db = abs(mb.response.duration - songDurationSeconds)
            if da != db { return da < db }
            return a.0 < b.0
        }.map(\.1)
    }

    /// The score of one response, or nil when it has no lyrics, a different variant, a duration outside the
    /// tolerance, a non-matching title, or (for a known artist) a non-matching artist.
    public static func remoteLyricsMatchScore(song: Song, response: LrcLibResponse, mode: RemoteLyricsMatchMode,
                                              songDurationSeconds: Double,
                                              romanization: any CJKRomanizationProvider = NoCJKRomanization()) -> Int? {
        if !response.hasLyrics || response.duration <= 0 { return nil }
        if !variantDescriptorsCompatible(song: song, response: response) { return nil }
        let hasSynced = response.hasSyncedLyrics
        let tolerance = remoteDurationToleranceSeconds(songDurationSeconds, hasSyncedLyrics: hasSynced, mode: mode)
        let durationDiff = abs(response.duration - songDurationSeconds)
        if durationDiff > tolerance { return nil }
        guard let titleScore = titleMatchScore(song.title, response.name, mode: mode, romanization: romanization) else { return nil }
        let artistScore = artistMatchScore(song.displayArtist, response.artistName, romanization: romanization)
        if !isUnknownArtist(song.displayArtist) && artistScore == nil { return nil }
        let durationScore = Int(KotlinMath.toInt(max(tolerance - durationDiff, 0)))
        return titleScore + (artistScore ?? 0) + durationScore + (hasSynced ? 10 : 0)
    }

    /// Automatic: 1 % of the song (2–3 s) with synced lyrics, 4 % (8–15 s) without; candidates: 15 s.
    public static func remoteDurationToleranceSeconds(_ songDurationSeconds: Double, hasSyncedLyrics: Bool,
                                                      mode: RemoteLyricsMatchMode) -> Double {
        switch mode {
        case .automatic:
            return hasSyncedLyrics ? (songDurationSeconds * 0.01).coerced(in: 2.0, 3.0)
                : (songDurationSeconds * 0.04).coerced(in: 8.0, 15.0)
        case .candidate:
            return 15.0
        }
    }

    /// 70 identical base titles, 65 identical romanisations, 60 equal single tokens, 55 single-token containment,
    /// 58/54 whole-phrase containment, 45 enough token overlap; nil otherwise.
    public static func titleMatchScore(_ songTitle: String, _ responseTitle: String, mode: RemoteLyricsMatchMode,
                                       romanization: any CJKRomanizationProvider = NoCJKRomanization()) -> Int? {
        let songBase = baseTitleForMatching(songTitle)
        let responseBase = baseTitleForMatching(responseTitle)
        if ParseKit.isBlank(songBase) || ParseKit.isBlank(responseBase) { return nil }
        if songBase.isIdentical(to: responseBase) { return 70 }

        if MultiLangRomanizer.isScriptThatNeedsRomanization(songBase)
            || MultiLangRomanizer.isScriptThatNeedsRomanization(responseBase) {
            let songRoman = normalizeForMatch(romanizeForMatch(songBase, romanization: romanization))
            let responseRoman = normalizeForMatch(romanizeForMatch(responseBase, romanization: romanization))
            if songRoman.isIdentical(to: responseRoman) && !ParseKit.isBlank(songRoman) { return 65 }
        }

        let songTokens = matchTokens(songBase)
        let responseTokens = matchTokens(responseBase)
        if songTokens.isEmpty || responseTokens.isEmpty { return nil }

        if songTokens.count == 1 || responseTokens.count == 1 {
            if songTokens == responseTokens { return 60 }
            let s1 = ParseKit.replacing(songBase, " ", with: "")
            let s2 = ParseKit.replacing(responseBase, " ", with: "")
            if !ParseKit.isBlank(s1) && !ParseKit.isBlank(s2) && (ParseKit.contains(s1, s2) || ParseKit.contains(s2, s1)) {
                return 55
            }
            return nil
        }

        if containsWholePhrase(responseBase, songBase) || containsWholePhrase(songBase, responseBase) {
            return mode == .automatic ? 58 : 54
        }

        let overlap = Double(songTokens.intersection(responseTokens).count)
        let songCoverage = overlap / Double(songTokens.count)
        let responseCoverage = overlap / Double(responseTokens.count)
        let requiredSong = mode == .automatic ? 0.85 : 0.75
        let requiredResponse = mode == .automatic ? 0.70 : 0.55
        return songCoverage >= requiredSong && responseCoverage >= requiredResponse ? 45 : nil
    }

    /// 0 for an unknown artist; 30 identical, 28 identical romanisations, 22 whole-phrase containment, 12 when half
    /// of the smaller artist's tokens overlap; nil otherwise.
    public static func artistMatchScore(_ songArtist: String, _ responseArtist: String,
                                        romanization: any CJKRomanizationProvider = NoCJKRomanization()) -> Int? {
        if isUnknownArtist(songArtist) { return 0 }
        let songBase = normalizeForMatch(songArtist)
        let responseBase = normalizeForMatch(responseArtist)
        if ParseKit.isBlank(songBase) || ParseKit.isBlank(responseBase) { return nil }
        if songBase.isIdentical(to: responseBase) { return 30 }

        if MultiLangRomanizer.isScriptThatNeedsRomanization(songBase)
            || MultiLangRomanizer.isScriptThatNeedsRomanization(responseBase) {
            let songRoman = normalizeForMatch(romanizeForMatch(songBase, romanization: romanization))
            let responseRoman = normalizeForMatch(romanizeForMatch(responseBase, romanization: romanization))
            if songRoman.isIdentical(to: responseRoman) && !ParseKit.isBlank(songRoman) { return 28 }
        }

        if containsWholePhrase(responseBase, songBase) || containsWholePhrase(songBase, responseBase) { return 22 }

        let songTokens = artistTokens(songBase)
        let responseTokens = artistTokens(responseBase)
        if songTokens.isEmpty || responseTokens.isEmpty { return nil }
        let overlap = Double(songTokens.intersection(responseTokens).count)
        return overlap / Double(min(songTokens.count, responseTokens.count)) >= 0.5 ? 12 : nil
    }

    /// The song (title and file name) and the response must carry the same remix/live/… descriptors.
    public static func variantDescriptorsCompatible(song: Song, response: LrcLibResponse) -> Bool {
        let songVariants = timingVariantTokens(song.title).union(timingVariantTokensFromFileName(song))
        let responseVariants = timingVariantTokens(response.name)
        if songVariants.isEmpty { return responseVariants.isEmpty }
        return responseVariants == songVariants
    }

    // MARK: Normalisation

    /// Lower-cased, diacritics removed (NFD minus non-spacing marks), `&` → "and", apostrophes dropped, every run
    /// of non-letters/digits → one space, trimmed.
    public static func normalizeForMatch(_ value: String) -> String {
        let decomposed = ParseKit.lowercased(value).decomposedStringWithCanonicalMapping
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        func emit(_ scalar: Unicode.Scalar) {
            if ParseKit.isLetter(scalar) || ParseKit.isNumber(scalar) {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        for scalar in decomposed.unicodeScalars {
            if scalar.properties.generalCategory == .nonspacingMark { continue }
            switch scalar {
            case "&": emit(" "); emit("a"); emit("n"); emit("d"); emit(" ")
            case "\u{2019}", "'", "`": continue
            default: emit(scalar)
            }
        }
        return String(out)
    }

    /// The title without a leading track number, droppable bracketed qualifiers (feat., remix, explicit…) and
    /// trailing droppable ` - qualifier` parts, normalised.
    public static func baseTitleForMatching(_ title: String) -> String {
        var base = stripLeadingTrackNumber(title)
        base = replaceBracketedQualifiers(base) { qualifier in
            shouldDropTitleQualifier(qualifier) ? " " : " " + qualifier + " "
        }
        var parts = splitOnTitleSeparators(base)
        while parts.count > 1, shouldDropTitleQualifier(parts[parts.count - 1]) { parts.removeLast() }
        return normalizeForMatch(parts.joined(separator: " "))
    }

    static func shouldDropTitleQualifier(_ value: String) -> Bool {
        let normalized = normalizeForMatch(value)
        if ParseKit.isBlank(normalized) { return true }
        return containsFeatureQualifier(value) || !timingVariantTokens(value).isEmpty || titleDropQualifiers.contains(normalized)
    }

    /// Remix/live/… descriptors in a title (`mash up` and `vs`/`versus` count as `mashup`).
    public static func timingVariantTokens(_ value: String) -> Set<String> {
        let normalized = normalizeForMatch(value)
        if ParseKit.isBlank(normalized) { return [] }
        let tokens = matchTokens(normalized)
        var variants = tokens.filter(timingVariantKeywords.contains)
        if containsMashUp(normalized) { variants.insert("mashup") }
        if tokens.contains("versus") || tokens.contains("vs") { variants.insert("mashup") }
        return variants
    }

    /// Descriptors from the file name: bracketed ones, and any words after the title in a ` - ` separated part.
    static func timingVariantTokensFromFileName(_ song: Song) -> Set<String> {
        let fileName = songFileName(song)
        if ParseKit.isBlank(fileName) { return [] }
        var variants = Set<String>()
        forEachBracketedQualifier(fileName) { variants.formUnion(timingVariantTokens($0)) }
        let titleBase = baseTitleForMatching(song.title)
        if ParseKit.isBlank(titleBase) { return variants }
        for part in splitOnTitleSeparators(fileName) {
            let normalizedPart = normalizeForMatch(part)
            if ParseKit.hasPrefix(normalizedPart, titleBase + " ") {
                let rest = String(normalizedPart.unicodeScalars.dropFirst(titleBase.unicodeScalars.count))
                variants.formUnion(timingVariantTokens(ParseKit.trim(rest)))
            }
        }
        return variants
    }

    /// `File(path).nameWithoutExtension` ("" for a blank path).
    static func songFileName(_ song: Song) -> String {
        if ParseKit.isBlank(song.path) { return "" }
        var path = Array(song.path.unicodeScalars)
        while path.count > 1, path.last == "/" { path.removeLast() }
        let name = path.lastIndex(of: "/").map { Array(path[($0 + 1)...]) } ?? path
        let stem = name.lastIndex(of: ".").map { Array(name[..<$0]) } ?? name
        return ParseKit.string(stem)
    }

    static func artistTokens(_ normalizedArtist: String) -> Set<String> {
        matchTokens(normalizedArtist).subtracting(artistConnectorTokens)
    }

    static func matchTokens(_ normalizedValue: String) -> Set<String> {
        Set(normalizedValue.split(separator: " ", omittingEmptySubsequences: true).map(String.init).filter { !ParseKit.isBlank($0) })
    }

    /// `(?:^|\s)needle(?:\s|$)` in `haystack`.
    static func containsWholePhrase(_ haystack: String, _ needle: String) -> Bool {
        if ParseKit.isBlank(needle) { return false }
        let h = Array(haystack.unicodeScalars)
        let n = Array(needle.unicodeScalars)
        var from = 0
        while let i = ParseKit.indexOf(h, n, from: from) {
            let end = i + n.count
            if (i == 0 || ParseKit.isRegexSpace(h[i - 1])) && (end == h.count || ParseKit.isRegexSpace(h[end])) { return true }
            from = i + 1
        }
        return false
    }

    /// Kotlin romanisation used for matching: Japanese, Chinese or Korean; other text unchanged.
    public static func romanizeForMatch(_ text: String, romanization: any CJKRomanizationProvider = NoCJKRomanization()) -> String {
        if MultiLangRomanizer.isJapanese(text) { return MultiLangRomanizer.romanizeJapanese(text, provider: romanization) ?? text }
        if MultiLangRomanizer.isChinese(text) { return MultiLangRomanizer.romanizeChinese(text, provider: romanization) ?? text }
        if MultiLangRomanizer.isKorean(text) { return MultiLangRomanizer.romanizeKorean(text) }
        return text
    }

    public static func isUnknownArtist(_ value: String) -> Bool { unknownArtists.contains(normalizeForMatch(value)) }

    /// Leading digits/whitespace/dots/hyphens removed, then cut at the first `-` or opening bracket, trimmed.
    public static func cleanTitleSmart(_ title: String) -> String {
        var s = Array(title.unicodeScalars)
        var start = 0
        while start < s.count, ParseKit.isAsciiDigit(s[start]) || ParseKit.isRegexSpace(s[start]) || s[start] == "."
            || s[start] == "-" || s[start].value == 0xFF0D { start += 1 }
        s = Array(s[start...])
        let cutChars: Set<UInt32> = [0x2D, 0x28, 0x5B, 0x7B, 0xFF08, 0xFF3B, 0xFF5B, 0x3010, 0x300E, 0x300C, 0x3014, 0x3008, 0x300A]
        if let cut = s.firstIndex(where: { cutChars.contains($0.value) }) { s = Array(s[..<cut]) }
        return ParseKit.trim(ParseKit.string(s))
    }

    // MARK: Search strategies

    /// `fetchLyricsFromAPI`'s parallel strategies (the first non-empty batch wins).
    public static func automaticSearchRequests(song: Song,
                                               romanization: any CJKRomanizationProvider = NoCJKRomanization()) -> [LrcLibSearchRequest] {
        let cleanArtist = ParseKit.trim(replaceBracketedQualifiers(ParseKit.trim(song.displayArtist)) { _ in "" })
        let cleanTitle = ParseKit.trim(replaceBracketedQualifiers(ParseKit.trim(song.title)) { _ in "" })
        let simplifiedArtist = ParseKit.trim(prefixBeforeAny(cleanArtist, [" feat.", " ft.", " featuring", " & ", " , "]))
        let simplifiedTitle = ParseKit.trim(prefixBeforeAny(cleanTitle, [" feat.", " ft.", " featuring", " ("]))
        let useSimplified = !simplifiedArtist.isIdentical(to: cleanArtist) || !simplifiedTitle.isIdentical(to: cleanTitle)

        var requests = [
            LrcLibSearchRequest(name: "track+artist", trackName: cleanTitle, artistName: cleanArtist),
            LrcLibSearchRequest(name: "combined_query", query: cleanArtist + " " + cleanTitle),
        ]
        if useSimplified {
            requests.append(LrcLibSearchRequest(name: "simplified_track+artist", trackName: simplifiedTitle,
                                                artistName: simplifiedArtist))
        }
        if MultiLangRomanizer.isScriptThatNeedsRomanization(cleanTitle) {
            let romanTitle = romanizeForMatch(cleanTitle, romanization: romanization)
            if !romanTitle.isIdentical(to: cleanTitle) {
                requests.append(LrcLibSearchRequest(name: "romanized_track", trackName: romanTitle, artistName: cleanArtist))
            }
        }
        let smartTitle = cleanTitleSmart(cleanTitle)
        if !smartTitle.isIdentical(to: cleanTitle) && !ParseKit.isBlank(smartTitle) {
            requests.append(LrcLibSearchRequest(name: "smart_track_only", trackName: smartTitle))
        }
        return requests
    }

    /// The aggressive fallback when every automatic strategy came back empty: the title cut at its first
    /// separator, searched without the artist (nil when there is none).
    public static func automaticFallbackRequest(song: Song) -> LrcLibSearchRequest? {
        let cleanTitle = ParseKit.trim(replaceBracketedQualifiers(ParseKit.trim(song.title)) { _ in "" })
        let separators: Set<UInt32> = [0x2D, 0x2C, 0x28, 0x29, 0x3A, 0xFF0D, 0x00B7, 0x30FB]
        let s = Array(cleanTitle.unicodeScalars)
        guard let index = s.firstIndex(where: { separators.contains($0.value) }) else { return nil }
        let superClean = ParseKit.trim(ParseKit.string(s[..<index]))
        return superClean.isEmpty ? nil : LrcLibSearchRequest(name: "super_clean_track_only", trackName: superClean)
    }

    /// `searchRemote`'s strategies and the query it reports.
    public static func candidateSearchRequests(song: Song) -> (query: String, requests: [LrcLibSearchRequest]) {
        let combinedQuery = song.title + " " + song.displayArtist
        let cleanTitle = ParseKit.trim(song.title)
        let cleanArtist = ParseKit.trim(song.displayArtist)
        var requests = [
            LrcLibSearchRequest(name: "query+artist", query: combinedQuery, artistName: cleanArtist),
            LrcLibSearchRequest(name: "track+artist", trackName: cleanTitle, artistName: cleanArtist),
        ]
        let smartTitle = cleanTitleSmart(cleanTitle)
        if !smartTitle.isIdentical(to: cleanTitle) && !ParseKit.isBlank(smartTitle) {
            requests.append(LrcLibSearchRequest(name: "smart_track_only", trackName: smartTitle))
        }
        requests.append(LrcLibSearchRequest(name: "track_only", trackName: cleanTitle))
        requests.append(LrcLibSearchRequest(name: "query_title_only", query: cleanTitle))
        return (combinedQuery, requests)
    }

    /// `searchRemoteByQuery`'s strategies and the query it reports.
    public static func manualSearchRequests(title: String, artist: String?) -> (query: String, requests: [LrcLibSearchRequest]) {
        let cleanTitle = ParseKit.trim(title)
        let cleanArtist = artist.map(ParseKit.trim).flatMap { ParseKit.isBlank($0) ? nil : $0 }
        let query = [ParseKit.isBlank(cleanTitle) ? nil : cleanTitle, cleanArtist].compactMap { $0 }.joined(separator: " ")
        var requests = [LrcLibSearchRequest(name: "manual_query", query: query)]
        if let cleanArtist {
            requests.append(LrcLibSearchRequest(name: "manual_track+artist", trackName: cleanTitle, artistName: cleanArtist))
        }
        return (query, requests)
    }

    /// The winning batch, de-duplicated by id (first occurrence kept).
    public static func distinctById(_ responses: [LrcLibResponse]) -> [LrcLibResponse] {
        var seen = Set<Int>()
        return responses.filter { seen.insert($0.id).inserted }
    }

    // MARK: Results

    /// The automatic pick (`fetchLyricsFromAPI`): the best-ranked response whose raw lyrics parse.
    /// Only the top-ranked response is considered, as on Android.
    public static func automaticResult(song: Song, responses: [LrcLibResponse],
                                       romanization: any CJKRomanizationProvider = NoCJKRomanization()) -> LyricsSearchResult? {
        guard let best = rankRemoteLyricsMatches(song: song, responses: responses, mode: .automatic,
                                                 romanization: romanization).first?.response,
              let raw = best.rawLyrics, !ParseKit.isBlank(raw) else { return nil }
        var parsed = LyricsUtils.parseLyrics(raw, romanization: romanization)
        parsed.areFromRemote = true
        return LyricsRepositoryLogic.isUsable(parsed) ? LyricsSearchResult(record: best, lyrics: parsed, rawLyrics: raw) : nil
    }

    /// The exact-match fallback (`api/get` response) accepted only when it ranks automatically.
    public static func exactMatchResult(song: Song, response: LrcLibResponse?,
                                        romanization: any CJKRomanizationProvider = NoCJKRomanization()) -> LyricsSearchResult? {
        guard let response,
              let match = rankRemoteLyricsMatches(song: song, responses: [response], mode: .automatic,
                                                  romanization: romanization).first?.response,
              let raw = match.rawLyrics else { return nil }
        var parsed = LyricsUtils.parseLyrics(raw, romanization: romanization)
        parsed.areFromRemote = true
        return LyricsRepositoryLogic.isUsable(parsed) ? LyricsSearchResult(record: match, lyrics: parsed, rawLyrics: raw) : nil
    }

    /// The candidate list (`searchRemote`): ranked in candidate mode, unparseable entries dropped.
    public static func candidateResults(song: Song, responses: [LrcLibResponse],
                                        romanization: any CJKRomanizationProvider = NoCJKRomanization()) -> [LyricsSearchResult] {
        rankRemoteLyricsMatches(song: song, responses: responses, mode: .candidate, romanization: romanization)
            .compactMap { match in result(for: match.response, romanization: romanization) }
    }

    /// Manual search results (`searchRemoteByQuery`): unranked, synced results first.
    public static func manualResults(responses: [LrcLibResponse],
                                     romanization: any CJKRomanizationProvider = NoCJKRomanization()) -> [LyricsSearchResult] {
        let results = responses.compactMap { result(for: $0, romanization: romanization) }
        return results.enumerated().sorted { a, b in
            let sa = !(a.element.record.syncedLyrics ?? "").isEmpty, sb = !(b.element.record.syncedLyrics ?? "").isEmpty
            return sa != sb ? sa : a.offset < b.offset
        }.map(\.element)
    }

    private static func result(for response: LrcLibResponse, romanization: any CJKRomanizationProvider) -> LyricsSearchResult? {
        guard let raw = response.rawLyrics else { return nil }
        var parsed = LyricsUtils.parseLyrics(raw, romanization: romanization)
        parsed.areFromRemote = true
        return LyricsRepositoryLogic.isUsable(parsed) ? LyricsSearchResult(record: response, lyrics: parsed, rawLyrics: raw) : nil
    }

    // MARK: Pattern helpers

    private static let openBrackets: Set<UInt32> = [0x28, 0x5B, 0x7B, 0xFF08, 0xFF3B, 0xFF5B, 0x3010, 0x300E, 0x300C, 0x3014, 0x3008, 0x300A]
    private static let closeBrackets: Set<UInt32> = [0x29, 0x5D, 0x7D, 0xFF09, 0xFF3D, 0xFF5D, 0x3011, 0x300F, 0x300D, 0x3015, 0x3009, 0x300B]

    /// Each `BRACKETED_QUALIFIER_REGEX` match: any opening bracket, text without closing brackets, any closing one.
    private static func bracketMatches(_ s: [Unicode.Scalar]) -> [(range: Range<Int>, inner: Range<Int>)] {
        var out: [(range: Range<Int>, inner: Range<Int>)] = []
        var i = 0
        while i < s.count {
            if openBrackets.contains(s[i].value),
               let close = s[(i + 1)...].firstIndex(where: { closeBrackets.contains($0.value) }) {
                out.append((i..<(close + 1), (i + 1)..<close))
                i = close + 1
                continue
            }
            i += 1
        }
        return out
    }

    static func replaceBracketedQualifiers(_ value: String, _ transform: (String) -> String) -> String {
        let s = Array(value.unicodeScalars)
        var out = ""
        var last = 0
        for match in bracketMatches(s) {
            out += ParseKit.string(s[last..<match.range.lowerBound])
            out += transform(ParseKit.string(s[match.inner]))
            last = match.range.upperBound
        }
        out += ParseKit.string(s[last...])
        return out
    }

    private static func forEachBracketedQualifier(_ value: String, _ body: (String) -> Void) {
        let s = Array(value.unicodeScalars)
        for match in bracketMatches(s) { body(ParseKit.string(s[match.inner])) }
    }

    private static let titleSeparators: Set<UInt32> = [0x2D, 0x2013, 0x2014, 0x3A, 0xFF0D, 0x00B7, 0x30FB]

    /// `split(Regex("\\s*[-–—:－·・]\\s*"))` (Kotlin keeps empty parts).
    static func splitOnTitleSeparators(_ value: String) -> [String] {
        let s = Array(value.unicodeScalars)
        var parts: [String] = []
        var last = 0
        var i = 0
        while i < s.count {
            var q = i
            while q < s.count, ParseKit.isRegexSpace(s[q]) { q += 1 }
            if q < s.count, titleSeparators.contains(s[q].value) {
                var end = q + 1
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

    /// `^\s*\d{1,3}\s*[\._-]\s+` removed.
    static func stripLeadingTrackNumber(_ title: String) -> String {
        let s = Array(title.unicodeScalars)
        var i = 0
        while i < s.count, ParseKit.isRegexSpace(s[i]) { i += 1 }
        let digitsStart = i
        while i < s.count, ParseKit.isAsciiDigit(s[i]) { i += 1 }
        let digits = i - digitsStart
        guard (1...3).contains(digits) else { return title }
        while i < s.count, ParseKit.isRegexSpace(s[i]) { i += 1 }
        guard i < s.count, s[i] == "." || s[i] == "_" || s[i] == "-" else { return title }
        i += 1
        let spacesStart = i
        while i < s.count, ParseKit.isRegexSpace(s[i]) { i += 1 }
        guard i > spacesStart else { return title }
        return ParseKit.string(s[i...])
    }

    /// Word boundary at `i` (ICU word characters, see ParseKit).
    private static func isBoundary(_ s: [Unicode.Scalar], _ i: Int) -> Bool {
        let before = i > 0 && ParseKit.isWordChar(s[i - 1])
        let after = i < s.count && ParseKit.isWordChar(s[i])
        return before != after
    }

    private static func matchesASCIIIgnoringCase(_ s: [Unicode.Scalar], _ at: Int, _ word: String) -> Bool {
        var j = at
        for c in word.unicodeScalars {
            guard j < s.count, s[j].isASCII, ParseKit.lowerASCII(UInt8(s[j].value)) == UInt8(c.value) else { return false }
            j += 1
        }
        return true
    }

    /// `\b(feat(?:uring)?|ft)\.?\b`, case-insensitive.
    static func containsFeatureQualifier(_ value: String) -> Bool {
        let s = Array(value.unicodeScalars)
        for i in s.indices where isBoundary(s, i) {
            for word in ["featuring", "feat", "ft"] where matchesASCIIIgnoringCase(s, i, word) {
                let end = i + word.unicodeScalars.count
                if end < s.count, s[end] == ".", isBoundary(s, end + 1) { return true }
                if isBoundary(s, end) { return true }
            }
        }
        return false
    }

    /// `\bmash\s+up\b`.
    static func containsMashUp(_ value: String) -> Bool {
        let s = Array(value.unicodeScalars)
        for i in s.indices where isBoundary(s, i) && matchesASCIIIgnoringCase(s, i, "mash") {
            var j = i + 4
            let spaceStart = j
            while j < s.count, ParseKit.isRegexSpace(s[j]) { j += 1 }
            if j > spaceStart, j + 1 < s.count, s[j] == "u", s[j + 1] == "p", isBoundary(s, j + 2) { return true }
        }
        return false
    }

    /// The text before the earliest occurrence of any delimiter (Kotlin `split(vararg delimiters).first()`).
    static func prefixBeforeAny(_ value: String, _ delimiters: [String]) -> String {
        let s = Array(value.unicodeScalars)
        var earliest: Int?
        for delimiter in delimiters {
            if let i = ParseKit.indexOf(s, Array(delimiter.unicodeScalars), from: 0), earliest.map({ i < $0 }) ?? true {
                earliest = i
            }
        }
        return earliest.map { ParseKit.string(s[..<$0]) } ?? value
    }
}
