// Identity of the music brain (docs/brain-spec.md, 3.1): one Int64 per recording (`rid`) and per artist (`aid`),
// minted the first time a key is seen and kept for good in an alias table. A line-by-line transliteration of the
// Android `:brain` module's `Ids.kt`.
//
// This file is pure: it reads the table through `AliasLookup` and returns the rows to write. The caller applies
// them in one step. Key forms:
//
//  - tracks:  `s:<spotifyTrackId>`, `i:<ISRC upper case>`, `y:<videoId>`,
//             `n:<fold(primary artist)>|<fold(clean title)>|<identity flags, lower-case hex>`
//  - artists: `sa:<spotifyArtistId>`, `ya:<UC...>`, `da:<deezerId>`, `mb:<mbid>`, `na:<fold(name)>`

/// Identity: keys, minting and resolving.
public enum Ids {
    /// Two plays under one name are the same recording when their lengths differ by at most this.
    public static let nameMatchMaxDurationDeltaMs: Int32 = 3_000

    /// What the resolver needs to read. Every method is a point lookup. Keys are compared by their UTF-8 bytes.
    public protocol AliasLookup {
        /// The id stored for `key`, or nil.
        func idOf(_ key: String) -> Int64?
        /// True when `id` already belongs to something (any alias row points at it).
        func isTaken(_ id: Int64) -> Bool
        /// The survivor `id` was merged into, or `id` itself.
        func survivorOf(_ id: Int64) -> Int64
        /// The duration stored with the alias row of `key`, 0 when unknown.
        func durationMsOf(_ key: String) -> Int32
    }

    /// One alias row to insert. `durationMs` is what the caller knew, 0 when unknown.
    public struct AliasWrite: Sendable, Equatable {
        public let key: String
        public let id: Int64
        public let durationMs: Int32

        public init(key: String, id: Int64, durationMs: Int32) {
            self.key = key
            self.id = id
            self.durationMs = durationMs
        }
    }

    /// `from` is now the same thing as `into`.
    public struct MergeWrite: Sendable, Equatable {
        public let from: Int64
        public let into: Int64

        public init(from: Int64, into: Int64) {
            self.from = from
            self.into = into
        }
    }

    public struct Resolution: Sendable {
        public let id: Int64
        /// True when the id did not exist before this call.
        public let minted: Bool
        public let aliases: [AliasWrite]
        public let merges: [MergeWrite]
    }

    /// The keys a caller has for one track. Blank values are treated as absent.
    public struct TrackKeys: Sendable {
        public let s: String?
        public let i: String?
        public let y: String?
        public let n: String?

        public init(spotifyId: String? = nil, isrc: String? = nil, videoId: String? = nil, nameKey: String? = nil) {
            s = Ids.notBlank(spotifyId).map { "s:" + $0 }
            i = Ids.notBlank(isrc).map { "i:" + Ids.asciiUpper(BrainText.trim($0)) }
            y = Ids.notBlank(videoId).map { "y:" + $0 }
            n = Ids.notBlank(nameKey)
        }

        /// Strong keys in resolve order.
        func strong() -> [String] { [s, i, y].compactMap { $0 } }
    }

    /// The keys a caller has for one artist.
    public struct ArtistKeys: Sendable {
        public let sa: String?
        public let ya: String?
        public let da: String?
        public let mb: String?
        public let na: String?

        public init(spotifyId: String? = nil, youTubeChannelId: String? = nil, deezerId: String? = nil,
                    mbid: String? = nil, name: String? = nil) {
            sa = Ids.notBlank(spotifyId).map { "sa:" + $0 }
            ya = Ids.notBlank(youTubeChannelId).map { "ya:" + $0 }
            da = Ids.notBlank(deezerId).map { "da:" + $0 }
            mb = Ids.notBlank(mbid).map { "mb:" + $0 }
            if let name {
                let folded = BrainText.fold(name)
                na = folded.isEmpty ? nil : "na:" + folded
            } else {
                na = nil
            }
        }

        func strong() -> [String] { [sa, ya, da, mb].compactMap { $0 } }
    }

    static func notBlank(_ value: String?) -> String? {
        guard let value, !BrainText.isBlank(value) else { return nil }
        return value
    }

    static func asciiUpper(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if v >= 0x61 && v <= 0x7A {
                out.append(Unicode.Scalar(UInt8(v - 32)))
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// Lower-case hexadecimal of the bits of `value` (Java `Integer.toHexString`).
    static func hex(_ value: Int32) -> String {
        var bits = UInt32(bitPattern: value)
        if bits == 0 { return "0" }
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        var reversed: [UInt8] = []
        while bits != 0 {
            reversed.append(digits[Int(bits & 0xF)])
            bits >>= 4
        }
        return String(decoding: reversed.reversed(), as: UTF8.self)
    }

    /// The names-only key of a track: `n:<fold(artist)>|<clean title>|<identity flags hex>`, or nil when either part
    /// folds to nothing. `primaryArtist` must be ONE artist (the first of the library's own split list), never a
    /// joined display string.
    public static func nameKey(primaryArtist: String, rawTitle: String) -> String? {
        let artist = BrainText.fold(primaryArtist)
        let clean = BrainText.cleanTitle(rawTitle)
        if artist.isEmpty || clean.title.isEmpty { return nil }
        return "n:" + artist + "|" + clean.title + "|" + hex(clean.identityFlags)
    }

    /// Mints an id for `firstKey`: `fnv1a64(utf8(firstKey))`, or with `#1`, `#2`, ... appended while the value is 0
    /// or `isTaken`.
    public static func mint(_ firstKey: String, isTaken: (Int64) -> Bool) -> Int64 {
        var candidate = BrainHash.id(BrainHash.fnv1a64(firstKey))
        var n = 0
        while candidate == 0 || isTaken(candidate) {
            n += 1
            candidate = BrainHash.id(BrainHash.fnv1a64(firstKey + "#" + String(n)))
        }
        return candidate
    }

    /// Resolves a track to its rid (the four steps of 3.1), returning the rows to write.
    public static func resolveTrack(_ keys: TrackKeys, durationMs: Int32, table: any AliasLookup) -> Resolution? {
        let strong = keys.strong()
        let nameKey = keys.n
        if strong.isEmpty && nameKey == nil { return nil }
        let duration: Int32 = durationMs > 0 ? durationMs : 0

        // Step 1: the first strong key the table knows decides.
        var rid: Int64 = 0
        var found = false
        for key in strong {
            if let hit = table.idOf(key) {
                rid = table.survivorOf(hit)
                found = true
                break
            }
        }

        // Step 2: the name key, unless it is clearly another recording under the same name.
        var storeNameKey = true
        if !found, let nameKey, let hit = table.idOf(nameKey) {
            let stored = table.durationMsOf(nameKey)
            let delta = duration > stored ? duration &- stored : stored &- duration
            let accept = strong.isEmpty || duration == 0 || stored <= 0 || delta <= nameMatchMaxDurationDeltaMs
            if accept {
                rid = table.survivorOf(hit)
                found = true
            } else {
                storeNameKey = false
            }
        }

        // Step 3: mint from the caller's strongest key.
        var minted = false
        if !found {
            guard let firstKey = strong.first ?? nameKey else { return nil }
            rid = mint(firstKey, isTaken: table.isTaken)
            minted = true
        }

        // Step 4: store what is new; a strong key that lives under another rid merges the two.
        var aliases: [AliasWrite] = []
        var merges: [MergeWrite] = []
        for key in strong {
            if let hit = table.idOf(key) {
                let other = table.survivorOf(hit)
                if other != rid && !merges.contains(where: { $0.from == other }) {
                    merges.append(MergeWrite(from: other, into: rid))
                }
            } else {
                aliases.append(AliasWrite(key: key, id: rid, durationMs: duration))
            }
        }
        if let nameKey, storeNameKey, table.idOf(nameKey) == nil {
            aliases.append(AliasWrite(key: nameKey, id: rid, durationMs: duration))
        }
        return Resolution(id: rid, minted: minted, aliases: aliases, merges: merges)
    }

    /// Resolves an artist to its aid. Order `sa`, `ya`, `da`, `mb`, `na`; a name hit is always accepted.
    public static func resolveArtist(_ keys: ArtistKeys, table: any AliasLookup) -> Resolution? {
        let strong = keys.strong()
        let nameKey = keys.na
        if strong.isEmpty && nameKey == nil { return nil }
        var aid: Int64 = 0
        var found = false
        for key in strong {
            if let hit = table.idOf(key) {
                aid = table.survivorOf(hit)
                found = true
                break
            }
        }
        if !found, let nameKey, let hit = table.idOf(nameKey) {
            aid = table.survivorOf(hit)
            found = true
        }
        var minted = false
        if !found {
            guard let firstKey = strong.first ?? nameKey else { return nil }
            aid = mint(firstKey, isTaken: table.isTaken)
            minted = true
        }
        var aliases: [AliasWrite] = []
        for key in strong where table.idOf(key) == nil { aliases.append(AliasWrite(key: key, id: aid, durationMs: 0)) }
        if let nameKey, table.idOf(nameKey) == nil { aliases.append(AliasWrite(key: nameKey, id: aid, durationMs: 0)) }
        // Artists are not merged in stage 1: two ids for one artist stay two until stage 2 brings real ids.
        return Resolution(id: aid, minted: minted, aliases: aliases, merges: [])
    }

    /// An in-memory alias table: the reference behaviour for tests, golden vectors and any caller that resolves a
    /// batch before writing it. Not thread-safe.
    public final class MemoryAliasTable: AliasLookup {
        private var ids: [BrainKey: Int64] = [:]
        private var durations: [BrainKey: Int32] = [:]
        private var taken: Set<Int64> = []
        private var merged: [Int64: Int64] = [:]

        public init() {}

        public func idOf(_ key: String) -> Int64? { ids[BrainKey(key)] }
        public func isTaken(_ id: Int64) -> Bool { taken.contains(id) }
        public func survivorOf(_ id: Int64) -> Int64 { merged[id] ?? id }
        public func durationMsOf(_ key: String) -> Int32 { durations[BrainKey(key)] ?? 0 }

        /// Applies a resolution, flattening merge chains at write time.
        public func apply(_ resolution: Resolution) {
            taken.insert(resolution.id)
            for alias in resolution.aliases {
                ids[BrainKey(alias.key)] = alias.id
                durations[BrainKey(alias.key)] = alias.durationMs
                taken.insert(alias.id)
            }
            for merge in resolution.merges { self.merge(from: merge.from, into: merge.into) }
        }

        public func merge(from: Int64, into: Int64) {
            let target = survivorOf(into)
            if from == target { return }
            merged[from] = target
            // Flatten: anything that pointed at `from` now points at the survivor.
            for (key, value) in merged where value == from { merged[key] = target }
        }

        public func resolveTrack(_ keys: TrackKeys, durationMs: Int32) -> Int64? {
            guard let resolution = Ids.resolveTrack(keys, durationMs: durationMs, table: self) else { return nil }
            apply(resolution)
            return resolution.id
        }

        public func resolveArtist(_ keys: ArtistKeys) -> Int64? {
            guard let resolution = Ids.resolveArtist(keys, table: self) else { return nil }
            apply(resolution)
            return resolution.id
        }

        public var aliasCount: Int { ids.count }
    }
}
