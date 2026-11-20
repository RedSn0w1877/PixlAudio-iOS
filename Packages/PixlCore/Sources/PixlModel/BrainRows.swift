// Plain rows of the music brain (docs/brain-spec.md, 3.3 and 10.1): what the YouTube Music parsers in PixlNet
// produce and the brain in PixlLibrary consumes. PixlNet and PixlLibrary are siblings, so the types they share
// live here. No JSON tree, no platform type. Mirrors Android's `InnerTubeMusicModels.kt` and `BrainExtras.kt`.

import Foundation
import PixlFoundation

/// An artist credit of a radio row. `channelId` is the `UC...` browse id; nil when the byline run carried no link.
/// (Android `RadioArtistRef`; the spec's `ArtistRef` is already the name of a song's artist here.)
public struct RadioArtistRef: Sendable, Hashable, Codable {
    public var name: String
    public var channelId: String?

    public init(name: String, channelId: String? = nil) {
        self.name = name
        self.channelId = channelId
    }
}

/// What kind of video a row is. Only `atv` (official audio) is a playable candidate in stage 1.
public enum MusicVideoKind: String, Sendable, Hashable, Codable {
    case atv = "ATV"
    case omv = "OMV"
    case ugc = "UGC"
    case podcast = "PODCAST"
    /// The response did not say. Never treated as official audio.
    case unknown = "UNKNOWN"

    public static func from(musicVideoType: String?) -> MusicVideoKind {
        guard let musicVideoType else { return .unknown }
        if musicVideoType.isIdentical(to: "MUSIC_VIDEO_TYPE_ATV") { return .atv }
        if musicVideoType.isIdentical(to: "MUSIC_VIDEO_TYPE_OMV") { return .omv }
        if musicVideoType.isIdentical(to: "MUSIC_VIDEO_TYPE_UGC") { return .ugc }
        if musicVideoType.isIdentical(to: "MUSIC_VIDEO_TYPE_PODCAST_EPISODE") { return .podcast }
        return .unknown
    }
}

/// One track of a radio, a Related shelf or an artist's top songs.
public struct RadioRow: Sendable, Hashable, Codable {
    public var videoId: String
    public var title: String
    /// Credited artists, primary first.
    public var artists: [RadioArtistRef]
    public var album: String?
    /// `MPREb_...`
    public var albumBrowseId: String?
    /// 0 = unknown.
    public var year: Int
    /// 0 = unknown (Related-tab and top-song rows carry no length).
    public var durationSec: Int
    public var thumbnailUrl: String?
    public var explicit: Bool
    public var kind: MusicVideoKind
    /// From "3.4B plays" on an artist page; nil elsewhere.
    public var playCount: Int64?

    public init(videoId: String, title: String, artists: [RadioArtistRef] = [], album: String? = nil,
                albumBrowseId: String? = nil, year: Int = 0, durationSec: Int = 0, thumbnailUrl: String? = nil,
                explicit: Bool = false, kind: MusicVideoKind = .unknown, playCount: Int64? = nil) {
        self.videoId = videoId
        self.title = title
        self.artists = artists
        self.album = album
        self.albumBrowseId = albumBrowseId
        self.year = year
        self.durationSec = durationSec
        self.thumbnailUrl = thumbnailUrl
        self.explicit = explicit
        self.kind = kind
        self.playCount = playCount
    }

    public var isOfficialAudio: Bool { kind == .atv }

    /// "A, B": for display only. Never split this again.
    public var artistDisplay: String { artists.map(\.name).joined(separator: ", ") }
}

/// A tuning chip of a radio ("Popular", "Deep cuts", "V-pop"). Kept as text for stage 2's tag source.
public struct RadioChip: Sendable, Hashable, Codable {
    public var label: String
    public var playlistId: String
    public var params: String?

    public init(label: String, playlistId: String, params: String? = nil) {
        self.label = label
        self.playlistId = playlistId
        self.params = params
    }
}

/// One `next` response: a radio's first page, or a continuation page.
public struct RadioPage: Sendable, Hashable {
    public var rows: [RadioRow]
    /// Token for the next page; nil when the response had none.
    public var continuation: String?
    public var chips: [RadioChip]
    /// `MPTRt_...` of the Related tab; only on a first page.
    public var relatedBrowseId: String?

    public init(rows: [RadioRow], continuation: String?, chips: [RadioChip] = [], relatedBrowseId: String? = nil) {
        self.rows = rows
        self.continuation = continuation
        self.chips = chips
        self.relatedBrowseId = relatedBrowseId
    }

    public static let empty = RadioPage(rows: [], continuation: nil)
}

/// The Related tab of a track.
public struct RelatedPage: Sendable, Hashable {
    public var youMightAlsoLike: [RadioRow]
    /// Other recordings of the same song: a dedupe list, never candidates.
    public var otherPerformances: [RadioRow]
    public var similarArtists: [RadioArtistRef]

    public init(youMightAlsoLike: [RadioRow], otherPerformances: [RadioRow], similarArtists: [RadioArtistRef]) {
        self.youMightAlsoLike = youMightAlsoLike
        self.otherPerformances = otherPerformances
        self.similarArtists = similarArtists
    }

    public static let empty = RelatedPage(youMightAlsoLike: [], otherPerformances: [], similarArtists: [])
}

/// The three values of an artist page's "radio" button, sent back to `next` exactly as they came.
public struct RadioEndpoint: Sendable, Hashable, Codable {
    public var videoId: String?
    public var playlistId: String
    public var params: String?

    public init(videoId: String?, playlistId: String, params: String? = nil) {
        self.videoId = videoId
        self.playlistId = playlistId
        self.params = params
    }
}

/// What a release is, from the subtitle ("Album", "Single", "EP") of its card.
public enum ReleaseKind: String, Sendable, Hashable { case album = "ALBUM", single = "SINGLE", ep = "EP", unknown = "UNKNOWN" }

/// An album, single or EP on an artist page or in the discography (`MPAD...`).
///
/// `audioPlaylistId` is the `OLAK5uy_...` audio playlist the card's "Shuffle play" menu item names, when the response
/// kept the menu: the tracks of a release are read through it (spec 3.3, "Album tracks"), never from the album page
/// itself, whose ids are music videos when anonymous. Nil means "read it from the album page".
public struct ReleaseRef: Sendable, Hashable {
    public var browseId: String
    public var title: String
    public var year: Int
    public var kind: ReleaseKind
    public var audioPlaylistId: String?
    public var thumbnailUrl: String?

    public init(browseId: String, title: String, year: Int = 0, kind: ReleaseKind = .unknown,
                audioPlaylistId: String? = nil, thumbnailUrl: String? = nil) {
        self.browseId = browseId
        self.title = title
        self.year = year
        self.kind = kind
        self.audioPlaylistId = audioPlaylistId
        self.thumbnailUrl = thumbnailUrl
    }
}

/// A playlist page (`browse VL...`) or one of its continuations: rows plus the token of the next page.
public struct PlaylistPage: Sendable, Hashable {
    public var rows: [RadioRow]
    public var continuation: String?

    public init(rows: [RadioRow], continuation: String?) {
        self.rows = rows
        self.continuation = continuation
    }

    public static let empty = PlaylistPage(rows: [], continuation: nil)
}

/// An artist's page: top songs, releases, similar artists and the radio button's endpoint.
public struct ArtistPage: Sendable, Hashable {
    public var name: String
    public var radio: RadioEndpoint?
    public var topSongs: [RadioRow]
    public var albums: [ReleaseRef]
    public var singles: [ReleaseRef]
    public var fansAlsoLike: [RadioArtistRef]

    public init(name: String, radio: RadioEndpoint?, topSongs: [RadioRow], albums: [ReleaseRef], singles: [ReleaseRef],
                fansAlsoLike: [RadioArtistRef]) {
        self.name = name
        self.radio = radio
        self.topSongs = topSongs
        self.albums = albums
        self.singles = singles
        self.fansAlsoLike = fansAlsoLike
    }

    public static let empty = ArtistPage(name: "", radio: nil, topSongs: [], albums: [], singles: [], fansAlsoLike: [])
}

/// A radio as fetched: merged, deduplicated rows and what the first page said about itself. `rows` can be empty: the
/// request was answered, with nothing in it.
public struct FetchedRadio: Sendable, Hashable {
    public var rows: [RadioRow]
    public var chips: [RadioChip]
    /// `MPTRt_...` of the seed's Related tab, when the response named one.
    public var relatedBrowseId: String?
    /// How many network requests this took (first page, retry, continuations).
    public var requests: Int
    /// The token of the page after the last one taken, when the chain goes on: a later deepening starts from it and
    /// does not fetch page one again.
    public var continuation: String?

    public init(rows: [RadioRow], chips: [RadioChip] = [], relatedBrowseId: String? = nil, requests: Int = 1,
                continuation: String? = nil) {
        self.continuation = continuation
        self.rows = rows
        self.chips = chips
        self.relatedBrowseId = relatedBrowseId
        self.requests = requests
    }
}

/// A radio row with the recording id it resolved to (what a stored list holds).
public struct StoredRadioRow: Sendable, Hashable, Codable {
    public var row: RadioRow
    public var rid: Int64

    public init(row: RadioRow, rid: Int64) {
        self.row = row
        self.rid = rid
    }
}

/// One stored list of related music (`radio_list`, 3.8): parsed rows, never raw JSON.
public struct RadioList: Sendable, Hashable {
    /// The song radio of the seed.
    public static let kindSong = 0
    /// The Related tab's "You might also like".
    public static let kindRelated = 1
    /// The radio of the seed's primary artist.
    public static let kindArtist = 2

    public var seedRid: Int64
    public var kind: Int
    /// "" for the plain list; "+pages" for a song radio stored with its continuation pages.
    public var chip: String
    public var fetchedAt: Int64
    public var lastUsedAt: Int64
    /// False for a seed whose radio was junk: remembered so it is not asked again for a day.
    public var healthy: Bool
    public var rows: [StoredRadioRow]
    public var chips: [RadioChip]
    /// The token of the radio's next page, when the list is the first pages of a chain that goes on (deepening starts
    /// from it, so page one is not fetched again).
    public var continuation: String?

    public init(seedRid: Int64, kind: Int, chip: String, fetchedAt: Int64, lastUsedAt: Int64, healthy: Bool,
                rows: [StoredRadioRow], chips: [RadioChip], continuation: String? = nil) {
        self.continuation = continuation
        self.seedRid = seedRid
        self.kind = kind
        self.chip = chip
        self.fetchedAt = fetchedAt
        self.lastUsedAt = lastUsedAt
        self.healthy = healthy
        self.rows = rows
        self.chips = chips
    }
}

// MARK: - Junk detector and page merging (3.3, parser rules 5 and 6)

/// The rules a radio is judged by before it is stored.
public enum RadioRules {
    /// Fewer rows than this in a radio's first page means the radio is junk.
    public static let junkMinRows = 40
    /// The seed's artist must show up again within this many rows after the seed.
    public static let junkArtistWindow = 25

    /// True when a radio's first page should not be stored (rule 6): fewer than 40 rows, or no row among rows 1..25
    /// shares an artist with the seed. `seedArtistIds` are channel ids; a row without an artist id is kept but can
    /// never satisfy the test. When the seed has no channel id at all (a row whose byline is not linked) the test
    /// falls back to the folded artist name, so such a seed is not junk by construction.
    ///
    /// `fold` is the brain's text folding (`BrainText.fold` in PixlLibrary, which this module cannot import).
    public static func isJunkRadio(rows: [RadioRow], seedVideoId: String?, seedArtistIds: Set<String>,
                                   seedArtistNames: [String] = [], fold: (String) -> String) -> Bool {
        if rows.count < junkMinRows { return true }
        var seedIndex = 0
        if let seedVideoId, let found = rows.firstIndex(where: { $0.videoId.isIdentical(to: seedVideoId) }) {
            seedIndex = found
        }
        let seedRow = rows[seedIndex]
        var ids = Set<[UInt8]>()
        if seedArtistIds.isEmpty {
            for artist in seedRow.artists { if let id = artist.channelId { ids.insert(Array(id.utf8)) } }
        } else {
            for id in seedArtistIds { ids.insert(Array(id.utf8)) }
        }
        var names = Set<[UInt8]>()
        if ids.isEmpty {
            for name in seedArtistNames + seedRow.artists.map(\.name) {
                let folded = fold(name)
                if !folded.isEmpty { names.insert(Array(folded.utf8)) }
            }
        }
        if ids.isEmpty && names.isEmpty { return true }
        var checked = 0
        for i in rows.indices {
            if i == seedIndex { continue }
            if checked >= junkArtistWindow { break }
            checked += 1
            let row = rows[i]
            if !ids.isEmpty {
                if row.artists.contains(where: { artist in
                    guard let id = artist.channelId else { return false }
                    return ids.contains(Array(id.utf8))
                }) { return false }
            } else if row.artists.contains(where: { names.contains(Array(fold($0.name).utf8)) }) {
                return false
            }
        }
        return true
    }
}

/// Merges a radio's pages (rule 5): continuation pages repeat earlier rows, so a page counts by its new video ids,
/// never by its length. Stop on a missing token, after `maxContinuations` continuations, or when two pages in a row
/// add fewer than `minNewPerPage` new ids.
///
/// Rows are deduplicated by video id here; the caller dedupes again by recording id, because one recording appears
/// under several audio ids.
public struct RadioPager: Sendable {
    public static let maxContinuations = 3
    public static let minNewPerPage = 5

    private var seen = Set<[UInt8]>()
    public private(set) var rows: [RadioRow] = []
    private var continuationsTaken = 0
    private var poorPagesInARow = 0
    private var pages = 0
    /// Token to request next, or nil when the chain is over.
    public private(set) var nextToken: String?
    /// New ids each accepted page added, in order.
    public private(set) var newPerPage: [Int] = []

    public init() {}

    /// Adds one page and returns how many new rows it brought.
    @discardableResult
    public mutating func accept(_ page: RadioPage) -> Int {
        var added = 0
        for row in page.rows where seen.insert(Array(row.videoId.utf8)).inserted {
            rows.append(row)
            added += 1
        }
        newPerPage.append(added)
        if pages > 0 {
            continuationsTaken += 1
            poorPagesInARow = added < Self.minNewPerPage ? poorPagesInARow + 1 : 0
        }
        pages += 1
        if let token = page.continuation, continuationsTaken < Self.maxContinuations, poorPagesInARow < 2 {
            nextToken = token
        } else {
            nextToken = nil
        }
        return added
    }
}

// MARK: - Where a queue item came from (4.2)

/// The context a queue item carries about where it came from. It is kept on the queue entry and saved with the
/// queue (`PlaybackQueueItemSnapshot`), so it survives a restart.
///
/// An item with an arm (`isEngineOwned`, in PixlLibrary) was put in the queue by the engine: it sits under the
/// Autoplay line. An item without one was chosen by the listener and is never touched.
public struct BrainItemTag: Sendable, Hashable {
    public static let maxSurfaceIdLength = 40

    /// `Surface` name: "autoplay", "station", ...
    public var surface: String?
    /// Shelf id, mix id, hashed playlist id, or a station's seed. 40 characters at most.
    public var surfaceId: String?
    /// The list this pick was part of; 0 when the play was not a recommendation.
    public var recId: Int64
    /// Position in that list; -1 when the play was not a recommendation.
    public var slot: Int
    /// `Arm` name: "RADIO", "FAV", ...; nil for a track the listener chose.
    public var arm: String?
    /// The name the reason is about ("Fans of X also play this"); display only.
    public var whyArg: String?
    /// The pick's best radio rank at serve time, -1 when it had none.
    public var radioRank: Int
    /// The pick's retrieval percentile x 1000 at serve time, -1 when it had none.
    public var retrQ: Int
    /// The reason key of the pick (`WhyLine` name: "radio_fans", ...); nil for none.
    public var whyKey: String?
    /// ONE artist name: the track's own primary artist, when whoever queued it knew.
    public var primaryArtist: String?
    /// The listener put this pick in the queue themselves (they played a Home row): it has an `arm`, because it
    /// was a recommendation, but it is theirs like a playlist's track, not the engine's tail.
    public var chosen: Bool
    /// The list this pick came from was ranked with the prior because its session is a control session (5.12 point 8).
    /// Decided when the list was built and carried with the queue entry, never worked out when the play ends.
    public var control: Bool
    /// `play_event.modelVersion` the list was ranked with (1: the learned weights, 0: the prior); -1 when not recorded
    /// (an old queue entry).
    public var modelVersion: Int
    /// The pick filled a novel slot the arm bandit drew (5.10): an exploration slot, logged with `EventFlags.exploreSlot`.
    public var explore: Bool

    public init(surface: String? = nil, surfaceId: String? = nil, recId: Int64 = 0, slot: Int = -1, arm: String? = nil,
                whyArg: String? = nil, radioRank: Int = -1, retrQ: Int = -1, whyKey: String? = nil,
                primaryArtist: String? = nil, chosen: Bool = false, control: Bool = false, modelVersion: Int = -1,
                explore: Bool = false) {
        self.surface = surface
        self.surfaceId = surfaceId.map { String($0.unicodeScalars.prefix(Self.maxSurfaceIdLength)) }
        self.recId = recId
        self.slot = slot
        self.arm = arm
        self.whyArg = whyArg
        self.radioRank = radioRank
        self.retrQ = retrQ
        self.whyKey = whyKey
        self.primaryArtist = primaryArtist
        self.chosen = chosen
        self.control = control
        self.modelVersion = modelVersion
        self.explore = explore
    }

    /// True when nothing is set: such a tag is not saved with the queue.
    public var isEmpty: Bool {
        surface == nil && surfaceId == nil && recId == 0 && slot < 0 && arm == nil && whyKey == nil && whyArg == nil
            && primaryArtist == nil && !chosen && retrQ < 0 && radioRank < 0 && !control && modelVersion < 0 && !explore
    }
}

extension PlaybackQueueItemSnapshot {
    /// The item's brain context, or nil when it has none (a track the listener chose, an old snapshot).
    public func brainTag() -> BrainItemTag? {
        let tag = BrainItemTag(surface: brainSurface, surfaceId: brainSurfaceId, recId: brainRecId ?? 0,
                               slot: brainSlot ?? -1, arm: brainArm, whyArg: brainWhyArg,
                               radioRank: brainRadioRank ?? -1, retrQ: brainRetrQ ?? -1, whyKey: brainWhyKey,
                               primaryArtist: brainPrimaryArtist, chosen: brainChosen == true, control: brainControl == true,
                               modelVersion: brainModel ?? -1, explore: brainExplore == true)
        return tag.isEmpty ? nil : tag
    }

    /// The same item carrying `tag` (unchanged for nil or an empty tag).
    public func withBrainTag(_ tag: BrainItemTag?) -> PlaybackQueueItemSnapshot {
        guard let tag, !tag.isEmpty else { return self }
        var copy = self
        copy.brainSurface = tag.surface
        copy.brainSurfaceId = tag.surfaceId
        copy.brainRecId = tag.recId != 0 ? tag.recId : nil
        copy.brainSlot = tag.slot >= 0 ? tag.slot : nil
        copy.brainArm = tag.arm
        copy.brainWhyKey = tag.whyKey
        copy.brainWhyArg = tag.whyArg
        copy.brainPrimaryArtist = tag.primaryArtist
        copy.brainChosen = tag.chosen ? true : nil
        copy.brainRetrQ = tag.retrQ >= 0 ? tag.retrQ : nil
        copy.brainRadioRank = tag.radioRank >= 0 ? tag.radioRank : nil
        copy.brainControl = tag.control ? true : nil
        copy.brainModel = tag.modelVersion >= 0 ? tag.modelVersion : nil
        copy.brainExplore = tag.explore ? true : nil
        return copy
    }
}

// MARK: - Where related music comes from (2.1)

/// Where related music comes from. The brain talks to this interface, so the YouTube Music source can be switched
/// off or replaced without touching what uses it. Every call returns nil when the source is unavailable, over
/// budget, or had no data: never an error.
public protocol RadioSource: Sendable {
    /// The radio of one song: seed first, then up to `continuations` further pages merged by video id.
    func songRadio(videoId: String, continuations: Int) async -> FetchedRadio?
    /// The Related tab of a track.
    func related(browseId: String) async -> RelatedPage?
    /// An artist's page: top songs, releases, similar artists and the radio button's endpoint.
    func artistPage(channelId: String) async -> ArtistPage?
    /// An artist radio, from the endpoint an artist page carried.
    func artistRadio(endpoint: RadioEndpoint) async -> FetchedRadio?
    /// Up to `pages` further pages of a radio, from the token its first page named: only the new rows, no page one.
    func songRadioContinuation(token: String, pages: Int) async -> FetchedRadio?
    /// The whole discography of an artist (`MPAD<channelId>`), newest first. Nil when the source is unavailable or over
    /// budget; an empty list when the answer had no releases.
    func discography(channelId: String) async -> [ReleaseRef]?
    /// The tracks of one release, read through its audio playlist (3.3, "Album tracks"): the playlist id the card
    /// carried, else one album-page request to read it. Nil when nothing could be read.
    func releaseTracks(_ release: ReleaseRef) async -> [RadioRow]?
    /// Up to `maxPages` pages of a playlist (`VL<playlistId>`), rows deduplicated by video id.
    func playlistRows(playlistId: String, maxPages: Int) async -> [RadioRow]?
    /// `music/get_queue`: full rows for video ids. An id the source does not know is left out.
    func hydrate(videoIds: [String]) async -> [RadioRow]?
    /// The `UC...` channel id of the artist called `artistName`, from a songs search; nil when none matches.
    func channelId(forArtist artistName: String) async -> String?
}

public extension RadioSource {
    func songRadioContinuation(token: String, pages: Int) async -> FetchedRadio? { nil }
    func discography(channelId: String) async -> [ReleaseRef]? { nil }
    func releaseTracks(_ release: ReleaseRef) async -> [RadioRow]? { nil }
    func playlistRows(playlistId: String, maxPages: Int) async -> [RadioRow]? { nil }
    func hydrate(videoIds: [String]) async -> [RadioRow]? { nil }
    func channelId(forArtist artistName: String) async -> String? { nil }
}

/// One token bucket and one parallelism limit per host (docs/brain-spec.md, 2.1 and 12.1). Stage 1 has a single
/// bucket, for YouTube Music: radios are fetched on demand while music plays, about 2 per 10 autoplayed tracks, at
/// most `dailyLimit` requests in any 24 hours and `maxParallel` at a time.
///
/// The shape is a large burst and a slow trickle: `burst` requests may go out as fast as they are asked for (an
/// evening of tapping songs and starting stations), and the rest of the day's allowance comes back one request at
/// a time. Twelve and then one per 24 minutes, as it first was, left a listener on library-only picks after an
/// hour of ordinary use.
///
/// The bucket lives in memory; the caller also counts the radios stored in the last 24 hours, so a restart cannot
/// reset the daily limit.
public actor HostBudget {
    public static let dailyLimit = 60
    public static let maxParallel = 2
    /// Requests that may go out back to back.
    public static let burst = 24
    public static let dayMs: Int64 = 24 * 60 * 60 * 1000
    /// One request comes back this often: what is left of the day's allowance after the burst, spread over the day.
    public static let refillIntervalMs: Int64 = dayMs / Int64(dailyLimit - burst)

    private let capacity: Int
    private let refillIntervalMs: Int64
    private let parallelLimit: Int
    private let clock: @Sendable () -> Int64
    private var tokens: Int
    private var lastRefillMs: Int64
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(capacity: Int = HostBudget.burst, refillIntervalMs: Int64 = HostBudget.refillIntervalMs,
                maxParallel: Int = HostBudget.maxParallel,
                clock: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        self.capacity = capacity
        self.refillIntervalMs = max(refillIntervalMs, 1)
        parallelLimit = max(maxParallel, 1)
        self.clock = clock
        tokens = capacity
        lastRefillMs = clock()
    }

    /// Takes one token when there is one.
    public func tryAcquire() -> Bool {
        refill()
        if tokens <= 0 { return false }
        tokens -= 1
        return true
    }

    public func available() -> Int {
        refill()
        return tokens
    }

    /// Runs `block` under the parallelism limit when a token is available; nil when the budget is spent.
    public func withPermit<T: Sendable>(_ block: @Sendable () async -> T?) async -> T? {
        guard tryAcquire() else { return nil }
        if running < parallelLimit {
            running += 1
        } else {
            // The slot is handed over by the request that finishes: `running` stays as it is.
            await withCheckedContinuation { waiters.append($0) }
        }
        let result = await block()
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
        return result
    }

    private func refill() {
        let now = clock()
        if now < lastRefillMs {
            // The clock went back: start counting again from now, keep what is left.
            lastRefillMs = now
            return
        }
        let earned = (now - lastRefillMs) / refillIntervalMs
        if earned > 0 {
            tokens = Int(min(Int64(capacity), Int64(tokens) + earned))
            lastRefillMs += earned * refillIntervalMs
        }
    }
}


/// What the Spotify Web API already returns with a track and the app used to throw away (docs/brain-spec.md, 3.3 B,
/// 13.1): the artists' Spotify ids, the album and its release date, whether the track is explicit.
public struct SpotifyFactInput: Sendable, Hashable, Codable {
    public var spotifyId: String
    public var isrc: String?
    /// Spotify artist ids, the primary artist first.
    public var artistIds: [String]
    public var albumId: String?
    /// `YYYY`, `YYYY-MM` or `YYYY-MM-DD`, as Spotify gave it; nil when it gave none.
    public var releaseDate: String?
    /// `year`, `month` or `day`.
    public var releasePrecision: String?
    /// Nil when Spotify did not say.
    public var explicit: Bool?

    public init(spotifyId: String, isrc: String? = nil, artistIds: [String] = [], albumId: String? = nil,
                releaseDate: String? = nil, releasePrecision: String? = nil, explicit: Bool? = nil) {
        self.spotifyId = spotifyId
        self.isrc = isrc
        self.artistIds = artistIds
        self.albumId = albumId
        self.releaseDate = releaseDate
        self.releasePrecision = releasePrecision
        self.explicit = explicit
    }
}

/// Where the Spotify sync hands those facts: called from the one place that maps a Spotify track to a library row, so
/// a sync pays nothing for it. The implementation queues and writes them a moment later, off the sync's path.
public protocol SpotifyFactsSink: Sendable {
    func record(_ fact: SpotifyFactInput)
}
