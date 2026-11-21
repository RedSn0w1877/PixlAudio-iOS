// The seeds of Endless Listening, read from the app's own state (the pure picker is `EndlessSeeds`). A port of Android's
// `EndlessSeedSource.kt`.

import Foundation
import PixlModel

/// One seed of Endless Listening: a library song, the ids the brain knows it by, and the island it stands for (-1: a top artist).
public struct EndlessSeedPick: Sendable {
    public let song: Song
    public let rid: Int64
    public let aid: Int64
    public let islandId: Int

    public init(song: Song, rid: Int64, aid: Int64, islandId: Int) {
        self.song = song
        self.rid = rid
        self.aid = aid
        self.islandId = islandId
    }
}

extension BrainMixes {
    /// The seeds of Endless Listening, drawn from the library tracks of the Your Mix pool (the shortlist of about 500 that Your Mix is
    /// planned from): one for each taste island, biggest first, at most five; the listener's top artists with fewer than two islands
    /// (`EndlessSeeds`).
    ///
    /// Reads the island fit the weekly build left, the shortlist (cached for the day) and the in-memory affinity tables; never the
    /// network, and it does not open anything that is not already open. Empty when there is nothing to seed from.
    public func endlessSeeds(now: Int64) async -> [EndlessSeedPick] {
        let taste = await sources.constraints()
        let tz = sources.tzOffsetMin(now)
        let salt = await engine.salt()
        let all = await sources.library()
        let library = await shortlist(all, now: now, tz: tz, salt: salt, taste: taste).filter { track in
            let folded = BrainText.fold(BrainLibraryIndex.primaryArtistName(track.song))
            return !Self.noArtistNames.contains { BrainKey.sameBytes($0, folded) }
        }
        if library.isEmpty { return [] }
        let set = await parts?.islands.current()
        let memberOf = set?.memberOf ?? [:]
        let islandList = set?.islands ?? []
        let inputs: (islands: [EndlessSeeds.IslandIn], artists: [EndlessSeeds.ArtistIn]) = await engine.readAffinity { state in
            var weights: [Int64: Double] = [:]
            weights.reserveCapacity(library.count * 2)
            for t in library { weights[t.rid] = Affinity.weight(state, family: Family.track, key: t.rid, nowMs: now) }
            func track(_ t: LibraryTrack) -> EndlessSeeds.Track { EndlessSeeds.Track(rid: t.rid, aid: t.aid, weight: weights[t.rid] ?? 0.0) }
            var islands: [EndlessSeeds.IslandIn] = []
            if set != nil {
                var byIsland: [Int: [EndlessSeeds.Track]] = [:]
                for t in library {
                    guard let id = memberOf[t.rid] else { continue }
                    byIsland[id, default: []].append(track(t))
                }
                for island in islandList {
                    guard let tracks = byIsland[island.id] else { continue }
                    islands.append(EndlessSeeds.IslandIn(id: island.id, weight: island.weight, tracks: tracks))
                }
            }
            var order: [Int64] = []
            var byArtist: [Int64: [EndlessSeeds.Track]] = [:]
            for t in library where t.aid != 0 {
                if byArtist[t.aid] == nil { order.append(t.aid) }
                byArtist[t.aid, default: []].append(track(t))
            }
            let artists = order.map { aid in
                EndlessSeeds.ArtistIn(aid: aid, weight: Affinity.weight(state, family: Family.artist, key: aid, nowMs: now),
                                      tracks: byArtist[aid] ?? [])
            }
            return (islands, artists)
        }
        let seeds = EndlessSeeds.pick(islands: inputs.islands, artists: inputs.artists)
        if seeds.isEmpty { return [] }
        var byRid: [Int64: LibraryTrack] = [:]
        byRid.reserveCapacity(library.count * 2)
        for t in library where byRid[t.rid] == nil { byRid[t.rid] = t }
        return seeds.compactMap { s in byRid[s.rid].map { EndlessSeedPick(song: $0.song, rid: s.rid, aid: s.aid, islandId: s.islandId) } }
    }

    /// The names of the islands the seeds stand for, as the Daily Mixes name them ("Soft pop & R&B"), in seed order; an island that
    /// is not named (too few of its tracks carry a genre) is left out. Real names only: the card says nothing when there are none.
    public func endlessIslandNames(_ seeds: [EndlessSeedPick]) async -> [String] {
        guard let set = await parts?.islands.current() else { return [] }
        var out: [String] = []
        for s in seeds where s.islandId >= 0 {
            guard let island = set.islands.first(where: { $0.id == s.islandId }) else { continue }
            let name = await islandGenreName(island)
            if !BrainText.isBlank(name) && !out.contains(name) { out.append(name) }
        }
        return out
    }
}
