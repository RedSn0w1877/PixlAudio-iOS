// The optional batch jobs of "Let Taizo help the engine" (docs/brain-spec.md, 9.4, stage 4 milestone 2). A port of Android's `AssistantHelp`.
// ONE class, run from inside the existing refresh (`RefreshWork.assistantHelp`), never a second job, never at app start:
//  1. names and one-line descriptions for the taste islands (one call for all islands, only for islands whose genres changed);
//  2. genres for tracks no source knows (tag source 10): 50 tracks a call, each constrained to a shortlist of 30 atlas ids;
//  3. artists this listener likely does not know, one well-known song each, looked up like `resolve_tracks` does (arm ASK).
//
// Off unless the listener turned the switch on AND the remote config does not switch it off; and only on the automatic route with the
// built-in key, a connection and monthly budget left, the same door and the same budget every assistant feature uses. Every answer is
// data: `AssistBatch` validates it against the atlas and the island, an invalid id or name is dropped and never shown, and what it kept is
// cached forever by (model id, prompt version, input hash) in `AssistCache`, so the same input is never asked twice. A call is made only
// when something is missing from the cache; with the switch off nothing is asked, and what the tagging job wrote is taken back out.

import Foundation
import PixlModel

public actor AssistantHelp {
    public struct Report: Sendable, Equatable {
        public var islandsNamed = 0
        public var tracksTagged = 0
        public var songsSuggested = 0
        public var calls = 0
        public var tagsTakenBack = 0
    }

    /// What the jobs need from the app: the switch, the door to the cloud assistant, and the engine's own lookups.
    public struct Host: Sendable {
        /// The local switch AND the remote one (`BrainRemoteConfig.assistAllowed`).
        public var allowed: @Sendable () async -> Bool
        /// The assistant's own route (consent and switches), a connection and the monthly budget: asked before every call.
        public var mayAsk: @Sendable () async -> Bool
        public var ask: @Sendable (_ system: String, _ prompt: String, _ maxTokens: Int) async -> String?
        /// The atlas ids of the genres the listener plays (Your sound).
        public var listenerGenres: @Sendable () async -> [Int]
        /// `resolve_tracks`' lookup: the library, then one budgeted YouTube search.
        public var resolve: @Sendable (_ items: [(title: String, artist: String)]) async -> [AssistantLookup]
        /// The engine track registered for a YouTube video id (title, artists, album, length, art, recording id), or nil.
        public var trackOf: @Sendable (_ videoId: String) async -> EngineTrack?

        public init(allowed: @escaping @Sendable () async -> Bool, mayAsk: @escaping @Sendable () async -> Bool,
                    ask: @escaping @Sendable (_ system: String, _ prompt: String, _ maxTokens: Int) async -> String?,
                    listenerGenres: @escaping @Sendable () async -> [Int],
                    resolve: @escaping @Sendable (_ items: [(title: String, artist: String)]) async -> [AssistantLookup],
                    trackOf: @escaping @Sendable (_ videoId: String) async -> EngineTrack?) {
            self.allowed = allowed
            self.mayAsk = mayAsk
            self.ask = ask
            self.listenerGenres = listenerGenres
            self.resolve = resolve
            self.trackOf = trackOf
        }
    }

    private let host: Host
    private let cache: AssistCache
    private let islands: IslandStore
    private let atlasProvider: any AtlasProvider
    private let dna: DnaRepository
    private let clock: @Sendable () -> Int64

    public init(host: Host, cache: AssistCache, islands: IslandStore, atlas: any AtlasProvider, dna: DnaRepository,
                clock: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        self.host = host
        self.cache = cache
        self.islands = islands
        self.atlasProvider = atlas
        self.dna = dna
        self.clock = clock
    }

    public func run(playing: @Sendable () async -> Bool, requestsLeft: @Sendable () async -> Int = { Int.max }) async -> Report {
        // Switched off: the tags the job wrote leave with it (the names and suggestions are not read while it is off).
        if !(await host.allowed()) { return Report(tagsTakenBack: await takeBackTags()) }
        if await playing() { return Report() }
        if !(await mayAsk()) { return Report() }
        guard let atlas = await atlasProvider.atlas() else { return Report() }
        var report = Report()
        let inputs: [IslandInput]
        if let set = await islands.current() { inputs = await islandInputs(set.islands, atlas) } else { inputs = [] }
        if !inputs.isEmpty, !(await playing()), await mayAsk() {
            let r = await nameIslands(inputs)
            report.calls += r.calls
            report.islandsNamed = r.done
        }
        if !(await playing()), await mayAsk() {
            let r = await tagTracks(atlas)
            report.calls += r.calls
            report.tracksTagged = r.done
        }
        if !inputs.isEmpty, !(await playing()), await mayAsk() {
            let r = await suggestSongs(inputs, requestsLeft)
            report.calls += r.calls
            report.songsSuggested = r.done
        }
        return report
    }

    private func mayAsk() async -> Bool {
        if !(await host.allowed()) { return false }
        return await host.mayAsk()
    }

    // MARK: Islands

    private struct IslandInput {
        let id: Int
        let genreNames: [String]
        let artists: [String]
        var key: String { AssistCache.islandInput(id: id, genreNames: genreNames) }
    }

    private func islandInputs(_ list: [Islands.Island], _ atlas: GenreAtlas) async -> [IslandInput] {
        var out: [IslandInput] = []
        for island in list.prefix(Self.maxIslands) {
            var genres: [String] = []
            for id in island.topTags {
                if let name = AtlasNames.genreName(atlas, id), !genres.contains(where: { KotlinText.equals($0, name) }) { genres.append(name) }
            }
            genres = Array(genres.prefix(5))
            if genres.isEmpty { continue }
            var artists: [String] = []
            if !island.topArtists.isEmpty {
                for row in await dna.artists(island.topArtists) where AtlasNames.isShown(row.name) { artists.append(row.name) }
            }
            out.append(IslandInput(id: island.id, genreNames: genres, artists: Array(artists.prefix(3))))
        }
        return out
    }

    private func nameIslands(_ inputs: [IslandInput]) async -> (calls: Int, done: Int) {
        let known = await cache.read().islands
        var missing: [IslandInput] = []
        for i in inputs {
            let key = await cache.keyOf("island", i.key)
            if known[key] == nil { missing.append(i) }
        }
        if missing.isEmpty { return (0, 0) }
        var prompt = ""
        for i in missing {
            prompt += "id=\(i.id); genres=\(i.genreNames.joined(separator: ", ")); artists=\(i.artists.joined(separator: ", "))\n"
        }
        guard let text = await host.ask(Self.islandSystem, prompt, Self.maxTokensIslands) else { return (1, 0) }
        var outs: [AssistBatch.IslandName] = []
        for el in Self.objectsOf(text, "islands") {
            guard let id = Self.intValue(el["id"]) else { continue }
            outs.append(AssistBatch.IslandName(id: id, name: (el["name"] as? String) ?? "", line: (el["line"] as? String) ?? ""))
        }
        let kept = AssistBatch.validateIslandNames(missing.map { AssistBatch.IslandIn(id: $0.id, genres: $0.genreNames, artists: $0.artists) }, outs)
        var byId: [Int: AssistBatch.IslandName] = [:]
        for k in kept { byId[k.id] = k }
        var keys: [(String, AssistCache.IslandAnswer)] = []
        // Every island that was asked is stored: a valid answer by its name, any other as "asked, nothing usable".
        for i in missing {
            keys.append((await cache.keyOf("island", i.key), AssistCache.IslandAnswer(name: byId[i.id]?.name ?? "", line: byId[i.id]?.line ?? "")))
        }
        let stored = keys
        await cache.update { d in for (k, v) in stored { d.islands[k] = v } }
        return (1, kept.count)
    }

    // MARK: Genres for tracks no source knows

    private struct TagTrack {
        let rid: Int64
        let title: String
        let artist: String
        let shortlist: [Int]
        let key: String
    }

    private func tagTracks(_ atlas: GenreAtlas) async -> (calls: Int, done: Int) {
        let listenerGenres = await host.listenerGenres()
        var calls = 0
        var tagged = 0
        var after: Int64 = 0
        var scanned = 0
        var chosen: [TagTrack] = []
        let answered = await cache.read().tags
        while chosen.count < Self.tagTracksPerRun && scanned < Self.tagScanLimit {
            let rows = await dna.untagged(after: after, limit: Self.tagScanPage)
            if rows.isEmpty { break }
            var firstAids: [Int64] = []
            for r in rows { if let a = r.artistIds.split(separator: ",").first.flatMap({ Int64($0) }) { firstAids.append(a) } }
            var countries: [Int64: String] = [:]
            for a in await dna.artists(Array(Set(firstAids))) { countries[a.aid] = a.country }
            for row in rows {
                after = row.rid
                scanned += 1
                if BrainText.isBlank(row.title) || BrainText.isBlank(row.artistDisplay) { continue }
                let aid = row.artistIds.split(separator: ",").first.flatMap { Int64($0) } ?? 0
                let shortlist = Self.shortlistFor(atlas, listenerGenres, countries[aid] ?? "")
                if shortlist.count < Self.minShortlist { continue }
                let key = await cache.keyOf("tag", "\(row.title)|\(row.artistDisplay)")
                if answered[key] != nil { continue }
                chosen.append(TagTrack(rid: row.rid, title: row.title, artist: row.artistDisplay, shortlist: shortlist, key: key))
                if chosen.count >= Self.tagTracksPerRun { break }
            }
            if rows.count < Self.tagScanPage { break }
        }
        var start = 0
        while start < chosen.count {
            let batch = Array(chosen[start..<min(start + AssistBatch.tagBatch, chosen.count)])
            start += AssistBatch.tagBatch
            if !(await mayAsk()) { break }
            var prompt = ""
            for (n, t) in batch.enumerated() {
                prompt += "\(n): \(t.title) - \(t.artist) | allowed: "
                prompt += t.shortlist.map { "\($0) \(atlas.genre($0)?.name ?? "")" }.joined(separator: ", ") + "\n"
            }
            calls += 1
            guard let text = await host.ask(Self.tagSystem, prompt, Self.maxTokensTags) else { continue }
            var answers: [AssistBatch.TagOut] = []
            for el in Self.objectsOf(text, "tracks") {
                guard let i = Self.intValue(el["i"]) else { continue }
                for t in (el["tags"] as? [Any]) ?? [] {
                    guard let o = t as? [String: Any], let id = Self.intValue(o["id"]), let c = Self.doubleValue(o["c"]) else { continue }
                    answers.append(AssistBatch.TagOut(index: i, atlasId: id, confidence: c))
                }
            }
            let kept = AssistBatch.validateTags(batch.map(\.shortlist), answers)
            var byTrack: [Int: [AssistBatch.TagOut]] = [:]
            for k in kept { byTrack[k.index, default: []].append(k) }
            let now = clock()
            var written: [Int64] = []
            var byKey: [String: [AssistCache.TagAnswer]] = [:]
            for (n, t) in batch.enumerated() {
                let claims = (byTrack[n] ?? []).map { AssistCache.TagAnswer(atlasId: $0.atlasId, conf: min(max(Int($0.confidence * 255.0 + 0.5), 0), 255)) }
                byKey[t.key] = claims
                if claims.isEmpty { continue }
                guard let row = await dna.track(t.rid) else { continue }
                let updated = DnaAssembler.withAssistantClaims(
                    row, claims: claims.map { DnaAssembler.Claim(provider: DnaAssembler.pAssistant, atlasId: $0.atlasId, conf: $0.conf) },
                    atlas: atlas, atlasVersion: row.atlasVersion, nowMs: now)
                await dna.upsert(track: updated, artist: nil)
                written.append(t.rid)
                tagged += 1
            }
            let storedTags = byKey
            let storedRids = written
            await cache.update { d in
                for (k, v) in storedTags { d.tags[k] = v }
                for r in storedRids where !d.tagRids.contains(r) { d.tagRids.append(r) }
            }
        }
        return (calls, tagged)
    }

    /// At most 30 atlas ids for one track: the genres the listener plays, then genres of the artist's own region, each by id order within its group.
    static func shortlistFor(_ atlas: GenreAtlas, _ listenerGenres: [Int], _ country: String) -> [Int] {
        var out: [Int] = []
        var seen = Set<Int>()
        for id in listenerGenres {
            if atlas.genre(id) != nil, AtlasNames.genreName(atlas, id) != nil, seen.insert(id).inserted { out.append(id) }
            if out.count >= shortlistListener { break }
        }
        let c = BrainText.trim(BrainText.fold(country))
        if !c.isEmpty {
            for id in atlas.allIds {
                if out.count >= AssistBatch.shortlist { break }
                guard let g = atlas.genre(id) else { continue }
                if g.depth < 1 || AtlasNames.genreName(atlas, id) == nil { continue }
                if g.regions.contains(where: { KotlinText.equals(BrainText.trim(BrainText.fold($0)), c) }), seen.insert(id).inserted { out.append(id) }
            }
        }
        return Array(out.prefix(AssistBatch.shortlist))
    }

    /// Takes the assistant's claims out of every row the job wrote (the switch was turned off). Returns how many rows changed.
    private func takeBackTags() async -> Int {
        let rids = await cache.read().tagRids
        if rids.isEmpty { return 0 }
        guard let atlas = await atlasProvider.atlas() else { return 0 }
        var changed = 0
        let now = clock()
        var start = 0
        while start < rids.count {
            let chunk = Array(rids[start..<min(start + 200, rids.count)])
            start += 200
            for row in await dna.tracks(chunk) {
                let cleaned = DnaAssembler.withAssistantClaims(row, claims: [], atlas: atlas, atlasVersion: row.atlasVersion, nowMs: now)
                await dna.upsert(track: cleaned, artist: nil)
                changed += 1
            }
        }
        await cache.update { $0.tagRids = [] }
        return changed
    }

    // MARK: Artists the listener likely does not know

    private func suggestSongs(_ inputs: [IslandInput], _ requestsLeft: @Sendable () async -> Int) async -> (calls: Int, done: Int) {
        // The searches share the day's YouTube budget with everything the listener does: the worker's own share must have room for them,
        // or nothing is asked (a week is not marked as asked, so a later run tries again).
        let room = await requestsLeft()
        if room < Self.askMinRoom { return (0, 0) }
        let week = clock() / Self.weekMs
        let input = "week=\(week)|" + inputs.map(\.key).joined(separator: "|")
        let key = await cache.keyOf("ask", input)
        if await cache.read().ask[key] != nil { return (0, 0) }
        var prompt = ""
        for i in inputs.prefix(Self.maxAskIslands) {
            prompt += "id=\(i.id); genres=\(i.genreNames.joined(separator: ", ")); artists they play=\(i.artists.joined(separator: ", "))\n"
        }
        let text = await host.ask(Self.askSystem, prompt, Self.maxTokensAsk)
        // The week is marked asked at once (a failed call is not retried until next week).
        guard let text else {
            await cache.update { $0.ask[key] = [] }
            return (1, 0)
        }
        var known = Set<String>()
        for i in inputs { for a in i.artists { known.insert(BrainText.trim(BrainText.fold(a))) } }
        var wanted: [(title: String, artist: String)] = []
        for el in Self.objectsOf(text, "islands") {
            let picks = ((el["picks"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
            let names = AssistBatch.validateArtistNames(picks.map { ($0["artist"] as? String) ?? "" }, knownFolded: known)
            for name in names.prefix(Self.askPerIslandLookups) {
                let song = BrainText.trim(((picks.first { BrainText.trim(($0["artist"] as? String) ?? "") == name })?["song"] as? String) ?? "")
                if !song.isEmpty { wanted.append((song, name)) }
            }
        }
        var kept: [AssistCache.AskAnswer] = []
        // Looked up the way `resolve_tracks` does it: the library first (free), then one songs search under the day's YouTube budget.
        let looked = wanted.isEmpty ? [] : await host.resolve(Array(wanted.prefix(min(Self.askLookupsPerRun, room))))
        for l in looked {
            guard let t = l.track, !t.inLibrary, t.ref.hasPrefix("yt:") else { continue }
            let videoId = String(t.ref.dropFirst(3))
            guard let track = await host.trackOf(videoId), track.rid != 0 else { continue }
            kept.append(AssistCache.AskAnswer(videoId: videoId, title: track.title, artist: track.artists.first?.name ?? t.artist,
                                              album: track.album ?? "", year: t.year, durationSec: Int(track.durationMs / 1000),
                                              artUrl: track.artUrl ?? "", rid: track.rid))
        }
        let stored = kept
        await cache.update { d in
            d.ask[key] = stored
            d.askLatest = key
        }
        return (1, kept.count)
    }

    // MARK: Reading what the model wrote

    /// The objects of the array `name` in the first JSON object of `text`; empty for anything that does not parse.
    static func objectsOf(_ text: String, _ name: String) -> [[String: Any]] {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return [] }
        let body = String(text[start...end])
        guard let root = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let list = root[name] as? [Any] else { return [] }
        return list.compactMap { $0 as? [String: Any] }
    }

    static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        return nil
    }

    static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        return nil
    }

    // MARK: Limits and the instructions

    static let weekMs: Int64 = 7 * 24 * 60 * 60 * 1000
    static let maxIslands = 10
    static let maxAskIslands = 6
    static let askPerIslandLookups = 4
    static let askLookupsPerRun = 12
    static let askMinRoom = 6
    static let tagTracksPerRun = 100
    static let tagScanPage = 200
    static let tagScanLimit = 5_000
    static let minShortlist = 6
    static let shortlistListener = 18
    static let maxTokensIslands = 900
    static let maxTokensTags = 2_500
    static let maxTokensAsk = 1_800

    /// The instructions. They never name the vendor or the model or a product.
    static let islandSystem = """
        You name groups of songs for a music app. Each line gives an island id, the genres it holds and some artists in it.
        Answer with JSON only, no other text: {"islands":[{"id":1,"name":"two to four words","line":"one short sentence"}]}.
        A name must use at least one word from that island's own genre names, must not be an artist's name, and must not use any other name.
        A line has no digits and no quotation marks. Do not mention any company or product.
        """

    static let tagSystem = """
        You give genres to songs. Each line gives an index, a song and artist, and the only genre ids you may use for it, with their names.
        Answer with JSON only, no other text: {"tracks":[{"i":0,"tags":[{"id":123,"c":0.7}]}]}.
        Use only ids from that line's own allowed list, at most three per song, c between 0.5 and 1. Give an empty tags list when you are not sure.
        """

    static let askSystem = """
        You suggest music. Each line gives an island of one listener's taste: its genres and some artists they play.
        For each island suggest up to four real artists this listener likely does not know yet, each with one real, well-known song by them.
        Answer with JSON only, no other text: {"islands":[{"id":1,"picks":[{"artist":"name","song":"title"}]}]}.
        Never suggest an artist already listed. Do not mention any company or product.
        """
}
