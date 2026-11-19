// The rules of the arms stage 2b completes (docs/brain-spec.md, 6.1): SIM, BACK and EDGE. They decide which candidates
// carry the flag the planner reads; the data they need (a similar artist's top songs, the imported plays, the atlas)
// comes from the caller as plain numbers. A transliteration of the Android `:brain` module's `ArmRules.kt`.

public enum ArmRules {
    /// BACK: imported-history tracks with at least this many completions ...
    public static let backMinCompletions = 5

    /// ... last played over a year ago.
    public static let backAgeMs: Int64 = 365 * 86_400_000

    /// SIM and EDGE start from artists and tags with an affinity above this.
    public static let highAffinity = 0.5

    /// EDGE: a tag the listener plays less than this is "not yet theirs" (`share < 0.005`).
    public static let edgeMaxShare = 0.005

    /// BACK: "forgotten favourites", not in the library.
    public static func isBack(completions: Int, lastPlayedMs: Int64, nowMs: Int64, inLibrary: Bool) -> Bool {
        !inLibrary && completions >= backMinCompletions && lastPlayedMs > 0 && nowMs &- lastPlayedMs > backAgeMs
    }

    /// SIM: the artists to take top tracks from. `aff` and `weight` are the listener's artist affinity and decayed play
    /// weight for each of `aids`; the result is the artists with `aff > 0.5` and enough plays (the ARTIST arm's own
    /// bar), best first, ties by id. The similar artists of those are what the caller then fetches.
    public static func simSources(aids: [Int64], aff: [Double], weight: [Double], limit: Int) -> [Int64] {
        var idx: [Int] = []
        for i in 0..<aids.count where aff[i] > highAffinity && weight[i] >= StationPlanner.artistArmWeight { idx.append(i) }
        idx.sort { a, b in
            let ka = BrainMath.orderKey(aff[a])
            let kb = BrainMath.orderKey(aff[b])
            if ka != kb { return ka > kb }
            return aids[a] < aids[b]
        }
        let n = idx.count < limit ? idx.count : limit
        return (0..<n).map { aids[idx[$0]] }
    }

    /// EDGE: the genres next to the ones the listener loves. `loved` are atlas ids with `aff > 0.5`, best first;
    /// `share` says how much of the listener's listening a tag already is. A genre is adjacent to a loved one when it is
    /// a sibling (a child of one of its parents), one of its nearest related genres, or a genre it is a fusion with;
    /// not the loved genre itself, not its ancestors or descendants, not a family root, and not one the listener
    /// already plays (`share >= 0.005`). Best loved genre first, then by id. Unknown genres are absent: an atlas id the
    /// atlas does not hold is skipped.
    public static func adjacentGenres(_ atlas: GenreAtlas, loved: [Int], share: (Int) -> Double, limit: Int) -> [Int] {
        var rank: [Int: Int] = [:]
        let all = atlas.allIds
        for r in 0..<loved.count {
            guard let g = atlas.genre(loved[r]) else { continue }
            let ancestors = atlas.ancestors(g.id)
            var candidates = Set<Int>()
            for rel in g.related { candidates.insert(rel) }
            for fus in g.fusionOf { candidates.insert(fus) }
            for parent in g.parents {
                for id in all {
                    guard let other = atlas.genre(id) else { continue }
                    for p in other.parents where p == parent { candidates.insert(id) }
                }
            }
            for c in candidates.sorted() {
                guard let cg = atlas.genre(c) else { continue }
                if c == g.id || cg.depth < 1 { continue }
                if ancestors.contains(c) { continue }
                if atlas.ancestors(c).contains(g.id) { continue }
                if share(c) >= edgeMaxShare { continue }
                if rank[c] == nil || rank[c]! > r { rank[c] = r }
            }
        }
        let ordered = rank.keys.sorted { a, b in
            let ra = rank[a]!
            let rb = rank[b]!
            if ra != rb { return ra < rb }
            return a < b
        }
        let n = ordered.count < limit ? ordered.count : limit
        return Array(ordered[0..<n])
    }
}
