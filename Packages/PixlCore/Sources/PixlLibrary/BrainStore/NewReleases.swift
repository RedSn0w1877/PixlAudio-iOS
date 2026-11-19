// New releases by the artists the listener plays (docs/brain-spec.md, 6.3, 8.1), found by the refresh and saved in one
// small file that Home reads without the brain's state. A port of Android's `NewReleases.kt`.
//
// The rules (`NewReleaseRules`) are pure and tested without any I/O. `NewReleases.check` asks about one artist: the
// artist page (the cards of the albums and of the singles and EPs), the whole discography when a carousel was full,
// the audio playlist of each release that is news (at most two per artist), and nothing else. Every request goes
// through the `RadioSource`'s `HostBudget` and is noted in the file, so the refresh's daily share counts them.

import Foundation
import PixlModel

/// What the brain knows about the releases of one artist the listener plays: the `MPREb_` ids it has seen, and the
/// folded titles of those releases (a "new" id whose title matches an older release is a re-release, not news).
public struct ArtistReleaseState: Sendable, Hashable, Codable {
    public var channelId: String
    public var name: String
    public var knownIds: [String] = []
    public var knownTitles: [String] = []
    public var checkedAtMs: Int64 = 0

    public init(channelId: String, name: String, knownIds: [String] = [], knownTitles: [String] = [], checkedAtMs: Int64 = 0) {
        self.channelId = channelId
        self.name = name
        self.knownIds = knownIds
        self.knownTitles = knownTitles
        self.checkedAtMs = checkedAtMs
    }
}

/// One release that was new when the artist was checked, with its playable tracks.
public struct FoundRelease: Sendable, Hashable, Codable {
    public var channelId: String
    public var artistName: String
    public var browseId: String
    public var title: String
    public var year: Int
    public var kind: String
    public var foundAtMs: Int64
    public var rows: [StoredRadioRow]

    public init(channelId: String, artistName: String, browseId: String, title: String, year: Int, kind: ReleaseKind,
                foundAtMs: Int64, rows: [StoredRadioRow]) {
        self.channelId = channelId
        self.artistName = artistName
        self.browseId = browseId
        self.title = title
        self.year = year
        self.kind = kind.rawValue
        self.foundAtMs = foundAtMs
        self.rows = rows
    }
}

/// The whole saved state of the New releases row: one small file, never the brain's tables.
public struct NewReleaseFile: Sendable, Hashable, Codable {
    public var v: Int = 1
    public var artists: [ArtistReleaseState] = []
    public var found: [FoundRelease] = []
    /// When the releases lane spent a network request, newest last: the daily budget counts these.
    public var requests: [Int64] = []

    public init(artists: [ArtistReleaseState] = [], found: [FoundRelease] = [], requests: [Int64] = []) {
        self.artists = artists
        self.found = found
        self.requests = requests
    }

    // A file written by a version that lacked a field still reads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        artists = try c.decodeIfPresent([ArtistReleaseState].self, forKey: .artists) ?? []
        found = try c.decodeIfPresent([FoundRelease].self, forKey: .found) ?? []
        requests = try c.decodeIfPresent([Int64].self, forKey: .requests) ?? []
    }

    enum Keys: String, CodingKey { case v, artists, found, requests }
}

/// The pure rules of 6.3: what is new, and which cards of it a row shows.
public enum NewReleaseRules {
    /// A carousel on an artist page holds 10 cards; at 10 it may be cut short, so the discography is read.
    public static let carouselFull = 10
    /// At most this many new releases of one artist are looked into per check.
    public static let maxNewPerArtist = 2
    /// A found release stays on the row this long (feature 39 of 5.8: "first seen in the last 28 days").
    public static let freshMs: Int64 = 28 * 24 * 60 * 60 * 1000
    /// An artist checked this recently is not asked again.
    public static let recheckMs: Int64 = 20 * 60 * 60 * 1000
    public static let maxKnownIds = 300
    public static let maxFound = 40
    public static let cards = 12
    public static let maxCardsPerRelease = 3
    public static let maxCardsPerArtist = 2
    /// A row with fewer cards than this is hidden, not padded (8.1 page rules).
    public static let minCards = 6
    public static let minDurationS = 60
    public static let maxDurationS = 900

    public static func titleKey(_ title: String) -> String { BrainText.fold(BrainText.cleanTitle(title).title) }

    /// Release dates are year-only on YouTube Music: the year must be this one (or last, during January).
    public static func isCurrentYear(_ year: Int, nowYear: Int, nowMonth: Int) -> Bool {
        year == nowYear || (nowMonth == 1 && year == nowYear - 1)
    }

    public struct Diff: Sendable, Equatable {
        /// The releases to look into, newest first. Empty on a baseline.
        public var surfaced: [ReleaseRef]
        public var knownIds: [String]
        public var knownTitles: [String]
        public var baseline: Bool
    }

    /// Compares `found` with what was known. The first look at an artist is a baseline and surfaces nothing. Afterwards
    /// an id not seen before is news unless its folded title matches an older release of the same artist (a re-release
    /// under a new id), its year is not the current one, or an earlier card of this same check already carries the
    /// title. Every id seen is remembered, news or not, so it is judged once.
    public static func diff(known: ArtistReleaseState?, found: [ReleaseRef], nowYear: Int, nowMonth: Int) -> Diff {
        var ids = OrderedSet(known?.knownIds ?? [])
        var titles = OrderedSet(known?.knownTitles ?? [])
        guard let known else {
            for release in found {
                ids.insert(release.browseId)
                titles.insert(titleKey(release.title))
            }
            return Diff(surfaced: [], knownIds: capped(ids), knownTitles: capped(titles), baseline: true)
        }
        var surfaced: [ReleaseRef] = []
        let titlesAtStart = Set(titles.items)
        var seenNow: Set<String> = []
        let knownIds = Set(known.knownIds)
        for release in found {
            if knownIds.contains(release.browseId) { continue }
            ids.insert(release.browseId)
            let key = titleKey(release.title)
            let repeated = key.isEmpty || titlesAtStart.contains(key) || !seenNow.insert(key).inserted
            titles.insert(key)
            if repeated || !isCurrentYear(release.year, nowYear: nowYear, nowMonth: nowMonth) { continue }
            surfaced.append(release)
        }
        return Diff(surfaced: surfaced, knownIds: capped(ids), knownTitles: capped(titles), baseline: false)
    }

    struct OrderedSet {
        private(set) var items: [String] = []
        private var seen: Set<String> = []
        init(_ values: [String]) { for v in values { insert(v) } }
        mutating func insert(_ value: String) { if seen.insert(value).inserted { items.append(value) } }
    }

    private static func capped(_ set: OrderedSet) -> [String] {
        set.items.count <= maxKnownIds ? set.items : Array(set.items.suffix(maxKnownIds))
    }

    /// The tracks of a release worth a card: official audio of a sane length, with an artist.
    public static func usable(_ row: RadioRow) -> Bool {
        row.isOfficialAudio && !row.artists.isEmpty
            && (row.durationSec == 0 || (row.durationSec >= minDurationS && row.durationSec <= maxDurationS))
    }

    public struct Card: Sendable, Equatable {
        public var release: FoundRelease
        public var stored: StoredRadioRow
    }

    /// The cards of the row: the newest releases first, up to `maxCardsPerRelease` tracks of each, at most
    /// `maxCardsPerArtist` per artist, `cards` in all, a recording once.
    public static func cards(found: [FoundRelease], nowMs: Int64, accept: (StoredRadioRow) -> Bool = { _ in true }) -> [Card] {
        var out: [Card] = []
        var perArtist: [String: Int] = [:]
        var rids: Set<Int64> = []
        let fresh = found.filter { nowMs - $0.foundAtMs >= 0 && nowMs - $0.foundAtMs < freshMs }
            .sorted { $0.foundAtMs > $1.foundAtMs }
        for release in fresh {
            var taken = 0
            for stored in release.rows {
                if out.count >= cards { return out }
                if taken >= maxCardsPerRelease { break }
                if (perArtist[release.channelId] ?? 0) >= maxCardsPerArtist { break }
                if stored.rid == 0 || rids.contains(stored.rid) || !accept(stored) { continue }
                rids.insert(stored.rid)
                perArtist[release.channelId, default: 0] += 1
                out.append(Card(release: release, stored: stored))
                taken += 1
            }
        }
        return out
    }
}

/// Where the New releases state is kept: a file in the app, memory in tests.
public protocol ReleaseFileStore: Sendable {
    func read() -> NewReleaseFile
    func write(_ file: NewReleaseFile)
}

public final class AtomicReleaseFileStore: ReleaseFileStore, @unchecked Sendable {
    public static let fileName = "brain_new_releases_v1.json"
    static let maxFileBytes = 1024 * 1024
    private let url: URL

    public init(directory: URL) { url = directory.appendingPathComponent(Self.fileName, isDirectory: false) }

    public func read() -> NewReleaseFile {
        guard let data = try? Data(contentsOf: url), !data.isEmpty, data.count <= Self.maxFileBytes,
              let file = try? JSONDecoder().decode(NewReleaseFile.self, from: data), file.v >= 1, file.v <= 1 else {
            return NewReleaseFile()
        }
        return file
    }

    public func write(_ file: NewReleaseFile) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// What Home and the player need to play a brain row: its cards, and what each carries into the queue.
public struct BrainReleaseRow: Sendable, Hashable, Identifiable {
    public static let id = "brain_new_releases"
    /// Low byte of the row's `recId`, apart from Home rows (0xF0) and the autoplay batches' sequence numbers.
    static let recTag: Int64 = 0xF2

    public var id: String { Self.id }
    public var recId: Int64
    public var items: [BrainHomeItem]
    /// The artist each card is about, by song id: its reason line reads "New from <artist>".
    public var artistBySongId: [String: String]

    public static func recId(builtAtMs: Int64) -> Int64 { (builtAtMs << 8) | recTag }

    public func tags() -> [String: BrainItemTag] {
        var out: [String: BrainItemTag] = [:]
        out.reserveCapacity(items.count)
        for item in items {
            let artist = item.track.artists.first?.name
            out[item.track.songId] = BrainItemTag(
                surface: Surface.nameOf(Surface.homeShelf), surfaceId: Self.id, recId: recId, slot: item.slot,
                arm: Arm.nameOf(Arm.new), whyArg: artistBySongId[item.track.songId], radioRank: item.radioRank,
                retrQ: item.retrQ, whyKey: WhyLine.nameOf(WhyLine.newRelease),
                primaryArtist: artist.flatMap { BrainText.isBlank($0) ? nil : $0 }, chosen: true)
        }
        return out
    }

    /// What a card says under its title: "New from <artist>".
    public func cardReason(_ item: BrainHomeItem) -> WhyLineText.Line? {
        WhyLineText.line(key: WhyLine.newRelease, arg: artistBySongId[item.track.songId])
    }
}

/// The local calendar, for the year rule of 6.3.
public enum NewReleaseCalendar {
    public static func localYearAndMonth(_ ms: Int64) -> (year: Int, month: Int) {
        let parts = Calendar.current.dateComponents([.year, .month], from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
        return (parts.year ?? 1970, parts.month ?? 1)
    }
}

/// New releases by the artists the listener plays.
public actor NewReleases {
    private static let dayMs: Int64 = 24 * 60 * 60 * 1000

    private let store: any ReleaseFileStore
    private let source: (any RadioSource)?
    private let repository: BrainRepository
    private let clock: @Sendable () -> Int64
    private let yearAndMonth: @Sendable (Int64) -> (year: Int, month: Int)
    private var memory: NewReleaseFile?
    private var busy = false

    /// The app's: the clock is the wall clock and the year and month are the local ones.
    public init(store: any ReleaseFileStore, source: (any RadioSource)?, repository: BrainRepository) {
        self.store = store
        self.source = source
        self.repository = repository
        clock = { currentTimeMillis() }
        yearAndMonth = { NewReleaseCalendar.localYearAndMonth($0) }
    }

    /// Tests: the clock and the calendar are given.
    public init(store: any ReleaseFileStore, source: (any RadioSource)?, repository: BrainRepository,
                clock: @escaping @Sendable () -> Int64, yearAndMonth: @escaping @Sendable (Int64) -> (year: Int, month: Int)) {
        self.store = store
        self.source = source
        self.repository = repository
        self.clock = clock
        self.yearAndMonth = yearAndMonth
    }

    private func state() -> NewReleaseFile {
        if let memory { return memory }
        let read = store.read()
        memory = read
        return read
    }

    /// The artists to check next: those never checked first, then the longest ago.
    public func checkOrder(_ artistNames: [String]) -> [String] {
        var checked: [String: Int64] = [:]
        for artist in state().artists { checked[BrainText.fold(artist.name)] = artist.checkedAtMs }
        return artistNames.enumerated().sorted { a, b in
            let x = checked[BrainText.fold(a.element)] ?? Int64.min
            let y = checked[BrainText.fold(b.element)] ?? Int64.min
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    /// The channel id learned for `artistName` in an earlier check; nil when none.
    public func channelOf(_ artistName: String) -> String? {
        let key = BrainText.fold(artistName)
        return state().artists.first { BrainKey.sameBytes(BrainText.fold($0.name), key) }?.channelId
    }

    /// Requests the releases lane spent since `sinceMs`.
    public func requestsSince(_ sinceMs: Int64) -> Int { state().requests.filter { $0 >= sinceMs }.count }

    /// True when `channelId` was checked recently enough that asking again would only repeat the answer.
    public func isFresh(_ channelId: String) -> Bool {
        let now = clock()
        guard let known = state().artists.first(where: { $0.channelId == channelId }) else { return false }
        return now - known.checkedAtMs >= 0 && now - known.checkedAtMs < NewReleaseRules.recheckMs
    }

    /// Looks at one artist. `libraryHas` says whether the listener already owns a row (a release's track they have is
    /// not news to them). `.network` when a request was made, `.cached` when none was needed, `.none` when the source
    /// gave nothing.
    public func check(channelId: String, artistName: String, libraryHas: @Sendable (RadioRow) -> Bool = { _ in false }) async -> RefreshFetch {
        guard let source else { return .none }
        // One check at a time: the file is read, changed and written back.
        while busy { await Task.yield() }
        busy = true
        defer { busy = false }
        let now = clock()
        let file = state()
        let known = file.artists.first { $0.channelId == channelId }
        if let known, now - known.checkedAtMs >= 0, now - known.checkedAtMs < NewReleaseRules.recheckMs { return .cached }
        var spent = 0
        let page = await source.artistPage(channelId: channelId)
        spent += 1
        guard let page else {
            save(NewReleaseFile(artists: file.artists, found: file.found, requests: withRequests(file.requests, now, spent)))
            return .none
        }
        var releases = page.albums + page.singles
        if page.albums.count >= NewReleaseRules.carouselFull || page.singles.count >= NewReleaseRules.carouselFull {
            // A full carousel may be cut short: the whole discography is the list that can be diffed.
            spent += 1
            if let all = await source.discography(channelId: channelId) {
                var order: [String] = []
                var byId: [String: ReleaseRef] = [:]
                for release in all where byId[release.browseId] == nil {
                    byId[release.browseId] = release
                    order.append(release.browseId)
                }
                // The cards of the artist page carry what the grid's may not: keep the richer one.
                for release in releases where byId[release.browseId] == nil {
                    byId[release.browseId] = release
                    order.append(release.browseId)
                }
                releases = order.compactMap { byId[$0] }
            }
        }
        let date = yearAndMonth(now)
        let diff = NewReleaseRules.diff(known: known, found: releases, nowYear: date.year, nowMonth: date.month)

        var newFound: [FoundRelease] = []
        var unreadable: Set<String> = []
        for release in diff.surfaced.prefix(NewReleaseRules.maxNewPerArtist) {
            spent += release.audioPlaylistId != nil ? 1 : 2
            guard let rows = await source.releaseTracks(release) else {
                // Not read: it stays "not seen", so the next check tries it again.
                unreadable.insert(release.browseId)
                continue
            }
            let stored = await storedRows(rows.filter { NewReleaseRules.usable($0) && !libraryHas($0) })
            if !stored.isEmpty {
                newFound.append(FoundRelease(channelId: channelId, artistName: artistName, browseId: release.browseId,
                                             title: release.title, year: release.year, kind: release.kind,
                                             foundAtMs: now, rows: stored))
            }
        }
        // A release that could not be read is forgotten whole, its title too: tried again, it must not be taken for a
        // re-release of itself.
        let unreadableTitles = Set(diff.surfaced.filter { unreadable.contains($0.browseId) }
            .map { NewReleaseRules.titleKey($0.title) })
        let next = ArtistReleaseState(
            channelId: channelId, name: artistName,
            knownIds: diff.knownIds.filter { !unreadable.contains($0) },
            knownTitles: diff.knownTitles.filter { !unreadableTitles.contains($0) },
            checkedAtMs: now)
        let artists = file.artists.filter { $0.channelId != channelId } + [next]
        let fresh = Set(newFound.map(\.browseId))
        let kept = file.found.filter { now - $0.foundAtMs >= 0 && now - $0.foundAtMs < NewReleaseRules.freshMs
            && !fresh.contains($0.browseId) }
        let found = Array((newFound + kept).sorted { $0.foundAtMs > $1.foundAtMs }.prefix(NewReleaseRules.maxFound))
        save(NewReleaseFile(artists: artists, found: found, requests: withRequests(file.requests, now, spent)))
        return .network
    }

    private func storedRows(_ rows: [RadioRow]) async -> [StoredRadioRow] {
        if rows.isEmpty { return [] }
        let rids = await repository.resolveTracks(rows.map { row in
            TrackRequest(keys: Ids.TrackKeys(videoId: row.videoId,
                                             nameKey: row.artists.first.flatMap { Ids.nameKey(primaryArtist: $0.name, rawTitle: row.title) }),
                         durationMs: Int32(clamping: row.durationSec * 1000))
        })
        var out: [StoredRadioRow] = []
        for i in rows.indices where rids[i] != 0 { out.append(StoredRadioRow(row: rows[i], rid: rids[i])) }
        return out
    }

    private func save(_ next: NewReleaseFile) {
        memory = next
        store.write(next)
    }

    private func withRequests(_ old: [Int64], _ now: Int64, _ spent: Int) -> [Int64] {
        old.filter { now - $0 >= 0 && now - $0 < Self.dayMs } + [Int64](repeating: now, count: spent)
    }

    /// The row for Home, from the saved file only. Cards the listener has since muted or blocked are left out; nil
    /// when fewer than `NewReleaseRules.minCards` are left.
    public func row(blocked: BlockedArtistMatcher, adjustments: TasteAdjustmentSet) -> BrainReleaseRow? {
        let now = clock()
        let file = state()
        if file.found.isEmpty { return nil }
        let cards = NewReleaseRules.cards(found: file.found, nowMs: now) { stored in
            let song = EngineTrack(row: stored.row, rid: stored.rid).song()
            return !blocked.isBlocked(song) && !adjustments.isExcluded(song) && !adjustments.isBlocked(song)
        }
        if cards.count < NewReleaseRules.minCards { return nil }
        var items: [BrainHomeItem] = []
        var artists: [String: String] = [:]
        for (slot, card) in cards.enumerated() {
            let track = EngineTrack(row: card.stored.row, rid: card.stored.rid)
            items.append(BrainHomeItem(track: track, arm: Arm.new, slot: slot, retrQ: -1, radioRank: -1))
            artists[track.songId] = card.release.artistName
        }
        let builtAt = cards.map { $0.release.foundAtMs }.max() ?? now
        return BrainReleaseRow(recId: BrainReleaseRow.recId(builtAtMs: builtAt), items: items, artistBySongId: artists)
    }
}
