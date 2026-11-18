// The "Because you listened to X" rows of Home (docs/brain-spec.md, 8.1): for the two newest anchors by different
// artists, X's cached radio, filtered (6.1) and scored (5.7), twelve cards of music the listener does not have.
// Ports of Android's `HomeAnchorStore.kt` and `BrainHomeRows.kt`.
//
// Home shows the saved rows at once (one small file) and never waits for anything here. A rebuild happens only once
// the brain is in memory in this process (so never at app start), only when the anchors or the listener's taste
// changes moved, and asks the network for at most one radio per anchor, under the YouTube budget. Its result is
// what the next visit to Home shows.

import Foundation
import PixlModel

/// A track a "Because you listened to" row can be built around, with what a radio request needs.
public struct HomeAnchor: Sendable, Hashable, Codable {
    public var rid: Int64
    public var aid: Int64
    public var mediaId: String
    public var title: String
    /// ONE artist name.
    public var primaryArtist: String
    public var spotifyId: String?
    /// The YouTube audio id the track played from, when the play itself named it (a `yt:` song).
    public var videoId: String?
    public var durationMs: Int64
    public var heardAtMs: Int64

    public init(rid: Int64, aid: Int64, mediaId: String, title: String, primaryArtist: String, spotifyId: String? = nil,
                videoId: String? = nil, durationMs: Int64 = 0, heardAtMs: Int64) {
        self.rid = rid
        self.aid = aid
        self.mediaId = mediaId
        self.title = title
        self.primaryArtist = primaryArtist
        self.spotifyId = spotifyId
        self.videoId = videoId
        self.durationMs = durationMs
        self.heardAtMs = heardAtMs
    }
}

/// The newest tracks a Home row may be built around (8.1): a play on a surface the listener picked from that they
/// heard out (`r >= 0.8`), or an engine pick they liked, saved or replayed. Never a track that merely played
/// through on autoplay.
///
/// `play_event` is the source of truth, but an event holds ids, not a title or a media id, and the in-memory
/// session is gone by the time Home is opened. So the recorder writes this short list beside the event, in
/// `brain_state`: a cache of the log's last few qualifying rows, `max` at most.
public enum HomeAnchors {
    public static let max = 8
    public static let maxAgeMs: Int64 = 7 * 24 * 60 * 60 * 1000

    static let actedOn = EventFlags.likedDuring | EventFlags.savedDuring | EventFlags.addedToPlaylist | EventFlags.replayed

    public static func qualifies(_ event: PlayEvent, _ graded: Reward.Graded) -> Bool {
        if event.origin != Origin.live || event.rid == 0 { return false }
        if event.has(EventFlags.notForMe) || event.has(EventFlags.neverAudible) { return false }
        return event.arm == Arm.none ? graded.r >= Reward.completionR : event.flags & actedOn != 0
    }

    /// `anchor` first; an older entry of the same recording goes; `max` at most.
    public static func push(_ current: [HomeAnchor], _ anchor: HomeAnchor) -> [HomeAnchor] {
        var out = [anchor]
        for old in current {
            if out.count >= max { break }
            if old.rid != anchor.rid { out.append(old) }
        }
        return out
    }

    /// The anchors a Home page shows rows for: the newest ones, by different artists, heard within the last seven
    /// days; `count` at most.
    public static func pick(_ anchors: [HomeAnchor], nowMs: Int64, count: Int) -> [HomeAnchor] {
        var out: [HomeAnchor] = []
        var artistKeys: [String] = []
        for anchor in anchors {
            if out.count >= count { break }
            let age = nowMs - anchor.heardAtMs
            if age < 0 || age >= maxAgeMs { continue }
            let key = BrainText.fold(anchor.primaryArtist)
            let sameArtist = out.contains { anchor.aid != 0 && $0.aid == anchor.aid }
                || artistKeys.contains { BrainKey.sameBytes($0, key) }
            if sameArtist { continue }
            out.append(anchor)
            artistKeys.append(key)
        }
        return out
    }

    /// One line of JSON (a named value is one line of text).
    public static func encode(_ anchors: [HomeAnchor]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(anchors)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    public static func decode(_ text: String?) -> [HomeAnchor] {
        guard let text, !BrainText.isBlank(text) else { return [] }
        return (try? JSONDecoder().decode([HomeAnchor].self, from: Data(text.utf8))) ?? []
    }
}

/// One card of a row, as it is saved.
public struct StoredHomeItem: Sendable, Hashable, Codable {
    public var stored: StoredRadioRow
    public var arm: Int32
    public var slot: Int
    public var retrQ: Int
    public var radioRank: Int
}

public struct StoredHomeRow: Sendable, Hashable, Codable {
    public var anchor: HomeAnchor
    public var recId: Int64
    public var items: [StoredHomeItem]
}

public struct StoredHomeRows: Sendable, Hashable, Codable {
    public var builtAtMs: Int64 = 0
    /// What the rows were built from; the same signature means the same rows.
    public var signature: String = ""
    public var rows: [StoredHomeRow] = []

    public init(builtAtMs: Int64 = 0, signature: String = "", rows: [StoredHomeRow] = []) {
        self.builtAtMs = builtAtMs
        self.signature = signature
        self.rows = rows
    }
}

/// One card: a track the listener does not have, ready to play as an engine track.
public struct BrainHomeItem: Sendable, Hashable {
    public var track: EngineTrack
    public var arm: Int32
    public var slot: Int
    public var retrQ: Int
    public var radioRank: Int
}

/// A "Because you listened to X" row.
public struct BrainHomeRow: Sendable, Hashable, Identifiable {
    public static let idPrefix = "because_"

    /// Also the `surfaceId` its plays are logged under.
    public var id: String
    public var anchor: HomeAnchor
    public var recId: Int64
    public var items: [BrainHomeItem]

    /// `because_` and the anchor's recording id in lower-case hexadecimal (Java `Long.toHexString`).
    public static func idOf(anchorRid: Int64) -> String { idPrefix + String(UInt64(bitPattern: anchorRid), radix: 16) }

    /// What every item of the row carries into the queue when a card is played, by song id.
    public func tags() -> [String: BrainItemTag] {
        var out: [String: BrainItemTag] = [:]
        out.reserveCapacity(items.count)
        for item in items {
            let artist = item.track.artists.first?.name
            out[item.track.songId] = BrainItemTag(
                surface: Surface.nameOf(Surface.homeShelf), surfaceId: id, recId: recId, slot: item.slot,
                arm: Arm.nameOf(item.arm), whyArg: anchor.title, radioRank: item.radioRank, retrQ: item.retrQ,
                whyKey: WhyLine.nameOf(WhyLine.becauseListened),
                primaryArtist: artist.flatMap { BrainText.isBlank($0) ? nil : $0 },
                // The listener chose to play the row: its tracks are theirs, like a playlist's.
                chosen: true)
        }
        return out
    }

    /// What a card says under its title: what the pick's arm says (8.8). The row's own "Because you listened to"
    /// is its title, and is the line the track carries into the queue.
    public func cardReason(_ item: BrainHomeItem) -> WhyLineText.Line? {
        if item.arm == Arm.artist {
            return WhyLineText.line(key: WhyLine.artistMore, arg: item.track.artists.first?.name)
        }
        return WhyLineText.line(key: WhyLine.radioFans, arg: anchor.primaryArtist)
    }
}

/// What a rebuild reads from the rest of the app: captured only when one is due.
public struct HomeRowInputs: Sendable {
    public var library: [Song]
    public var blocked: BlockedArtistMatcher
    public var adjustments: TasteAdjustmentSet
    /// Online, and the YouTube source is switched on.
    public var allowNetwork: Bool
    public var tzOffsetMin: Int32
    /// The stored YouTube match of a Spotify track id.
    public var matchedVideoId: @Sendable (String) async -> String?

    public init(library: [Song], blocked: BlockedArtistMatcher = .empty, adjustments: TasteAdjustmentSet = .empty,
                allowNetwork: Bool, tzOffsetMin: Int32 = 0,
                matchedVideoId: @escaping @Sendable (String) async -> String? = { _ in nil }) {
        self.library = library
        self.blocked = blocked
        self.adjustments = adjustments
        self.allowNetwork = allowNetwork
        self.tzOffsetMin = tzOffsetMin
        self.matchedVideoId = matchedVideoId
    }
}

/// Builds and keeps the rows.
public actor BrainHomeRows {
    public static let fileName = "brain_home_rows_v1.json"
    /// At most two rows, for the two newest anchors by different artists.
    public static let maxRows = 2
    public static let cards = 12
    /// A row with fewer playable cards than this is hidden, not padded.
    public static let minCards = 6
    public static let maxAgeMs: Int64 = 6 * 60 * 60 * 1000
    public static let retryMs: Int64 = 10 * 60 * 1000
    static let maxFileBytes = 512 * 1024
    /// Low byte of a Home row's `recId`: apart from the autoplay batches' sequence numbers of the same millisecond.
    static let homeRecTag: Int64 = 0xF0

    private let file: URL
    private let repository: BrainRepository
    private let engine: BrainEngine
    private let clock: @Sendable () -> Int64
    private var memory: StoredHomeRows?
    private var lastFailedSignature = ""
    private var lastFailedAtMs: Int64 = 0
    private var refreshing = false

    public init(directory: URL, repository: BrainRepository, engine: BrainEngine,
                clock: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        file = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        self.repository = repository
        self.engine = engine
        self.clock = clock
    }

    public static func signature(of anchors: [HomeAnchor], tasteRevision: Int, blockedCount: Int) -> String {
        anchors.map { String(UInt64(bitPattern: $0.rid), radix: 16) }.joined(separator: ",")
            + "|\(tasteRevision)|\(blockedCount)"
    }

    /// The saved rows, newest anchor first. Reads one small file the first time; never the brain's own files.
    public func cached() -> [BrainHomeRow] {
        Self.present(stored(), nowMs: clock())
    }

    private func stored() -> StoredHomeRows {
        if let memory { return memory }
        let read = readFile()
        memory = read
        return read
    }

    /// Rebuilds the rows when they are due. Nil when nothing was rebuilt: the brain has not been used in this
    /// process yet, or the rows are still what the anchors and the taste changes ask for. `inputs` is asked only
    /// when a rebuild runs.
    public func refreshIfDue(tasteRevision: Int, blockedCount: Int,
                             inputs: @Sendable () async -> HomeRowInputs) async -> [BrainHomeRow]? {
        guard await engine.isLoaded, !refreshing else { return nil }
        refreshing = true
        defer { refreshing = false }
        let now = clock()
        let current = stored()
        let anchors = HomeAnchors.pick(await engine.homeAnchors(), nowMs: now, count: Self.maxRows)
        let signature = Self.signature(of: anchors, tasteRevision: tasteRevision, blockedCount: blockedCount)
        let age = now - current.builtAtMs
        if BrainKey.sameBytes(signature, current.signature) && age >= 0 && age < Self.maxAgeMs { return nil }
        // Rows that could not be built yet (a radio that is not cached, offline) are tried again on a later visit,
        // not on every one.
        let sinceFailure = now - lastFailedAtMs
        if BrainKey.sameBytes(signature, lastFailedSignature) && sinceFailure >= 0 && sinceFailure < Self.retryMs {
            return nil
        }
        let rows = anchors.isEmpty ? [] : await build(anchors, nowMs: now, inputs: await inputs())
        if rows.count < anchors.count {
            lastFailedSignature = signature
            lastFailedAtMs = now
        }
        // A row that could not be rebuilt keeps its saved cards while its anchor is still wanted.
        var merged: [StoredHomeRow] = []
        for anchor in anchors {
            if let fresh = rows.first(where: { $0.anchor.rid == anchor.rid }) {
                merged.append(fresh)
            } else if let kept = current.rows.first(where: { $0.anchor.rid == anchor.rid }) {
                merged.append(kept)
            }
        }
        let next = StoredHomeRows(builtAtMs: now, signature: rows.count == anchors.count ? signature : current.signature,
                                  rows: merged)
        memory = next
        if next.rows == current.rows {
            // The same cards: nothing new to show. Only the note of what they were built from moved.
            if !BrainKey.sameBytes(next.signature, current.signature) { writeFile(next) }
            return nil
        }
        writeFile(next)
        return Self.present(next, nowMs: now)
    }

    private func build(_ anchors: [HomeAnchor], nowMs: Int64, inputs: HomeRowInputs) async -> [StoredHomeRow] {
        // Folding the whole library is only worth it once a radio is there to be filtered.
        var libraryIndex: BrainLibraryIndex?
        let ignored = await engine.ignoredRids(nowMs: nowMs)
        var out: [StoredHomeRow] = []
        // A track appears once on the page.
        var usedRids: Set<Int64> = []
        for (rowIndex, anchor) in anchors.enumerated() {
            guard let seed = await seed(for: anchor, matchedVideoId: inputs.matchedVideoId),
                  let radio = await repository.radioFor(seed: seed, allowNetwork: inputs.allowNetwork) else { continue }
            let artistRadio = radio.kind == RadioList.kindArtist
            let seedFlags = BrainText.cleanTitle(anchor.title).versionFlags
            let index = libraryIndex ?? BrainLibraryIndex(songs: inputs.library)
            libraryIndex = index

            var rows: [StoredRadioRow] = []
            var ranks: [Int] = []
            var candidates: [Candidate] = []
            for (rank, stored) in radio.rows.enumerated() {
                let row = stored.row
                // Music the listener does not have: a recording of the library is not a card here.
                if row.artists.isEmpty || stored.rid == 0 || index.match(row) != nil { continue }
                if ignored.contains(stored.rid) || usedRids.contains(stored.rid) { continue }
                let track = EngineTrack(row: row, rid: stored.rid)
                let albumKey = row.album.flatMap(BrainLibraryIndex.albumKey(of:))
                let policy = AutoplayPolicy.Candidate(
                    mediaId: track.songId, rid: stored.rid, artistKey: BrainLibraryIndex.artistKey(of: row),
                    albumKey: albumKey, durationMs: track.durationMs,
                    versionFlags: BrainText.cleanTitle(row.title).versionFlags, officialAudio: row.isOfficialAudio,
                    inLibrary: false, arm: artistRadio ? Arm.artist : Arm.radio, radioRank: Int32(rank + 1))
                if !AutoplayPolicy.passesFilters(policy, seedFlags: seedFlags) { continue }
                let song = track.song()
                if inputs.blocked.isBlocked(song) || inputs.adjustments.isExcluded(song)
                    || inputs.adjustments.isBlocked(song) { continue }
                rows.append(stored)
                ranks.append(rank + 1)
                candidates.append(Candidate(rid: stored.rid, aid: 0, albumKey: AutoplayPool.albumHash(albumKey),
                                            inLibrary: false, fromArtistRadio: artistRadio,
                                            boostLn: AutoplayPool.boostLn(inputs.adjustments, song)))
            }
            if rows.count < Self.minCards { continue }

            let aids = await repository.resolveArtistNames([anchor.primaryArtist] + rows.map { $0.row.artists[0].name })
            for i in candidates.indices { candidates[i].aid = aids[i + 1] }
            let seedList = Retrieval.SeedList(seedRid: radio.seedRid, seedAid: aids[0], rids: radio.rows.map(\.rid),
                                              edgeFactor: radio.kind == RadioList.kindRelated ? Graph.related : Graph.radio)
            let plan = await engine.planHomeRow(candidates: candidates, seed: seedList, count: Self.cards, nowMs: nowMs,
                                                tzOffsetMin: inputs.tzOffsetMin, excludedRids: usedRids)
            if plan.picks.count < Self.minCards { continue }
            var byRid: [Int64: Int] = [:]
            for i in rows.indices { byRid[rows[i].rid] = i }
            var items: [StoredHomeItem] = []
            for pick in plan.picks {
                guard let i = byRid[pick.rid] else { continue }
                items.append(StoredHomeItem(stored: rows[i], arm: pick.arm, slot: items.count, retrQ: Int(pick.retrQ),
                                            radioRank: ranks[i]))
                usedRids.insert(pick.rid)
            }
            out.append(StoredHomeRow(anchor: anchor, recId: (nowMs << 8) | (Self.homeRecTag + Int64(rowIndex)), items: items))
        }
        return out
    }

    /// What a radio request needs to know about an anchor; nil when it has no known YouTube audio id.
    private func seed(for anchor: HomeAnchor, matchedVideoId: @Sendable (String) async -> String?) async -> RadioSeed? {
        var videoId = anchor.videoId
        if videoId == nil, let spotifyId = anchor.spotifyId { videoId = await matchedVideoId(spotifyId) }
        guard let videoId, !BrainText.isBlank(videoId) else { return nil }
        return RadioSeed(mediaId: anchor.mediaId, videoId: videoId, title: anchor.title,
                         primaryArtist: anchor.primaryArtist, durationMs: anchor.durationMs, spotifyId: anchor.spotifyId)
    }

    static func present(_ stored: StoredHomeRows, nowMs: Int64) -> [BrainHomeRow] {
        var out: [BrainHomeRow] = []
        for row in stored.rows {
            let age = nowMs - row.anchor.heardAtMs
            if age < 0 || age >= HomeAnchors.maxAgeMs || row.items.count < minCards { continue }
            let items = row.items.map { item in
                BrainHomeItem(track: EngineTrack(row: item.stored.row, rid: item.stored.rid), arm: item.arm,
                              slot: item.slot, retrQ: item.retrQ, radioRank: item.radioRank)
            }
            out.append(BrainHomeRow(id: BrainHomeRow.idOf(anchorRid: row.anchor.rid), anchor: row.anchor,
                                    recId: row.recId, items: items))
        }
        return out
    }

    private func readFile() -> StoredHomeRows {
        guard let data = try? Data(contentsOf: file), !data.isEmpty, data.count <= Self.maxFileBytes,
              let rows = try? JSONDecoder().decode(StoredHomeRows.self, from: data) else { return StoredHomeRows() }
        return rows
    }

    private func writeFile(_ rows: StoredHomeRows) {
        guard let data = try? JSONEncoder().encode(rows) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
