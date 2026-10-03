// The pure, storage-free parts of the Android `LyricsRepositoryImpl.kt` and `LyricsRepository.kt`: source order,
// catalog choice, embedded-tag field choice, the raw text stored for parsed lyrics (word-by-word LRC), the JSON
// disk-cache record, the flattened-cache heuristic, user-sync protection and the LRCLIB rate limiter. The iOS
// `LyricsService` (stage 9) owns caching, persistence and the network calls.

import Foundation
import PixlFoundation
import PixlModel

/// A catalog result and the catalog's name (`OnlineSyncedLyrics`).
public struct OnlineSyncedLyrics: Sendable, Hashable {
    public var lyrics: Lyrics
    public var source: String
    /// The catalog's own text, when it should be stored instead of `lyricsToRawContent(lyrics)` (a BiniLyrics TTML
    /// keeps translations and romanisations the lyrics JSON format has no place for).
    public var rawContent: String?

    public init(lyrics: Lyrics, source: String, rawContent: String? = nil) {
        self.lyrics = lyrics
        self.source = source
        self.rawContent = rawContent
    }
}

/// Where `getLyrics` looks.
public enum LyricsSourceKind: String, Sendable, Hashable, CaseIterable {
    case api = "API"
    case embedded = "Embedded"
    case local = "Local"
}

public enum LyricsRepositoryLogic {
    /// `LyricsEntity.source` / `LyricsMetadata.source` of a sync the user made themselves; fetchers never overwrite it.
    public static let userSource = "user"
    /// Embedded tag fields, in preference order.
    public static let embeddedLyricsKeys = ["LYRICS", "SYNCEDLYRICS", "TTML", "UNSYNCEDLYRICS"]
    /// Catalog names used by `findCatalogLyrics`.
    public static let amllSourceName = "AMLL TTML"
    public static let neteaseSourceName = "NetEase YRC"
    public static let lrclibSourceName = "LRCLIB"
    public static let biniLyricsSourceName = BiniLyricsMatching.sourceName

    /// Lyrics with synced or plain lines (`Lyrics.isValid()`).
    public static func isUsable(_ lyrics: Lyrics) -> Bool {
        !(lyrics.synced ?? []).isEmpty || !(lyrics.plain ?? []).isEmpty
    }

    /// The order `getLyrics` tries sources for a preference (online first / embedded first / local first).
    public static func sourceOrder(for preference: LyricsSourcePreference) -> [LyricsSourceKind] {
        switch preference {
        case .apiFirst: return [.api, .embedded, .local]
        case .embeddedFirst: return [.embedded, .api, .local]
        case .localFirst: return [.local, .embedded, .api]
        }
    }

    /// `findCatalogLyrics`: keeps results with timed non-blank lines (or, when `syncedOnly` is false, any plain
    /// text) and prefers word-synced, then line-synced, then anything — in catalog order (BiniLyrics, AMLL, NetEase,
    /// LRCLIB), so word timing from any catalog beats line timing and BiniLyrics wins a tie.
    public static func chooseCatalogResult(_ candidates: [OnlineSyncedLyrics], syncedOnly: Bool) -> OnlineSyncedLyrics? {
        let usable = candidates.filter { isUsableCatalogResult($0, syncedOnly: syncedOnly) }
        return usable.first(where: isWordSynced)
            ?? usable.first { !($0.lyrics.synced ?? []).isEmpty }
            ?? usable.first
    }

    /// The race's early answer. `slots` are the catalogs in `chooseCatalogResult` order: nil while a catalog is still
    /// running, `.some(nil)` when it found nothing. Returns `chooseCatalogResult`'s final answer as soon as no
    /// running catalog can change it (a usable word-synced result with every catalog before it finished), else nil.
    public static func decidedCatalogResult(_ slots: [OnlineSyncedLyrics??], syncedOnly: Bool) -> OnlineSyncedLyrics?? {
        for slot in slots {
            guard let finished = slot else { return nil }
            if let result = finished, isUsableCatalogResult(result, syncedOnly: syncedOnly), isWordSynced(result) {
                return .some(result)
            }
        }
        return .some(chooseCatalogResult(slots.compactMap { $0 ?? nil }, syncedOnly: syncedOnly))
    }

    /// Timed non-blank lines, or (unless `syncedOnly`) non-blank plain text.
    static func isUsableCatalogResult(_ result: OnlineSyncedLyrics, syncedOnly: Bool) -> Bool {
        let synced = result.lyrics.synced ?? []
        return (synced.contains { !ParseKit.isBlank($0.line) } && synced.contains { $0.time > 0 })
            || (!syncedOnly && (result.lyrics.plain ?? []).contains { !ParseKit.isBlank($0) })
    }

    static func isWordSynced(_ result: OnlineSyncedLyrics) -> Bool {
        (result.lyrics.synced ?? []).contains { !($0.words ?? []).isEmpty }
    }

    /// `parseBestEmbeddedLyricsField`: the first field (in `embeddedLyricsKeys` order) that parses into synced
    /// lyrics, else the first that parses at all. Results are local (`areFromRemote = false`).
    public static func parseBestEmbeddedLyricsField(_ propertyMap: [String: [String]]?,
                                                    romanization: any CJKRomanizationProvider = NoCJKRomanization()) -> Lyrics? {
        var firstPlain: Lyrics?
        for key in embeddedLyricsKeys {
            for field in propertyMap?[key] ?? [] {
                if ParseKit.isBlank(field) { continue }
                var parsed = LyricsUtils.parseLyrics(field, romanization: romanization)
                if !isUsable(parsed) { continue }
                parsed.areFromRemote = false
                if !(parsed.synced ?? []).isEmpty { return parsed }
                if firstPlain == nil { firstPlain = parsed }
            }
        }
        return firstPlain
    }

    /// `[mm:ss.xx]` body for a millisecond time (`formatTimestamp`).
    public static func formatTimestamp(_ timeMs: Int) -> String { ParseKit.lrcTimestamp(Int32(truncatingIfNeeded: timeMs)) }

    /// Word-by-word LRC: `[line]<word>word <word>word…`, a space before each word that starts a new word.
    public static func wordByWordLrc(_ lines: [SyncedLine]) -> String {
        lines.map { line -> String in
            let prefix = "[" + formatTimestamp(line.time) + "]"
            guard let words = line.words, !words.isEmpty else { return prefix + line.line }
            return prefix + words.enumerated().map { index, word in
                (index > 0 && word.startsNewWord ? " " : "") + "<" + formatTimestamp(word.time) + ">" + word.word
            }.joined()
        }.joined(separator: "\n")
    }

    /// The raw text stored for parsed lyrics (`lyricsToRawContent`): the document JSON, else word-by-word or line
    /// LRC, else the plain lines; nil when there is nothing.
    public static func lyricsToRawContent(_ lyrics: Lyrics) -> String? {
        if let document = lyrics.document { return LyricsDocCodec.encode(document) }
        if let synced = lyrics.synced, !synced.isEmpty {
            if synced.contains(where: { !($0.words ?? []).isEmpty }) { return wordByWordLrc(synced) }
            return synced.map { "[" + formatTimestamp($0.time) + "]" + $0.line }.joined(separator: "\n")
        }
        guard let plain = lyrics.plain, !plain.isEmpty else { return nil }
        let joined = plain.joined(separator: "\n")
        return ParseKit.isBlank(joined) ? nil : joined
    }

    /// Two or more space-free lines with a 10+ letter Latin run: a legacy cache that lost its word spacing.
    public static func looksLikeFlattenedWordByWordCache(_ lyrics: Lyrics) -> Bool {
        guard let synced = lyrics.synced else { return false }
        var suspicious = 0
        for line in synced {
            let text = line.line
            if ParseKit.isBlank(text) || text.unicodeScalars.contains(where: ParseKit.isWhitespace) { continue }
            var run = 0
            var longRun = false
            for scalar in text.unicodeScalars {
                if scalar.isASCII && scalar.properties.isAlphabetic {
                    run += 1
                    if run >= 10 { longRun = true; break }
                } else {
                    run = 0
                }
            }
            if longRun {
                suspicious += 1
                if suspicious >= 2 { return true }
            }
        }
        return false
    }

    /// Whether a cached document JSON is a sync the user made (`isUserSynced`'s JSON path).
    public static func documentIsUserSynced(_ documentJSON: String) -> Bool {
        guard ParseKit.contains(documentJSON, "\"" + userSource + "\"") else { return false }
        return LyricsDocCodec.decode(documentJSON)?.metadata.source == userSource
    }
}

/// The JSON disk-cache record (`LyricsData`, Gson-encoded `<songId>.json`).
public struct LyricsCacheData: Sendable, Hashable {
    public var plainLyrics: String?
    public var syncedLyrics: String?
    public var wordByWordLyrics: String?
    public var lyricsDocument: String?

    public init(plainLyrics: String? = nil, syncedLyrics: String? = nil, wordByWordLyrics: String? = nil,
                lyricsDocument: String? = nil) {
        self.plainLyrics = plainLyrics
        self.syncedLyrics = syncedLyrics
        self.wordByWordLyrics = wordByWordLyrics
        self.lyricsDocument = lyricsDocument
    }

    /// The record `saveLocalLyricsJson` writes for parsed lyrics.
    public init(lyrics: Lyrics) {
        plainLyrics = lyrics.plain?.joined(separator: "\n")
        syncedLyrics = lyrics.synced?.map { "[" + LyricsRepositoryLogic.formatTimestamp($0.time) + "]" + $0.line }
            .joined(separator: "\n")
        if let synced = lyrics.synced, synced.contains(where: { !($0.words ?? []).isEmpty }) {
            wordByWordLyrics = LyricsRepositoryLogic.wordByWordLrc(synced)
        }
        lyricsDocument = lyrics.document.map(LyricsDocCodec.encode)
    }

    public var hasLyrics: Bool {
        [lyricsDocument, plainLyrics, syncedLyrics, wordByWordLyrics].contains { !ParseKit.isBlank($0 ?? "") }
    }

    /// The richest stored text: document, word-by-word, synced, plain.
    public var preferredRawLyrics: String? { lyricsDocument ?? wordByWordLyrics ?? syncedLyrics ?? plainLyrics }

    /// Gson's output: members in declaration order, nulls omitted, HTML-safe escaping.
    public func encodedJSON() -> String {
        var members: [String] = []
        for (key, value) in [("plainLyrics", plainLyrics), ("syncedLyrics", syncedLyrics),
                             ("wordByWordLyrics", wordByWordLyrics), ("lyricsDocument", lyricsDocument)] {
            if let value { members.append(Self.gsonString(key) + ":" + Self.gsonString(value)) }
        }
        return "{" + members.joined(separator: ",") + "}"
    }

    /// Reads a cache file; nil when it is not a JSON object (a torn write is a cache miss).
    public static func decode(_ json: String) -> LyricsCacheData? {
        guard let value = try? GsonJSON.parse(json), case .object(let o) = value else { return nil }
        func field(_ key: String) -> String?? {
            guard let v = o[key] else { return .some(nil) }
            switch v {
            case .null: return .some(nil)
            case .string(let s): return .some(s)
            case .number(let n): return .some(n)
            case .bool(let b): return .some(b ? "true" : "false")
            default: return nil
            }
        }
        guard let plain = field("plainLyrics"), let synced = field("syncedLyrics"),
              let words = field("wordByWordLyrics"), let document = field("lyricsDocument") else { return nil }
        return LyricsCacheData(plainLyrics: plain, syncedLyrics: synced, wordByWordLyrics: words, lyricsDocument: document)
    }

    /// Gson `JsonWriter` string escaping with `htmlSafe` (the default).
    static func gsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x0C: out += "\\f"
            case 0x00..<0x20, 0x2028, 0x2029, 0x3C, 0x3E, 0x26, 0x3D, 0x27:
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

/// LRCLIB's client-side rate limit (`calculateApiDelay` / `updateLastApiCall`): a minimum gap between calls
/// (100 ms for "lrclib", 250 ms otherwise) and a doubled delay once 30 calls fall in a fixed 60 s window.
public struct LyricsRateLimiter: Sendable {
    public static let lrclibMinDelayMs: Int64 = 100
    public static let defaultMinDelayMs: Int64 = 250
    public static let maxCallsPerMinute = 30

    private var lastCall: [String: Int64] = [:]
    private var windows: [String: (start: Int64, count: Int)] = [:]

    public init() {}

    /// Milliseconds to wait before calling `apiName` at `nowMs`.
    public func delayBeforeCall(_ apiName: String, nowMs: Int64) -> Int64 {
        let last = lastCall[apiName] ?? 0
        let minDelay = apiName.lowercased() == "lrclib" ? Self.lrclibMinDelayMs : Self.defaultMinDelayMs
        let sinceLast = nowMs - last
        if sinceLast < minDelay { return minDelay - sinceLast }
        let inWindow = windows[apiName].map { nowMs - $0.start < 60_000 ? $0.count : 0 } ?? 0
        if inWindow >= Self.maxCallsPerMinute { return minDelay * 2 }
        return 0
    }

    /// Records a call made at `timestampMs`.
    public mutating func recordCall(_ apiName: String, timestampMs: Int64) {
        lastCall[apiName] = timestampMs
        if let window = windows[apiName], timestampMs - window.start < 60_000 {
            windows[apiName] = (window.start, window.count + 1)
        } else {
            windows[apiName] = (timestampMs, 1)
        }
    }
}
