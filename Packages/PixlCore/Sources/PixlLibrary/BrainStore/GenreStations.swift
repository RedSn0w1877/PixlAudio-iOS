// Genre and mood stations (docs/brain-spec.md, 6.2, 8.1 "Stations for you", 8.3, stage 2b): the listener's own songs under an
// atlas node seed the station and the radios of those seeds fill it, as for an album or a playlist station. Unknown genres are
// absent: a song with no tags is under no genre, a name the atlas does not hold gives no card and no tile, and a node with
// none of the listener's songs under it starts nothing. A port of Android's `GenreStations.kt`.
//
// Reads the track DNA of the library once per library change, off the main actor; never at app start.

import Foundation
import PixlModel

/// A genre or mood station as a card.
public struct StationCard: Sendable, Equatable {
    public static let kindGenre = 0
    public static let kindMood = 1

    public var kind: Int
    /// The atlas id of the genre, or the index of the mood in the atlas's mood list.
    public var atlasId: Int
    /// A real atlas name, sentence case. Never invented: a node the atlas does not hold has no card.
    public var name: String
    /// How many of the listener's songs sit under it.
    public var count: Int
    /// Up to three album arts.
    public var covers: [String]
}

public actor GenreStations {
    /// A tag below this weight (of 255) is a trace, not what the song is.
    public static let minQ = 40
    public static let minSongs = 8
    public static let minAdjacentSongs = 3
    public static let genreCards = 5
    /// A genre or mood station is seeded by up to this many of the listener's songs (6.2: up to 5).
    public static let seeds = 5

    private struct Index {
        var key: String
        var byGenre: [Int: [LibraryTrack]]
        var byMood: [Int: [LibraryTrack]]
    }

    private let library: LibraryRids
    private let dna: DnaRepository
    private let atlasProvider: any AtlasProvider
    private let engine: BrainEngine
    private let islands: IslandStore
    private var cache: Index?

    public init(library: LibraryRids, dna: DnaRepository, atlas: any AtlasProvider, engine: BrainEngine, islands: IslandStore) {
        self.library = library
        self.dna = dna
        atlasProvider = atlas
        self.engine = engine
        self.islands = islands
    }

    /// The genres and moods of the library, by the DNA the knowledge lanes stored. A track with none is in none.
    private func index(_ nowMs: Int64) async -> Index {
        let all = await library.all(nowMs: nowMs)
        // The DNA changes while the library does not (the refresh job writes it): its row count and write counter are in the key.
        let key = "\(all.count):\(all.first?.rid ?? 0):\(all.last?.rid ?? 0):\(await islands.embeddingCount()):\(await dna.count()):\(await dna.revision())"
        if let cache, BrainKey.sameBytes(cache.key, key) { return cache }
        var byRid: [Int64: LibraryTrack] = [:]
        byRid.reserveCapacity(all.count * 2)
        for t in all where byRid[t.rid] == nil { byRid[t.rid] = t }
        var byGenre: [Int: [LibraryTrack]] = [:]
        var byMood: [Int: [LibraryTrack]] = [:]
        for row in await dna.tracks(byRid.keys.sorted()) {
            guard let track = byRid[row.rid] else { continue }
            // Parents carry weight too (3.4 spreads to them), so "pop" holds its sub-genres' songs.
            for t in row.tagVector.tags where t.q >= Self.minQ { byGenre[t.atlasId, default: []].append(track) }
            for m in row.moods { byMood[Int(m), default: []].append(track) }
        }
        let built = Index(key: key, byGenre: byGenre, byMood: byMood)
        cache = built
        return built
    }

    /// The atlas id of a name ("Hip-Hop", "R&B"), or `GenreAtlas.none` when the atlas has no such genre.
    public func idForName(_ name: String) async -> Int { await atlasProvider.atlas()?.idForName(name) ?? GenreAtlas.none }

    /// The names among `names` the atlas holds: the Search tiles of a genre the atlas lacks are not shown. Nil when the atlas
    /// could not be read (nothing is then hidden or shown on its word).
    public func knownNames(_ names: [String]) async -> Set<String>? {
        guard let atlas = await atlasProvider.atlas() else { return nil }
        return Set(names.filter { name in
            let id = atlas.idForName(name)
            return id != GenreAtlas.none && AtlasNames.genreName(atlas, id) != nil
        })
    }

    /// The listener's songs under the node, most played first; empty when there are none (nothing is guessed).
    public func songsFor(kind: Int, atlasId: Int, nowMs: Int64) async -> [Song] {
        let idx = await index(nowMs)
        let tracks = (kind == StationCard.kindMood ? idx.byMood[atlasId] : idx.byGenre[atlasId]) ?? []
        if tracks.isEmpty { return [] }
        let rids = tracks.map(\.rid)
        let weights: [Int64: Double] = await engine.readAffinity { st in
            var out: [Int64: Double] = [:]
            for r in rids { out[r] = Affinity.weight(st, family: Family.track, key: r, nowMs: nowMs) }
            return out
        }
        var seen = Set<Int64>()
        let distinct = tracks.filter { seen.insert($0.rid).inserted }
        return distinct.sorted { a, b in
            let ka = BrainMath.orderKey(weights[a.rid] ?? 0.0)
            let kb = BrainMath.orderKey(weights[b.rid] ?? 0.0)
            if ka != kb { return ka > kb }
            return a.rid < b.rid
        }.map(\.song)
    }

    /// Up to six cards from the listener's biggest nodes (5 genres and 1 mood), plus one adjacent genre they hold songs of
    /// (8.1 "Stations for you"). A genre must hold at least `minSongs` of their songs, and a genre related to one already
    /// chosen (an ancestor or a descendant) is skipped, so the shelf is not "Pop", "Dance-pop", "Pop rock".
    public func cards(nowMs: Int64, adjacent: [Int]) async -> [StationCard] {
        guard let atlas = await atlasProvider.atlas() else { return [] }
        let idx = await index(nowMs)
        var out: [StationCard] = []
        var chosen: [Int] = []
        func distinct(_ t: [LibraryTrack]) -> [LibraryTrack] {
            var seen = Set<Int64>()
            return t.filter { seen.insert($0.rid).inserted }
        }
        let candidates = idx.byGenre.filter {
            (atlas.genre($0.key)?.depth ?? 0) >= 1 && AtlasNames.isShown(atlas.genre($0.key)?.name) && distinct($0.value).count >= Self.minSongs
        }
        // "Your top nodes": ranked by what the listener plays (decayed finished plays of the songs under each genre), then by how
        // many songs sit under it; a genre the listener owns a lot of but never plays does not lead the shelf.
        var wanted = Set<Int64>()
        for entry in candidates { for t in entry.value { wanted.insert(t.rid) } }
        let played = await playedWeight(wanted, nowMs: nowMs)
        var score: [Int: Int64] = [:]
        for entry in candidates {
            var total = 0.0
            for t in distinct(entry.value) { total += played[t.rid] ?? 0.0 }
            score[entry.key] = BrainMath.orderKey(total)
        }
        let genres = candidates.sorted { a, b in
            let sa = score[a.key] ?? 0, sb = score[b.key] ?? 0
            if sa != sb { return sa > sb }
            if a.value.count != b.value.count { return a.value.count > b.value.count }
            return a.key < b.key
        }
        for (id, tracks) in genres {
            if out.count >= Self.genreCards { break }
            if chosen.contains(where: { Self.related(atlas, $0, id) }) { continue }
            guard let name = AtlasNames.genreName(atlas, id) else { continue }
            chosen.append(id)
            out.append(card(StationCard.kindGenre, id, name, tracks))
        }
        let moods = idx.byMood.filter {
            $0.key >= 0 && $0.key < atlas.moods.count && AtlasNames.moodName(atlas, $0.key) != nil && distinct($0.value).count >= Self.minSongs
        }.sorted { a, b in a.value.count != b.value.count ? a.value.count > b.value.count : a.key < b.key }
        if let (id, tracks) = moods.first, let name = AtlasNames.moodName(atlas, id) { out.append(card(StationCard.kindMood, id, name, tracks)) }
        for id in adjacent {
            let tracks = idx.byGenre[id] ?? []
            if tracks.count < Self.minAdjacentSongs || out.contains(where: { $0.kind == StationCard.kindGenre && $0.atlasId == id }) { continue }
            guard let name = AtlasNames.genreName(atlas, id) else { continue }
            out.append(card(StationCard.kindGenre, id, name, tracks))
            break
        }
        return out
    }

    private func playedWeight(_ rids: Set<Int64>, nowMs: Int64) async -> [Int64: Double] {
        let wanted = Array(rids)
        return await engine.readAffinity { st in
            var out: [Int64: Double] = [:]
            out.reserveCapacity(wanted.count)
            for r in wanted {
                let w = Affinity.weight(st, family: Family.track, key: r, nowMs: nowMs)
                if w > 0.0 { out[r] = w }
            }
            return out
        }
    }

    private func card(_ kind: Int, _ id: Int, _ name: String, _ tracks: [LibraryTrack]) -> StationCard {
        var seen = Set<Int64>()
        let distinct = tracks.filter { seen.insert($0.rid).inserted }
        var arts: [String] = []
        for t in distinct {
            if let art = t.song.albumArtUriString, !arts.contains(art) { arts.append(art) }
            if arts.count >= 3 { break }
        }
        var title = name
        if let first = title.first { title = first.uppercased() + title.dropFirst() }
        return StationCard(kind: kind, atlasId: id, name: title, count: distinct.count, covers: arts)
    }

    private static func related(_ atlas: GenreAtlas, _ a: Int, _ b: Int) -> Bool {
        atlas.ancestors(a).contains(b) || atlas.ancestors(b).contains(a)
    }
}
