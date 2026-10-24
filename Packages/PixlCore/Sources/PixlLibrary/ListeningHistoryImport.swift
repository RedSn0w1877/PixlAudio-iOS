// Imported listening history (spec section B): the weights, the identity of a play (for de-duplication and for mapping
// to library songs), merging new plays into the stored ones without double counting, and the on-disk codec. The
// constants are the same on Android.
//
// Weights: a Spotify play counts 1.0, a YouTube Music play 0.35 — the recommendations lean on Spotify. Imported plays
// fade with a 180-day half-life: a play from a year ago counts a quarter of one from today.

import Foundation
import PixlFoundation
import PixlModel

public enum ListeningHistoryWeights {
    public static let spotify = 1.0
    public static let youTubeMusic = 0.35
    /// Imported plays lose half their weight every 180 days.
    public static let halfLifeDays = 180.0
    /// Shorter listens are ignored, as the app's own taste learning ignores sessions under 5 s.
    public static let minListenMs: Int64 = 5_000
    /// Listened to at least 80 % of the track: a completion.
    public static let completionFraction = 0.8
    /// Skipped before 30 s: an early skip.
    public static let earlySkipMs: Int64 = 30_000
    /// Two plays of one track this close together are the same play (Spotify's API and its export round differently).
    public static let duplicateWindowMs: Int64 = 2_000
    /// The basic Spotify export has minute precision: against a minute-precise timestamp the window is a minute.
    public static let minutePrecisionWindowMs: Int64 = 60_000

    public static func sourceWeight(_ source: ImportedPlaySource) -> Double {
        source.isSpotify ? spotify : youTubeMusic
    }

    /// 2^(−age / 180 days); a play in the future counts as now.
    public static func decay(timestampMs: Int64, nowMs: Int64) -> Double {
        let days = Double(max(nowMs - timestampMs, 0)) / 86_400_000.0
        return pow(2.0, -days / halfLifeDays)
    }

    /// What one play is worth today.
    public static func weight(_ play: ImportedPlay, nowMs: Int64) -> Double {
        sourceWeight(play.source) * decay(timestampMs: play.timestampMs, nowMs: nowMs)
    }

    /// Whether the play counts at all (too-short listens don't; unknown lengths do).
    public static func counts(_ play: ImportedPlay) -> Bool {
        play.msPlayed == 0 || play.msPlayed >= minListenMs
    }
}

/// What a Spotify extended-history play says about the song (nil fields: unknown).
public struct ImportedPlayOutcome: Sendable, Hashable {
    /// The export had completion / skip information for this play.
    public var isKnown: Bool
    public var completed: Bool
    public var earlySkip: Bool
    /// Chosen by hand (`reason_start` clickrow / playbtn).
    public var voluntary: Bool

    public init(_ play: ImportedPlay) {
        let reasonEnd = play.reasonEnd?.lowercased()
        let reasonStart = play.reasonStart?.lowercased()
        isKnown = play.source == .spotifyExport && (reasonEnd != nil || play.skipped != nil)
        let finished = reasonEnd == "trackdone"
        let byLength = play.durationMs > 0
            && Double(play.msPlayed) / Double(play.durationMs) >= ListeningHistoryWeights.completionFraction
        completed = isKnown && (finished || byLength)
        let skippedByHand = play.skipped == true || reasonEnd == "fwdbtn" || reasonEnd == "backbtn"
        earlySkip = isKnown && !completed && skippedByHand && play.msPlayed > 0
            && play.msPlayed < ListeningHistoryWeights.earlySkipMs
        voluntary = reasonStart == "clickrow" || reasonStart == "playbtn"
    }
}

/// How plays are identified and matched to songs.
public enum ImportedPlayIdentity {
    /// The title without "(feat. …)", "[Remastered 2011]", "- 2011 Remaster", "(Official Video)" and the like,
    /// normalised (NFKC, lower case, single spaces).
    public static func normalizedTitle(_ title: String) -> String {
        var text = MusicRecommendationEngine.normalize(title)
        text = strippingBrackets(text)
        // "song - 2011 remaster", "song - remastered", "song - radio edit"
        if let dash = text.range(of: " - ", options: .backwards) {
            let tail = text[dash.upperBound...]
            if tail.contains("remaster") || tail.contains("radio edit") || tail.contains("mono") || tail.contains("stereo") {
                text = String(text[..<dash.lowerBound])
            }
        }
        return KotlinText.collapseJavaWhitespace(text).kotlinTrimmed()
    }

    private static let bracketNoise = ["feat", "ft.", "with ", "remaster", "official", "audio", "video", "lyric",
                                       "visualizer", "visualiser", "explicit", "clean", "hd", "4k"]

    private static func strippingBrackets(_ text: String) -> String {
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch == "(" || ch == "[" {
                let close: Character = ch == "(" ? ")" : "]"
                if let end = text[index...].firstIndex(of: close) {
                    let inner = text[text.index(after: index)..<end]
                    if bracketNoise.contains(where: { inner.contains($0) }) {
                        index = text.index(after: end)
                        continue
                    }
                }
            }
            out.append(ch)
            index = text.index(after: index)
        }
        return out
    }

    /// The first artist of a credit ("a, b", "a & b", "a feat. b", "a x b" → "a"), normalised.
    public static func primaryArtistKey(_ artist: String) -> String {
        let n = MusicRecommendationEngine.normalize(artist)
        var cut = n.endIndex
        for separator in [", ", " & ", " feat. ", " feat ", " ft. ", " featuring ", " x ", " / ", "; "] {
            if let range = n.range(of: separator), range.lowerBound < cut { cut = range.lowerBound }
        }
        return String(n[..<cut]).kotlinTrimmed()
    }

    /// `normalized title|primary artist`: how a play without a Spotify id finds its song.
    public static func nameKey(title: String, artist: String) -> String {
        "\(normalizedTitle(title))|\(primaryArtistKey(artist))"
    }

    /// The track identity: the Spotify id when known, else the name key.
    public static func trackKey(_ play: ImportedPlay) -> String {
        if let id = play.spotifyTrackId, !id.isEmpty { return "sp:\(id)" }
        return "nm:\(nameKey(title: play.title, artist: play.artist))"
    }
}

/// Keys computed once per distinct title / artist: normalising (NFKC) is the expensive part, and a decade of history
/// repeats the same few thousand tracks.
public struct ImportedPlayKeyCache {
    private var names: [String: String] = [:]
    private var artists: [String: String] = [:]

    public init() {}

    public mutating func nameKey(title: String, artist: String) -> String {
        let raw = "\(title)\u{1F}\(artist)"
        if let cached = names[raw] { return cached }
        let key = "\(ImportedPlayIdentity.normalizedTitle(title))|\(artistKey(artist))"
        names[raw] = key
        return key
    }

    public mutating func artistKey(_ artist: String) -> String {
        if let cached = artists[artist] { return cached }
        let key = ImportedPlayIdentity.primaryArtistKey(artist)
        artists[artist] = key
        return key
    }

    /// Every key a play is known by (the Spotify id and the name), for de-duplication across sources.
    mutating func dedupeKeys(_ play: ImportedPlay) -> [String] {
        var keys = ["nm:\(nameKey(title: play.title, artist: play.artist))"]
        if let id = play.spotifyTrackId, !id.isEmpty { keys.append("sp:\(id)") }
        return keys
    }

    /// YouTube Music's history page lists each song once (at its latest play): one entry per video.
    mutating func youTubeEntryKey(_ play: ImportedPlay) -> String {
        if let id = play.videoId, !id.isEmpty { return "yt:\(id)" }
        return "nm:\(nameKey(title: play.title, artist: play.artist))"
    }
}

/// Adds new plays to the stored ones. Re-importing a file, or an automatic sync that overlaps the last one, adds
/// nothing twice: a play is a duplicate when the same track (by Spotify id or by name) was already stored within 2 s
/// (60 s against the basic export's minute-precise times). YouTube Music history-page entries are one per song: a newer
/// sighting moves the stored entry's time forward instead of adding a play.
public enum ImportedHistoryMerge {
    public struct Result: Sendable {
        public var plays: [ImportedPlay]
        public var added: Int
    }

    public static func merge(existing: [ImportedPlay], adding new: [ImportedPlay]) -> Result {
        var plays = existing
        var cache = ImportedPlayKeyCache()
        var timesByKey: [String: [Int64]] = [:]
        var youTubeIndex: [String: Int] = [:]
        for (index, play) in existing.enumerated() {
            if play.source == .ytmusic {
                youTubeIndex[cache.youTubeEntryKey(play)] = index
            } else {
                for key in cache.dedupeKeys(play) { timesByKey[key, default: []].append(play.timestampMs) }
            }
        }
        for key in timesByKey.keys { timesByKey[key]!.sort() }

        var added = 0
        for play in new {
            if play.source == .ytmusic {
                let key = cache.youTubeEntryKey(play)
                if let index = youTubeIndex[key] {
                    if play.timestampMs > plays[index].timestampMs { plays[index].timestampMs = play.timestampMs }
                } else {
                    youTubeIndex[key] = plays.count
                    plays.append(play)
                    added += 1
                }
                continue
            }
            let keys = cache.dedupeKeys(play)
            if keys.contains(where: { isDuplicate(play.timestampMs, in: timesByKey[$0] ?? []) }) { continue }
            plays.append(play)
            added += 1
            for key in keys { insertSorted(play.timestampMs, into: &timesByKey[key, default: []]) }
        }
        return Result(plays: plays, added: added)
    }

    static func isDuplicate(_ time: Int64, in sorted: [Int64]) -> Bool {
        guard !sorted.isEmpty else { return false }
        let window = ListeningHistoryWeights.minutePrecisionWindowMs
        var index = lowerBound(time - window, in: sorted)
        while index < sorted.count, sorted[index] <= time + window {
            let other = sorted[index]
            let delta = abs(other - time)
            if delta <= ListeningHistoryWeights.duplicateWindowMs { return true }
            if other % 60_000 == 0 || time % 60_000 == 0 { return true }
            index += 1
        }
        return false
    }

    private static func lowerBound(_ value: Int64, in sorted: [Int64]) -> Int {
        var low = 0, high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func insertSorted(_ value: Int64, into array: inout [Int64]) {
        array.insert(value, at: lowerBound(value, in: array))
    }

    /// The plays without the given sources ("Clear imported history" clears everything; a source can be cleared alone).
    public static func removing(_ sources: Set<ImportedPlaySource>, from plays: [ImportedPlay]) -> [ImportedPlay] {
        plays.filter { !sources.contains($0.source) }
    }
}

/// `imported_history.tsv`: one play per line, tab-separated, so a decade of Spotify history (~150,000 plays) stays a
/// compact file that reads in one pass. Unknown or damaged lines are skipped, never the whole file.
///
///     PIXLHIST1
///     source  ts  msPlayed  durationMs  flags  reasonStart  reasonEnd  spotifyId  videoId  title  artist  album
///
/// `flags`: two characters, skipped then shuffle — `1` yes, `0` no, `-` unknown. Empty optional fields are empty.
public enum ImportedHistoryCodec {
    public static let fileName = "imported_history.tsv"
    static let header = "PIXLHIST1"

    public static func encode(_ plays: [ImportedPlay]) -> String {
        var out = header + "\n"
        out.reserveCapacity(plays.count * 96)
        for play in plays {
            out += play.source.rawValue
            out += "\t\(play.timestampMs)\t\(play.msPlayed)\t\(play.durationMs)\t"
            out += flag(play.skipped) + flag(play.shuffle)
            for field in [play.reasonStart, play.reasonEnd, play.spotifyTrackId, play.videoId, play.title, play.artist,
                          play.album] {
                out += "\t"
                out += escape(field ?? "")
            }
            out += "\n"
        }
        return out
    }

    public static func decode(_ text: String) -> [ImportedPlay] {
        var plays: [ImportedPlay] = []
        var first = true
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if first {
                first = false
                if line == header { continue }
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 12, let source = ImportedPlaySource(rawValue: String(fields[0])),
                  let ts = Int64(fields[1]), let msPlayed = Int64(fields[2]), let duration = Int64(fields[3]) else { continue }
            let flags = Array(fields[4])
            func optional(_ i: Int) -> String? {
                let value = unescape(fields[i])
                return value.isEmpty ? nil : value
            }
            let title = unescape(fields[9]), artist = unescape(fields[10])
            guard !title.isEmpty else { continue }
            plays.append(ImportedPlay(source: source, timestampMs: ts, title: title, artist: artist, album: optional(11),
                                      spotifyTrackId: optional(7), videoId: optional(8), msPlayed: msPlayed,
                                      durationMs: duration, skipped: flags.count > 0 ? unflag(flags[0]) : nil,
                                      reasonStart: optional(5), reasonEnd: optional(6),
                                      shuffle: flags.count > 1 ? unflag(flags[1]) : nil))
        }
        return plays
    }

    private static func flag(_ value: Bool?) -> String {
        switch value {
        case true?: "1"
        case false?: "0"
        case nil: "-"
        }
    }

    private static func unflag(_ c: Character) -> Bool? {
        switch c {
        case "1": true
        case "0": false
        default: nil
        }
    }

    static func escape(_ s: String) -> String {
        guard s.contains(where: { $0 == "\\" || $0 == "\t" || $0 == "\n" || $0 == "\r" }) else { return s }
        var out = ""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.append(ch)
            }
        }
        return out
    }

    static func unescape(_ s: Substring) -> String {
        guard s.contains("\\") else { return String(s) }
        var out = ""
        var escaping = false
        for ch in s {
            if escaping {
                switch ch {
                case "t": out.append("\t")
                case "n": out.append("\n")
                case "r": out.append("\r")
                default: out.append(ch)
                }
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else {
                out.append(ch)
            }
        }
        return out
    }
}

/// Timestamps in the export files.
public enum ListeningHistoryTime {
    /// ISO-8601 instants (`2024-03-01T12:34:56Z`, `…56.789Z`, `…56+02:00`) and the basic export's
    /// `2024-03-01 12:34` (UTC). nil for anything else.
    public static func parse(_ s: String) -> Int64? {
        let c = Array(s.utf8)
        func num(_ from: Int, _ len: Int) -> Int? {
            guard from >= 0, from + len <= c.count else { return nil }
            var v = 0
            for i in from..<(from + len) {
                guard c[i] >= 48 && c[i] <= 57 else { return nil }
                v = v * 10 + Int(c[i] - 48)
            }
            return v
        }
        guard c.count >= 16, let y = num(0, 4), c[4] == 45, let mo = num(5, 2), c[7] == 45, let d = num(8, 2),
              c[10] == 84 || c[10] == 116 || c[10] == 32, let h = num(11, 2), c[13] == 58, let mi = num(14, 2),
              (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60 else { return nil }
        var sec = 0
        var i = 16
        if i < c.count, c[i] == 58 {
            guard let s = num(17, 2), s < 61 else { return nil }
            sec = min(s, 59)
            i = 19
        }
        var millis: Int64 = 0
        if i < c.count, c[i] == 46 {
            i += 1
            var digits = 0
            var value: Int64 = 0
            while i < c.count, c[i] >= 48, c[i] <= 57 {
                if digits < 3 { value = value * 10 + Int64(c[i] - 48) }
                digits += 1
                i += 1
            }
            guard digits > 0 else { return nil }
            for _ in min(digits, 3)..<3 { value *= 10 }
            millis = value
        }
        var offsetSeconds = 0
        if i < c.count {
            if c[i] == 90 || c[i] == 122 {
                i += 1
            } else if c[i] == 43 || c[i] == 45 {
                let sign = c[i] == 45 ? -1 : 1
                guard let oh = num(i + 1, 2) else { return nil }
                var om = 0
                if i + 3 < c.count, c[i + 3] == 58 {
                    guard let m = num(i + 4, 2) else { return nil }
                    om = m
                    i += 6
                } else if let m = num(i + 3, 2) {
                    om = m
                    i += 5
                } else {
                    i += 3
                }
                offsetSeconds = sign * (oh * 3600 + om * 60)
            }
        }
        // A space-separated time (the basic export) may be followed by nothing; an ISO one ends here too.
        guard i == c.count else { return nil }
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let mp = (mo + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = Int64(era * 146097 + doe - 719468)
        let seconds = days * 86400 + Int64(h * 3600 + mi * 60 + sec) - Int64(offsetSeconds)
        return seconds * 1000 + millis
    }
}
