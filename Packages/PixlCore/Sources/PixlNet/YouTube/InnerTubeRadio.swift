// YouTube Music radios and pages for the music brain (docs/brain-spec.md, 3.3): the `next` and `browse` calls and
// the parsers that turn their JSON into plain rows (`PixlModel/BrainRows.swift`). A port of Android's
// `InnerTubeMusicParsers.kt`, `YouTubeRadioSource.kt` and the radio calls of `InnerTubeClient.kt`; both platforms'
// parser tests read the same saved responses and must produce the same rows.
//
// The parser rules, each one a break that happened to some client:
//  1. Renderers are found by name with a tree walk, never by array index. Byline runs are classified by their
//     `pageType`; years and play counts by their shape.
//  2. A response without the expected renderer is "no data" (an empty page), not an error.
//  3. `playlistPanelVideoWrapperRenderer` is unwrapped to its primary renderer; rows with `unplayableText` are
//     skipped; a missing `musicVideoType` is unknown, not official audio.
//  4. Shelves without a header are skipped.

import Foundation
import PixlFoundation
import PixlModel

/// YouTube Music response JSON to plain rows.
public enum InnerTubeRadio {
    static let pageArtist = "MUSIC_PAGE_TYPE_ARTIST"
    static let pageUserChannel = "MUSIC_PAGE_TYPE_USER_CHANNEL"
    static let pageAlbum = "MUSIC_PAGE_TYPE_ALBUM"
    static let pageTrackRelated = "MUSIC_PAGE_TYPE_TRACK_RELATED"
    static let bullet = "\u{2022}"
    /// The prefix of a song radio's playlist id (`"RDAMVM" + videoId`).
    public static let songRadioPrefix = "RDAMVM"

    // MARK: Radio (`next`)

    /// A radio's first page or a continuation page. Never fails on an unexpected shape.
    public static func parseRadio(_ root: JSONValue) -> RadioPage {
        // No panel is "no rows", not "nothing": the response can still name the seed's Related tab, and that tab is
        // the first fallback of an empty or junk radio.
        let panel = findFirst(root, "playlistPanelRenderer") ?? findFirst(root, "playlistPanelContinuation")

        var rows: [RadioRow] = []
        rows.reserveCapacity(50)
        for item in array(panel, "contents") ?? [] {
            guard let object = item.objectValue else { continue }
            let renderer = obj(object, "playlistPanelVideoRenderer")
                ?? obj(obj(obj(object, "playlistPanelVideoWrapperRenderer"), "primaryRenderer"), "playlistPanelVideoRenderer")
            guard let renderer, let row = parsePanelRow(renderer) else { continue }
            rows.append(row)
        }

        var continuation: String?
        for item in array(panel, "continuations") ?? [] {
            if let token = string(obj(item.objectValue, "nextRadioContinuationData"), "continuation"), !token.isKotlinBlank {
                continuation = token
            }
        }

        var chips: [RadioChip] = []
        if let cloud = obj(findFirst(root, "musicQueueRenderer"), "subHeaderChipCloud") {
            collect(.object(cloud), "chipCloudChipRenderer") { chip in
                let endpoint = findFirst(chip["navigationEndpoint"], "watchEndpoint")
                if let playlistId = string(endpoint, "playlistId"), !playlistId.isKotlinBlank {
                    chips.append(RadioChip(label: runsText(obj(chip, "text")), playlistId: playlistId,
                                           params: string(endpoint, "params")))
                }
            }
        }

        var related: String?
        collect(root, "tabRenderer") { tab in
            let endpoint = obj(tab, "endpoint")
            if let type = pageTypeOf(endpoint), type.isIdentical(to: pageTrackRelated), let id = browseIdOf(endpoint) {
                related = id
            }
        }
        return RadioPage(rows: rows, continuation: continuation, chips: chips, relatedBrowseId: related)
    }

    /// Parses response text; nil when it is not JSON at all.
    public static func parseRadio(text: String) -> RadioPage? { OrgJSON.parse(text).map(parseRadio) }

    static func parsePanelRow(_ renderer: JSONObject) -> RadioRow? {
        if renderer["unplayableText"] != nil { return nil }
        guard let videoId = string(renderer, "videoId"), !videoId.isKotlinBlank else { return nil }
        let title = runsText(obj(renderer, "title"))
        if title.isKotlinBlank { return nil }
        let byline = parseByline(array(obj(renderer, "longBylineText"), "runs"))
        return RadioRow(
            videoId: videoId,
            title: title,
            artists: byline.artists,
            album: byline.album,
            albumBrowseId: byline.albumBrowseId,
            year: byline.year,
            durationSec: parseClock(runsText(obj(renderer, "lengthText"))),
            thumbnailUrl: largestThumbnail(array(obj(renderer, "thumbnail"), "thumbnails")),
            explicit: hasExplicitBadge(array(renderer, "badges")),
            kind: MusicVideoKind.from(musicVideoType: findFirstString(renderer["navigationEndpoint"], "musicVideoType")))
    }

    // MARK: Related tab (`browse MPTRt_...`)

    public static func parseRelated(_ root: JSONValue) -> RelatedPage {
        var alsoLike: [RadioRow] = []
        var otherPerformances: [RadioRow] = []
        var similar: [RadioArtistRef] = []
        for shelf in shelves(root) {
            let songs = shelf.items.compactMap { obj($0, "musicResponsiveListItemRenderer").flatMap(parseListItemRow) }
            if !songs.isEmpty {
                // hl=en is pinned for exactly this reason: the only thing that tells "Other performances" (same
                // song, a dedupe list) from "You might also like" is the header text.
                if NetText.containsIgnoreCase(shelf.header, "performances") {
                    otherPerformances.append(contentsOf: songs)
                } else if alsoLike.isEmpty {
                    alsoLike = songs
                }
                continue
            }
            let artists = shelf.items.compactMap(parseTwoRowArtist)
            if !artists.isEmpty && artists.count == shelf.items.count && similar.isEmpty { similar = artists }
        }
        return RelatedPage(youMightAlsoLike: alsoLike, otherPerformances: otherPerformances, similarArtists: similar)
    }

    public static func parseRelated(text: String) -> RelatedPage? { OrgJSON.parse(text).map(parseRelated) }

    // MARK: Artist page (`browse UC...`)

    public static func parseArtistPage(_ root: JSONValue) -> ArtistPage {
        guard let rootObject = root.objectValue else { return .empty }
        let headerRoot = rootObject["header"]
        let header = findFirst(headerRoot, "musicImmersiveHeaderRenderer") ?? findFirst(headerRoot, "musicVisualHeaderRenderer")
        var radio: RadioEndpoint?
        if let endpoint = findFirst(header?["startRadioButton"], "watchEndpoint"),
           let playlistId = string(endpoint, "playlistId"), !playlistId.isKotlinBlank {
            radio = RadioEndpoint(videoId: string(endpoint, "videoId"), playlistId: playlistId,
                                  params: string(endpoint, "params"))
        }

        var topSongs: [RadioRow] = []
        var albums: [ReleaseRef] = []
        var singles: [ReleaseRef] = []
        var fans: [RadioArtistRef] = []
        for shelf in shelves(root) {
            let songs = shelf.items.compactMap { obj($0, "musicResponsiveListItemRenderer").flatMap(parseListItemRow) }
            if !songs.isEmpty {
                if topSongs.isEmpty { topSongs = songs }
                continue
            }
            let releases = shelf.items.compactMap(parseTwoRowRelease)
            if !releases.isEmpty && releases.count == shelf.items.count {
                if NetText.containsIgnoreCase(shelf.header, "single") {
                    singles.append(contentsOf: releases.map { var r = $0; if r.kind == .unknown { r.kind = .single }; return r })
                } else {
                    albums.append(contentsOf: releases.map { var r = $0; if r.kind == .unknown { r.kind = .album }; return r })
                }
                continue
            }
            let artists = shelf.items.compactMap(parseTwoRowArtist)
            if !artists.isEmpty && artists.count == shelf.items.count && fans.isEmpty { fans = artists }
        }
        return ArtistPage(name: runsText(obj(header, "title")), radio: radio, topSongs: topSongs, albums: albums,
                          singles: singles, fansAlsoLike: fans)
    }

    public static func parseArtistPage(text: String) -> ArtistPage? { OrgJSON.parse(text).map(parseArtistPage) }

    // MARK: Shelves and their items

    struct Shelf {
        let header: String
        let items: [JSONObject]
    }

    static let shelfRenderers = ["musicCarouselShelfRenderer", "musicShelfRenderer"]

    /// Every headed shelf of the page's section list, under either browse-results layout.
    static func shelves(_ root: JSONValue) -> [Shelf] {
        guard let sections = array(findFirst(root, "sectionListRenderer"), "contents") else { return [] }
        var out: [Shelf] = []
        out.reserveCapacity(sections.count)
        for section in sections {
            guard let object = section.objectValue else { continue }
            for name in shelfRenderers {
                guard let body = obj(object, name) else { continue }
                let header = runsText(findFirst(body["header"], "title") ?? obj(body, "title"))
                if header.isKotlinBlank { continue }
                out.append(Shelf(header: header, items: (array(body, "contents") ?? []).compactMap(\.objectValue)))
            }
        }
        return out
    }

    static func parseListItemRow(_ renderer: JSONObject) -> RadioRow? { parseListItemRow(renderer, bylineClock: false) }

    static func parseListItemRow(_ renderer: JSONObject, bylineClock: Bool) -> RadioRow? {
        let columns: [JSONObject] = (array(renderer, "flexColumns") ?? []).compactMap {
            obj(obj($0.objectValue, "musicResponsiveListItemFlexColumnRenderer"), "text")
        }
        guard let titleColumn = columns.first else { return nil }
        let watch = findFirst(.object(titleColumn), "watchEndpoint")
        var foundId = string(watch, "videoId")
        if foundId?.isKotlinBlank ?? true { foundId = string(obj(renderer, "playlistItemData"), "videoId") }
        guard let videoId = foundId, !videoId.isKotlinBlank else { return nil }
        let title = runsText(titleColumn)
        if title.isKotlinBlank { return nil }

        // The remaining columns are one byline split across columns.
        var runs: [JSONValue] = []
        var playCount: Int64?
        var clock = 0
        for i in columns.indices.dropFirst() {
            guard let columnRuns = array(columns[i], "runs") else { continue }
            if !runs.isEmpty { runs.append(separatorRun) }
            for run in columnRuns {
                let text = (string(run.objectValue, "text") ?? "").kotlinTrimmed()
                if let plays = parsePlayCount(text) { playCount = plays } else { runs.append(run) }
                if bylineClock && clock == 0 { clock = parseClock(text) }
            }
        }
        let byline = parseByline(runs)
        let fixedClock = parseClock(runsText(findFirst(renderer["fixedColumns"], "text")))
        let thumbnails = array(findFirst(renderer["thumbnail"], "thumbnail"), "thumbnails")
            ?? findFirstArray(renderer["thumbnail"], "thumbnails")
        return RadioRow(
            videoId: videoId,
            title: title,
            artists: byline.artists,
            album: byline.album,
            albumBrowseId: byline.albumBrowseId,
            year: byline.year,
            durationSec: fixedClock > 0 ? fixedClock : clock,
            thumbnailUrl: largestThumbnail(thumbnails),
            explicit: hasExplicitBadge(array(renderer, "badges")),
            kind: MusicVideoKind.from(musicVideoType: findFirstString(watch.map { JSONValue.object($0) }, "musicVideoType")),
            playCount: playCount)
    }

    static let separatorRun: JSONValue = .object(JSONObject([(key: "text", value: .string(" \u{2022} "))]))

    static func parseTwoRowArtist(_ item: JSONObject) -> RadioArtistRef? {
        guard let renderer = obj(item, "musicTwoRowItemRenderer") else { return nil }
        let endpoint = obj(renderer, "navigationEndpoint")
        guard let type = pageTypeOf(endpoint), type.isIdentical(to: pageArtist) else { return nil }
        let name = runsText(obj(renderer, "title"))
        if name.isKotlinBlank { return nil }
        return RadioArtistRef(name: name, channelId: browseIdOf(endpoint))
    }

    static func parseTwoRowRelease(_ item: JSONObject) -> ReleaseRef? {
        guard let renderer = obj(item, "musicTwoRowItemRenderer") else { return nil }
        let endpoint = obj(renderer, "navigationEndpoint")
        guard let type = pageTypeOf(endpoint), type.isIdentical(to: pageAlbum), let browseId = browseIdOf(endpoint) else {
            return nil
        }
        var year = 0
        var kind = ReleaseKind.unknown
        for run in array(obj(renderer, "subtitle"), "runs") ?? [] {
            let text = (string(run.objectValue, "text") ?? "").kotlinTrimmed()
            if let parsed = parseYear(text) {
                year = parsed
            } else {
                switch text.lowercased() {
                case "album": kind = .album
                case "single": kind = .single
                case "ep": kind = .ep
                default: break
                }
            }
        }
        return ReleaseRef(browseId: browseId, title: runsText(obj(renderer, "title")), year: year, kind: kind,
                          audioPlaylistId: audioPlaylistIn(renderer["menu"]),
                          thumbnailUrl: largestThumbnail(findFirstArray(renderer["thumbnailRenderer"], "thumbnails")))
    }

    /// The first `OLAK5uy_...` playlist a `watchPlaylistEndpoint` below `root` names; nil when none.
    static func audioPlaylistIn(_ root: JSONValue?) -> String? {
        var found: String?
        collect(root, "watchPlaylistEndpoint") { endpoint in
            if found == nil, let id = string(endpoint, "playlistId"), id.hasPrefix(audioPlaylistPrefix) { found = id }
        }
        return found
    }

    // MARK: Discography, album audio, playlists, get_queue, search (stage 2a)

    static let audioPlaylistPrefix = "OLAK5uy_"

    /// The whole discography (`browse MPAD<channelId>`, no params): a grid of cards, newest first. Each card is a
    /// release; its `audioPlaylistId` is read from the "Shuffle play" menu item when the response kept it. Empty (never
    /// a failure) when the response has no grid.
    public static func parseDiscography(_ root: JSONValue) -> [ReleaseRef] {
        guard let grid = findFirst(root, "gridRenderer") else { return [] }
        return (array(grid, "items") ?? []).compactMap { $0.objectValue.flatMap(parseTwoRowRelease) }
    }

    public static func parseDiscography(text: String) -> [ReleaseRef]? { OrgJSON.parse(text).map(parseDiscography) }

    /// The `OLAK5uy_...` audio playlist of an album page (`browse MPREb_...`), from
    /// `microformat.microformatDataRenderer.urlCanonical`; failing that, from the "Shuffle play" button. Nil when the
    /// page names none.
    public static func parseAlbumAudioPlaylistId(_ root: JSONValue) -> String? {
        if let canonical = string(findFirst(root, "microformatDataRenderer"), "urlCanonical"),
           let id = audioListParam(canonical) { return id }
        return audioPlaylistIn(root.objectValue?["contents"])
    }

    public static func parseAlbumAudioPlaylistId(text: String) -> String? {
        OrgJSON.parse(text).flatMap(parseAlbumAudioPlaylistId)
    }

    /// `[?&]list=(OLAK5uy_[A-Za-z0-9_-]+)`: the first match in a URL.
    static func audioListParam(_ url: String) -> String? {
        let bytes = Array(url.utf8)
        let needle = Array("list=OLAK5uy_".utf8)
        guard bytes.count > needle.count else { return nil }
        var i = 1
        while i + needle.count <= bytes.count {
            if (bytes[i - 1] == 0x3F || bytes[i - 1] == 0x26) && Array(bytes[i..<(i + needle.count)]) == needle {
                var end = i + needle.count
                while end < bytes.count, isIdByte(bytes[end]) { end += 1 }
                if end > i + needle.count { return String(decoding: bytes[(i + 5)..<end], as: UTF8.self) }
            }
            i += 1
        }
        return nil
    }

    private static func isIdByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b == 0x2D
    }

    /// One page of a playlist (`browse VL<id>`) or of its continuation (`browse {continuation}`). Only the playlist
    /// shelf is read: an album page's own track list is music videos when anonymous, so the `musicShelfRenderer` of an
    /// album page is deliberately ignored.
    ///
    /// The continuation token is the last `continuationItemRenderer` of the page; the older
    /// `musicPlaylistShelfContinuation` shape is accepted too.
    public static func parsePlaylistPage(_ root: JSONValue) -> PlaylistPage {
        let items: [JSONValue]?
        var token: String?
        if let shelf = findFirst(root, "musicPlaylistShelfRenderer") {
            items = array(shelf, "contents")
        } else if let appended = findFirst(root, "appendContinuationItemsAction") {
            items = array(appended, "continuationItems")
        } else if let legacy = findFirst(root, "musicPlaylistShelfContinuation") {
            items = array(legacy, "contents")
            for entry in array(legacy, "continuations") ?? [] {
                if let t = string(obj(entry.objectValue, "nextContinuationData"), "continuation"), !t.isKotlinBlank { token = t }
            }
        } else {
            return .empty
        }
        var rows: [RadioRow] = []
        rows.reserveCapacity(items?.count ?? 0)
        for item in items ?? [] {
            guard let object = item.objectValue else { continue }
            if let renderer = obj(object, "musicResponsiveListItemRenderer"), let row = parseListItemRow(renderer) {
                rows.append(row)
            }
            if let renderer = obj(object, "continuationItemRenderer"),
               let t = string(findFirst(.object(renderer), "continuationCommand"), "token"), !t.isKotlinBlank {
                token = t
            }
        }
        return PlaylistPage(rows: rows, continuation: token)
    }

    public static func parsePlaylistPage(text: String) -> PlaylistPage? { OrgJSON.parse(text).map(parsePlaylistPage) }

    /// `music/get_queue`: the rows of `queueDatas[].content.playlistPanelVideoRenderer`. Unplayable rows are skipped.
    public static func parseGetQueue(_ root: JSONValue) -> [RadioRow] {
        guard let datas = root.objectValue?["queueDatas"]?.arrayValue else { return [] }
        var rows: [RadioRow] = []
        rows.reserveCapacity(datas.count)
        for data in datas {
            guard let content = obj(data.objectValue, "content") else { continue }
            let renderer = obj(content, "playlistPanelVideoRenderer")
                ?? obj(obj(obj(content, "playlistPanelVideoWrapperRenderer"), "primaryRenderer"), "playlistPanelVideoRenderer")
            if let renderer, let row = parsePanelRow(renderer) { rows.append(row) }
        }
        return rows
    }

    public static func parseGetQueue(text: String) -> [RadioRow]? { OrgJSON.parse(text).map(parseGetQueue) }

    /// A songs search: its rows, with the artist runs' channel ids kept (the first hit's artist carries the `UC...` id an
    /// artist station needs when nothing in the library names it). The duration is in the byline here ("Song • Artist •
    /// Album • 3:20"), not in a fixed column.
    public static func parseSongSearch(_ root: JSONValue) -> [RadioRow] {
        var rows: [RadioRow] = []
        rows.reserveCapacity(20)
        collect(root, "musicResponsiveListItemRenderer") { renderer in
            if let row = parseListItemRow(renderer, bylineClock: true) { rows.append(row) }
        }
        return rows
    }

    public static func parseSongSearch(text: String) -> [RadioRow]? { OrgJSON.parse(text).map(parseSongSearch) }

    // MARK: Bylines

    struct Byline {
        var artists: [RadioArtistRef] = []
        var album: String?
        var albumBrowseId: String?
        var year = 0
    }

    /// "Artist & Artist • Album • 2020" as runs. Linked runs are classified by their page type. When no run links to
    /// an artist, the plain runs before the first bullet are the artists, without ids.
    static func parseByline(_ runs: [JSONValue]?) -> Byline {
        var byline = Byline()
        var plainBeforeBullet: [String] = []
        var seenBullet = false
        for element in runs ?? [] {
            guard let run = element.objectValue else { continue }
            let text = string(run, "text") ?? ""
            let trimmed = text.kotlinTrimmed()
            let endpoint = obj(run, "navigationEndpoint")
            let type = pageTypeOf(endpoint)
            if let type, type.isIdentical(to: pageArtist) || type.isIdentical(to: pageUserChannel) {
                byline.artists.append(RadioArtistRef(name: text, channelId: browseIdOf(endpoint)))
            } else if let type, type.isIdentical(to: pageAlbum) {
                byline.album = text
                byline.albumBrowseId = browseIdOf(endpoint)
            } else if let parsed = parseYear(trimmed) {
                byline.year = parsed
            } else if trimmed.isIdentical(to: bullet) {
                seenBullet = true
            } else if !seenBullet && !trimmed.isIdentical(to: "&") && !trimmed.isIdentical(to: ",") && !trimmed.isEmpty {
                plainBeforeBullet.append(trimmed)
            }
        }
        if byline.artists.isEmpty { byline.artists = plainBeforeBullet.map { RadioArtistRef(name: $0, channelId: nil) } }
        return byline
    }

    /// Exactly four ASCII digits, as a number.
    static func parseYear(_ text: String) -> Int? {
        let bytes = Array(text.utf8)
        guard bytes.count == 4, bytes.allSatisfy(isDigit) else { return nil }
        return bytes.reduce(0) { $0 * 10 + Int($1 - 0x30) }
    }

    @inline(__always)
    static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    /// "3.4B plays" to 3,400,000,000; nil when `text` is not a play count. The shape is a number of digits and dots,
    /// an optional K, M or B, one space, and "plays" or "views".
    static func parsePlayCount(_ text: String) -> Int64? {
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count, isDigit(bytes[i]) || bytes[i] == 0x2E { i += 1 }
        guard i > 0 else { return nil }
        let numberText = String(decoding: bytes[..<i], as: UTF8.self)
        var scale = 1.0
        if i < bytes.count {
            switch bytes[i] {
            case 0x4B: scale = 1e3; i += 1
            case 0x4D: scale = 1e6; i += 1
            case 0x42: scale = 1e9; i += 1
            default: break
            }
        }
        let rest = String(decoding: bytes[i...], as: UTF8.self)
        guard rest.isIdentical(to: " plays") || rest.isIdentical(to: " views") else { return nil }
        // Kotlin `toDoubleOrNull`: one dot at most.
        guard numberText.utf8.filter({ $0 == 0x2E }).count <= 1, numberText.utf8.contains(where: isDigit),
              let number = Double(numberText) else { return nil }
        let rounded = (number * scale + 0.5).rounded(.down)
        guard rounded.isFinite, rounded < 9.2e18 else { return nil }
        return Int64(rounded)
    }

    /// "5:02" to 302, "1:02:03" to 3723; 0 when `text` is not a clock (digits, then one or two groups of a colon
    /// and one or two digits).
    static func parseClock(_ text: String) -> Int {
        let parts = text.utf8.split(separator: 0x3A, omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return 0 }
        var total = 0
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty, part.allSatisfy(isDigit) else { return 0 }
            if index > 0 && part.count > 2 { return 0 }
            // A clock of more than a few digits is not a length this app can use.
            if part.count > 6 { return 0 }
            total = total * 60 + part.reduce(0) { $0 * 10 + Int($1 - 0x30) }
        }
        return total
    }

    // MARK: JSON helpers

    static func obj(_ object: JSONObject?, _ key: String) -> JSONObject? { object?[key]?.objectValue }
    static func array(_ object: JSONObject?, _ key: String) -> [JSONValue]? { object?[key]?.arrayValue }
    static func string(_ object: JSONObject?, _ key: String) -> String? { object?[key]?.stringValue }

    static func runsText(_ text: JSONObject?) -> String {
        guard let runs = array(text, "runs") else { return "" }
        if runs.count == 1 { return string(runs[0].objectValue, "text") ?? "" }
        var out = ""
        for run in runs {
            if let piece = string(run.objectValue, "text") { out += piece }
        }
        return out
    }

    static func pageTypeOf(_ endpoint: JSONObject?) -> String? {
        string(obj(obj(obj(endpoint, "browseEndpoint"), "browseEndpointContextSupportedConfigs"),
                   "browseEndpointContextMusicConfig"), "pageType")
    }

    static func browseIdOf(_ endpoint: JSONObject?) -> String? {
        guard let id = string(obj(endpoint, "browseEndpoint"), "browseId"), !id.isKotlinBlank else { return nil }
        return id
    }

    static func largestThumbnail(_ thumbnails: [JSONValue]?) -> String? {
        var best: String?
        var bestWidth = -1
        for item in thumbnails ?? [] {
            guard let object = item.objectValue, let url = string(object, "url") else { continue }
            var width = 0
            switch object["width"] {
            case .number(let literal)?: width = Int(Int32(literal) ?? 0)
            case .string(let text)?: width = Int(Int32(text) ?? 0)
            default: break
            }
            if width >= bestWidth {
                bestWidth = width
                best = url
            }
        }
        return best
    }

    static func hasExplicitBadge(_ badges: [JSONValue]?) -> Bool {
        for badge in badges ?? [] {
            if let type = string(obj(obj(badge.objectValue, "musicInlineBadgeRenderer"), "icon"), "iconType"),
               type.isIdentical(to: "MUSIC_EXPLICIT_BADGE") { return true }
        }
        return false
    }

    /// The first object stored under `key` anywhere below `root`: a member of the object itself first, then depth
    /// first in document order.
    static func findFirst(_ root: JSONValue?, _ key: String) -> JSONObject? {
        switch root {
        case .object(let object)?:
            if let direct = object[key]?.objectValue { return direct }
            for member in object.members {
                if let found = findFirst(member.value, key) { return found }
            }
        case .array(let items)?:
            for item in items {
                if let found = findFirst(item, key) { return found }
            }
        default:
            break
        }
        return nil
    }

    static func findFirstArray(_ root: JSONValue?, _ key: String) -> [JSONValue]? {
        switch root {
        case .object(let object)?:
            if let direct = object[key]?.arrayValue { return direct }
            for member in object.members {
                if let found = findFirstArray(member.value, key) { return found }
            }
        case .array(let items)?:
            for item in items {
                if let found = findFirstArray(item, key) { return found }
            }
        default:
            break
        }
        return nil
    }

    static func findFirstString(_ root: JSONValue?, _ key: String) -> String? {
        switch root {
        case .object(let object)?:
            if let direct = object[key]?.stringValue { return direct }
            for member in object.members {
                if let found = findFirstString(member.value, key) { return found }
            }
        case .array(let items)?:
            for item in items {
                if let found = findFirstString(item, key) { return found }
            }
        default:
            break
        }
        return nil
    }

    /// Depth first: every object stored under `key`, in document order. Does not look inside a match.
    static func collect(_ root: JSONValue?, _ key: String, _ onFound: (JSONObject) -> Void) {
        switch root {
        case .object(let object)?:
            for member in object.members {
                if member.key.isIdentical(to: key), case .object(let found) = member.value {
                    onFound(found)
                } else {
                    collect(member.value, key, onFound)
                }
            }
        case .array(let items)?:
            for item in items { collect(item, key, onFound) }
        default:
            break
        }
    }
}

// MARK: - Requests

/// The anonymous YouTube Music calls of the music brain: `next` for a radio and its pages, `browse` for a track's
/// Related tab and an artist page. No cookie and no account: only the seed is sent, with the process-wide anonymous
/// `visitorData` when there is one (`hl=en`, `gl=US` stay pinned: strings localise otherwise).
///
/// Every call answers nil on a transport or HTTP error, a blank body or a body that is not JSON; it never throws. A
/// response of about 550 KB is parsed here, off the main actor; only the rows leave this type.
public struct InnerTubeRadioClient: Sendable {
    private let http: any HTTPClient
    private let visitorData: @Sendable () async -> String?
    private let profile: InnerTubeClientProfile

    public init(http: any HTTPClient, visitorData: @escaping @Sendable () async -> String?,
                profile: InnerTubeClientProfile = InnerTubeContexts.webRemix) {
        self.http = http
        self.visitorData = visitorData
        self.profile = profile
    }

    /// `next` for a radio. Song radio: `playlistId` = `"RDAMVM" + videoId`. Artist radio: the three values of the
    /// artist page's radio button, sent as they came.
    public func nextRadio(videoId: String?, playlistId: String, params: String? = nil) async -> RadioPage? {
        var body = await musicBody()
        if let videoId, !videoId.isKotlinBlank { body.append("videoId", .string(videoId)) }
        body.append("playlistId", .string(playlistId))
        if let params, !params.isKotlinBlank { body.append("params", .string(params)) }
        return await postText("next", body).flatMap(InnerTubeRadio.parseRadio(text:))
    }

    /// The next page of a radio. The token goes in the body; no query parameter is needed.
    public func nextRadioContinuation(_ continuation: String) async -> RadioPage? {
        var body = await musicBody()
        body.append("continuation", .string(continuation))
        return await postText("next", body).flatMap(InnerTubeRadio.parseRadio(text:))
    }

    /// The next page of a `browse` list (a playlist, a long top-songs list): the token goes in the body. Answers raw text;
    /// parse with `InnerTubeRadio.parsePlaylistPage(text:)`.
    public func browseContinuation(_ continuation: String) async -> String? {
        var body = await musicBody()
        body.append("continuation", .string(continuation))
        return await postText("browse", body)
    }

    /// `browse` as raw text, for an id the caller parses itself (`MPAD<channel>`, `VL<playlist>`, `MPREb_...`).
    public func browseText(_ browseId: String) async -> String? { await browse(browseId) }

    /// `music/get_queue`: turns up to 100 video ids into full rows (title, artists, length, kind). One invalid id makes
    /// the whole batch a 404, which comes back here as nil: the caller bisects.
    public func getQueueText(_ videoIds: [String]) async -> String? {
        if videoIds.isEmpty { return nil }
        var body = await musicBody()
        body.append("videoIds", .array(videoIds.prefix(InnerTubeRadioClient.maxGetQueueIds).map { JSONValue.string($0) }))
        return await postText("music/get_queue", body)
    }

    /// A songs search as raw text, on the same anonymous context as the radios. The first hit's artist run carries the
    /// artist's `UC...` id. Parse with `InnerTubeRadio.parseSongSearch(text:)`.
    public func searchSongsText(_ query: String) async -> String? {
        let trimmed = NetText.trim(query)
        if trimmed.isEmpty { return nil }
        var body = await musicBody()
        body.append("query", .string(trimmed))
        body.append("params", .string(InnerTubeContexts.songsSearchParams))
        return await postText("search", body)
    }

    public static let maxGetQueueIds = 100

    /// `browse` for a track's Related tab (`MPTRt_...`).
    public func related(browseId: String) async -> RelatedPage? {
        await browse(browseId).flatMap(InnerTubeRadio.parseRelated(text:))
    }

    /// `browse` for an artist (`UC...`).
    public func artistPage(channelId: String) async -> ArtistPage? {
        await browse(channelId).flatMap(InnerTubeRadio.parseArtistPage(text:))
    }

    private func browse(_ browseId: String) async -> String? {
        var body = await musicBody()
        body.append("browseId", .string(browseId))
        return await postText("browse", body)
    }

    private func musicBody() async -> JSONObject {
        InnerTubeContexts.buildContext(profile, visitorData: await visitorData())
    }

    private func postText(_ path: String, _ body: JSONObject) async -> String? {
        let request = InnerTubeRequests.post(path: path, body: body, profile: profile)
        guard let response = try? await http.send(request), response.isSuccessful else { return nil }
        let text = response.text
        return text.isKotlinBlank ? nil : text
    }
}

/// YouTube Music as a `RadioSource` (docs/brain-spec.md, 3.3 A): anonymous, through `InnerTubeRadioClient`, and
/// under the YouTube `HostBudget`. Nothing raw is kept: the rows are taken out and the tree is dropped at once.
public struct YouTubeRadioSource: RadioSource {
    private let client: InnerTubeRadioClient
    private let budget: HostBudget
    /// The brain's text folding (`BrainText.fold`, which this module cannot import); the default only lower-cases.
    private let fold: @Sendable (String) -> String

    public init(client: InnerTubeRadioClient, budget: HostBudget,
                fold: @escaping @Sendable (String) -> String = { $0.lowercased() }) {
        self.client = client
        self.budget = budget
        self.fold = fold
    }

    public static let discographyPrefix = "MPAD"
    public static let playlistPrefix = "VL"
    public static let maxPlaylistPages = 3
    public static let hydrateBatch = 100
    public static let hydrateBisectRequests = 3

    public func discography(channelId: String) async -> [ReleaseRef]? {
        guard channelId.hasPrefix("UC") else { return nil }
        let client = self.client
        let id = YouTubeRadioSource.discographyPrefix + channelId
        guard let text = await budget.withPermit({ await client.browseText(id) }) else { return nil }
        return InnerTubeRadio.parseDiscography(text: text)
    }

    public func releaseTracks(_ release: ReleaseRef) async -> [RadioRow]? {
        let client = self.client
        var playlistId = release.audioPlaylistId
        if playlistId == nil {
            guard let album = await budget.withPermit({ await client.browseText(release.browseId) }) else { return nil }
            playlistId = InnerTubeRadio.parseAlbumAudioPlaylistId(text: album)
        }
        guard let playlistId else { return nil }
        return await playlistRows(playlistId: playlistId, maxPages: 1)
    }

    public func playlistRows(playlistId: String, maxPages: Int) async -> [RadioRow]? {
        let client = self.client
        let id = YouTubeRadioSource.playlistPrefix + playlistId
        guard let firstText = await budget.withPermit({ await client.browseText(id) }),
              var page = InnerTubeRadio.parsePlaylistPage(text: firstText) else { return nil }
        var seen: Set<String> = []
        var rows: [RadioRow] = []
        rows.reserveCapacity(page.rows.count)
        for row in page.rows where seen.insert(row.videoId).inserted { rows.append(row) }
        var pages = 1
        while pages < min(max(maxPages, 1), YouTubeRadioSource.maxPlaylistPages) {
            guard let token = page.continuation,
                  let text = await budget.withPermit({ await client.browseContinuation(token) }),
                  let next = InnerTubeRadio.parsePlaylistPage(text: text) else { break }
            page = next
            for row in page.rows where seen.insert(row.videoId).inserted { rows.append(row) }
            pages += 1
        }
        return rows
    }

    public func hydrate(videoIds: [String]) async -> [RadioRow]? {
        var seen: Set<String> = []
        var ids: [String] = []
        for id in videoIds where seen.insert(id).inserted { ids.append(id) }
        ids = Array(ids.prefix(YouTubeRadioSource.hydrateBatch))
        if ids.isEmpty { return [] }
        // One invalid id makes the whole batch a 404: bisect, with a small bound on the extra requests.
        var spare = YouTubeRadioSource.hydrateBisectRequests
        return await fetchQueue(ids, spare: &spare)
    }

    private func fetchQueue(_ part: [String], spare: inout Int) async -> [RadioRow]? {
        let client = self.client
        if let text = await budget.withPermit({ await client.getQueueText(part) }) {
            return InnerTubeRadio.parseGetQueue(text: text)
        }
        if part.count <= 1 || spare <= 0 { return nil }
        spare -= 1
        let half = part.count / 2
        let left = await fetchQueue(Array(part[..<half]), spare: &spare)
        let right = await fetchQueue(Array(part[half...]), spare: &spare)
        if left == nil && right == nil { return nil }
        return (left ?? []) + (right ?? [])
    }

    public func channelId(forArtist artistName: String) async -> String? {
        let key = fold(artistName)
        if key.isEmpty { return nil }
        let client = self.client
        guard let text = await budget.withPermit({ await client.searchSongsText(artistName) }),
              let rows = InnerTubeRadio.parseSongSearch(text: text) else { return nil }
        for row in rows {
            if let ref = row.artists.first(where: { $0.channelId != nil && fold($0.name) == key }) { return ref.channelId }
        }
        return nil
    }

    public func songRadio(videoId: String, continuations: Int) async -> FetchedRadio? {
        let client = self.client
        return await radio(continuations: continuations) {
            await client.nextRadio(videoId: videoId, playlistId: InnerTubeRadio.songRadioPrefix + videoId)
        }
    }

    public func artistRadio(endpoint: RadioEndpoint) async -> FetchedRadio? {
        let client = self.client
        return await radio(continuations: 0) {
            await client.nextRadio(videoId: endpoint.videoId, playlistId: endpoint.playlistId, params: endpoint.params)
        }
    }

    public func related(browseId: String) async -> RelatedPage? {
        let client = self.client
        guard let page = await budget.withPermit({ await client.related(browseId: browseId) }) else { return nil }
        return page.youMightAlsoLike.isEmpty && page.similarArtists.isEmpty ? nil : page
    }

    public func artistPage(channelId: String) async -> ArtistPage? {
        let client = self.client
        guard let page = await budget.withPermit({ await client.artistPage(channelId: channelId) }) else { return nil }
        return page.radio == nil && page.topSongs.isEmpty ? nil : page
    }

    private func radio(continuations: Int, firstPage: @escaping @Sendable () async -> RadioPage?) async -> FetchedRadio? {
        var requests = 0
        var first: RadioPage?
        // A response without the expected renderer is "no data"; an empty radio is retried once.
        for _ in 0..<2 {
            guard let page = await budget.withPermit(firstPage) else { break }
            requests += 1
            first = page
            if !page.rows.isEmpty { break }
        }
        // Nil only when nothing came back at all. A response with no rows is returned as an empty radio: the caller
        // treats it as junk, remembers it, and tries the fallbacks.
        guard let page = first else { return nil }

        var pager = RadioPager()
        pager.accept(page)
        var wanted = min(max(continuations, 0), RadioPager.maxContinuations)
        let client = self.client
        while wanted > 0 {
            guard let token = pager.nextToken,
                  let next = await budget.withPermit({ await client.nextRadioContinuation(token) }) else { break }
            requests += 1
            pager.accept(next)
            wanted -= 1
        }
        return FetchedRadio(rows: pager.rows, chips: page.chips, relatedBrowseId: page.relatedBrowseId, requests: requests)
    }
}
