// Taste islands (docs/brain-spec.md, 5.4, stage 2): weighted spherical k-means over the listener's top 1,500 tracks by
// `w_t` (computed by the caller). A transliteration of the Android `:brain` module's `Islands.kt`.
//
//     point x_t = concat( e_t / 127 , 0.7 * P(g_t) ), L2-normalised;  P = a fixed hashed random projection of the tag vector to 32 dims
//     K0        = clamp( round( sqrt(n / 20) ), 3, 12 )
//     init      = first centre: highest w; each next: the point maximising sqrt(w) * (1 - max cos to the chosen centres)
//     iterate   = exactly 15 rounds, ties to the lower cluster index
//     merge     = centroid cosine > 0.85;  dissolve clusters under 8 tracks into the nearest
//     stability = match new clusters to old greedily by descending centroid cosine, so "Daily Mix 2" stays the same island
//
// Fewer than 60 engaged tracks: one island. A track with neither an embedding nor a tag has no point and cannot be
// placed (unknown stays unknown); it is left out of the fit.

public enum Islands {
    public static let dim = Embeddings.dim + TagProjection.dim
    public static let maxTracks = 1500
    public static let minForMany = 60
    public static let rounds = 15
    public static let mergeCos = 0.85
    public static let minSize = 8
    public static let minK = 3
    public static let maxK = 12
    public static let tagFactor = 0.7

    /// A matched new cluster must be at least this close to an old one to keep its id.
    public static let matchFloor = 0.5

    /// A tag must make up at least this much of an island to count for its name (lift on a trace is noise).
    public static let minLiftShare = 0.03

    /// One track that goes into the fit.
    public struct Track: Sendable {
        public let rid: Int64
        public let aid: Int64
        /// `w_t`.
        public let weight: Double
        /// The part of `weight` from the last 21 days.
        public let recentWeight: Double
        public let emb: [UInt8]?
        public let tags: Tags.Vector?

        public init(rid: Int64, aid: Int64, weight: Double, recentWeight: Double, emb: [UInt8]?, tags: Tags.Vector?) {
            self.rid = rid; self.aid = aid; self.weight = weight; self.recentWeight = recentWeight
            self.emb = emb; self.tags = tags
        }
    }

    public struct Island: Sendable {
        public let id: Int
        /// Unit length, `Islands.dim` numbers.
        public let centroid: [Double]
        public let medoidRid: Int64
        /// Up to 5 atlas ids by weighted share, best first.
        public let topTags: [Int]
        /// Up to 5 atlas ids by lift over the listener's average, best first (the name of the island, 8.2).
        public let liftTags: [Int]
        /// Up to 3 artists by weight, best first.
        public let topArtists: [Int64]
        /// `W_c`.
        public let weight: Double
        /// The 21-day weight.
        public let recentWeight: Double
        public let size: Int

        public init(id: Int, centroid: [Double], medoidRid: Int64, topTags: [Int], liftTags: [Int], topArtists: [Int64],
                    weight: Double, recentWeight: Double, size: Int) {
            self.id = id; self.centroid = centroid; self.medoidRid = medoidRid; self.topTags = topTags
            self.liftTags = liftTags; self.topArtists = topArtists; self.weight = weight
            self.recentWeight = recentWeight; self.size = size
        }

        public func withId(_ newId: Int) -> Island {
            Island(id: newId, centroid: centroid, medoidRid: medoidRid, topTags: topTags, liftTags: liftTags,
                   topArtists: topArtists, weight: weight, recentWeight: recentWeight, size: size)
        }
    }

    public struct Fit: Sendable {
        public let islands: [Island]
        /// Placed tracks, by rid ascending, and the id of the island each belongs to.
        public let memberRids: [Int64]
        public let memberIslandIds: [Int]
        /// The largest island id ever used: pass it as `lastId` to the next fit so ids are never reused.
        public let maxId: Int
        /// Atlas ids the listener's tracks carry, and each one's share of their weighted tag mass; ascending id.
        public let tagIds: [Int]
        public let tagShares: [Double]

        public init(islands: [Island], memberRids: [Int64], memberIslandIds: [Int], maxId: Int,
                    tagIds: [Int] = [], tagShares: [Double] = []) {
            self.islands = islands; self.memberRids = memberRids; self.memberIslandIds = memberIslandIds
            self.maxId = maxId; self.tagIds = tagIds; self.tagShares = tagShares
        }

        public func tagShare(_ atlasId: Int) -> Double {
            var lo = 0
            var hi = tagIds.count - 1
            while lo <= hi {
                let mid = (lo + hi) >> 1
                let v = tagIds[mid]
                if v == atlasId { return tagShares[mid] }
                if v < atlasId { lo = mid + 1 } else { hi = mid - 1 }
            }
            return 0.0
        }

        public func islandOf(_ rid: Int64) -> Int {
            var lo = 0
            var hi = memberRids.count - 1
            while lo <= hi {
                let mid = (lo + hi) >> 1
                let v = memberRids[mid]
                if v == rid { return memberIslandIds[mid] }
                if v < rid { lo = mid + 1 } else { hi = mid - 1 }
            }
            return 0
        }
    }

    /// The point of a track, or nil when it has neither an embedding nor a tag.
    public static func point(_ emb: [UInt8]?, _ tags: Tags.Vector?) -> [Double]? {
        var x = [Double](repeating: 0.0, count: dim)
        var any = false
        if let emb {
            for j in 0..<Embeddings.dim {
                let v = Int8(bitPattern: emb[j])
                x[j] = Double(v) / 127.0
                if v != 0 { any = true }
            }
        }
        if let tags, !tags.isEmpty {
            let p = TagProjection.project(tags)
            for j in 0..<TagProjection.dim { x[Embeddings.dim + j] = tagFactor * p[j] }
            any = true
        }
        if !any { return nil }
        var norm = 0.0
        for v in x { norm += v * v }
        if norm <= 0.0 { return nil }
        let inv = 1.0 / BrainMath.sqrt(norm)
        for j in 0..<dim { x[j] *= inv }
        return x
    }

    /// Cosine of two unit points.
    public static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var s = 0.0
        for j in 0..<dim { s += a[j] * b[j] }
        return s
    }

    /// `sim(track, island)` for the island features: the cosine to the centroid, 0..1.
    public static func similarity(_ island: Island, _ point: [Double]) -> Double {
        BrainMath.clip(dot(island.centroid, point), 0.0, 1.0)
    }

    public static func kFor(_ n: Int) -> Int {
        let k = Int(BrainMath.floorToLong(BrainMath.sqrt(Double(n) / 20.0) + 0.5))
        return k < minK ? minK : (k > maxK ? maxK : k)
    }

    /// Descending by the quantised key, ties to the smaller id: the order of every "top" list here.
    private static func keyDescending<K: Comparable>(_ keys: [K], _ score: (K) -> Double) -> [K] {
        keys.sorted { a, b in
            let ka = BrainMath.orderKey(score(a))
            let kb = BrainMath.orderKey(score(b))
            if ka != kb { return ka > kb }
            return a < b
        }
    }

    public static func fit(_ tracks: [Track], previous: [Island] = [], lastId: Int = 0) -> Fit {
        var ordered = tracks.sorted { a, b in
            let ka = BrainMath.orderKey(a.weight)
            let kb = BrainMath.orderKey(b.weight)
            if ka != kb { return ka > kb }
            return a.rid < b.rid
        }
        if ordered.count > maxTracks { ordered = Array(ordered[0..<maxTracks]) }
        var used: [Track] = []
        var pts: [[Double]] = []
        used.reserveCapacity(ordered.count)
        pts.reserveCapacity(ordered.count)
        for t in ordered {
            if t.weight <= 0.0 { continue }
            guard let p = point(t.emb, t.tags) else { continue }
            used.append(t)
            pts.append(p)
        }
        let n = used.count
        if n == 0 { return Fit(islands: [], memberRids: [], memberIslandIds: [], maxId: lastId) }
        var assign = [Int](repeating: 0, count: n)
        var centres: [[Double]]
        if n < minForMany {
            centres = [centroidOf(used, pts, Array(0..<n), nil)]
        } else {
            centres = seedCentres(used, pts, kFor(n))
            for _ in 0..<rounds {
                assignAll(pts, centres, &assign)
                for c in 0..<centres.count {
                    let members = membersOf(assign, c)
                    if !members.isEmpty { centres[c] = centroidOf(used, pts, members, centres[c]) }
                }
            }
            assignAll(pts, centres, &assign)
            // Merge: the closest pair of centres above the threshold, the lower index absorbing the other.
            while centres.count > 1 {
                var bi = -1
                var bj = -1
                var best = mergeCos
                for i in 0..<centres.count {
                    for j in (i + 1)..<max(centres.count, i + 1) {
                        let c = dot(centres[i], centres[j])
                        if c > best { best = c; bi = i; bj = j }
                    }
                }
                if bi < 0 { break }
                for x in 0..<n {
                    if assign[x] == bj { assign[x] = bi } else if assign[x] > bj { assign[x] -= 1 }
                }
                centres.remove(at: bj)
                let members = membersOf(assign, bi)
                if !members.isEmpty { centres[bi] = centroidOf(used, pts, members, centres[bi]) }
            }
            // Dissolve: the smallest cluster under minSize goes to the nearest of the others.
            while centres.count > 1 {
                var small = -1
                var smallN = minSize
                for c in 0..<centres.count {
                    let m = membersOf(assign, c).count
                    if m < smallN { smallN = m; small = c }
                }
                if small < 0 { break }
                centres.remove(at: small)
                for x in 0..<n {
                    if assign[x] > small { assign[x] -= 1 } else if assign[x] == small { assign[x] = -1 }
                }
                for x in 0..<n where assign[x] == -1 { assign[x] = nearest(pts[x], centres) }
                for c in 0..<centres.count {
                    let members = membersOf(assign, c)
                    if !members.isEmpty { centres[c] = centroidOf(used, pts, members, centres[c]) }
                }
            }
        }
        if centres.count == 1 {
            for x in 0..<n { assign[x] = 0 }
        } else {
            assignAll(pts, centres, &assign)
        }

        // Global tag mass, once, in the order of `used`.
        var globalMass: [Int: Double] = [:]
        var globalTotal = 0.0
        for t in used {
            guard let v = t.tags else { continue }
            for g in v.tags {
                let m = t.weight * (Double(g.q) / 255.0)
                globalMass[g.atlasId] = (globalMass[g.atlasId] ?? 0.0) + m
                globalTotal += m
            }
        }
        // The temporary cluster number of each island is kept beside it (Android keeps it in the island's id).
        var raw: [(island: Island, cluster: Int)] = []
        raw.reserveCapacity(centres.count)
        for c in 0..<centres.count {
            let members = membersOf(assign, c)
            if members.isEmpty { continue }
            raw.append((describe(c, centres[c], used, pts, members, globalMass, globalTotal), c))
        }
        // Largest first; ties by the medoid, then the matching keeps old ids where it can.
        raw.sort { a, b in
            let ka = BrainMath.orderKey(a.island.weight)
            let kb = BrainMath.orderKey(b.island.weight)
            if ka != kb { return ka > kb }
            return a.island.medoidRid < b.island.medoidRid
        }
        let ids = matchIds(previous, raw.map { $0.island }, lastId)
        var islands: [Island] = []
        islands.reserveCapacity(raw.count)
        var maxId = lastId
        for i in 0..<raw.count {
            islands.append(raw[i].island.withId(ids[i]))
            if ids[i] > maxId { maxId = ids[i] }
        }
        var idByTempCluster: [Int: Int] = [:]
        for i in 0..<raw.count { idByTempCluster[raw[i].cluster] = ids[i] }
        let order = (0..<n).sorted { a, b in
            if used[a].rid != used[b].rid { return used[a].rid < used[b].rid }
            return a < b
        }
        var rids = [Int64](repeating: 0, count: n)
        var owner = [Int](repeating: 0, count: n)
        for k in 0..<n {
            rids[k] = used[order[k]].rid
            owner[k] = idByTempCluster[assign[order[k]]] ?? 0
        }
        let tagIds = globalMass.keys.sorted()
        let tagShares = tagIds.map { globalTotal > 0.0 ? globalMass[$0]! / globalTotal : 0.0 }
        return Fit(islands: islands, memberRids: rids, memberIslandIds: owner, maxId: maxId, tagIds: tagIds, tagShares: tagShares)
    }

    private static func nearest(_ p: [Double], _ centres: [[Double]]) -> Int {
        var best = 0
        var bestCos = dot(p, centres[0])
        if centres.count > 1 {
            for c in 1..<centres.count {
                let v = dot(p, centres[c])
                if v > bestCos { bestCos = v; best = c }
            }
        }
        return best
    }

    private static func assignAll(_ pts: [[Double]], _ centres: [[Double]], _ assign: inout [Int]) {
        for x in 0..<pts.count { assign[x] = nearest(pts[x], centres) }
    }

    private static func membersOf(_ assign: [Int], _ cluster: Int) -> [Int] {
        var out: [Int] = []
        for x in 0..<assign.count where assign[x] == cluster { out.append(x) }
        return out
    }

    /// The weighted mean of the members' points, normalised; `fallback` when it has no direction.
    private static func centroidOf(_ used: [Track], _ pts: [[Double]], _ members: [Int], _ fallback: [Double]?) -> [Double] {
        var sum = [Double](repeating: 0.0, count: dim)
        for x in members {
            let w = used[x].weight
            let p = pts[x]
            for j in 0..<dim { sum[j] += w * p[j] }
        }
        var norm = 0.0
        for v in sum { norm += v * v }
        if norm <= 0.0 { return fallback ?? [Double](repeating: 0.0, count: dim) }
        let inv = 1.0 / BrainMath.sqrt(norm)
        for j in 0..<dim { sum[j] *= inv }
        return sum
    }

    private static func seedCentres(_ used: [Track], _ pts: [[Double]], _ k: Int) -> [[Double]] {
        let n = used.count
        var chosen: [Int] = [0] // `used` is ordered by weight, so index 0 is the highest `w`.
        var isChosen = [Bool](repeating: false, count: n)
        isChosen[0] = true
        var maxCos = (0..<n).map { dot(pts[$0], pts[0]) }
        while chosen.count < k && chosen.count < n {
            var best = -1
            var bestKey: Int64 = 0
            for x in 0..<n {
                if isChosen[x] { continue }
                let key = BrainMath.orderKey(BrainMath.sqrt(used[x].weight) * (1.0 - maxCos[x]))
                if best < 0 || key > bestKey { best = x; bestKey = key }
            }
            if best < 0 { break }
            chosen.append(best)
            isChosen[best] = true
            for x in 0..<n {
                let c = dot(pts[x], pts[best])
                if c > maxCos[x] { maxCos[x] = c }
            }
        }
        return chosen.map { pts[$0] }
    }

    private static func describe(
        _ cluster: Int, _ centre: [Double], _ used: [Track], _ pts: [[Double]], _ members: [Int],
        _ globalMass: [Int: Double], _ globalTotal: Double
    ) -> Island {
        var weight = 0.0
        var recent = 0.0
        var medoid = members[0]
        var medoidKey = Int64.min
        var tagMass: [Int: Double] = [:]
        var tagTotal = 0.0
        var artistWeight: [Int64: Double] = [:]
        for x in members {
            let t = used[x]
            weight += t.weight
            recent += t.recentWeight
            let key = BrainMath.orderKey(dot(pts[x], centre))
            if key > medoidKey || (key == medoidKey && t.rid < used[medoid].rid) {
                medoidKey = key
                medoid = x
            }
            if let v = t.tags {
                for g in v.tags {
                    let m = t.weight * (Double(g.q) / 255.0)
                    tagMass[g.atlasId] = (tagMass[g.atlasId] ?? 0.0) + m
                    tagTotal += m
                }
            }
            if t.aid != 0 { artistWeight[t.aid] = (artistWeight[t.aid] ?? 0.0) + t.weight }
        }
        let byShare = Array(keyDescending(Array(tagMass.keys)) { tagMass[$0]! }.prefix(5))
        var lifts: [Int: Double] = [:]
        for id in tagMass.keys.sorted() {
            let m = tagMass[id]!
            let share = tagTotal > 0.0 ? m / tagTotal : 0.0
            let g = globalMass[id] ?? 0.0
            let globalShare = globalTotal > 0.0 ? g / globalTotal : 0.0
            if share >= minLiftShare && globalShare > 0.0 { lifts[id] = share / globalShare }
        }
        let byLift = Array(keyDescending(Array(lifts.keys)) { lifts[$0]! }.prefix(5))
        let artists = Array(keyDescending(Array(artistWeight.keys)) { artistWeight[$0]! }.prefix(3))
        return Island(
            id: cluster, centroid: centre, medoidRid: used[medoid].rid,
            topTags: byShare, liftTags: byLift, topArtists: artists,
            weight: weight, recentWeight: recent, size: members.count
        )
    }

    /// Greedy matching (5.4 "stability"): new clusters take the id of the old island they are closest to, by descending
    /// centroid cosine, once the cosine reaches `matchFloor`; the rest get fresh ids above `lastId`.
    public static func matchIds(_ old: [Island], _ fresh: [Island], _ lastId: Int) -> [Int] {
        var ids = [Int](repeating: -1, count: fresh.count)
        struct Pair { let o: Int; let n: Int; let key: Int64 }
        var pairs: [Pair] = []
        for o in 0..<old.count {
            for n in 0..<fresh.count {
                let c = dot(old[o].centroid, fresh[n].centroid)
                if c >= matchFloor { pairs.append(Pair(o: o, n: n, key: BrainMath.orderKey(c))) }
            }
        }
        pairs.sort { a, b in
            if a.key != b.key { return a.key > b.key }
            if old[a.o].id != old[b.o].id { return old[a.o].id < old[b.o].id }
            return a.n < b.n
        }
        var takenOld = Set<Int>()
        for p in pairs {
            if ids[p.n] >= 0 || takenOld.contains(p.o) { continue }
            ids[p.n] = old[p.o].id
            takenOld.insert(p.o)
        }
        var next = lastId
        for island in old where island.id > next { next = island.id }
        for n in 0..<fresh.count where ids[n] < 0 {
            next += 1
            ids[n] = next
        }
        return ids
    }
}

/// The hashed random projection of a tag vector to `dim` numbers (5.4 `P`). Fixed: nothing here is fitted.
public enum TagProjection {
    public static let dim = 32
    private static let scale = 1.0 / BrainMath.sqrt(32.0)

    /// `R(atlasId, j)`: plus or minus one, from the lowest bit of a SplitMix64 hash.
    public static func sign(_ atlasId: Int, _ j: Int) -> Double {
        let h = BrainHash.splitmix64(BrainHash.splitmix64(UInt64(bitPattern: Int64(atlasId))) ^ UInt64(j + 1000))
        return (h & 1) == 0 ? 1.0 : -1.0
    }

    public static func project(_ v: Tags.Vector) -> [Double] {
        var out = [Double](repeating: 0.0, count: dim)
        for t in v.tags {
            let w = Double(t.q) / 255.0
            for j in 0..<dim { out[j] += w * sign(t.atlasId, j) }
        }
        for j in 0..<dim { out[j] *= scale }
        return out
    }
}

/// The name of an island (docs/brain-spec.md, 8.2): its two tags with the highest lift over the listener's average, by
/// atlas name. A tag that is an ancestor or a descendant of the first one is skipped (so "pop" does not follow
/// "dance-pop"). Only real atlas genres are returned: an island with no tags has no name, and the surface shows
/// "Daily Mix N" and the artists alone.
public enum IslandNames {
    public static func pick(_ atlas: GenreAtlas, _ liftTags: [Int], count: Int = 2) -> [Int] {
        var out: [Int] = []
        for id in liftTags {
            guard let g = atlas.genre(id) else { continue }
            if g.name.isEmpty { continue }
            var related = false
            for chosen in out {
                if atlas.ancestors(chosen).contains(id) || atlas.ancestors(id).contains(chosen) { related = true }
            }
            if related { continue }
            out.append(id)
            if out.count >= count { break }
        }
        return out
    }
}
