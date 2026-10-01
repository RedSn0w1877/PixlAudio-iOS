// The response-parsing half of `InnerTubeClient.kt`. InnerTube is private and reshapes its responses at will, so
// (as on Android) the parsing walks the tree looking for the keys it needs instead of following fixed paths.

import Foundation
import PixlFoundation

/// InnerTube response parsing.
public enum InnerTubeParsing {
    /// The only itag exempt from PoToken in yt-dlp (360p mp4 with audio and video together).
    public static let muxedFallbackItag = 18

    // MARK: Player

    /// Parses a `player` response object.
    public static func playerResponse(_ json: JSONObject, streamingPoToken: String? = nil) -> YouTubePlayerResponse {
        let playability = OrgJSON.optObject(json, "playabilityStatus")
        let rawStatus = playability.map { OrgJSON.optString($0, "status") } ?? ""
        let status = NetText.isBlank(rawStatus) ? "UNKNOWN" : rawStatus
        let rawReason = playability.map { OrgJSON.optString($0, "reason") }
        let reason = rawReason.flatMap { NetText.isBlank($0) ? nil : $0 }

        let streamingData = OrgJSON.optObject(json, "streamingData")
        let rawArrays = [OrgJSON.optArray(streamingData, "adaptiveFormats"), OrgJSON.optArray(streamingData, "formats")].compactMap { $0 }
        var formats: [YouTubeAudioFormat] = []
        for array in rawArrays {
            for item in array {
                guard let object = item.objectValue else { continue }
                if let format = format(object) { formats.append(format) }
            }
        }
        var onlyUnusable = false
        var mimeTypes: [String] = []
        var hasHls = false
        if status.lowercased() == "ok" && formats.isEmpty {
            onlyUnusable = true
            mimeTypes = rawArrays.flatMap { array in array.compactMap { $0.objectValue.map { OrgJSON.optString($0, "mimeType") } } }
            hasHls = streamingData.map { OrgJSON.has($0, "hlsManifestUrl") } ?? false
        }
        return YouTubePlayerResponse(status: status, reason: reason, formats: formats, streamingPoToken: streamingPoToken,
                                     hadOnlyUnusableFormats: onlyUnusable, rawMimeTypes: mimeTypes, hasHlsManifest: hasHls)
    }

    /// `parseFormat`: audio tracks (plus itag 18) that carry a URL or a cipher.
    public static func format(_ format: JSONObject) -> YouTubeAudioFormat? {
        let mimeTypeText = OrgJSON.optString(format, "mimeType")
        let mimeType = NetText.isBlank(mimeTypeText) ? nil : mimeTypeText
        let itag = OrgJSON.optInt(format, "itag", -1)
        let muxedFallback = itag == muxedFallbackItag
        if let mimeType, !mimeType.hasPrefix("audio/"), !muxedFallback { return nil }

        let urlText = OrgJSON.optString(format, "url")
        let url = NetText.isBlank(urlText) ? nil : urlText
        let signatureCipher = OrgJSON.optString(format, "signatureCipher")
        let legacyCipher = OrgJSON.optString(format, "cipher")
        let cipher = !NetText.isBlank(signatureCipher) ? signatureCipher : (!NetText.isBlank(legacyCipher) ? legacyCipher : nil)
        if url == nil && cipher == nil { return nil }

        return YouTubeAudioFormat(
            itag: itag,
            mimeType: mimeType,
            bitrate: OrgJSON.optInt(format, "bitrate", 0),
            url: url,
            signatureCipher: cipher,
            contentLength: NetText.toLong(OrgJSON.optString(format, "contentLength")),
            approxDurationMs: NetText.toLong(OrgJSON.optString(format, "approxDurationMs")),
            isMuxedFallback: muxedFallback)
    }

    // MARK: Search

    /// The outcome of parsing a search response.
    public enum SearchOutcome: Sendable, Hashable {
        case results([YouTubeSearchResult])
        /// No results and no `contents`/`continuationContents`: not a results page (Android throws an IOException).
        case notAResultsPage
    }

    /// `searchFiltered`'s parsing: every `musicResponsiveListItemRenderer` in document order until `limit`
    /// (at most 50) results, de-duplicated by video id.
    public static func searchResults(_ json: JSONObject, limit: Int, isVideo: Bool) -> SearchOutcome {
        var results: [YouTubeSearchResult] = []
        let cap = min(limit, 50)
        collectByKey(.object(json), "musicResponsiveListItemRenderer") { renderer in
            if var item = searchItem(renderer) {
                item.isMusicVideo = isVideo
                results.append(item)
            }
            return results.count < cap
        }
        if results.isEmpty && !OrgJSON.has(json, "contents") && !OrgJSON.has(json, "continuationContents") {
            return .notAResultsPage
        }
        var seen = Set<String>()
        return .results(results.filter { seen.insert($0.videoId).inserted })
    }

    /// `parseSearchItem`: one YouTube Music list item (also used for browse shelves, which use the same renderer).
    public static func searchItem(_ renderer: JSONObject) -> YouTubeSearchResult? {
        var videoId: String?
        if let playlistItem = OrgJSON.optObject(renderer, "playlistItemData") {
            let id = OrgJSON.optString(playlistItem, "videoId")
            if !NetText.isBlank(id) { videoId = id }
        }
        if videoId == nil { videoId = findFirstString(.object(renderer), "videoId") }
        guard let videoId else { return nil }

        guard let columns = OrgJSON.optArray(renderer, "flexColumns") else { return nil }
        let columnTexts: [[String]] = columns.map { item in
            let column = OrgJSON.optObject(item.objectValue, "musicResponsiveListItemFlexColumnRenderer")
            return collectRuns(OrgJSON.optObject(column, "text"))
        }

        guard let titleRuns = columnTexts.first else { return nil }
        let title = titleRuns.joined()
        if NetText.isBlank(title) { return nil }

        // The second column is "Artist • Album • 3:07" split into runs; separators arrive as lone "•" runs.
        let details = (columnTexts.count > 1 ? columnTexts[1] : []).map(NetText.trim).filter { !NetText.isBlank($0) && $0 != "•" }
        let duration = details.lazy.compactMap(parseDurationSeconds).first
        let meaningful = details.filter { parseDurationSeconds($0) == nil }
        let withoutType = meaningful.filter { !NetText.equalsIgnoreCase($0, "Song") && !NetText.equalsIgnoreCase($0, "Video") }

        var thumbnailUrl: String?
        let thumbnailRenderer = OrgJSON.optObject(OrgJSON.optObject(renderer, "thumbnail"), "musicThumbnailRenderer")
        if let thumbnails = OrgJSON.optArray(OrgJSON.optObject(thumbnailRenderer, "thumbnail"), "thumbnails") {
            var best: JSONObject?
            var bestWidth = Int.min
            for item in thumbnails {
                guard let object = item.objectValue else { continue }
                let width = OrgJSON.optInt(object, "width", 0)
                if best == nil || width > bestWidth {
                    best = object
                    bestWidth = width
                }
            }
            if let best {
                let url = OrgJSON.optString(best, "url")
                if !NetText.isBlank(url) { thumbnailUrl = url }
            }
        }

        var album: String?
        if withoutType.count > 1 {
            let candidate = withoutType[1]
            if !NetText.containsIgnoreCase(candidate, "views") && !NetText.containsIgnoreCase(candidate, "plays") { album = candidate }
        }
        return YouTubeSearchResult(videoId: videoId, title: title, artist: withoutType.first ?? "", album: album,
                                   durationSeconds: duration, thumbnailUrl: thumbnailUrl)
    }

    /// `collectRuns`: the `text` of every run (missing texts read "", as `optString` does).
    static func collectRuns(_ text: JSONObject?) -> [String] {
        guard let runs = OrgJSON.optArray(text, "runs") else { return [] }
        return runs.compactMap { $0.objectValue.map { OrgJSON.optString($0, "text") } }
    }

    /// `"3:07"` or `"1:02:33"` → seconds (Kotlin `Int` arithmetic, wrapping).
    public static func parseDurationSeconds(_ raw: String) -> Int? {
        let parts = raw.components(separatedBy: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var numbers: [Int32] = []
        for part in parts {
            guard let n = NetText.toInt(NetText.trim(part)) else { return nil }
            numbers.append(Int32(n))
        }
        if numbers.count == 2 { return Int(numbers[0] &* 60 &+ numbers[1]) }
        return Int(numbers[0] &* 3600 &+ numbers[1] &* 60 &+ numbers[2])
    }

    // MARK: Tree walking

    /// `collectByKey`: calls `onFound` for every object under `key` (depth first, document order); `onFound`
    /// returns false to stop. Returns false when stopped.
    @discardableResult
    public static func collectByKey(_ root: JSONValue, _ key: String, _ onFound: (JSONObject) -> Bool) -> Bool {
        switch root {
        case .object(let object):
            for member in OrgJSON.members(object) {
                if member.key == key, case .object(let found) = member.value {
                    if !onFound(found) { return false }
                } else if !collectByKey(member.value, key, onFound) {
                    return false
                }
            }
        case .array(let items):
            for item in items where !collectByKey(item, key, onFound) { return false }
        default:
            break
        }
        return true
    }

    /// `findFirstString`: the first non-blank string under `key` (depth first).
    public static func findFirstString(_ root: JSONValue, _ key: String) -> String? {
        switch root {
        case .object(let object):
            for member in OrgJSON.members(object) {
                if member.key == key, case .string(let s) = member.value, !NetText.isBlank(s) { return s }
                if let found = findFirstString(member.value, key) { return found }
            }
        case .array(let items):
            for item in items {
                if let found = findFirstString(item, key) { return found }
            }
        default:
            break
        }
        return nil
    }

    // MARK: visitorData

    /// `responseContext.visitorData` of any InnerTube response (what NewPipe's `getVisitorDataFromInnertube`
    /// reads from `visitor_id`). nil when missing or blank.
    public static func visitorData(_ json: JSONObject) -> String? {
        let value = OrgJSON.optString(OrgJSON.optObject(json, "responseContext"), "visitorData")
        return NetText.isBlank(value) ? nil : value
    }

    /// `ytcfg`'s `VISITOR_DATA` from a YouTube HTML page (what the login WebView reads as
    /// `window.yt.config_.VISITOR_DATA`). JSON escapes in the value are decoded.
    public static func visitorData(html: String) -> String? {
        let marker = "\"VISITOR_DATA\""
        var searchStart = html.startIndex
        while let range = html.range(of: marker, range: searchStart..<html.endIndex) {
            var i = range.upperBound
            while i < html.endIndex, html[i] == " " || html[i] == "\t" || html[i] == "\n" || html[i] == "\r" { i = html.index(after: i) }
            if i < html.endIndex, html[i] == ":" {
                i = html.index(after: i)
                while i < html.endIndex, html[i] == " " || html[i] == "\t" { i = html.index(after: i) }
                if i < html.endIndex, html[i] == "\"" {
                    var j = html.index(after: i)
                    var escaped = false
                    while j < html.endIndex {
                        let c = html[j]
                        if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { break }
                        j = html.index(after: j)
                    }
                    if j < html.endIndex,
                       let decoded = try? JSONParser(mode: .strict).parse(String(html[i...j])).stringValue,
                       !NetText.isBlank(decoded) {
                        return decoded
                    }
                }
            }
            searchStart = range.upperBound
        }
        return nil
    }
}
