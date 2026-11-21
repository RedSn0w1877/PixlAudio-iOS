// The seeds of Endless Listening: up to five tracks, one for each of the listener's taste islands, biggest island first. A station
// started from them plays what the radios of those tracks say, so it starts from the listener's own taste spread over its sides
// rather than from one song. A transliteration of the Android `:brain` module's `EndlessSeeds.kt`; both reproduce `endless.jsonl`
// bit for bit.
//
// With fewer than two usable islands (a thin history, or a library the islands could not split) the seeds are the listener's top
// artists instead, one track each. Pure: the app reads the islands, the plays and the library and hands the numbers over.

public enum EndlessSeeds {
    public static let maxSeeds = 5

    /// A library track that may be a seed. `weight` is the listener's decayed play weight of it (0 for a track never played).
    public struct Track: Sendable, Equatable {
        public let rid: Int64
        public let aid: Int64
        public let weight: Double

        public init(rid: Int64, aid: Int64, weight: Double) {
            self.rid = rid
            self.aid = aid
            self.weight = weight
        }
    }

    /// One taste island with the library tracks the fit placed in it. `weight` is the island's own weight (`W_c`).
    public struct IslandIn: Sendable, Equatable {
        public let id: Int
        public let weight: Double
        public let tracks: [Track]

        public init(id: Int, weight: Double, tracks: [Track]) {
            self.id = id
            self.weight = weight
            self.tracks = tracks
        }
    }

    /// One artist with its library tracks, for the fallback. `weight` is the artist's decayed play weight.
    public struct ArtistIn: Sendable, Equatable {
        public let aid: Int64
        public let weight: Double
        public let tracks: [Track]

        public init(aid: Int64, weight: Double, tracks: [Track]) {
            self.aid = aid
            self.weight = weight
            self.tracks = tracks
        }
    }

    /// A seed: `islandId` is the island it stands for, or -1 for a seed of the fallback.
    public struct Seed: Sendable, Equatable {
        public let rid: Int64
        public let aid: Int64
        public let islandId: Int

        public init(rid: Int64, aid: Int64, islandId: Int) {
            self.rid = rid
            self.aid = aid
            self.islandId = islandId
        }
    }

    /// The seeds, best first; empty when the listener has nothing to seed from.
    public static func pick(islands: [IslandIn], artists: [ArtistIn]) -> [Seed] {
        let byIsland = fromIslands(islands)
        if byIsland.count >= 2 { return byIsland }
        return fromArtists(artists)
    }

    /// Kotlin's `Double.compareTo`: a total order (`-0.0` below `0.0`, NaN above everything).
    private static func compare(_ a: Double, _ b: Double) -> Int {
        if a < b { return -1 }
        if a > b { return 1 }
        let x = Int64(bitPattern: a.isNaN ? 0x7ff8000000000000 : a.bitPattern)
        let y = Int64(bitPattern: b.isNaN ? 0x7ff8000000000000 : b.bitPattern)
        return x == y ? 0 : (x < y ? -1 : 1)
    }

    private static func fromIslands(_ islands: [IslandIn]) -> [Seed] {
        let order = islands.indices.sorted { i, j in
            let c = compare(islands[j].weight, islands[i].weight)
            if c != 0 { return c < 0 }
            if islands[i].id != islands[j].id { return islands[i].id < islands[j].id }
            return i < j
        }
        var out: [Seed] = []
        var usedAids = Set<Int64>()
        var usedRids = Set<Int64>()
        for k in order {
            if out.count >= maxSeeds { break }
            let island = islands[k]
            guard let best = bestOf(island.tracks, usedAids, usedRids) else { continue }
            out.append(Seed(rid: best.rid, aid: best.aid, islandId: island.id))
            usedRids.insert(best.rid)
            if best.aid != 0 { usedAids.insert(best.aid) }
        }
        return out
    }

    private static func fromArtists(_ artists: [ArtistIn]) -> [Seed] {
        let order = artists.indices.sorted { i, j in
            let c = compare(artists[j].weight, artists[i].weight)
            if c != 0 { return c < 0 }
            if artists[i].aid != artists[j].aid { return artists[i].aid < artists[j].aid }
            return i < j
        }
        var out: [Seed] = []
        var usedAids = Set<Int64>()
        var usedRids = Set<Int64>()
        for k in order {
            if out.count >= maxSeeds { break }
            let artist = artists[k]
            if artist.aid != 0 && usedAids.contains(artist.aid) { continue }
            guard let best = bestOf(artist.tracks, [], usedRids) else { continue }
            out.append(Seed(rid: best.rid, aid: best.aid != 0 ? best.aid : artist.aid, islandId: -1))
            usedRids.insert(best.rid)
            if artist.aid != 0 { usedAids.insert(artist.aid) }
        }
        return out
    }

    /// The most played track not yet used whose artist is not yet a seed; ties by the lower recording id.
    private static func bestOf(_ tracks: [Track], _ usedAids: Set<Int64>, _ usedRids: Set<Int64>) -> Track? {
        var best: Track?
        for t in tracks {
            if t.rid == 0 || usedRids.contains(t.rid) { continue }
            if t.aid != 0 && usedAids.contains(t.aid) { continue }
            if let b = best {
                if t.weight > b.weight || (t.weight == b.weight && t.rid < b.rid) { best = t }
            } else {
                best = t
            }
        }
        return best
    }
}
