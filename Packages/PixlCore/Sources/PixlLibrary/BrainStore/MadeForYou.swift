// The made-for-you lists of stage 2b (docs/brain-spec.md, 8.2) that `BrainMixes` does not plan with the station planner, and
// the helpers the island-aware ones share: the genres next to the listener's own (arm EDGE), the names of islands, the library
// merged with the shortlist. A port of Android's `MadeForYouBuild.kt`. Everything reads the files and the caches; nothing
// here touches the network.

import Foundation
import PixlModel

/// What the lists of stage 2b need beyond stage 2a: the islands, the DNA, the library by id, the atlas, the saved releases and
/// the artists the listener picked. Passed to `BrainMixes.configureStage2b`; nothing in it is read until a list is built.
public struct Stage2bParts: Sendable {
    public var islands: IslandStore
    public var builder: IslandBuilder
    public var candidateDna: CandidateDna
    public var libraryRids: LibraryRids
    public var atlas: any AtlasProvider
    public var newReleases: NewReleases?
    public var dna: DnaRepository?
    public var picked: PickedArtists?

    public init(islands: IslandStore, builder: IslandBuilder, candidateDna: CandidateDna, libraryRids: LibraryRids,
                atlas: any AtlasProvider, newReleases: NewReleases?, dna: DnaRepository?, picked: PickedArtists?) {
        self.islands = islands
        self.builder = builder
        self.candidateDna = candidateDna
        self.libraryRids = libraryRids
        self.atlas = atlas
        self.newReleases = newReleases
        self.dna = dna
        self.picked = picked
    }
}

/// A Just Dropped or First Listen list needs at least this many to be worth a card.
let minSimpleItems = 6
private let edgeLibraryCap = 150

/// The shortlist (it has repeat activation) first, then every other library track once.
func mergedLibrary(_ shortlisted: [LibraryTrack], _ all: [LibraryTrack]) -> [LibraryTrack] {
    var seen = Set<Int64>()
    seen.reserveCapacity(all.count * 2)
    var out: [LibraryTrack] = []
    out.reserveCapacity(all.count)
    for t in shortlisted where seen.insert(t.rid).inserted { out.append(t) }
    for t in all where seen.insert(t.rid).inserted { out.append(t) }
    return out
}

extension BrainMixes {
    /// The genres next to the ones the listener plays (6.1 EDGE): siblings and relatives of their six most played specific
    /// genres that they play next to nothing of. Empty when the atlas or the listener's genres are not known: unknown stays
    /// unknown.
    public func adjacentGenres(limit: Int = 8) async -> [Int] {
        guard let parts, let atlas = await parts.atlas.atlas() else { return [] }
        let shares = await parts.islands.tagShares()
        if shares.isEmpty { return [] }
        let loved = shares.keys.filter { (atlas.genre($0)?.depth ?? 0) >= 1 }.sorted { a, b in
            let ka = BrainMath.orderKey(shares[a]!)
            let kb = BrainMath.orderKey(shares[b]!)
            if ka != kb { return ka > kb }
            return a < b
        }.prefix(6)
        if loved.isEmpty { return [] }
        return ArmRules.adjacentGenres(atlas, loved: Array(loved), share: { shares[$0] ?? 0.0 }, limit: limit)
    }

    /// Library tracks the listener has not played whose strongest genre is an adjacent one (arm EDGE), each once.
    func edgeLibrary(_ nowMs: Int64) async -> [LibraryTrack] {
        var seen = Set<Int64>()
        var out: [LibraryTrack] = []
        for group in await edgeByGenre(nowMs) { for t in group.tracks where seen.insert(t.rid).inserted { out.append(t) } }
        return out
    }

    /// The same tracks grouped by the adjacent genre that is their strongest, in the order of `adjacentGenres`.
    func edgeByGenre(_ nowMs: Int64) async -> [(genre: Int, tracks: [LibraryTrack])] {
        guard let parts, let dna = parts.dna else { return [] }
        let adjacentList = await adjacentGenres()
        let adjacent = Set(adjacentList)
        if adjacent.isEmpty { return [] }
        let all = await parts.libraryRids.all(nowMs: nowMs)
        var byRid: [Int64: LibraryTrack] = [:]
        byRid.reserveCapacity(all.count * 2)
        for t in all where byRid[t.rid] == nil { byRid[t.rid] = t }
        let rids = byRid.keys.sorted()
        let heard: Set<Int64> = await engine.readAffinity { st in
            Set(rids.filter { Affinity.isHeard(st, family: Family.track, key: $0) })
        }
        var found: [Int: [Int64]] = [:]
        for row in await dna.tracks(rids) where !heard.contains(row.rid) {
            let v = row.tagVector
            if !v.isEmpty && adjacent.contains(v.top) { found[v.top, default: []].append(row.rid) }
        }
        var out: [(genre: Int, tracks: [LibraryTrack])] = []
        var left = edgeLibraryCap
        for genre in adjacentList {
            guard var ids = found[genre] else { continue }
            ids.sort()
            let tracks = ids.prefix(left).compactMap { byRid[$0] }
            if tracks.isEmpty { continue }
            out.append((genre, tracks))
            left -= tracks.count
            if left <= 0 { break }
        }
        return out
    }

    /// "Soft pop & R&B · Sabrina Carpenter, Chappell Roan": the island's two highest-lift genres and its two biggest artists,
    /// real ones only.
    func islandSubtitle(_ island: Islands.Island, nowMs: Int64) async -> String {
        guard let parts else { return "" }
        let genreText = await islandGenreName(island)
        var names: [Int64: String] = [:]
        for t in await parts.libraryRids.all(nowMs: nowMs) where t.aid != 0 && names[t.aid] == nil {
            names[t.aid] = BrainLibraryIndex.primaryArtistName(t.song)
        }
        let artists = island.topArtists.prefix(2).compactMap { names[$0] }.filter { !BrainText.isBlank($0) }
        return [genreText, artists.joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "Soft pop & R&B": the island's name by its two highest-lift genres only, "" when the island is not named (too few of its tracks
    /// have a genre). An island is named only when enough of it has a genre (unknown stays unknown), and only by a genre among its
    /// biggest shares.
    func islandGenreName(_ island: Islands.Island) async -> String {
        guard let parts else { return "" }
        var genres: [String] = []
        if let atlas = await parts.atlas.atlas(), await taggedShare(island) >= Self.nameMinTagged {
            let lift = island.liftTags.filter { island.topTags.contains($0) }
            for id in IslandNames.pick(atlas, lift) {
                if let name = AtlasNames.genreName(atlas, id) { genres.append(name) }
            }
        }
        var genreText = genres.joined(separator: " & ")
        if let first = genreText.first { genreText = first.uppercased() + genreText.dropFirst() }
        return genreText
    }

    /// At least this share of an island's tracks must have a genre before the island gets a genre name.
    static let nameMinTagged = 0.4

    /// The share of the island's placed tracks that carry a genre at all (0...1), looked up in the DNA.
    func taggedShare(_ island: Islands.Island) async -> Double {
        guard let parts, let dna = parts.dna, let members = await parts.islands.current()?.memberOf else { return 0.0 }
        var rids: [Int64] = []
        rids.reserveCapacity(island.size)
        for (rid, id) in members where id == island.id { rids.append(rid) }
        if rids.isEmpty { return 0.0 }
        var tagged = 0
        for row in await dna.tracks(rids) where !row.tagVector.isEmpty { tagged += 1 }
        return Double(tagged) / Double(rids.count)
    }

    /// The recording ids of this week's First Listen, or none.
    func firstListenRids(now: Int64, tz: Int32) -> Set<Int64> {
        let spec = MixSpec(kind: MixKinds.firstListen)
        guard let stored = served.todays(surface: spec.surface, nowMs: now, tzOffsetMin: tz, surfaceId: spec.surfaceId, weekly: true)
        else { return [] }
        return Set(stored.items.map(\.rid))
    }

    /// On Repeat, Rediscover and Just Dropped (6.2): ranked by one number each and filled under the hard constraints of 6.4.
    func buildSimple(_ spec: MixSpec, now: Int64, tz: Int32, regenerate: Int32) async -> StoredMix? {
        guard let parts else { return nil }
        let level = Novelty.clamp(await sources.noveltyLevel())
        let salt = await engine.salt()
        let ignored = await engine.ignoredRids(nowMs: now)
        let log = served.recent(nowMs: now)
        var taken = Repetition.takenOnDay(ServedListStore.newestPerList(log), nowMs: now, tzOffsetMin: tz, exceptSurface: spec.surface, exceptId: spec.surfaceId)
        // This week's First Listen is held all week (8.2): no other list repeats it.
        taken.formUnion(firstListenRids(now: now, tz: tz))
        let times = Repetition.timesServed(log, nowMs: now)
        let excluded = taken.union(ignored)
        let constraints = await sources.constraints()
        let day = Repetition.mixDay(now, tzOffsetMin: tz)
        let inner = Int64(bitPattern: BrainHash.splitmix64(
            UInt64(bitPattern: day &* 8 &+ Int64(spec.kind) &+ Int64(regenerate) &* 1024)))
        let tie = Int64(bitPattern: BrainHash.splitmix64(UInt64(bitPattern: salt ^ inner)))
        var items: [StoredMixItem] = []
        items.reserveCapacity(ListMixes.size)
        if spec.kind == MixKinds.onRepeat || spec.kind == MixKinds.rediscover {
            var seen = Set<Int64>()
            let tracks = await parts.libraryRids.all(nowMs: now).filter { seen.insert($0.rid).inserted }
            if tracks.isEmpty { return nil }
            let rids = tracks.map(\.rid)
            let aids = tracks.map(\.aid)
            let albums = tracks.map { AutoplayPool.albumHash(BrainLibraryIndex.albumKey(of: $0.song.album)) }
            let isRepeat = spec.kind == MixKinds.onRepeat
            let picked: [ListMixes.Item] = await engine.readAffinity { st in
                let ranked = isRepeat
                    ? ListMixes.onRepeat(st, rids: rids, aids: aids, albumKeys: albums, nowMs: now)
                    : ListMixes.rediscover(st, rids: rids, aids: aids, albumKeys: albums, servedTimes: times, nowMs: now)
                return ListMixes.fill(ranked, count: ListMixes.size, excluded: excluded, tieSeed: tie)
            }
            for p in picked {
                let track = tracks[p.tag]
                // The list's own title says what the songs have in common; a line under each would only repeat it.
                items.append(StoredMixItem(rid: p.rid, songId: track.song.id, arm: p.arm, slot: items.count, whyKey: WhyLine.none))
            }
        } else {
            guard let releases = parts.newReleases else { return nil }
            let all = await sources.library()
            let cards = await releases.cards(blocked: constraints.blocked, adjustments: constraints.adjustments,
                                             library: BrainLibraryIndex(songs: all))
            if cards.isEmpty { return nil }
            let rids = cards.map(\.stored.rid)
            let names = cards.map { $0.stored.row.artists.first?.name ?? "" }
            let aids = await repository.resolveArtistNames(names)
            let albums = cards.map { AutoplayPool.albumHash(BrainLibraryIndex.albumKey(of: $0.stored.row.album ?? "")) }
            let recency = (0..<cards.count).map { Double(cards.count - $0) }
            let picked: [ListMixes.Item] = await engine.readAffinity { st in
                let p0 = Affinity.p0(st, nowMs: now)
                let aff = (0..<cards.count).map { aids[$0] == 0 ? 0.0 : Affinity.aff(st, family: Family.artist, key: aids[$0], nowMs: now, p0: p0) }
                let heard = (0..<cards.count).map { aids[$0] != 0 && Affinity.isHeard(st, family: Family.artist, key: aids[$0]) }
                return ListMixes.fill(
                    ListMixes.justDropped(rids: rids, aids: aids, albumKeys: albums, artistAff: aff, artistHeard: heard, recency: recency),
                    count: ListMixes.size, excluded: excluded, tieSeed: tie, maxPerArtist: 2)
            }
            for p in picked {
                let card = cards[p.tag]
                items.append(StoredMixItem(rid: p.rid, row: card.stored, arm: Arm.new, slot: items.count, whyKey: WhyLine.newRelease,
                                           whyArg: p.aid, whyName: card.release.artistName))
            }
        }
        if items.count < minSimpleItems { return nil }
        return StoredMix(kind: spec.kind, builtAtMs: now, seed: tie, regenerate: regenerate, novelty: level,
                         tasteSignature: constraints.signature, seedLists: 0, items: items,
                         mixId: spec.surfaceId)
    }
}

// MARK: - The kit the app builds once

/// Everything of stage 2b that has no dependency on the mixes themselves, built in one call so the app's side stays thin.
/// Reads nothing and fetches nothing: every file opens on first use, off the main actor.
public struct Stage2bKit: Sendable {
    public let parts: Stage2bParts
    /// Nil when the knowledge layer (the DNA files) is not there: no genre or mood stations then.
    public let genre: GenreStations?
    public let picked: PickedArtists
    public let planStore: HomePlanStore
    public let recent: RecentContexts

    public static func make(directory: URL, engine: BrainEngine, repository: BrainRepository, sources: MixSources,
                            dna: DnaRepository?, atlas: any AtlasProvider, newReleases: NewReleases?,
                            flow: (any FlowFactsSource)? = nil) -> Stage2bKit {
        let state = StateValues.of(engine)
        let islands = IslandStore(directory: directory, state: state)
        let libraryRids = LibraryRids(sources: sources, repository: repository)
        let inputs = IslandInputs.live(engine: engine, repository: repository, library: libraryRids, dna: dna, atlas: atlas,
                                       timing: sources.timing)
        let picked = PickedArtists(state: state, repository: repository)
        let parts = Stage2bParts(islands: islands, builder: IslandBuilder(store: islands, inputs: inputs, state: state),
                                 candidateDna: CandidateDna(store: islands, dna: dna, flow: flow), libraryRids: libraryRids, atlas: atlas,
                                 newReleases: newReleases, dna: dna, picked: picked)
        let genre = dna.map { GenreStations(library: libraryRids, dna: $0, atlas: atlas, engine: engine, islands: islands) }
        return Stage2bKit(parts: parts, genre: genre, picked: picked, planStore: HomePlanStore(directory: directory),
                          recent: RecentContexts(directory: directory))
    }
}

public extension IslandInputs {
    /// The fit's inputs as the app has them: the library by id, the stored graph, the affinity tables, the event log and the DNA.
    static func live(engine: BrainEngine, repository: BrainRepository, library: LibraryRids, dna: DnaRepository?,
                     atlas: (any AtlasProvider)? = nil, timing: @escaping @Sendable (String, Int64) -> Void) -> IslandInputs {
        IslandInputs(
            library: { now in await library.all(nowMs: now) },
            edges: { await repository.allEdges() },
            hasState: { await engine.hasState() },
            weights: { rids, now in
                await engine.readAffinity { st in
                    var out: [Int64: [Double]] = [:]
                    for rid in rids {
                        let k = st.counter(Family.track, rid)
                        let prior = st.prior(Family.track, rid)
                        let pos = (k.map { Affinity.pos($0, nowMs: now) } ?? 0.0) + (prior.map { BrainMath.fromQ($0.posQ) } ?? 0.0)
                        if pos <= 0.0 { continue }
                        out[rid] = [pos, k.map { Affinity.posRecent($0, nowMs: now) } ?? 0.0]
                    }
                    return out
                }
            },
            qualifiedPlaysSince: { since in BrainEventQueries.qualifiedPlays(await engine.recentEvents(sinceMs: since), sinceMs: since) },
            tags: { rids in
                var out: [Int64: Tags.Vector] = [:]
                // Nothing Spotify said is a feature of the fit (it never trains a model): the vector is re-merged without it.
                // Without an atlas the stored vector cannot be taken apart, so no tags are used at all.
                guard let dna, let atlas = await atlas?.atlas() else { return out }
                for row in await dna.tracks(rids) {
                    let v = DnaAssembler.tagVectorWithoutSpotify(row, atlas: atlas, atlasVersion: atlas.version)
                    if !v.isEmpty { out[row.rid] = v }
                }
                return out
            },
            timing: timing)
    }
}
