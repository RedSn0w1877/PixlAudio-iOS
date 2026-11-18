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
                    singles.append(contentsOf: releases)
                } else {
                    albums.append(contentsOf: releases)
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

    static func parseListItemRow(_ renderer: JSONObject) -> RadioRow? {
        let columns: [JSONObject] = (array(renderer, "flexColumns") ?? []).compactMap {
            obj(obj($0.objectValue, "musicResponsiveListItemFlexColumnRenderer"), "text")
        }
        guard let titleColumn = columns.first else { return nil }
        let watch = findFirst(.object(titleColumn), "watchEndpoint")
        guard let videoId = string(watch, "videoId"), !videoId.isKotlinBlank else { return nil }
        let title = runsText(titleColumn)
        if title.isKotlinBlank { return nil }

        // The remaining columns are one byline split across columns.
        var runs: [JSONValue] = []
        var playCount: Int64?
        for i in columns.indices.dropFirst() {
            guard let columnRuns = array(columns[i], "runs") else { continue }
            if !runs.isEmpty { runs.append(separatorRun) }
            for run in columnRuns {
                let text = (string(run.objectValue, "text") ?? "").kotlinTrimmed()
                if let plays = parsePlayCount(text) { playCount = plays } else { runs.append(run) }
            }
        }
        let byline = parseByline(runs)
        let thumbnails = array(findFirst(renderer["thumbnail"], "thumbnail"), "thumbnails")
            ?? findFirstArray(renderer["thumbnail"], "thumbnails")
        return RadioRow(
            videoId: videoId,
            title: title,
            artists: byline.artists,
            album: byline.album,
            albumBrowseId: byline.albumBrowseId,
            year: byline.year,
            durationSec: parseClock(runsText(findFirst(renderer["fixedColumns"], "text"))),
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
        for run in array(obj(renderer, "subtitle"), "runs") ?? [] {
            let text = (string(run.objectValue, "text") ?? "").kotlinTrimmed()
            if let parsed = parseYear(text) { year = parsed }
        }
        return ReleaseRef(browseId: browseId, title: runsText(obj(renderer, "title")), year: year)
    }

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

    public init(client: InnerTubeRadioClient, budget: HostBudget) {
        self.client = client
        self.budget = budget
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
