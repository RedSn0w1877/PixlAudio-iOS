// The tag vector of a track (docs/brain-spec.md, 3.4 and 5.3): what the sources say its genres are, merged, mapped to
// atlas nodes, spread a little to the parents, weighted toward the specific, and quantised to 12 bytes of weight. A
// transliteration of the Android `:brain` module's `Tags.kt`.
//
//     per atlas id g:   w(g)   = 1 - PRODUCT over sources s of (1 - trust_s * conf_s(g))        noisy-OR
//     propagate:        w(parent) = max(w(parent), 0.5 * w(child)); grandparent 0.25
//     weight:           w(g)  *= min(2.4, 1 + 0.35 * depth(g))
//     keep the 12 largest (ties: smaller atlas id); L2-normalise; quantise  q = floor(255 * w + 0.5)
//     unknown:          if no source reached w >= 0.25 before propagation, the vector is empty
//
// Sources 7, 9 and 10 run only when the others are weak (`max w < 0.5`). Unknown stays unknown: an empty vector is the
// answer when the sources said nothing the atlas can place, and nothing here invents a genre.

public enum Tags {
    public static let srcRecording = 1
    public static let srcArtist = 2
    public static let srcSpotify = 3
    public static let srcChip = 4
    public static let srcDiscogs = 5
    public static let srcITunes = 6
    public static let srcRelatedArtists = 7
    public static let srcDeezerAlbum = 8
    public static let srcShared = 9
    public static let srcAssistant = 10

    /// Trust of each source, by its number (index 0 unused).
    private static let trustTable: [Double] = [0.0, 1.0, 0.8, 0.7, 0.6, 0.5, 0.4, 0.35, 0.3, 0.3, 0.25]

    public static let maxTags = 12
    private static let knownFloor = 0.25
    private static let weakBelow = 0.5
    private static let artistFallback = 0.7

    public static func trust(_ source: Int) -> Double { source >= 1 && source <= 10 ? trustTable[source] : 0.0 }

    /// Sources that run only when the rest left the track weakly tagged (3.4).
    private static func isLate(_ source: Int) -> Bool {
        source == srcRelatedArtists || source == srcShared || source == srcAssistant
    }

    /// One source's claim that a track is atlas genre `atlasId`, with the share of its votes in 0...1.
    public struct Input: Sendable, Equatable {
        public var source: Int
        public var atlasId: Int
        public var conf: Double
        public init(source: Int, atlasId: Int, conf: Double) {
            self.source = source
            self.atlasId = atlasId
            self.conf = conf
        }
    }

    /// One genre string a source returned: its words, a MusicBrainz genre id when it gave one, and its vote count or -1.
    public struct Raw: Sendable, Equatable {
        public var label: String
        public var mbid: String
        public var votes: Int
        public init(_ label: String, mbid: String = "", votes: Int = -1) {
            self.label = label
            self.mbid = mbid
            self.votes = votes
        }
    }

    public struct Tag: Sendable, Equatable {
        public var atlasId: Int
        public var q: Int
        public init(atlasId: Int, q: Int) {
            self.atlasId = atlasId
            self.q = q
        }
    }

    /// At most `maxTags` tags, strongest first (ties: smaller atlas id). Empty means "unknown", never "no genre".
    public struct Vector: Sendable, Equatable {
        public var tags: [Tag]
        public init(_ tags: [Tag] = []) { self.tags = tags }
        public static let empty = Vector([])
        public var isEmpty: Bool { tags.isEmpty }
        /// The heaviest tag's atlas id, or `GenreAtlas.none`.
        public var top: Int { tags.isEmpty ? GenreAtlas.none : tags[0].atlasId }
    }

    /// Turns one source's raw genre strings into inputs. `table` is the source table to try first ("deezer", "itunes",
    /// "chip"; nil for sources whose strings are plain names). A string with a MusicBrainz genre id is placed by that
    /// id. Strings the atlas cannot place are dropped. `conf` is `votes / max votes` over the raws that carry votes,
    /// and 1 for a raw without votes.
    public static func inputs(_ atlas: GenreAtlas, source: Int, table: String?, raws: [Raw]) -> [Input] {
        var maxVotes = 0
        for r in raws where r.votes > maxVotes { maxVotes = r.votes }
        var out: [Input] = []
        out.reserveCapacity(raws.count)
        for r in raws {
            let conf: Double
            if r.votes > 0 && maxVotes > 0 {
                conf = Double(r.votes) / Double(maxVotes)
            } else if r.votes == 0 {
                conf = 0.0
            } else {
                conf = 1.0
            }
            if conf <= 0.0 { continue }
            let byId = r.mbid.isEmpty ? GenreAtlas.none : atlas.idForMbid(r.mbid)
            if byId != GenreAtlas.none {
                out.append(Input(source: source, atlasId: byId, conf: conf))
                continue
            }
            let ids = atlas.resolve(table ?? "", r.label)
            for id in ids { out.append(Input(source: source, atlasId: id, conf: conf)) }
        }
        return out
    }

    /// Merges every source's claims into one vector (3.4). The order of `inputs` does not matter.
    public static func merge(_ atlas: GenreAtlas, _ inputs: [Input]) -> Vector {
        // conf[id][source], the largest when a source repeats an id.
        var perId: [Int: [Double]] = [:]
        for i in inputs {
            if i.source < 1 || i.source > 10 || atlas.genre(i.atlasId) == nil { continue }
            let c = i.conf > 1.0 ? 1.0 : (i.conf < 0.0 ? 0.0 : i.conf)
            var a = perId[i.atlasId] ?? [Double](repeating: 0.0, count: 11)
            if c > a[i.source] { a[i.source] = c }
            perId[i.atlasId] = a
        }
        if perId.isEmpty { return .empty }
        let ids = perId.keys.sorted()

        var w = noisyOr(ids, perId, includeLate: false)
        var maxW = 0.0
        for v in w.values where v > maxW { maxW = v }
        if maxW < weakBelow {
            w = noisyOr(ids, perId, includeLate: true)
            maxW = 0.0
            for v in w.values where v > maxW { maxW = v }
        }
        if maxW < knownFloor { return .empty }

        // Spread to the parents from the weights before any spreading, so the order does not matter.
        var spread = w
        for (id, v) in w {
            guard let g = atlas.genre(id) else { continue }
            for p in g.parents {
                let half = 0.5 * v
                if half > (spread[p] ?? 0.0) { spread[p] = half }
                guard let pg = atlas.genre(p) else { continue }
                for gp in pg.parents {
                    let quarter = 0.25 * v
                    if quarter > (spread[gp] ?? 0.0) { spread[gp] = quarter }
                }
            }
        }
        // Specific beats generic. Ascending atlas id, so every later sum has a fixed order.
        let atlasIds = spread.keys.sorted()
        var values: [Double] = []
        values.reserveCapacity(atlasIds.count)
        for id in atlasIds {
            let boost = BrainMath.min(2.4, 1.0 + 0.35 * Double(atlas.depth(id)))
            values.append((spread[id] ?? 0.0) * boost)
        }
        // The 12 largest, by quantised weight then smaller id.
        var order = Array(atlasIds.indices)
        order.sort { a, b in
            let ka = BrainMath.orderKey(values[a])
            let kb = BrainMath.orderKey(values[b])
            if ka != kb { return kb < ka }
            return atlasIds[a] < atlasIds[b]
        }
        let keep = Array(order.prefix(maxTags)).sorted { atlasIds[$0] < atlasIds[$1] }
        var sumSq = 0.0
        for k in keep { sumSq += values[k] * values[k] }
        if sumSq <= 0.0 { return .empty }
        let norm = BrainMath.sqrt(sumSq)
        var tags: [Tag] = []
        tags.reserveCapacity(keep.count)
        for k in keep {
            let q = Int(BrainMath.floorToLong(255.0 * (values[k] / norm) + 0.5))
            if q > 0 { tags.append(Tag(atlasId: atlasIds[k], q: q > 255 ? 255 : q)) }
        }
        tags.sort { a, b in a.q != b.q ? a.q > b.q : a.atlasId < b.atlasId }
        return Vector(tags)
    }

    private static func noisyOr(_ ids: [Int], _ perId: [Int: [Double]], includeLate: Bool) -> [Int: Double] {
        var out: [Int: Double] = [:]
        out.reserveCapacity(ids.count)
        for id in ids {
            guard let conf = perId[id] else { continue }
            var keep = 1.0
            var any = false
            for s in 1...10 {
                if !includeLate && isLate(s) { continue }
                let c = conf[s]
                if c <= 0.0 { continue }
                keep *= 1.0 - trustTable[s] * c
                any = true
            }
            if any { out[id] = 1.0 - keep }
        }
        return out
    }

    /// A track with no tags of its own takes its primary artist's vector at 0.7 weight (3.4): the quantised weights are
    /// scaled and rounded, and a weight that rounds to 0 is dropped.
    public static func fromArtist(_ artist: Vector) -> Vector {
        if artist.isEmpty { return .empty }
        var out: [Tag] = []
        out.reserveCapacity(artist.tags.count)
        for t in artist.tags {
            let q = Int(BrainMath.floorToLong(artistFallback * Double(t.q) + 0.5))
            if q > 0 { out.append(Tag(atlasId: t.atlasId, q: q)) }
        }
        return Vector(out)
    }

    /// `sum over shared ids of (wa / 255) * (wb / 255)` (5.3), summed in ascending atlas id.
    public static func tagdot(_ a: Vector, _ b: Vector) -> Double {
        if a.isEmpty || b.isEmpty { return 0.0 }
        let x = a.tags.enumerated().sorted { $0.element.atlasId != $1.element.atlasId ? $0.element.atlasId < $1.element.atlasId : $0.offset < $1.offset }.map(\.element)
        let y = b.tags.enumerated().sorted { $0.element.atlasId != $1.element.atlasId ? $0.element.atlasId < $1.element.atlasId : $0.offset < $1.offset }.map(\.element)
        var i = 0
        var j = 0
        var sum = 0.0
        while i < x.count && j < y.count {
            let ia = x[i].atlasId
            let ib = y[j].atlasId
            if ia == ib {
                sum += (Double(x[i].q) / 255.0) * (Double(y[j].q) / 255.0)
                i += 1
                j += 1
            } else if ia < ib {
                i += 1
            } else {
                j += 1
            }
        }
        return sum
    }

    /// Three bytes a tag: the atlas id (16 bits, big endian) and the weight. The empty vector is no bytes.
    public static func encode(_ v: Vector) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: v.tags.count * 3)
        for (k, t) in v.tags.enumerated() {
            out[k * 3] = UInt8(truncatingIfNeeded: t.atlasId >> 8)
            out[k * 3 + 1] = UInt8(truncatingIfNeeded: t.atlasId)
            out[k * 3 + 2] = UInt8(truncatingIfNeeded: t.q)
        }
        return out
    }

    public static func decode(_ bytes: [UInt8]?) -> Vector {
        guard let bytes, bytes.count >= 3 else { return .empty }
        let n = bytes.count / 3
        var tags: [Tag] = []
        tags.reserveCapacity(n)
        for k in 0..<n {
            let id = (Int(bytes[k * 3]) << 8) | Int(bytes[k * 3 + 1])
            tags.append(Tag(atlasId: id, q: Int(bytes[k * 3 + 2])))
        }
        return Vector(tags)
    }
}
