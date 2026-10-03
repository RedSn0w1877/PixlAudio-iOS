// BiniLyrics (https://lyrics.binimum.org): a keyless public lyrics API whose documents are TTML in the big
// streaming catalogs' shape, mostly word-timed. This is the pure half: request parameters, the host allowlist,
// the search-response decoder, the candidate gates and choice, and the checks on parsed lyrics. PixlNet's
// `BiniLyricsClient` performs the requests.
//
// API: `GET https://lyrics-api.binimum.org/?isrc=<ISRC>` or `?track=<title>&artist=<artist>` answers 307 to
// `https://lrc.red/api/v1?…` (same query), which returns
// `{"results":[{"track_name","artist_name","album_name","duration" (s),"isrc","id","lyricsUrl","timing_type"}],
// "source","total"}`; `lyricsUrl` serves `application/ttml+xml`.

import Foundation
import PixlFoundation
import PixlModel

/// One search result.
public struct BiniLyricsCandidate: Sendable, Hashable {
    /// `timing_type`: "word", "line", or anything else (untimed or unknown).
    public enum Timing: Int, Sendable, Hashable, Comparable {
        case none = 0
        case line = 1
        case word = 2

        public init(_ raw: String?) {
            switch raw.map({ ParseKit.trim($0).lowercased() }) {
            case "word", "syllable": self = .word
            case "line": self = .line
            default: self = .none
            }
        }

        public static func < (a: Timing, b: Timing) -> Bool { a.rawValue < b.rawValue }
    }

    public var trackName: String
    public var artistName: String
    public var albumName: String
    /// Seconds; 0 when unknown.
    public var durationSeconds: Double
    public var isrc: String?
    public var lyricsURL: String
    public var timing: Timing

    public init(trackName: String, artistName: String, albumName: String = "", durationSeconds: Double,
                isrc: String? = nil, lyricsURL: String, timing: Timing) {
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.durationSeconds = durationSeconds
        self.isrc = isrc
        self.lyricsURL = lyricsURL
        self.timing = timing
    }

    public var durationMs: Int64 { durationSeconds > 0 && durationSeconds.isFinite ? Int64((durationSeconds * 1000).rounded()) : 0 }
}

public enum BiniLyricsMatching {
    /// The source name shown with the lyrics ("Lyrics: BiniLyrics").
    public static let sourceName = "BiniLyrics"
    /// The documented endpoint.
    public static let apiURL = "https://lyrics-api.binimum.org/"
    /// The only hosts a request (or a redirect, or a lyrics URL) may go to — HTTPS only.
    public static let allowedHosts: Set<String> = ["lyrics-api.binimum.org", "lrc.red", "lyrics-storage.binimum.org"]
    /// A candidate's duration must be this close to the song's (when both are known).
    public static let durationToleranceMs: Int64 = 3_000
    /// Parsed lyrics may not run past the song's end by more than this (AMLL's check).
    public static let lyricsOverrunMs: Int64 = 1_500
    /// Largest accepted search response and TTML document.
    public static let maxSearchBytes = 1_048_576
    public static let maxDocumentBytes = 4 * 1_048_576
    /// Results looked at per search.
    public static let maxCandidates = 50

    // MARK: Requests

    /// The ISRC in canonical form (`CC-XXX-YY-NNNNN` → `CCXXXYYNNNNN`, upper case), or nil when it is not one.
    public static func normalizedISRC(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let scalars = raw.unicodeScalars.filter { $0 != "-" && $0 != " " && $0 != "\u{00A0}" }
        guard scalars.count == 12, scalars.allSatisfy(\.isASCII) else { return nil }
        let upper = String(String.UnicodeScalarView(scalars)).uppercased()
        let chars = Array(upper.unicodeScalars)
        func isLetter(_ c: Unicode.Scalar) -> Bool { (0x41...0x5A).contains(c.value) }
        func isDigit(_ c: Unicode.Scalar) -> Bool { (0x30...0x39).contains(c.value) }
        guard chars[0..<2].allSatisfy(isLetter), chars[2..<5].allSatisfy({ isLetter($0) || isDigit($0) }),
              chars[5..<12].allSatisfy(isDigit) else { return nil }
        return upper
    }

    /// `?isrc=`.
    public static func isrcQuery(_ isrc: String) -> [(name: String, value: String)] { [("isrc", isrc)] }

    /// `?track=&artist=`: the title without featured credits or a trailing ` - Remastered …`, and the song's first
    /// artist credit. nil when the title is blank or the artist unknown.
    public static func searchQuery(song: Song) -> [(name: String, value: String)]? {
        var title = NeteaseLyricsMatching.recordingTitle(song.title)
        title = LrcLibMatching.replaceBracketedQualifiers(title) { isRemasterQualifier($0) ? " " : "(" + $0 + ")" }
        while let dash = title.range(of: " - ", options: .backwards), isRemasterQualifier(String(title[dash.upperBound...])) {
            title = String(title[..<dash.lowerBound])
        }
        title = ParseKit.trim(TtmlLyricsParser.collapseSpaces(title))
        let artist = credits(song.artist).first ?? ""
        if ParseKit.isBlank(title) || ParseKit.isBlank(artist) || LrcLibMatching.isUnknownArtist(song.artist) { return nil }
        return [("track", title), ("artist", artist)]
    }

    // MARK: URLs

    /// HTTPS on an allowlisted host, default port, no credentials.
    public static func isAllowedURL(_ raw: String) -> Bool {
        guard raw.utf8.count <= 2_048, let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "https", let host = url.host?.lowercased(), allowedHosts.contains(host),
              url.user == nil, url.password == nil else { return false }
        if let port = url.port, port != 443 { return false }
        return true
    }

    /// A redirect target (`Location`, absolute or relative to `from`), when it is allowed.
    public static func redirectTarget(location: String, from current: String) -> String? {
        let trimmed = ParseKit.trim(location)
        guard !trimmed.isEmpty, let base = URL(string: current),
              let resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL.absoluteString,
              isAllowedURL(resolved) else { return nil }
        return resolved
    }

    /// The document to fetch for a candidate: its TTML (an `.lrc` link is switched to `.ttml`), when allowed.
    public static func documentURL(_ candidate: BiniLyricsCandidate) -> String? {
        var raw = ParseKit.trim(candidate.lyricsURL)
        if raw.lowercased().hasSuffix(".lrc") { raw = String(raw.unicodeScalars.dropLast(4)) + ".ttml" }
        return isAllowedURL(raw) ? raw : nil
    }

    /// Whether a stored text is a BiniLyrics TTML document (its root declares lrc.red's namespace), so it is read
    /// with `TtmlDocumentParser` rather than the legacy TTML flattening.
    public static func isBiniLyricsDocument(_ raw: String) -> Bool {
        let head = String(raw.unicodeScalars.prefix(2_048))
        let start = ParseKit.trim(TtmlLyricsParser.normalizeTtmlDocument(head))
        return ParseKit.hasPrefix(start, "<tt") && ParseKit.contains(head, "lrc.red/lyric-ttml")
    }

    // MARK: Responses

    /// The results of a search response body; nil when it is too large or not the expected JSON.
    public static func candidates(fromBody body: [UInt8]) -> [BiniLyricsCandidate]? {
        if body.count > maxSearchBytes { return nil }
        guard let root = try? LyricsHTTP.decodeBody(body), case .array(let results)? = root["results"] else { return nil }
        var out: [BiniLyricsCandidate] = []
        for value in results.prefix(maxCandidates) {
            guard case .object(let o) = value, let track = string(o["track_name"]), let url = string(o["lyricsUrl"])
            else { continue }
            out.append(BiniLyricsCandidate(trackName: track, artistName: string(o["artist_name"]) ?? "",
                                           albumName: string(o["album_name"]) ?? "",
                                           durationSeconds: number(o["duration"]) ?? 0,
                                           isrc: normalizedISRC(string(o["isrc"])), lyricsURL: url,
                                           timing: BiniLyricsCandidate.Timing(string(o["timing_type"]))))
        }
        return out
    }

    private static func string(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let s)?: return s
        case .number(let n)?: return n
        default: return nil
        }
    }

    private static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .number(let n)?, .string(let n)?:
            guard let d = ParseKit.parseDouble(ParseKit.trim(n)), d.isFinite, d >= 0 else { return nil }
            return d
        default: return nil
        }
    }

    // MARK: Choosing

    /// The candidate to use, or nil when none passes the gates or the choice is ambiguous. Never guesses:
    ///  - with `isrc`, only results with that ISRC count, and each needs the duration and the title or the artist;
    ///  - otherwise each needs the title (same base title after featured credits, explicit/clean and remaster tags
    ///    are dropped, and the same remix/live/… descriptors), the artist (a shared credit) and the duration;
    ///  - durations must agree within 3 s when both are known;
    ///  - word timing beats line timing beats none; then the album; then the closest duration; then the API's order;
    ///  - without a song duration, finalists whose durations spread over more than 3 s are ambiguous.
    public static func choose(_ candidates: [BiniLyricsCandidate], song: Song, isrc: String? = nil,
                              romanization: any CJKRomanizationProvider = NoCJKRomanization()) -> BiniLyricsCandidate? {
        let wantedISRC = normalizedISRC(isrc)
        let passing = candidates.enumerated().filter { _, candidate in
            guard documentURL(candidate) != nil, durationMatches(song: song, candidate: candidate) else { return false }
            if let wantedISRC {
                guard candidate.isrc == wantedISRC else { return false }
                return titleMatches(song.title, candidate.trackName, romanization: romanization)
                    || artistMatches(song, candidate.artistName, romanization: romanization)
            }
            return titleMatches(song.title, candidate.trackName, romanization: romanization)
                && artistMatches(song, candidate.artistName, romanization: romanization)
        }
        if passing.isEmpty { return nil }

        let songAlbum = LrcLibMatching.normalizeForMatch(song.album)
        func albumMatches(_ c: BiniLyricsCandidate) -> Bool {
            !songAlbum.isEmpty && LrcLibMatching.normalizeForMatch(c.albumName).isIdentical(to: songAlbum)
        }
        func durationGap(_ c: BiniLyricsCandidate) -> Int64 {
            song.duration > 0 && c.durationMs > 0 ? abs(c.durationMs - song.duration) : Int64.max
        }
        let ranked = passing.sorted { a, b in
            if a.element.timing != b.element.timing { return a.element.timing > b.element.timing }
            let aa = albumMatches(a.element), ab = albumMatches(b.element)
            if aa != ab { return aa }
            let ga = durationGap(a.element), gb = durationGap(b.element)
            if ga != gb { return ga < gb }
            return a.offset < b.offset
        }.map(\.element)

        let best = ranked[0]
        if song.duration <= 0 {
            let finalists = ranked.filter { $0.timing == best.timing }.map(\.durationMs).filter { $0 > 0 }
            if let low = finalists.min(), let high = finalists.max(), high - low > durationToleranceMs { return nil }
        }
        return best
    }

    /// Both durations known → within 3 s; otherwise nothing to compare.
    public static func durationMatches(song: Song, candidate: BiniLyricsCandidate) -> Bool {
        guard song.duration > 0, candidate.durationMs > 0 else { return true }
        return abs(candidate.durationMs - song.duration) <= durationToleranceMs
    }

    /// Same base title (and romanisation, for CJK) and the same variant descriptors.
    public static func titleMatches(_ songTitle: String, _ candidateTitle: String,
                                    romanization: any CJKRomanizationProvider = NoCJKRomanization()) -> Bool {
        let songVariants = LrcLibMatching.timingVariantTokens(withoutRemaster(songTitle))
        let candidateVariants = LrcLibMatching.timingVariantTokens(withoutRemaster(candidateTitle))
        guard songVariants == candidateVariants else { return false }
        let a = baseTitle(songTitle), b = baseTitle(candidateTitle)
        if ParseKit.isBlank(a) || ParseKit.isBlank(b) { return false }
        if a.isIdentical(to: b) { return true }
        if MultiLangRomanizer.isScriptThatNeedsRomanization(a) || MultiLangRomanizer.isScriptThatNeedsRomanization(b) {
            let ra = LrcLibMatching.normalizeForMatch(LrcLibMatching.romanizeForMatch(a, romanization: romanization))
            let rb = LrcLibMatching.normalizeForMatch(LrcLibMatching.romanizeForMatch(b, romanization: romanization))
            return !ParseKit.isBlank(ra) && ra.isIdentical(to: rb)
        }
        return false
    }

    /// The song's artist (or one of its credits) is the candidate's artist or one of its credits.
    public static func artistMatches(_ song: Song, _ candidateArtist: String,
                                     romanization: any CJKRomanizationProvider = NoCJKRomanization()) -> Bool {
        if LrcLibMatching.isUnknownArtist(song.artist) && LrcLibMatching.isUnknownArtist(song.displayArtist) { return false }
        let candidateFull = LrcLibMatching.normalizeForMatch(candidateArtist)
        if candidateFull.isEmpty { return false }
        let candidateCredits = Set(credits(candidateArtist).map(LrcLibMatching.normalizeForMatch)).union([candidateFull])
        var songNames = [song.artist, song.displayArtist] + song.artists.map(\.name)
        songNames += credits(song.artist)
        for name in songNames {
            let normalized = LrcLibMatching.normalizeForMatch(name)
            if normalized.isEmpty { continue }
            if candidateCredits.contains(normalized) { return true }
        }
        if MultiLangRomanizer.isScriptThatNeedsRomanization(song.artist)
            || MultiLangRomanizer.isScriptThatNeedsRomanization(candidateArtist) {
            let ra = LrcLibMatching.normalizeForMatch(LrcLibMatching.romanizeForMatch(song.artist, romanization: romanization))
            let rb = LrcLibMatching.normalizeForMatch(LrcLibMatching.romanizeForMatch(candidateArtist, romanization: romanization))
            return !ParseKit.isBlank(ra) && ra.isIdentical(to: rb)
        }
        return false
    }

    /// Artist credits: split at `,` `;` `&` `/` `+` and ` x `, ` feat. `, ` ft. `, ` featuring `, ` with `, ` and `,
    /// ` vs `.
    public static func credits(_ artist: String) -> [String] {
        var parts = [artist]
        for separator in [",", ";", "&", "/", "+", "\u{00D7}"] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        for word in [" x ", " feat. ", " feat ", " ft. ", " ft ", " featuring ", " with ", " and ", " vs. ", " vs "] {
            parts = parts.flatMap { part -> [String] in
                var pieces: [String] = []
                var rest = part
                while let range = rest.range(of: word, options: [.caseInsensitive]) {
                    pieces.append(String(rest[..<range.lowerBound]))
                    rest = String(rest[range.upperBound...])
                }
                pieces.append(rest)
                return pieces
            }
        }
        return parts.map(ParseKit.trim).filter { !ParseKit.isBlank($0) }
    }

    /// `LrcLibMatching.baseTitleForMatching` after dropping remaster tags (`(2011 Remaster)`, ` - Remastered`).
    static func baseTitle(_ title: String) -> String { LrcLibMatching.baseTitleForMatching(withoutRemaster(title)) }

    static func withoutRemaster(_ title: String) -> String {
        let bracketsDropped = LrcLibMatching.replaceBracketedQualifiers(title) { qualifier in
            isRemasterQualifier(qualifier) ? " " : "(" + qualifier + ")"
        }
        var parts = LrcLibMatching.splitOnTitleSeparators(bracketsDropped)
        while parts.count > 1, let last = parts.last, isRemasterQualifier(last) { parts.removeLast() }
        return parts.joined(separator: " - ")
    }

    static func isRemasterQualifier(_ value: String) -> Bool {
        LrcLibMatching.normalizeForMatch(value).split(separator: " ").contains { $0.hasPrefix("remaster") }
    }

    // MARK: Parsed lyrics

    /// AMLL's post-parse checks, for word- and line-timed lyrics alike: something is timed after 0, and nothing
    /// starts past the song's end (+1.5 s). Untimed lyrics need a non-blank line.
    public static func isPlausible(_ lyrics: Lyrics, song: Song) -> Bool {
        let synced = lyrics.synced ?? []
        if synced.isEmpty { return (lyrics.plain ?? []).contains { !ParseKit.isBlank($0) } }
        let words = synced.flatMap { $0.words ?? [] }
        let times = words.isEmpty ? synced.map(\.time) : words.map(\.time)
        if !times.contains(where: { $0 > 0 }) { return false }
        if song.duration > 0, times.contains(where: { Int64($0) > song.duration + lyricsOverrunMs }) { return false }
        return synced.contains { !ParseKit.isBlank($0.line) }
    }
}
