import Foundation
@testable import PixlLibrary

/// Three made-up listeners for the evaluation tests (docs/brain-spec.md, 11: "Eval on three synthetic listeners in
/// CI"). A transliteration of the Android `:brain` module's `SyntheticListeners.kt`, so the same numbers come out of
/// the same code. Each has a hidden finish probability per track, and a history drawn from it, so a scorer that has
/// learned who they are should beat one that has not.
enum SyntheticListeners {
    struct Listener {
        let name: String
        let events: [PlayEvent]
        let library: [Candidate]
        let novel: [Candidate]
        let seeds: [Retrieval.SeedList]
        let finishRate: [Int64: Double]
        let nowMs: Int64
    }

    private static let t0: Int64 = 1_750_000_000_000
    private static let day: Int64 = 86_400_000

    private static func rid(_ world: String, _ i: Int) -> Int64 { BrainHash.id(BrainHash.fnv1a64("n:rid \(world) \(i)")) }
    private static func aid(_ world: String, _ i: Int) -> Int64 { BrainHash.id(BrainHash.fnv1a64("n:aid \(world) \(i)")) }

    private static func int(_ rng: inout BrainHash.Rng, _ n: Int) -> Int {
        let v = Int(BrainMath.floorToLong(rng.uniform() * Double(n)))
        return v < 0 ? 0 : (v > n - 1 ? n - 1 : v)
    }

    /// `artistRate`: finish probability by artist index; `trackJitter`: how far a track can sit from its artist's rate.
    private static func build(name: String, artists: Int, libraryTracks: Int, novelTracks: Int, events: Int, days: Int,
                              artistRate: (Int) -> Double, trackJitter: Double, popularShare: Double) -> Listener {
        var rng = BrainHash.Rng(seed: BrainHash.fnv1a64("synthetic:\(name)"))
        var artistOf = [Int](repeating: 0, count: libraryTracks + novelTracks)
        for i in artistOf.indices { artistOf[i] = int(&rng, artists) }
        var rate: [Int64: Double] = [:]
        for i in 0..<(libraryTracks + novelTracks) {
            let r = artistRate(artistOf[i]) + (rng.uniform() - 0.5) * 2.0 * trackJitter
            rate[rid(name, i)] = BrainMath.clip(r, 0.03, 0.97)
        }
        let library = (0..<libraryTracks).map {
            Candidate(rid: rid(name, $0), aid: aid(name, artistOf[$0]),
                      albumKey: BrainHash.id(BrainHash.fnv1a64("alb \(name) \($0 / 4)")), inLibrary: true)
        }
        let novel = (libraryTracks..<(libraryTracks + novelTracks)).map {
            Candidate(rid: rid(name, $0), aid: aid(name, artistOf[$0]),
                      albumKey: BrainHash.id(BrainHash.fnv1a64("alb \(name) \($0 / 4)")), inLibrary: false)
        }
        var list: [PlayEvent] = []
        list.reserveCapacity(events)
        var t = t0
        let step = (Int64(days) * day) / Int64(events)
        var session: Int64 = 1
        var pos: Int32 = 0
        for i in 0..<events {
            // A new session every 12 plays, or after a quiet gap.
            if i % 12 == 0 {
                session += 1
                pos = 0
                t += 2 * 3_600_000
            }
            // Mostly the tracks they like (a popular few are played again and again), sometimes anything.
            let idx = rng.uniform() < popularShare ? int(&rng, min(120, libraryTracks)) : int(&rng, libraryTracks)
            let c = library[idx]
            let finish = rng.uniform() < (rate[c.rid] ?? 0.5)
            let duration = Int32(150_000 + int(&rng, 120_000))
            let played: Int32 = finish ? duration : Int32(3_000 + int(&rng, 25_000))
            t += step
            let key = "n:track|\(c.rid)"
            list.append(PlayEvent(
                eventId: PlayEvent.mintId(startedAtMs: t, origin: Origin.live, keyAtWrite: key) { _ in nil },
                origin: Origin.live, rid: c.rid, primaryAid: c.aid, keyAtWrite: key, startedAtMs: t, tzOffsetMin: 0,
                playedMs: played, durationMs: duration, startReason: StartReason.tap,
                endReason: finish ? EndReason.trackDone : EndReason.next, surface: Surface.playlist, sessionId: session,
                posInSession: pos, route: Route.speaker))
            pos += 1
            t += Int64(played)
        }
        list.sort { $0.eventId < $1.eventId }
        let all = library + novel
        var seeds: [Retrieval.SeedList] = []
        for (s, seed) in library.prefix(3).enumerated() {
            var rids: [Int64] = []
            var seen: Set<Int64> = []
            while rids.count < 40 {
                let pick = all[int(&rng, all.count)]
                if pick.rid != seed.rid && seen.insert(pick.rid).inserted { rids.append(pick.rid) }
            }
            seeds.append(Retrieval.SeedList(seedRid: seed.rid, seedAid: seed.aid, rids: rids,
                                            edgeFactor: s == 2 ? Graph.related : Graph.radio))
        }
        return Listener(name: name, events: list, library: library, novel: novel, seeds: seeds, finishRate: rate, nowMs: t)
    }

    /// Twenty-five loved artists out of 80; everything else is skipped most of the time.
    static func loyal() -> Listener {
        build(name: "loyal", artists: 80, libraryTracks: 1500, novelTracks: 1000, events: 2000, days: 120,
              artistRate: { $0 < 25 ? 0.9 : 0.22 }, trackJitter: 0.05, popularShare: 0.5)
    }

    /// Many artists, each with its own taste level.
    static func explorer() -> Listener {
        var levels = BrainHash.Rng(seed: BrainHash.fnv1a64("synthetic:explorer:levels"))
        var table = [Double](repeating: 0.0, count: 120)
        for i in table.indices { table[i] = 0.15 + 0.75 * levels.uniform() }
        return build(name: "explorer", artists: 120, libraryTracks: 2000, novelTracks: 1200, events: 2500, days: 150,
                     artistRate: { table[$0] }, trackJitter: 0.15, popularShare: 0.25)
    }

    /// Few artists, and the track matters more than the artist.
    static func repeater() -> Listener {
        build(name: "repeater", artists: 40, libraryTracks: 800, novelTracks: 600, events: 1800, days: 90,
              artistRate: { _ in 0.5 }, trackJitter: 0.45, popularShare: 0.7)
    }

    static func all() -> [Listener] { [loyal(), explorer(), repeater()] }
}
