// The persisted similarity graph (docs/brain-spec.md, 3.6, 3.8 `graph_edge`), stage 2a: the edges of the radio lists.
// A radio the brain fetches is stored as a list AND as edges, so the graph outlives the 500-list cap on the lists; the
// lists stage 1 left behind are converted once (`BrainRepository.backfillEdgesOnce`). A port of Android's
// `GraphEdgeStore.kt` and the `graph_edge` table of its `brain.db` version 2.
//
// The weight of the row at rank k is `factor / log2(2 + k)` with the factor of its kind (1.0 for a radio, 0.8 for
// the Related tab), written as a number times 65,536. When the same pair has edges of several types the graph
// builder keeps the largest, and each node keeps its 64 heaviest: both are done when the graph is built, so what is
// stored may be a little more than a graph needs.
//
// File `graph_edge.pbl` (one `KeyedLogStore`):
//     `<src>|<dst>|<type>`  ->  {"r":rank,"t":fetchedAtMs,"v":1,"w":wQ16}
//     `~backfilled`         ->  {"t":nowMs,"v":1}     the one-time conversion of stage 1's lists is done
// A record is versioned (`v`); a reader skips a record it cannot read or a version it does not know, so a later stage
// can add fields or a type without a migration. A stage 1 install has no such file: it is an empty graph.

import Foundation
import PixlModel

/// The edges of the radio lists, on disk. Not thread-safe: own it from one actor (`BrainRepository`).
public final class GraphEdgeStore {
    public static let typeRadio: Int32 = 1
    public static let typeRelated: Int32 = 2
    /// Edges of a list fetched longer ago than this are dropped (the lists expire after 14 days; a graph that is
    /// consulted for mixes may be a little older).
    public static let retentionMs: Int64 = 30 * 24 * 60 * 60 * 1000
    public static let weightUnit: Double = 65_536.0
    public static let formatVersion = 1
    static let backfillKey = "~backfilled"

    struct Record: Codable, Equatable {
        var v: Int
        var w: Int32
        var r: Int32
        var t: Int64
    }

    struct Edge: Equatable {
        var src: Int64
        var dst: Int64
        var type: Int32
        var record: Record
    }

    private let file: KeyedLogStore
    private var loaded = false
    private var edges: [BrainKey: Edge] = [:]
    /// The keys of every edge that starts at a node (for replacing a seed's edges) and of every edge that touches it.
    private var fromSeed: [Int64: [BrainKey]] = [:]
    private var touching: [Int64: [BrainKey]] = [:]
    private var backfilledAtMs: Int64?

    public init(directory: URL, compactionFloorBytes: Int = 32 * 1024) {
        file = KeyedLogStore(url: directory.appendingPathComponent("graph_edge.pbl", isDirectory: false),
                             compactionFloorBytes: compactionFloorBytes)
    }

    // MARK: Weights

    public static func typeOf(kind: Int) -> Int32 { kind == RadioList.kindRelated ? typeRelated : typeRadio }

    public static func factorOf(type: Int32) -> Double { type == typeRelated ? Graph.related : Graph.radio }

    /// The weight of the row at `rank` (1 for the first non-seed row) of a list of `type`, times 65,536, rounded.
    public static func weightQ16(type: Int32, rank: Int) -> Int32 {
        let w = factorOf(type: type) / BrainMath.log2(2.0 + Double(rank))
        return Int32(truncatingIfNeeded: BrainMath.floorToLong(w * weightUnit + 0.5))
    }

    static func key(_ src: Int64, _ dst: Int64, _ type: Int32) -> String { "\(src)|\(dst)|\(type)" }

    // MARK: Load

    private func load() {
        if loaded { return }
        loaded = true
        file.open { key, payload in
            if BrainKey.sameBytes(key, Self.backfillKey) {
                if let marker = try? JSONDecoder().decode(Marker.self, from: Data(payload)), marker.v >= 1 {
                    self.backfilledAtMs = marker.t
                }
                return
            }
            let parts = key.utf8.split(separator: 0x7C, omittingEmptySubsequences: false)
            guard parts.count == 3,
                  let src = Int64(String(decoding: parts[0], as: UTF8.self)),
                  let dst = Int64(String(decoding: parts[1], as: UTF8.self)),
                  let type = Int32(String(decoding: parts[2], as: UTF8.self)),
                  let record = try? JSONDecoder().decode(Record.self, from: Data(payload)),
                  record.v >= 1, record.v <= Self.formatVersion else { return }
            self.add(Edge(src: src, dst: dst, type: type, record: record), key: BrainKey(key))
        }
    }

    private struct Marker: Codable {
        var v: Int
        var t: Int64
    }

    private func add(_ edge: Edge, key: BrainKey) {
        if edges[key] == nil {
            fromSeed[edge.src, default: []].append(key)
            touching[edge.src, default: []].append(key)
            touching[edge.dst, default: []].append(key)
        }
        edges[key] = edge
    }

    private func drop(_ key: BrainKey) {
        guard let edge = edges.removeValue(forKey: key) else { return }
        fromSeed[edge.src]?.removeAll { $0 == key }
        touching[edge.src]?.removeAll { $0 == key }
        touching[edge.dst]?.removeAll { $0 == key }
    }

    // MARK: Write

    /// One edge per distinct row: the seed to the recording at its place in the list.
    static func edgesOf(seedRid: Int64, type: Int32, rids: [Int64], nowMs: Int64) -> [Edge] {
        var seen: Set<Int64> = []
        var out: [Edge] = []
        out.reserveCapacity(rids.count)
        for i in rids.indices {
            let rid = rids[i]
            if rid == 0 || rid == seedRid || !seen.insert(rid).inserted { continue }
            out.append(Edge(src: seedRid, dst: rid, type: type,
                            record: Record(v: formatVersion, w: weightQ16(type: type, rank: i + 1), r: Int32(i + 1), t: nowMs)))
        }
        return out
    }

    /// Stores the list of `seedRid` as edges, replacing what an earlier fetch of the same seed and kind left. The
    /// graph is a cache of the lists: a failed write is not a failed radio, and the next fetch puts it right.
    public func record(seedRid: Int64, kind: Int, rids: [Int64], nowMs: Int64) {
        if seedRid == 0 { return }
        load()
        let type = Self.typeOf(kind: kind)
        let fresh = Self.edgesOf(seedRid: seedRid, type: type, rids: rids, nowMs: nowMs)
        let freshKeys = Set(fresh.map { BrainKey(Self.key($0.src, $0.dst, $0.type)) })
        var gone: [String] = []
        for key in fromSeed[seedRid] ?? [] where edges[key]?.type == type && !freshKeys.contains(key) {
            gone.append(key.text)
        }
        if !gone.isEmpty && file.remove(gone) {
            for key in gone { drop(BrainKey(key)) }
        }
        var writes: [(key: String, payload: [UInt8])] = []
        writes.reserveCapacity(fresh.count)
        for edge in fresh {
            guard let payload = Self.payload(edge.record) else { continue }
            writes.append((Self.key(edge.src, edge.dst, edge.type), payload))
        }
        if !writes.isEmpty && file.put(writes) {
            for edge in fresh { add(edge, key: BrainKey(Self.key(edge.src, edge.dst, edge.type))) }
        }
    }

    private static func payload(_ record: Record) -> [UInt8]? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(record)).map { [UInt8]($0) }
    }

    /// Drops the edges of lists fetched more than `retentionMs` ago. Returns how many went.
    @discardableResult
    public func prune(nowMs: Int64) -> Int {
        load()
        let before = nowMs - Self.retentionMs
        var doomed: [BrainKey] = []
        for (key, edge) in edges where edge.record.t < before { doomed.append(key) }
        if doomed.isEmpty { return 0 }
        guard file.remove(doomed.map(\.text)) else { return 0 }
        for key in doomed { drop(key) }
        file.compactIfNeeded()
        return doomed.count
    }

    // MARK: Read

    /// The stored edges that touch any of `nodes`, as the extra edges a mix is planned with.
    public func edgesFor(_ nodes: [Int64]) -> [MixPlanner.Edge] {
        if nodes.isEmpty { return [] }
        load()
        var seenNodes: Set<Int64> = []
        var seenKeys: Set<BrainKey> = []
        var out: [MixPlanner.Edge] = []
        for node in nodes where seenNodes.insert(node).inserted {
            for key in touching[node] ?? [] where seenKeys.insert(key).inserted {
                guard let edge = edges[key] else { continue }
                out.append(MixPlanner.Edge(a: edge.src, b: edge.dst, weight: Double(edge.record.w) / Self.weightUnit))
            }
        }
        // A fixed order: the planner's graph does not depend on it, but a stored mix and a test should not either.
        out.sort { x, y in x.a != y.a ? x.a < y.a : (x.b != y.b ? x.b < y.b : x.weight < y.weight) }
        return out
    }

    /// Every stored edge, in a fixed order (the island fit's graph, 5.3).
    public func allEdges() -> [MixPlanner.Edge] {
        load()
        var out: [MixPlanner.Edge] = []
        out.reserveCapacity(edges.count)
        for edge in edges.values { out.append(MixPlanner.Edge(a: edge.src, b: edge.dst, weight: Double(edge.record.w) / Self.weightUnit)) }
        out.sort { x, y in x.a != y.a ? x.a < y.a : (x.b != y.b ? x.b < y.b : x.weight < y.weight) }
        return out
    }

    public var count: Int {
        load()
        return edges.count
    }

    // MARK: The one-time conversion

    public var isBackfilled: Bool {
        load()
        return backfilledAtMs != nil
    }

    public func markBackfilled(nowMs: Int64) {
        load()
        guard let data = try? JSONEncoder().encode(Marker(v: Self.formatVersion, t: nowMs)) else { return }
        if file.put(Self.backfillKey, [UInt8](data)) { backfilledAtMs = nowMs }
    }
}
