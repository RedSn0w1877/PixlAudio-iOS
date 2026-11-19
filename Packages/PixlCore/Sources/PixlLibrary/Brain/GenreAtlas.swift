// The genre atlas (docs/brain-spec.md, 3.5): every MusicBrainz genre plus the hand-curated Vietnamese, Korean and
// soundtrack corner, with parents, families, depth, descriptors and the per-source name tables, parsed once from
// `genre-atlas-v1.json.gz` (decompressed by the caller: the core opens no file and no stream). A transliteration of the
// Android `:brain` module's `GenreAtlas.kt`; both must give the same answers for the same bytes.
//
// Two lookups the rest of the brain needs: by MusicBrainz id, and by name. A name is folded with `BrainText.fold` and
// then looked up by the FNV-1a hash of its UTF-8 bytes (10.3 rule 13: text is never compared as a Swift or Kotlin
// string, because the two disagree on canonical equivalence). Names and aliases of one node, and the names of the
// source tables, share one index; when two nodes claim the same folded name the smaller id wins.
//
// Unknown stays unknown: every lookup answers `none` (or nil) for what the atlas does not have, and nothing here
// guesses a genre.

/// A genre atlas that failed to read: the asset is corrupt or of a version this code does not know.
public struct AtlasError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

public final class GenreAtlas: Sendable {
    public static let none = -1

    /// What a genre sounds like: 0..255 scales, a tempo range, and up to 4 mood ids (an index into `moods`).
    public struct Descriptor: Sendable, Equatable {
        public let energy: Int
        public let valence: Int
        public let danceability: Int
        public let acousticness: Int
        public let tempoLo: Int
        public let tempoHi: Int
        public let moods: [Int]
    }

    public struct Genre: Sendable {
        public let id: Int
        /// MusicBrainz genre id; empty for a curated node.
        public let mbid: String
        public let wikidata: String
        public let name: String
        public let aliases: [String]
        public let parents: [Int]
        public let influencedBy: [Int]
        public let fusionOf: [Int]
        public let related: [Int]
        /// Index into `families`; -1 when no root is reachable.
        public let family: Int
        /// Steps below the family root along `parents` (a root is 0); 1 when it has no family.
        public let depth: Int
        public let regions: [String]
        /// The year the genre began, 0 unknown.
        public let eraStart: Int
        /// Its own descriptor or the nearest described ancestor's (inherited at build time); nil when none.
        public let descriptor: Descriptor?
        /// A one-paragraph description for the genres the atlas describes by hand; empty otherwise.
        public let description: String
    }

    public let version: Int
    public let families: [String]
    public let moods: [String]
    private let genres: [Genre?]
    /// Atlas ids in ascending order.
    public let allIds: [Int]
    private let byMbid: [BrainKey: Int]
    private let byName: [UInt64: Int]
    private let sources: [BrainKey: [UInt64: [Int]]]

    public var size: Int { allIds.count }

    private init(version: Int, families: [String], moods: [String], genres: [Genre?], ids: [Int], byMbid: [BrainKey: Int],
                 byName: [UInt64: Int], sources: [BrainKey: [UInt64: [Int]]]) {
        self.version = version
        self.families = families
        self.moods = moods
        self.genres = genres
        self.allIds = ids
        self.byMbid = byMbid
        self.byName = byName
        self.sources = sources
    }

    public func genre(_ id: Int) -> Genre? { id >= 0 && id < genres.count ? genres[id] : nil }

    public func descriptor(_ id: Int) -> Descriptor? { genre(id)?.descriptor }

    public func depth(_ id: Int) -> Int { genre(id)?.depth ?? 0 }

    /// The atlas id of a MusicBrainz genre id (lower case, hyphenated), or `none`.
    public func idForMbid(_ mbid: String) -> Int { byMbid[BrainKey(mbid)] ?? Self.none }

    /// The folded and trimmed key of a name: what both lookups hash.
    static func key(_ text: String) -> String { BrainText.trim(BrainText.fold(text)) }

    /// The atlas id a name or alias means, or `none`. Case, accents, spacing and punctuation do not matter.
    public func idForName(_ name: String) -> Int {
        let key = Self.key(name)
        if key.isEmpty { return Self.none }
        return byName[BrainHash.fnv1a64(key)] ?? Self.none
    }

    /// What a source's own genre string means (`source`: "deezer", "itunes", "chip"). nil when the table has no entry
    /// for the string (the caller may still try `idForName`); an empty array when the table says it is not a genre
    /// ("All", "Kids"): it must never be mapped or guessed.
    public func idsForSource(_ source: String, _ raw: String) -> [Int]? {
        guard let table = sources[BrainKey(source)] else { return nil }
        let key = Self.key(raw)
        if key.isEmpty { return nil }
        return table[BrainHash.fnv1a64(key)]
    }

    /// `idsForSource`, then `idForName`: every atlas id a raw genre string from `source` stands for, empty when none.
    /// A string the table marks "not a genre" stays empty even if its words are a genre's name.
    public func resolve(_ source: String, _ raw: String) -> [Int] {
        if let ids = idsForSource(source, raw) { return ids }
        let id = idForName(raw)
        return id == Self.none ? [] : [id]
    }

    /// The genre's ancestors, nearest first (breadth first over `parents`; within one step the smaller id first), each
    /// once, without the genre itself.
    public func ancestors(_ id: Int) -> [Int] {
        guard let start = genre(id) else { return [] }
        var out: [Int] = []
        var seen: Set<Int> = [id]
        var level = start.parents.sorted()
        while !level.isEmpty {
            var next: [Int] = []
            for p in level {
                if !seen.insert(p).inserted { continue }
                out.append(p)
                guard let g = genre(p) else { continue }
                next.append(contentsOf: g.parents)
            }
            level = Array(Set(next)).sorted()
        }
        return out
    }

    // MARK: Parsing

    /// Parses the atlas's UTF-8 JSON text. Throws on a document that is not an atlas of a version this code knows, so
    /// a corrupt asset is noticed at once rather than read as "no genres".
    public static func parse(utf8 bytes: [UInt8]) throws -> GenreAtlas {
        var parser = OrderedJson(bytes)
        let root: OrderedJson.Value
        do { root = try parser.parseDocument() } catch let e as OrderedJson.Failure { throw AtlasError(message: e.message) }
        guard case .object(let members) = root else { throw AtlasError(message: "not an atlas") }
        func member(_ name: String) -> OrderedJson.Value? { OrderedJson.member(members, name) }
        guard let version = member("v")?.long else { throw AtlasError(message: "no atlas version") }
        if version != 1 { throw AtlasError(message: "atlas version \(version) is not known") }
        let families = member("fam")?.strings ?? []
        let moods = member("moods")?.strings ?? []
        guard case .array(let list)? = member("g") else { throw AtlasError(message: "no genres") }
        var maxId = 0
        for g in list {
            guard case .object(let m) = g, let i = OrderedJson.member(m, "i")?.long else { throw AtlasError(message: "a genre has no id") }
            maxId = max(maxId, Int(i))
        }
        var genres = [Genre?](repeating: nil, count: maxId + 1)
        var ids: [Int] = []
        ids.reserveCapacity(list.count)
        var byMbid: [BrainKey: Int] = [:]
        byMbid.reserveCapacity(list.count * 2)
        for raw in list {
            guard case .object(let m) = raw, let i = OrderedJson.member(m, "i")?.long,
                  let name = OrderedJson.member(m, "n")?.string else { throw AtlasError(message: "a genre is not readable") }
            let id = Int(i)
            var descriptor: Descriptor?
            if case .object(let x)? = OrderedJson.member(m, "x") {
                guard let t = OrderedJson.member(x, "t")?.longs, t.count >= 2,
                      let e = OrderedJson.member(x, "e")?.long, let v = OrderedJson.member(x, "v")?.long,
                      let dn = OrderedJson.member(x, "dn")?.long, let ac = OrderedJson.member(x, "ac")?.long else {
                    throw AtlasError(message: "a descriptor is not readable")
                }
                descriptor = Descriptor(energy: Int(e), valence: Int(v), danceability: Int(dn), acousticness: Int(ac),
                                        tempoLo: t[0], tempoHi: t[1], moods: OrderedJson.member(x, "mood")?.longs ?? [])
            }
            let g = Genre(
                id: id,
                mbid: OrderedJson.member(m, "m")?.string ?? "",
                wikidata: OrderedJson.member(m, "w")?.string ?? "",
                name: name,
                aliases: OrderedJson.member(m, "a")?.strings ?? [],
                parents: OrderedJson.member(m, "p")?.longs ?? [],
                influencedBy: OrderedJson.member(m, "inf")?.longs ?? [],
                fusionOf: OrderedJson.member(m, "fus")?.longs ?? [],
                related: OrderedJson.member(m, "rel")?.longs ?? [],
                family: OrderedJson.member(m, "fam")?.long.map(Int.init) ?? -1,
                depth: OrderedJson.member(m, "d")?.long.map(Int.init) ?? 1,
                regions: OrderedJson.member(m, "reg")?.strings ?? [],
                eraStart: OrderedJson.member(m, "era")?.longs.first ?? 0,
                descriptor: descriptor,
                description: OrderedJson.member(m, "desc")?.string ?? "")
            if genres[id] != nil { throw AtlasError(message: "atlas id \(id) appears twice") }
            genres[id] = g
            ids.append(id)
            if !g.mbid.isEmpty { byMbid[BrainKey(g.mbid)] = id }
        }
        ids.sort()
        // Names, in id order, so that when two nodes fold to one name the smaller id keeps it.
        var byName: [UInt64: Int] = [:]
        byName.reserveCapacity(list.count * 4)
        func claim(_ text: String, _ id: Int) {
            let key = Self.key(text)
            if key.isEmpty { return }
            let h = BrainHash.fnv1a64(key)
            if byName[h] == nil { byName[h] = id }
        }
        for id in ids { if let g = genres[id] { claim(g.name, id) } }
        for id in ids { if let g = genres[id] { for a in g.aliases { claim(a, id) } } }
        var sources: [BrainKey: [UInt64: [Int]]] = [:]
        if case .object(let src)? = member("src") {
            for (name, table) in src {
                guard case .object(let entries) = table else { continue }
                var t: [UInt64: [Int]] = [:]
                t.reserveCapacity(entries.count)
                // In the file's order: the first of two names that fold alike keeps the key.
                for (raw, target) in entries {
                    let key = Self.key(raw)
                    if key.isEmpty { continue }
                    let h = BrainHash.fnv1a64(key)
                    if t[h] == nil { t[h] = target.longs }
                }
                sources[BrainKey(name)] = t
            }
        }
        return GenreAtlas(version: Int(version), families: families, moods: moods, genres: genres, ids: ids, byMbid: byMbid,
                          byName: byName, sources: sources)
    }
}

/// A small JSON reader for the atlas that keeps an object's members in the order of the file (the source tables are
/// read in that order, and the first of two names that fold alike wins). UTF-8 in; bare integers only.
struct OrderedJson {
    struct Failure: Error { let message: String }

    indirect enum Value {
        case object([(String, Value)])
        case array([Value])
        case string(String)
        case long(Int64)
        case bool(Bool)
        case null

        var string: String? { if case .string(let s) = self { return s } else { return nil } }
        var long: Int64? { if case .long(let v) = self { return v } else { return nil } }
        var strings: [String] {
            guard case .array(let a) = self else { return [] }
            return a.compactMap { $0.string }
        }
        var longs: [Int] {
            guard case .array(let a) = self else { return [] }
            return a.compactMap { $0.long.map(Int.init) }
        }
    }

    static func member(_ members: [(String, Value)], _ name: String) -> Value? {
        for (k, v) in members where BrainKey.sameBytes(k, name) { return v }
        return nil
    }

    private let s: [UInt8]
    private var pos = 0

    init(_ bytes: [UInt8]) { s = bytes }

    mutating func parseDocument() throws -> Value {
        skipSpace()
        let v = try value()
        skipSpace()
        if pos != s.count { throw Failure(message: "trailing text at \(pos)") }
        return v
    }

    private mutating func skipSpace() {
        while pos < s.count && (s[pos] == 0x20 || s[pos] == 0x0A || s[pos] == 0x0D || s[pos] == 0x09) { pos += 1 }
    }

    private func at(_ i: Int) throws -> UInt8 {
        if i >= s.count { throw Failure(message: "unexpected end") }
        return s[i]
    }

    private mutating func value() throws -> Value {
        let c = try at(pos)
        switch c {
        case 0x7B: return try object()
        case 0x5B: return try array()
        case 0x22: return .string(try string())
        case 0x74: try literal("true"); return .bool(true)
        case 0x66: try literal("false"); return .bool(false)
        case 0x6E: try literal("null"); return .null
        default:
            if c == 0x2D || (c >= 0x30 && c <= 0x39) { return .long(try number()) }
            throw Failure(message: "bad value at \(pos)")
        }
    }

    private mutating func literal(_ word: String) throws {
        for b in word.utf8 {
            if try at(pos) != b { throw Failure(message: "bad literal at \(pos)") }
            pos += 1
        }
    }

    private mutating func number() throws -> Int64 {
        let start = pos
        var negative = false
        if s[pos] == 0x2D { negative = true; pos += 1 }
        var v: Int64 = 0
        var digits = 0
        while pos < s.count && s[pos] >= 0x30 && s[pos] <= 0x39 {
            v = v &* 10 &+ Int64(s[pos] - 0x30)
            digits += 1
            pos += 1
        }
        if digits == 0 { throw Failure(message: "bad number at \(start)") }
        return negative ? -v : v
    }

    private mutating func string() throws -> String {
        pos += 1 // opening quote
        let start = pos
        // The fast path: no escape before the closing quote.
        while pos < s.count && s[pos] != 0x22 && s[pos] != 0x5C { pos += 1 }
        if pos >= s.count { throw Failure(message: "unterminated string") }
        if s[pos] == 0x22 {
            let text = String(decoding: s[start..<pos], as: UTF8.self)
            pos += 1
            return text
        }
        var units: [UInt16] = Array(String(decoding: s[start..<pos], as: UTF8.self).utf16)
        var run = pos
        func flush(_ end: Int, _ s: [UInt8], _ units: inout [UInt16]) {
            if end > run { units.append(contentsOf: String(decoding: s[run..<end], as: UTF8.self).utf16) }
        }
        run = pos
        while true {
            let c = try at(pos)
            if c == 0x22 {
                flush(pos, s, &units)
                pos += 1
                break
            }
            if c != 0x5C { pos += 1; continue }
            flush(pos, s, &units)
            pos += 1
            let e = try at(pos)
            pos += 1
            switch e {
            case 0x22: units.append(0x22)
            case 0x5C: units.append(0x5C)
            case 0x2F: units.append(0x2F)
            case 0x6E: units.append(0x0A)
            case 0x74: units.append(0x09)
            case 0x72: units.append(0x0D)
            case 0x62: units.append(0x08)
            case 0x66: units.append(0x0C)
            case 0x75:
                var unit: UInt16 = 0
                for _ in 0..<4 {
                    guard let d = BrainJson.hexValue(UInt16(try at(pos))) else { throw Failure(message: "bad hex at \(pos)") }
                    unit = (unit << 4) | d
                    pos += 1
                }
                units.append(unit)
            default: throw Failure(message: "bad escape at \(pos)")
            }
            run = pos
        }
        return String(decoding: units, as: UTF16.self)
    }

    private mutating func object() throws -> Value {
        pos += 1
        var out: [(String, Value)] = []
        skipSpace()
        if try at(pos) == 0x7D { pos += 1; return .object(out) }
        while true {
            skipSpace()
            if try at(pos) != 0x22 { throw Failure(message: "expected a key at \(pos)") }
            let k = try string()
            skipSpace()
            if try at(pos) != 0x3A { throw Failure(message: "expected : at \(pos)") }
            pos += 1
            skipSpace()
            out.append((k, try value()))
            skipSpace()
            let c = try at(pos)
            pos += 1
            if c == 0x7D { break }
            if c != 0x2C { throw Failure(message: "expected , at \(pos)") }
        }
        return .object(out)
    }

    private mutating func array() throws -> Value {
        pos += 1
        var out: [Value] = []
        skipSpace()
        if try at(pos) == 0x5D { pos += 1; return .array(out) }
        while true {
            skipSpace()
            out.append(try value())
            skipSpace()
            let c = try at(pos)
            pos += 1
            if c == 0x5D { break }
            if c != 0x2C { throw Failure(message: "expected , at \(pos)") }
        }
        return .array(out)
    }
}
