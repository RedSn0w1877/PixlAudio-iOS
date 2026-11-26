// Embeddings and islands on disk (docs/brain-spec.md, 3.2, 3.8, 5.3, 5.4, stage 2b). A port of Android's `brain.db` version 5
// tables `node_embedding`, `island` and `island_member` and of its `IslandStore.kt`, as record files like the others in
// `Application Support/Brain/`:
//
//     node_embedding.bin   one binary table: "PEMB", format 1, embedding version, count, ids (Int64 LE, ascending), 64 bytes a node
//     island.pbl           `<islandId>` -> {"v":1,"id":..,"c":<base64: 96 doubles, big endian>,"m":medoid,"tt":[..],"lt":[..],
//                                          "ta":[..],"wq":..,"rq":..,"n":size,"at":fitAtMs}
//                          `members`    -> {"v":1,"r":[rid..],"i":[islandId..],"ids":[islandId..]}   (the fit rewrites it whole)
//
// A fit is ONE append: every island and, last, the member record, which names the islands of that fit (`ids`). A reader
// takes the islands the member record names and nothing else, so a process killed mid-fit leaves the previous fit (or, with
// no previous fit, no islands), never a half set. Stale islands are removed only after the new ones are down.
//
// plus four values in `brain_state`: `island_last_id`, `island_tag_shares` (`id:share;...`), `emb_count`, `island_fit_at`.
// Everything here is a cache of what the brain can fit again from its own history, so a file that cannot be read is no
// islands, never an error. A stage 1 or 2a install has none of these files. Nothing is read until it is asked for, off the
// main actor, and nothing runs at app start.

import Foundation
import PixlModel

/// The listener's taste islands as stored (docs/brain-spec.md, 5.4): the islands, who belongs to which, and when they were fitted.
public struct IslandSet: Sendable {
    public static let maxDaily = 6

    /// Largest first (by `W_c`); each carries its stable id.
    public let islands: [Islands.Island]
    public let fitAtMs: Int64
    /// Recording id to island id, for the tracks the fit placed.
    public let memberOf: [Int64: Int]

    public init(islands: [Islands.Island], fitAtMs: Int64, memberOf: [Int64: Int]) {
        self.islands = islands
        self.fitAtMs = fitAtMs
        self.memberOf = memberOf
    }

    public var isEmpty: Bool { islands.isEmpty }

    public func indexOfId(_ islandId: Int) -> Int { islands.firstIndex { $0.id == islandId } ?? -1 }

    /// The islands that get a Daily Mix: the biggest `maxDaily` by weight, in ascending id (so "Daily Mix 2" stays one island).
    public func dailyIslands() -> [Islands.Island] { islands.prefix(Self.maxDaily).sorted { $0.id < $1.id } }

    /// True when there are several islands: the surfaces that need several are shown only then (5.4).
    public var hasMany: Bool { islands.count >= 2 }
}

/// Where the small named values live (`brain_state`): closures, so a test needs no engine.
public struct StateValues: Sendable {
    public var get: @Sendable (String) async -> String?
    public var set: @Sendable (String, String?) async -> Void

    public init(get: @escaping @Sendable (String) async -> String?, set: @escaping @Sendable (String, String?) async -> Void) {
        self.get = get
        self.set = set
    }

    public static func of(_ engine: BrainEngine) -> StateValues {
        StateValues(get: { await engine.storedValue($0) }, set: { await engine.setStoredValue($0, $1) })
    }
}

public actor IslandStore {
    public static let keyLastId = "island_last_id"
    public static let keyTagShares = "island_tag_shares"
    public static let keyEmbCount = "emb_count"
    public static let keyFitAt = "island_fit_at"
    public static let keyEmptyFitAt = "island_empty_fit_at"
    public static let keyForceRefit = "island_force_refit"
    public static let formatVersion = 1
    static let magic: [UInt8] = [0x50, 0x45, 0x4D, 0x42] // "PEMB"

    struct IslandRecord: Codable {
        var v: Int
        var id: Int
        var c: Data
        var m: Int64
        var tt: [Int]
        var lt: [Int]
        var ta: [Int64]
        var wq: Int64
        var rq: Int64
        var n: Int
        var at: Int64
    }

    struct MemberRecord: Codable {
        var v: Int
        var r: [Int64]
        var i: [Int]
        /// The islands of the fit this record belongs to. Absent only in a record from before this field.
        var ids: [Int]?
    }

    static let membersKey = "members"

    private let tableURL: URL
    private let islandFile: KeyedLogStore
    private let state: StateValues
    private var current_: IslandSet?
    private var currentLoaded = false
    private var table: Embeddings?
    private var tableLoaded = false

    public init(directory: URL, state: StateValues) {
        tableURL = directory.appendingPathComponent("node_embedding.bin", isDirectory: false)
        islandFile = KeyedLogStore(url: directory.appendingPathComponent("island.pbl", isDirectory: false))
        self.state = state
    }

    // MARK: Islands

    /// The stored islands, or nil when none have been fitted. Cached in memory after the first read.
    public func current() -> IslandSet? {
        if currentLoaded { return current_ }
        currentLoaded = true
        current_ = read()
        return current_
    }

    private func read() -> IslandSet? {
        var records: [Int: IslandRecord] = [:]
        var member: MemberRecord?
        let decoder = JSONDecoder()
        islandFile.open { key, payload in
            if key == Self.membersKey {
                guard let r = try? decoder.decode(MemberRecord.self, from: Data(payload)), r.v >= 1, r.v <= Self.formatVersion,
                      r.r.count == r.i.count else { return }
                member = r
            } else if let r = try? decoder.decode(IslandRecord.self, from: Data(payload)), r.v >= 1, r.v <= Self.formatVersion {
                records[r.id] = r
            }
        }
        // No member record: a fit that never finished. The islands of an unfinished fit are not a set.
        guard let member else { return nil }
        let wanted = member.ids.map(Set.init)
        let chosen = records.values.filter { wanted?.contains($0.id) ?? true }
        if chosen.isEmpty { return nil }
        var members: [Int64: Int] = [:]
        for k in 0..<member.r.count { members[member.r[k]] = member.i[k] }
        let islands = chosen.map(Self.islandOf).sorted { a, b in
            let ka = BrainMath.orderKey(a.weight)
            let kb = BrainMath.orderKey(b.weight)
            if ka != kb { return ka > kb }
            return a.medoidRid < b.medoidRid
        }
        return IslandSet(islands: islands, fitAtMs: chosen.map(\.at).max() ?? 0, memberOf: members)
    }

    /// Replaces the stored islands with `fit`: one append (the islands, then the member record), after the last island id is
    /// stamped, then the islands that are gone are removed. A fit that placed no island keeps the stored ones and is not
    /// written. False when the file could not be written (what is in memory then is the fit).
    @discardableResult
    public func save(_ fit: Islands.Fit, nowMs: Int64) async -> Bool {
        _ = current()
        if fit.islands.isEmpty { return false }
        // The id counter first: if the process dies after this, the next fit skips ids that never got stored, and never reuses one.
        await state.set(Self.keyLastId, String(max(fit.maxId, await lastId())))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var records: [(key: String, payload: [UInt8])] = []
        var ok = true
        for island in fit.islands {
            guard let data = try? encoder.encode(Self.recordOf(island, nowMs: nowMs)) else { ok = false; continue }
            records.append((String(island.id), [UInt8](data)))
        }
        let ids = fit.islands.map(\.id)
        if ok, let data = try? encoder.encode(MemberRecord(v: Self.formatVersion, r: fit.memberRids, i: fit.memberIslandIds, ids: ids)) {
            records.append((Self.membersKey, [UInt8](data)))
            ok = islandFile.put(records)
        } else {
            ok = false
        }
        if ok {
            let keep = Set(records.map(\.key))
            _ = islandFile.remove(islandFile.keys.filter { !keep.contains($0) })
        }
        var members: [Int64: Int] = [:]
        members.reserveCapacity(fit.memberRids.count)
        for k in 0..<fit.memberRids.count { members[fit.memberRids[k]] = fit.memberIslandIds[k] }
        current_ = IslandSet(islands: fit.islands, fitAtMs: nowMs, memberOf: members)
        currentLoaded = true
        return ok
    }

    /// A fit that placed nothing: the stored islands stay, and the next try waits a day (a refit is not free).
    public func noteEmptyFit(nowMs: Int64) async { await state.set(Self.keyEmptyFitAt, String(nowMs)) }

    public func lastEmptyFitMs() async -> Int64 { await state.get(Self.keyEmptyFitAt).flatMap { Int64($0) } ?? 0 }

    /// The DNA the islands were built from changed under them (the Spotify switch): the next fit is due at once.
    public func markRefit() async { await state.set(Self.keyForceRefit, "1") }

    public func refitMarked() async -> Bool { await state.get(Self.keyForceRefit) == "1" }

    /// True when the embedding file holds as many rows as the last fit counted. A file that does not (a damaged write, a
    /// deleted file) is repaired by the next fit, not in a week.
    public func embeddingsIntact() async -> Bool {
        let counted = await embeddingCount()
        guard let all = loadTable() else { return counted == 0 }
        return all.size == counted
    }

    public func lastId() async -> Int { await state.get(Self.keyLastId).flatMap { Int($0) } ?? 0 }

    /// The tag shares of the last fit: how much of the listener's listening each atlas tag is (for EDGE, 6.1).
    public func tagShares() async -> [Int: Double] {
        guard let text = await state.get(Self.keyTagShares) else { return [:] }
        var out: [Int: Double] = [:]
        for part in text.split(separator: ";") {
            guard let colon = part.firstIndex(of: ":"), colon != part.startIndex,
                  let id = Int(part[part.startIndex..<colon]), let share = Double(part[part.index(after: colon)...]) else { continue }
            out[id] = share
        }
        return out
    }

    public func saveTagShares(_ fit: Islands.Fit) async {
        var parts: [String] = []
        for i in 0..<fit.tagIds.count where fit.tagShares[i] >= 0.001 { parts.append("\(fit.tagIds[i]):\(fit.tagShares[i])") }
        await state.set(Self.keyTagShares, parts.joined(separator: ";"))
    }

    static func recordOf(_ i: Islands.Island, nowMs: Int64) -> IslandRecord {
        var c = Data(capacity: Islands.dim * 8)
        for v in i.centroid {
            let bits = v.bitPattern
            for shift in stride(from: 56, through: 0, by: -8) { c.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
        }
        return IslandRecord(v: formatVersion, id: i.id, c: c, m: i.medoidRid, tt: i.topTags, lt: i.liftTags, ta: i.topArtists,
                            wq: BrainMath.toQ(i.weight), rq: BrainMath.toQ(i.recentWeight), n: i.size, at: nowMs)
    }

    static func islandOf(_ r: IslandRecord) -> Islands.Island {
        let bytes = [UInt8](r.c)
        var centroid = [Double](repeating: 0.0, count: Islands.dim)
        for k in 0..<Islands.dim where bytes.count >= (k + 1) * 8 {
            var bits: UInt64 = 0
            for b in 0..<8 { bits = (bits << 8) | UInt64(bytes[k * 8 + b]) }
            centroid[k] = Double(bitPattern: bits)
        }
        return Islands.Island(id: r.id, centroid: centroid, medoidRid: r.m, topTags: r.tt, liftTags: r.lt, topArtists: r.ta,
                              weight: BrainMath.fromQ(r.wq), recentWeight: BrainMath.fromQ(r.rq), size: r.n)
    }

    // MARK: Embeddings

    private func loadTable() -> Embeddings? {
        if tableLoaded { return table }
        tableLoaded = true
        table = Self.readTable(tableURL)
        return table
    }

    static func readTable(_ url: URL) -> Embeddings? {
        guard let data = try? Data(contentsOf: url), data.count >= 16 else { return nil }
        let b = [UInt8](data)
        if Array(b[0..<4]) != magic { return nil }
        func u32(_ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 | Int(b[at + 2]) << 16 | Int(b[at + 3]) << 24 }
        let format = u32(4)
        let version = u32(8)
        let count = u32(12)
        if format < 1 || format > formatVersion || count < 0 || b.count != 16 + count * 8 + count * Embeddings.dim { return nil }
        var ids = [Int64](repeating: 0, count: count)
        for k in 0..<count {
            var bits: UInt64 = 0
            for s in 0..<8 { bits |= UInt64(b[16 + k * 8 + s]) << UInt64(8 * s) }
            ids[k] = Int64(bitPattern: bits)
        }
        for k in 1..<max(count, 1) where ids[k - 1] >= ids[k] { return nil }
        return Embeddings.of(version: version, ids: ids, data: Array(b[(16 + count * 8)...]))
    }

    /// The embeddings of `ids` only (never the whole table handed out), as one lookup table; nil when none is stored.
    public func embeddingsFor(_ ids: [Int64]) -> Embeddings? {
        if ids.isEmpty { return nil }
        guard let all = loadTable(), all.size > 0 else { return nil }
        let wanted = Set(ids).sorted()
        var outIds: [Int64] = []
        var data: [UInt8] = []
        let source = all.dataCopy()
        for id in wanted {
            let i = all.indexOf(id)
            if i < 0 { continue }
            outIds.append(id)
            data.append(contentsOf: source[(i * Embeddings.dim)..<((i + 1) * Embeddings.dim)])
        }
        if outIds.isEmpty { return nil }
        return Embeddings.of(version: all.version, ids: outIds, data: data)
    }

    public func saveEmbeddings(_ embeddings: Embeddings) async {
        var out = Data(capacity: 16 + embeddings.size * (8 + Embeddings.dim))
        out.append(contentsOf: Self.magic)
        func put32(_ v: Int) { for s in 0..<4 { out.append(UInt8(truncatingIfNeeded: v >> (8 * s))) } }
        put32(Self.formatVersion)
        put32(embeddings.version)
        put32(embeddings.size)
        for id in embeddings.idsCopy() {
            let bits = UInt64(bitPattern: id)
            for s in 0..<8 { out.append(UInt8(truncatingIfNeeded: bits >> UInt64(8 * s))) }
        }
        out.append(contentsOf: embeddings.dataCopy())
        try? FileManager.default.createDirectory(at: tableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? out.write(to: tableURL, options: .atomic)) != nil {
            table = embeddings
            tableLoaded = true
        }
        await state.set(Self.keyEmbCount, String(embeddings.size))
    }

    public func embeddingCount() async -> Int { await state.get(Self.keyEmbCount).flatMap { Int($0) } ?? 0 }

    /// Forgets everything (tests, the Developer screen's reset).
    public func clear() async {
        _ = islandFile.remove(islandFile.keys)
        try? FileManager.default.removeItem(at: tableURL)
        current_ = nil
        currentLoaded = true
        table = nil
        tableLoaded = true
        await state.set(Self.keyLastId, nil)
        await state.set(Self.keyTagShares, nil)
        await state.set(Self.keyEmbCount, nil)
        await state.set(Self.keyFitAt, nil)
        await state.set(Self.keyEmptyFitAt, nil)
        await state.set(Self.keyForceRefit, nil)
    }
}

// MARK: - The fit

/// What the island fit reads from the rest of the brain: closures, so nothing is loaded until a fit runs.
public struct IslandInputs: Sendable {
    /// Every allowed library track with its ids.
    public var library: @Sendable (_ nowMs: Int64) async -> [LibraryTrack]
    /// The persisted graph edges (radio and related lists).
    public var edges: @Sendable () async -> [MixPlanner.Edge]
    /// The brain has played enough tracks to rank by (`BrainEngineChoice.hasState`).
    public var hasState: @Sendable () async -> Bool
    /// `[decayed positive mass, 21-day mass]` of each track that has any (the affinity's counter plus the pseudo-count of 4.4).
    public var weights: @Sendable (_ rids: [Int64], _ nowMs: Int64) async -> [Int64: [Double]]
    /// Plays finished (30 s or more, sounded) since a time.
    public var qualifiedPlaysSince: @Sendable (_ sinceMs: Int64) async -> Int
    /// The tag vector of each of these recordings that has one.
    public var tags: @Sendable (_ rids: [Int64]) async -> [Int64: Tags.Vector]
    public var timing: @Sendable (_ name: String, _ ms: Int64) -> Void
    public var clock: @Sendable () -> Int64

    public init(library: @escaping @Sendable (Int64) async -> [LibraryTrack],
                edges: @escaping @Sendable () async -> [MixPlanner.Edge],
                hasState: @escaping @Sendable () async -> Bool,
                weights: @escaping @Sendable ([Int64], Int64) async -> [Int64: [Double]],
                qualifiedPlaysSince: @escaping @Sendable (Int64) async -> Int,
                tags: @escaping @Sendable ([Int64]) async -> [Int64: Tags.Vector],
                timing: @escaping @Sendable (String, Int64) -> Void = { _, _ in },
                clock: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        self.library = library
        self.edges = edges
        self.hasState = hasState
        self.weights = weights
        self.qualifiedPlaysSince = qualifiedPlaysSince
        self.tags = tags
        self.timing = timing
        self.clock = clock
    }
}

/// Fits the embeddings and the islands (docs/brain-spec.md, 5.3, 5.4): FastRP over the persisted graph, then weighted
/// spherical k-means over the listener's best 1,500 tracks. Background only; it reads the files and the affinity tables
/// and never the network. Due weekly, or after 200 qualified plays (5.4).
public actor IslandBuilder {
    public static let refitAgeMs: Int64 = 7 * 24 * 60 * 60 * 1000
    public static let refitPlays = 200
    /// A fit that placed nothing waits this long before the next try.
    public static let emptyFitRetryMs: Int64 = 24 * 60 * 60 * 1000
    /// FastRP holds three dense arrays of nodes x 64 doubles; this bounds the graph (about 45 MB at the cap).
    public static let maxNodes = 30_000

    private let store: IslandStore
    private let inputs: IslandInputs
    private let state: StateValues
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(store: IslandStore, inputs: IslandInputs, state: StateValues) {
        self.store = store
        self.inputs = inputs
        self.state = state
    }

    private func lock() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func unlock() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    /// True when the stored islands are older than a week, or 200 plays have been finished since they were fitted.
    public func isDue(nowMs: Int64) async -> Bool {
        // The DNA changed under the islands (the Spotify switch): due at once.
        if await store.refitMarked() { return true }
        // A fit that placed nothing waits a day before it tries again, so each Home plan does not refit.
        let emptyAt = await store.lastEmptyFitMs()
        if emptyAt > 0, nowMs - emptyAt >= 0, nowMs - emptyAt < Self.emptyFitRetryMs { return false }
        guard let set = await store.current() else { return true }
        if nowMs - set.fitAtMs > Self.refitAgeMs { return true }
        // Embedding rows that do not match what the fit counted (a damaged write) are repaired by the next fit.
        if !(await store.embeddingsIntact()) { return true }
        return await inputs.qualifiedPlaysSince(set.fitAtMs) >= Self.refitPlays
    }

    /// The edges to embed: every edge between two library nodes, then the heaviest of the rest, while the node count stays
    /// within `maxNodes`. Deterministic (ties fall back to the ids). Library nodes always stay.
    static func capEdges(_ edges: [MixPlanner.Edge], library: Set<Int64>, maxNodes: Int) -> [MixPlanner.Edge] {
        var nodes = library
        var keep: [MixPlanner.Edge] = []
        keep.reserveCapacity(edges.count)
        var rest: [MixPlanner.Edge] = []
        for e in edges {
            if library.contains(e.a) && library.contains(e.b) { keep.append(e) } else { rest.append(e) }
        }
        if nodes.count + rest.count * 2 <= maxNodes {
            keep.append(contentsOf: rest)
            return keep
        }
        rest.sort { x, y in
            let kx = BrainMath.orderKey(x.weight)
            let ky = BrainMath.orderKey(y.weight)
            if kx != ky { return kx > ky }
            if x.a != y.a { return x.a < y.a }
            return x.b < y.b
        }
        for e in rest {
            let add = (nodes.contains(e.a) ? 0 : 1) + (nodes.contains(e.b) ? 0 : 1)
            if nodes.count + add > maxNodes { continue }
            nodes.insert(e.a)
            nodes.insert(e.b)
            keep.append(e)
        }
        return keep
    }

    /// The islands, fitted now when they are due and the brain has enough to go on; the stored ones otherwise. Nil when there
    /// is nothing to fit yet.
    public func ensure(force: Bool = false) async -> IslandSet? {
        await lock()
        defer { unlock() }
        let now = inputs.clock()
        if !force, !(await isDue(nowMs: now)) { return await store.current() }
        if !(await inputs.hasState()) { return await store.current() }
        if let fitted = await fit(now) { return fitted }
        return await store.current()
    }

    private func fit(_ now: Int64) async -> IslandSet? {
        let started = inputs.clock()
        // One recording is one node: a song on an album and on a compilation resolves to the same rid and counts once.
        var seenRid = Set<Int64>()
        let tracks = await inputs.library(now).filter { seenRid.insert($0.rid).inserted }
        if tracks.isEmpty { return nil }
        // The graph: the persisted radio edges plus the track-artist edge of every library track.
        var builder = Graph.Builder()
        var libraryNodes = Set<Int64>()
        libraryNodes.reserveCapacity(tracks.count * 2)
        for t in tracks {
            libraryNodes.insert(t.rid)
            if t.aid != 0 { libraryNodes.insert(t.aid) }
        }
        for e in Self.capEdges(await inputs.edges(), library: libraryNodes, maxNodes: Self.maxNodes) { builder.addEdge(e.a, e.b, weight: e.weight) }
        for t in tracks { builder.addTrack(rid: t.rid, primaryAid: t.aid) }
        let table = FastRp.embed(builder.build())
        await store.saveEmbeddings(table)
        // The listener's tracks by weight: decayed finished plays and the pseudo-counts of 4.4 (a liked song counts before it is played).
        let weights = await inputs.weights(tracks.map(\.rid), now)
        var chosen = tracks.filter { weights[$0.rid] != nil }
        chosen.sort { a, b in
            let ka = BrainMath.orderKey(weights[a.rid]![0])
            let kb = BrainMath.orderKey(weights[b.rid]![0])
            if ka != kb { return ka > kb }
            return a.rid < b.rid
        }
        if chosen.count > Islands.maxTracks { chosen = Array(chosen[0..<Islands.maxTracks]) }
        let tagsByRid = await inputs.tags(chosen.map(\.rid))
        let input = chosen.map { t -> Islands.Track in
            let w = weights[t.rid]!
            return Islands.Track(rid: t.rid, aid: t.aid, weight: w[0], recentWeight: w[1], emb: table.vector(t.rid), tags: tagsByRid[t.rid])
        }
        let previous = await store.current()?.islands ?? []
        let fit = Islands.fit(input, previous: previous, lastId: await store.lastId())
        if fit.islands.isEmpty {
            // Nothing was placed (a transient empty read, a thin library): the stored islands keep serving, so every "Daily Mix N"
            // stays the island it was, and the next try waits a day.
            await store.noteEmptyFit(nowMs: now)
            inputs.timing("brain_island_fit", max(inputs.clock() - started, 0))
            return nil
        }
        await store.save(fit, nowMs: now)
        await store.saveTagShares(fit)
        await state.set(IslandStore.keyFitAt, String(now))
        await state.set(IslandStore.keyEmptyFitAt, "0")
        await state.set(IslandStore.keyForceRefit, "0")
        inputs.timing("brain_island_fit", max(inputs.clock() - started, 0))
        return await store.current()
    }
}

// MARK: - What the DNA and the embeddings know about a pool

/// What the DNA and the embeddings know about the candidates of a pool (stage 2b): tags, popularity, an embedding.
public struct CandidateDna: Sendable {
    public struct Known: Sendable {
        public var tags: [Int64: Tags.Vector]
        public var embeddings: Embeddings?
        /// Stage 5: what the flow ordering reads (6.5); empty for none, and the lists are then what they were before.
        public var flowFacts: [Int64: Flow.Facts]

        public init(tags: [Int64: Tags.Vector], embeddings: Embeddings?, flowFacts: [Int64: Flow.Facts] = [:]) {
            self.tags = tags
            self.embeddings = embeddings
            self.flowFacts = flowFacts
        }
    }

    private let store: IslandStore
    private let dna: DnaRepository?
    /// Stage 5: tempo, loudness and energy for the flow cost (6.5).
    private let flow: (any FlowFactsSource)?

    public init(store: IslandStore, dna: DnaRepository?, flow: (any FlowFactsSource)? = nil) {
        self.store = store
        self.dna = dna
        self.flow = flow
    }

    /// `candidates` with an embedding, tags and popularity where they are known. Unknown stays unknown: nothing is guessed.
    public func enrich(_ candidates: [Candidate]) async -> (candidates: [Candidate], known: Known) {
        let rids = candidates.map(\.rid)
        let emb = await store.embeddingsFor(rids)
        var tags: [Int64: Tags.Vector] = [:]
        var pop: [Int64: Int] = [:]
        if let dna {
            for row in await dna.tracks(rids) {
                let v = row.tagVector
                if !v.isEmpty { tags[row.rid] = v }
                if row.popPermille >= 0 { pop[row.rid] = row.popPermille }
            }
            // A track nothing placed takes its artist's genres at the weight of 3.4 (the artist fallback), or none.
            var needArtist: [Int64] = []
            var seenAid = Set<Int64>()
            for c in candidates where tags[c.rid] == nil && c.aid != 0 && seenAid.insert(c.aid).inserted { needArtist.append(c.aid) }
            var artistTags: [Int64: Tags.Vector] = [:]
            for row in await dna.artists(needArtist) {
                let v = Tags.decode([UInt8](row.tags))
                if !v.isEmpty { artistTags[row.aid] = Tags.fromArtist(v) }
            }
            for c in candidates where tags[c.rid] == nil { if let v = artistTags[c.aid] { tags[c.rid] = v } }
        }
        let out = candidates.map { c in c.withDna(emb: emb?.vector(c.rid), tags: tags[c.rid], popPermille: pop[c.rid] ?? -1) }
        let flowFacts = await flow?.flowFacts(rids) ?? [:]
        return (out, Known(tags: tags, embeddings: emb, flowFacts: flowFacts))
    }
}

// MARK: - The whole library by id

/// Every allowed library track with the ids the brain knows it by (docs/brain-spec.md, 3.1). The island fit, Rediscover, On
/// Repeat and the adjacent-genre pool read it here. Resolved off the main actor, remembered while the library and the
/// listener's taste stay the same.
public actor LibraryRids {
    private let sources: MixSources
    private let repository: BrainRepository
    private var cacheKey = ""
    private var cache: [LibraryTrack] = []

    public init(sources: MixSources, repository: BrainRepository) {
        self.sources = sources
        self.repository = repository
    }

    public func all(nowMs: Int64) async -> [LibraryTrack] {
        let songs = await sources.library()
        let taste = await sources.constraints()
        var favouriteHash: UInt64 = 0
        var favouriteCount = 0
        for song in songs where song.isFavorite || taste.favoriteIds.contains(song.id) {
            favouriteHash ^= BrainHash.fnv1a64(song.id)
            favouriteCount += 1
        }
        let key = "\(songs.count):\(taste.signature):\(favouriteCount):\(favouriteHash)"
        if BrainKey.sameBytes(key, cacheKey) && !cache.isEmpty { return cache }
        let allowed = songs.filter { taste.allows($0) }
        var requests: [TrackRequest] = []
        var kept: [Song] = []
        requests.reserveCapacity(allowed.count)
        for song in allowed {
            guard let facts = TrackCatalog.facts(of: song) else { continue }
            requests.append(TrackRequest(keys: facts.keys, durationMs: Int32(clamping: max(song.duration, 0))))
            kept.append(song)
        }
        let rids = await repository.resolveTracks(requests)
        let aids = await repository.resolveArtistNames(kept.map { BrainLibraryIndex.primaryArtistName($0) })
        var out: [LibraryTrack] = []
        out.reserveCapacity(kept.count)
        for i in kept.indices where rids[i] != 0 {
            let song = kept[i]
            out.append(LibraryTrack(song: song, rid: rids[i], aid: aids[i],
                                    liked: song.isFavorite || taste.favoriteIds.contains(song.id), boostLn: taste.boostLn(song)))
        }
        cacheKey = key
        cache = out
        return out
    }
}

// MARK: - Events the island rules read

public enum BrainEventQueries {
    /// Plays the listener finished (track done, 30 s or more, sounded) since `sinceMs`: the islands refit after 200 (5.4).
    public static func qualifiedPlays(_ events: [PlayEvent], sinceMs: Int64) -> Int {
        events.filter {
            $0.startedAtMs >= sinceMs && $0.endReason == EndReason.trackDone && $0.playedMs >= SeedQueries.finishedMs
                && !$0.has(EventFlags.neverAudible) && !$0.has(EventFlags.learnExcluded)
        }.count
    }

    /// Tracks the listener finished since `sinceMs`, newest first: "More like <album>" (8.1).
    public static func recentCompleted(_ events: [PlayEvent], sinceMs: Int64, limit: Int) -> [RecentTrack] {
        var byRid: [Int64: RecentTrack] = [:]
        for e in events where e.rid != 0 && e.startedAtMs >= sinceMs && e.endReason == EndReason.trackDone
            && e.playedMs >= SeedQueries.finishedMs && !e.has(EventFlags.neverAudible) && !e.has(EventFlags.learnExcluded) {
            if let old = byRid[e.rid], old.lastMs >= e.startedAtMs { continue }
            byRid[e.rid] = RecentTrack(rid: e.rid, aid: e.primaryAid, lastMs: e.startedAtMs)
        }
        let ordered = byRid.values.sorted { $0.lastMs != $1.lastMs ? $0.lastMs > $1.lastMs : $0.rid < $1.rid }
        return Array(ordered.prefix(limit))
    }
}
