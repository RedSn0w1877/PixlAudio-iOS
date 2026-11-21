// The facts the host of Endless Listening may put in a note beyond what the queue itself says: the name of the taste island a library
// song sits in, and the atlas' one-line description of a genre. Both are read from what the engine already stored; a fact that is not
// there is absent, and the note that needed it is not made (nothing is guessed). A port of Android's `HostNoteFacts.kt` and the host part
// of `EndlessStateHolder.hostFacts`.
//
// Read only while the Endless Listening station is the queue and the host's notes are on, off the main actor, for the few songs a note
// looks at.

import Foundation
import PixlModel

public actor HostNoteFacts {
    private let repository: BrainRepository
    private let mixes: BrainMixes
    private let atlas: any AtlasProvider
    /// The name of an island, kept for as long as the fit it came from is the current one.
    private var namesFit: Int64 = 0
    private var names: [Int: String] = [:]

    public init(repository: BrainRepository, mixes: BrainMixes, atlas: any AtlasProvider) {
        self.repository = repository
        self.mixes = mixes
        self.atlas = atlas
    }

    /// What the host may say about `window` (the current song and the next few): the island name of each library song, the engine's reason
    /// key of each pick, and the atlas' description of the genres of the window. Every part is read from what is already stored.
    public func facts(window: [Song], why: [String: QueueWhy]) async -> SetNoteLines.HostFacts {
        var keys: [String: String] = [:]
        for song in window {
            if let w = why[song.id] { keys[song.id] = w.key }
        }
        let islands = await islandNames(window)
        var genreFacts: [String: String] = [:]
        if let loaded = await atlas.loadedOrNil() {
            for song in window {
                let genre = SetNotes.firstGenre(song.genre)
                if genre.isEmpty || genreFacts[genre] != nil { continue }
                let id = loaded.idForName(genre)
                genreFacts[genre] = id == GenreAtlas.none ? "" : (loaded.genre(id)?.description ?? "")
            }
        }
        let facts = genreFacts
        return SetNoteLines.HostFacts(islandOf: islands, whyKeyOf: keys, genreFact: { facts[$0] ?? "" })
    }

    /// The island name of each of `songs` the listener's library has a placed track for, by song id. Library songs only; an unnamed
    /// island gives none.
    func islandNames(_ songs: [Song]) async -> [String: String] {
        guard let set = await mixes.currentIslands(), set.hasMany else { return [:] }
        if set.fitAtMs != namesFit {
            names.removeAll()
            namesFit = set.fitAtMs
        }
        var requests: [TrackRequest] = []
        var owners: [String] = []
        for song in songs where !SetNoteLines.isEngineOnly(song) {
            guard let request = SetNoteHistory.request(of: song) else { continue }
            requests.append(request)
            owners.append(song.id)
        }
        if requests.isEmpty { return [:] }
        let rids = await repository.resolveTracks(requests)
        var out: [String: String] = [:]
        for (i, owner) in owners.enumerated() where i < rids.count {
            guard let islandId = set.memberOf[rids[i]] else { continue }
            var name = names[islandId]
            if name == nil {
                if let island = set.islands.first(where: { $0.id == islandId }) {
                    name = await mixes.islandGenreName(island)
                } else {
                    name = ""
                }
                names[islandId] = name
            }
            if let name, !BrainText.isBlank(name) { out[owner] = name }
        }
        return out
    }
}

extension BrainMixes {
    /// The island fit the weekly build left, or nil when there is none yet.
    func currentIslands() async -> IslandSet? { await parts?.islands.current() }
}
