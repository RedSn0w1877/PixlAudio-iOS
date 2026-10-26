// YouTube Music listening history (spec B1, second source): the signed-in history page (`browse` FEmusic_history) on
// the WEB_REMIX client — the music.youtube.com web client, which is in yt-dlp's SUPPORTS_COOKIES, so the cookie and
// its SAPISIDHASH may go to it (the native clients answer 400 to a cookie and are never used here). The page lists each
// song once, under its latest day ("Today", "Yesterday", "This week", "Last week", "March 2026"…), without exact times:
// a play's time is the middle of its section, kept in page order. Fragile by nature — any failure returns nil and only
// means less data.

import Foundation
import PixlFoundation
import PixlModel

/// One history-page entry.
public struct YouTubeMusicHistoryEntry: Sendable, Hashable {
    public var section: String
    public var item: YouTubeSearchResult

    public init(section: String, item: YouTubeSearchResult) {
        self.section = section
        self.item = item
    }
}

public enum YouTubeMusicHistoryParsing {
    public static let browseId = "FEmusic_history"

    /// The entries of a history page (or continuation) and the next continuation token.
    public static func entries(_ json: JSONObject) -> (entries: [YouTubeMusicHistoryEntry], continuation: String?) {
        var entries: [YouTubeMusicHistoryEntry] = []
        InnerTubeParsing.collectByKey(.object(json), "musicShelfRenderer") { shelf in
            let title = InnerTubeParsing.collectRuns(OrgJSON.optObject(shelf, "title")).joined()
            InnerTubeParsing.collectByKey(OrgJSON.optArray(shelf, "contents").map { .array($0) } ?? .null,
                                          "musicResponsiveListItemRenderer") { renderer in
                if let item = InnerTubeParsing.searchItem(renderer) {
                    entries.append(YouTubeMusicHistoryEntry(section: NetText.trim(title), item: item))
                }
                return true
            }
            return true
        }
        var continuation: String?
        InnerTubeParsing.collectByKey(.object(json), "nextContinuationData") { data in
            let token = OrgJSON.optString(data, "continuation")
            if !NetText.isBlank(token) { continuation = token }
            return continuation == nil
        }
        return (entries, continuation)
    }

    private static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september",
                                 "october", "november", "december"]

    /// The time a section stands for ("Today" → now, "Yesterday" → yesterday noon, "This week" → 3 days ago,
    /// "Last week" → 10 days ago, "Last month" → 45 days ago, "March 2026" / "March" → the 15th at noon).
    public static func sectionTime(_ title: String, nowMs: Int64, timeZone: TimeZone) -> Int64 {
        let day: Int64 = 86_400_000
        let lower = title.lowercased().trimmingCharacters(in: .whitespaces)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let now = Date(timeIntervalSince1970: Double(nowMs) / 1000)
        let startOfToday = Int64(calendar.startOfDay(for: now).timeIntervalSince1970 * 1000)
        switch lower {
        case "today": return nowMs
        case "yesterday": return startOfToday - day / 2
        case "this week": return nowMs - 3 * day
        case "last week": return nowMs - 10 * day
        case "this month": return nowMs - 15 * day
        case "last month": return nowMs - 45 * day
        case "this year": return nowMs - 120 * day
        case "last year": return nowMs - 500 * day
        default: break
        }
        let words = lower.split(separator: " ")
        if let first = words.first, let monthIndex = months.firstIndex(of: String(first)) {
            let thisYear = calendar.component(.year, from: now)
            var year = words.count > 1 ? Int(words[1]) ?? thisYear : thisYear
            var components = DateComponents(year: year, month: monthIndex + 1, day: 15, hour: 12)
            if var date = calendar.date(from: components) {
                if words.count == 1, date > now {
                    year -= 1
                    components.year = year
                    date = calendar.date(from: components) ?? date
                }
                return min(Int64(date.timeIntervalSince1970 * 1000), nowMs)
            }
        }
        return nowMs - 30 * day
    }

    /// The entries as plays: each section's time, a minute earlier per place so the page order is kept.
    public static func plays(_ entries: [YouTubeMusicHistoryEntry], nowMs: Int64, timeZone: TimeZone) -> [ImportedPlay] {
        var indexInSection: [String: Int64] = [:]
        return entries.compactMap { entry in
            let item = entry.item
            guard !NetText.isBlank(item.title) else { return nil }
            let index = indexInSection[entry.section, default: 0]
            indexInSection[entry.section] = index + 1
            let ts = sectionTime(entry.section, nowMs: nowMs, timeZone: timeZone) - index * 60_000
            return ImportedPlay(source: .ytmusic, timestampMs: ts, title: item.title, artist: item.artist,
                                album: item.album, videoId: item.videoId,
                                durationMs: Int64(item.durationSeconds ?? 0) * 1000)
        }
    }
}

/// Reads the signed-in history page. Only with a cookie (the device-code sign-in has no cookie and is not used).
public struct YouTubeMusicHistoryClient: Sendable {
    public static let maxPages = 6

    private let http: any HTTPClient
    private let session: any YouTubeSessionProviding

    public init(http: any HTTPClient, session: any YouTubeSessionProviding) {
        self.http = http
        self.session = session
    }

    /// The history page as plays, or nil when signed out or YouTube refused (a failure is silent: less data).
    public func fetchPlays(nowMs: Int64, timeZone: TimeZone) async -> [ImportedPlay]? {
        let profile = InnerTubeContexts.webRemix
        guard profile.supportsCookies, let cookie = await session.cookie() else { return nil }
        let origin = InnerTubeContexts.originFor(profile)
        let visitorData = await session.storedVisitorData()
        var entries: [YouTubeMusicHistoryEntry] = []
        var continuation: String?
        for page in 0..<Self.maxPages {
            if page > 0 && continuation == nil { break }
            guard let authorization = YouTubeCookieAuth.sapisidHashAuthorization(
                cookie: cookie, origin: origin, timestampSeconds: session.nowSeconds()) else { return nil }
            let body = InnerTubeRequests.browseBody(browseId: page == 0 ? YouTubeMusicHistoryParsing.browseId : nil,
                                                    continuation: continuation, visitorData: visitorData, profile: profile)
            let request = InnerTubeRequests.post(path: "browse", body: body, profile: profile, cookie: cookie,
                                                 sapisidAuthorization: authorization, origin: origin, timeout: 20)
            guard let response = try? await http.send(request), response.isSuccessful,
                  let json = OrgJSON.parse(response.body)?.objectValue else {
                if page == 0 { return nil }
                break
            }
            let parsed = YouTubeMusicHistoryParsing.entries(json)
            entries += parsed.entries
            continuation = parsed.continuation
            if parsed.entries.isEmpty { break }
        }
        return YouTubeMusicHistoryParsing.plays(entries, nowMs: nowMs, timeZone: timeZone)
    }
}
