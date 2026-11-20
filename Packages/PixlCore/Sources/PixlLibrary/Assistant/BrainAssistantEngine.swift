// `MusicBackend` over the brain's real tables (docs/brain-spec.md, 9.2): the library for names, the engine's own pool and scorer for picks
// (`BrainMixes.assistantPlan`), the DNA, the atlas and the graph for facts, Your sound for taste, the saved releases file for new music.
// Nothing here is a model's opinion and nothing is invented: a value the tables do not hold is nil, and the tool says so. A port of
// Android's `BrainAssistantEngine.kt`.
//
// Network use is the existing, bounded kind: a name the library does not know costs one YouTube Music songs search under the day's host
// budget (the same bucket autoplay and the radios share, decided by `AssistantHost.searchSong`); when the day's requests are spent the item
// is skipped, not retried. Everything runs on the actors that own the stores; only handing songs to the player is the host's job.

import Foundation
import PixlModel

/// The result of one YouTube Music songs search for a name.
public enum AssistantSearch: Sendable {
    /// The best result that scores like a playback match.
    case found(RadioRow)
    case notFound
    /// The day's requests were used up before it could be asked.
    case skipped
}

/// What the app target does for the engine: the network search and the parts that touch the player.
public protocol AssistantHost: Sendable {
    /// One songs search, scored like playback does (title, artist, duration, version words) and accepted at the matcher's own threshold.
    func searchSong(title: String, artist: String) async -> AssistantSearch
    /// Starts a station and plays it. `song` is the resolved seed for `song` stations.
    func startStation(seedRef: String, seedKind: String, mode: String, song: Song?) async -> AssistantStationOutcome
    /// A lasting change (`scope` always): `target` is an artist name or a genre id; `song` is the track a ref named, when it did.
    func steer(change: String, target: String, scope: String, song: Song?) async -> AssistantSteerOutcome
    /// The song that is playing, if any.
    func nowPlaying() async -> Song?
    /// Makes tracks from outside the library known to the app, so their queue items can play (docs/brain-spec.md, 7.2).
    func register(_ tracks: [EngineTrack]) async
    /// Puts `songs` next in the queue, in order, after the song playing; returns how many were queued.
    func queueNext(_ songs: [Song], tags: [String: BrainItemTag]) async -> Int
}

public actor BrainAssistantEngine: MusicBackend, AssistantPlayable {
    static let maxIssued = 4_000
    static let maxMixes = 12
    static let nearestGenres = 5
    static let recTag: Int64 = 0x4B
    static let steerCount = 5

    private struct Issued {
        var ref: String
        var song: Song?
        var rid: Int64
        var track: EngineTrack?
        var primaryArtist: String
        var tag: BrainItemTag?
        var servedX: [UInt8]?
    }

    private struct BuiltRecord {
        var query: AssistantRules.Query
        var songs: [Song]
    }

    private let mixes: BrainMixes
    private let engine: BrainEngine
    private let repository: BrainRepository
    private let parts: Stage2bParts?
    private let yourSound: YourSoundReader?
    private let host: any AssistantHost
    private let library: @Sendable () async -> [Song]
    private let clock: @Sendable () -> Int64

    private var issued: [String: Issued] = [:]
    private var tagBySongId: [String: BrainItemTag] = [:]
    private var builtMixes: [String: BuiltRecord] = [:]
    private var builtOrder: [String] = []

    public init(mixes: BrainMixes, engine: BrainEngine, repository: BrainRepository, parts: Stage2bParts?, yourSound: YourSoundReader?,
                host: any AssistantHost, library: @escaping @Sendable () async -> [Song],
                clock: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        self.mixes = mixes
        self.engine = engine
        self.repository = repository
        self.parts = parts
        self.yourSound = yourSound
        self.host = host
        self.library = library
        self.clock = clock
    }

    // MARK: What this process issued

    private func register(_ tracks: [EngineTrack]) async {
        if tracks.isEmpty { return }
        await repository.registerPlayable(tracks, nowMs: clock())
        await host.register(tracks)
    }

    private func remember(_ entry: Issued) {
        if issued.count > Self.maxIssued {
            issued.removeAll()
            tagBySongId.removeAll()
        }
        issued[entry.ref] = entry
        if let song = entry.song, let tag = entry.tag { tagBySongId[song.id] = tag }
    }

    // MARK: Refs

    static func isRealSpotifyId(_ id: String?) -> Bool {
        guard let id, id.utf16.count == AssistantRules.spotifyIdLength else { return false }
        return id.utf16.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x41 && $0 <= 0x5A) }
    }

    static func isVideoId(_ id: String?) -> Bool {
        guard let id, id.utf16.count == AssistantRules.youTubeIdLength else { return false }
        return id.utf16.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x41 && $0 <= 0x5A) || $0 == 0x5F || $0 == 0x2D
        }
    }

    /// The ref a library or engine song is known by, or nil when it has neither a Spotify id nor a YouTube audio id.
    private func refFor(_ song: Song, _ track: EngineTrack?) async -> String? {
        if let track { return Self.isVideoId(track.videoId) ? AssistantRules.youTubeRef(track.videoId) : nil }
        if let video = TrackCatalog.videoId(ofSongId: song.id), Self.isVideoId(video) { return AssistantRules.youTubeRef(video) }
        if Self.isRealSpotifyId(song.spotifyId), let id = song.spotifyId { return AssistantRules.spotifyRef(id) }
        if let id = song.spotifyId, let video = await mixes.sources.matchedVideoId(id), Self.isVideoId(video) {
            return AssistantRules.youTubeRef(video)
        }
        return nil
    }

    private func info(_ ref: String, song: Song?, track: EngineTrack?, title: String, artist: String, year: Int,
                      inLibrary: Bool) -> AssistantTrack {
        let rawAlbum = song?.album ?? track?.album ?? ""
        let album = rawAlbum.lowercased() == EngineTrack.unknownAlbum.lowercased() ? "" : rawAlbum
        return AssistantTrack(ref: ref, title: title, artist: artist, year: year, inLibrary: inLibrary, album: album)
    }

    private func infoOfSong(_ song: Song, track: EngineTrack?, rid: Int64, tag: BrainItemTag?, servedX: [UInt8]?,
                            year: Int) async -> AssistantTrack? {
        guard let ref = await refFor(song, track) else { return nil }
        remember(Issued(ref: ref, song: song, rid: rid, track: track, primaryArtist: BrainLibraryIndex.primaryArtistName(song), tag: tag,
                        servedX: servedX))
        return info(ref, song: song, track: track, title: song.title, artist: song.artist, year: year > 0 ? year : song.year,
                    inLibrary: track == nil)
    }

    // MARK: AssistantPlayable

    public func songForRef(_ ref: String) async -> Song? {
        if let song = issued[ref]?.song { return song }
        guard let parsed = AssistantRules.parseRef(ref) else { return nil }
        let all = await library()
        if parsed.kind == AssistantRules.refSpotify { return all.first { $0.spotifyId == parsed.id } }
        let songId = EngineTrack.songId(videoId: parsed.id)
        if let song = all.first(where: { $0.id == songId }) { return song }
        if let track = await repository.engineTrack(songId: songId) { return mixes.sources.song(track) }
        for song in all {
            guard let id = song.spotifyId else { continue }
            if let video = await mixes.sources.matchedVideoId(id), video == parsed.id { return song }
        }
        return nil
    }

    public func songsForMix(_ mixId: String) async -> [Song]? { builtMixes[mixId]?.songs }

    public func tags(for songs: [Song]) async -> [String: BrainItemTag] {
        var out: [String: BrainItemTag] = [:]
        for s in songs { if let tag = tagBySongId[s.id] { out[s.id] = tag } }
        return out
    }

    // MARK: resolve_tracks

    public func resolve(_ items: [(title: String, artist: String)]) async -> [AssistantLookup] {
        let index = BrainLibraryIndex(songs: await library())
        var out: [AssistantLookup] = []
        out.reserveCapacity(items.count)
        for item in items { out.append(await resolveOne(item.title, item.artist, index)) }
        return out
    }

    private func sameRecording(_ want: BrainText.CleanTitle, _ got: BrainText.CleanTitle) -> Bool {
        KotlinText.equals(want.title, got.title) && (got.versionFlags & ~want.versionFlags) == 0
    }

    private func resolveOne(_ title: String, _ artist: String, _ index: BrainLibraryIndex) async -> AssistantLookup {
        let wanted = BrainText.cleanTitle(title)
        // 1. The listener's own library: free, and in_library is true.
        let artistKey = BrainText.fold(artist)
        if !artistKey.isEmpty,
           let hit = index.byPrimaryArtist(artistKey).first(where: { sameRecording(wanted, BrainText.cleanTitle($0.title)) }),
           let found = await infoOfSong(hit, track: nil, rid: 0, tag: nil, servedX: nil, year: 0) {
            return AssistantLookup(track: found)
        }
        // 2. A YouTube Music songs search, under the day's budget; scored like playback does.
        switch await host.searchSong(title: title, artist: artist) {
        case .skipped:
            return AssistantLookup(track: nil, skipped: true)
        case .notFound:
            return AssistantLookup(track: nil)
        case .found(let row):
            guard Self.isVideoId(row.videoId) else { return AssistantLookup(track: nil) }
            let nameKey = Ids.nameKey(primaryArtist: row.artists.first?.name ?? artist, rawTitle: row.title)
            let keys = Ids.TrackKeys(videoId: row.videoId, nameKey: nameKey)
            let rid = await repository.resolveTrack(keys, durationMs: Int32(clamping: max(row.durationSec, 0) * 1000))
            let track = EngineTrack(row: row, rid: rid)
            // In `playable` BEFORE a media item can reach the player (7.2).
            await register([track])
            let song = mixes.sources.song(track)
            guard let found = await infoOfSong(song, track: track, rid: rid, tag: nil, servedX: nil, year: row.year) else {
                return AssistantLookup(track: nil)
            }
            return AssistantLookup(track: found)
        }
    }

    // MARK: recommend / build_mix

    private func rid(of song: Song, ref: AssistantRules.Ref?, primary: String) async -> Int64 {
        let keys = Ids.TrackKeys(spotifyId: Self.isRealSpotifyId(song.spotifyId) ? song.spotifyId : nil,
                                 videoId: ref?.kind == AssistantRules.refYouTube ? ref?.id : nil,
                                 nameKey: Ids.nameKey(primaryArtist: primary, rawTitle: song.title))
        return await repository.resolveTrack(keys, durationMs: Int32(clamping: max(song.duration, 0)))
    }

    private func material(of ref: String) async -> AssistantSeed? {
        guard let parsed = AssistantRules.parseRef(ref) else { return nil }
        let known = issued[ref]
        guard let song = await songOf(known, ref) else { return nil }
        let primary = known?.primaryArtist ?? BrainLibraryIndex.primaryArtistName(song)
        var rid = known?.rid ?? 0
        if rid == 0 { rid = await self.rid(of: song, ref: parsed, primary: primary) }
        if rid == 0 { return nil }
        let aid = await repository.resolveArtistNames([primary]).first ?? 0
        var video: String?
        if parsed.kind == AssistantRules.refYouTube {
            video = parsed.id
        } else if let id = song.spotifyId {
            video = await mixes.sources.matchedVideoId(id)
        }
        let radioSeed = video.map {
            RadioSeed(mediaId: song.id, videoId: $0, title: song.title, primaryArtist: primary, durationMs: song.duration,
                      spotifyId: Self.isRealSpotifyId(song.spotifyId) ? song.spotifyId : nil)
        }
        return AssistantSeed(ref: ref, rid: rid, aid: aid, title: song.title, primaryArtist: primary, song: song, track: known?.track,
                             radioSeed: radioSeed)
    }

    private func songOf(_ known: Issued?, _ ref: String) async -> Song? {
        if let song = known?.song { return song }
        return await songForRef(ref)
    }

    private func planFor(_ query: AssistantRules.Query, bump: Int) async -> AssistantPlan? {
        var seeds: [AssistantSeed] = []
        for ref in query.seedRefs { if let s = await material(of: ref) { seeds.append(s) } }
        var excluded: [String] = []
        for ref in query.excludeArtistRefs {
            var name: String?
            if let known = issued[ref] {
                name = known.primaryArtist
            } else if let song = await songForRef(ref) {
                name = BrainLibraryIndex.primaryArtistName(song)
            }
            if let name, !BrainText.isBlank(name) { excluded.append(BrainText.fold(name)) }
        }
        return await mixes.assistantPlan(query, seeds: seeds, excludedArtists: excluded,
                                         regen: BrainMixes.assistantRegen(of: query, bump: bump))
    }

    private func picksOf(_ plan: AssistantPlan, surfaceId: String, now: Int64) async -> [AssistantPick] {
        let recId = (now << 8) | Self.recTag
        var out: [AssistantPick] = []
        out.reserveCapacity(plan.picks.count)
        for (slot, p) in plan.picks.enumerated() {
            let primary = BrainLibraryIndex.primaryArtistName(p.song)
            let hasWhy = p.whyKey != WhyLine.none && !p.whyName.isEmpty
            let whyKey: String? = p.arm == Arm.ask ? WhyLine.nameOf(WhyLine.asked) : (hasWhy ? WhyLine.nameOf(p.whyKey) : nil)
            // The listener asked for this list and plays it: its tracks are theirs, as a playlist's are.
            let tag = BrainItemTag(
                surface: Surface.nameOf(Surface.assistant), surfaceId: surfaceId, recId: recId, slot: slot, arm: Arm.nameOf(p.arm),
                whyArg: p.whyName.isEmpty ? nil : p.whyName, radioRank: Int(p.radioRank), retrQ: Int(p.retrQ), whyKey: whyKey,
                primaryArtist: primary, chosen: true, control: plan.control, modelVersion: plan.modelVersion, explore: p.explore,
                servedX: p.servedX.map(ServedVector.toHex))
            guard let info = await infoOfSong(p.song, track: p.track, rid: p.rid, tag: tag, servedX: p.servedX, year: p.year) else { continue }
            out.append(AssistantPick(track: info, whyKey: whyKey ?? "", whyArgs: p.whyName.isEmpty ? [] : [p.whyName]))
        }
        return out
    }

    public func recommend(_ query: AssistantRules.Query) async -> AssistantRecommendation {
        guard let plan = await planFor(query, bump: 0) else {
            return AssistantRecommendation(picks: [], unsupportedFilters: [], coldStart: !(await mixes.hasState()))
        }
        let picks = await picksOf(plan, surfaceId: "assistant", now: clock())
        return AssistantRecommendation(picks: Array(picks.prefix(query.count)), unsupportedFilters: plan.unsupported, coldStart: plan.coldStart)
    }

    public func buildMix(_ query: AssistantRules.Query) async -> AssistantMix? {
        guard let plan = await planFor(query, bump: 0), !plan.picks.isEmpty else { return nil }
        return await finish(query, plan)
    }

    public func adjustMix(mixId: String, chip: AssistantRules.Chip) async -> AssistantMix? {
        guard let record = builtMixes[mixId] else { return nil }
        let next = AssistantRules.applyChip(record.query, chip)
        guard let plan = await planFor(next, bump: 1), !plan.picks.isEmpty else { return nil }
        return await finish(next, plan)
    }

    private func finish(_ query: AssistantRules.Query, _ plan: AssistantPlan) async -> AssistantMix? {
        let now = clock()
        let seed = BrainHash.fnv1a64("assistant|\(query.title)|\(now)|\(plan.picks.first?.rid ?? 0)")
        let mixId = String(seed, radix: 16)
        let picks = await picksOf(plan, surfaceId: mixId, now: now)
        if picks.isEmpty { return nil }
        // Tracks from outside the library go into `playable` now, so Play and Save work from the card.
        let engineTracks = plan.picks.compactMap(\.track)
        await register(engineTracks)
        builtMixes[mixId] = BuiltRecord(query: query, songs: plan.picks.map(\.song))
        builtOrder.removeAll { $0 == mixId }
        builtOrder.append(mixId)
        while builtOrder.count > Self.maxMixes { builtMixes[builtOrder.removeFirst()] = nil }
        return await built(mixId, query, plan, picks)
    }

    private func firstArtist(_ display: String) -> String { display.components(separatedBy: ", ").first ?? display }

    private func built(_ mixId: String, _ query: AssistantRules.Query, _ plan: AssistantPlan, _ picks: [AssistantPick]) async -> AssistantMix {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for p in picks {
            let name = firstArtist(p.track.artist)
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        // Most tracks first; on a tie the shorter name.
        let topName = order.max { a, b in
            let ca = counts[a] ?? 0, cb = counts[b] ?? 0
            return ca != cb ? ca < cb : a.utf16.count > b.utf16.count
        } ?? ""
        let topRef = picks.first { firstArtist($0.track.artist) == topName }?.track.ref ?? ""
        var byGenre: [Int: Int] = [:]
        for p in plan.picks { for g in p.genreIds { byGenre[g, default: 0] += 1 } }
        let atlas = await parts?.atlas.loadedOrNil()
        // A genre with some depth (a root family is too broad to be a chip); ties go to the lower id.
        let topGenre = byGenre.filter { (atlas?.depth($0.key) ?? 0) >= 1 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.first?.key ?? 0
        return AssistantMix(mixId: mixId, title: query.title.isEmpty ? "Made for you" : query.title, tracks: picks,
                            unsupportedFilters: plan.unsupported, query: query, topArtistRef: topRef, topArtistName: topName,
                            topGenreId: topGenre, topGenreName: atlas?.genre(topGenre)?.name ?? "")
    }

    // MARK: start_station / steer_session

    public func startStation(seedRef: String, seedKind: String, mode: String) async -> AssistantStationOutcome {
        var song: Song?
        if seedKind == "song" {
            song = await songForRef(seedRef)
            if song == nil {
                return AssistantStationOutcome(started: false, reason: "That song could not be found. Call resolve_tracks first.")
            }
        }
        return await host.startStation(seedRef: seedRef, seedKind: seedKind, mode: mode, song: song)
    }

    /// `session`: five songs built for the change go next in the queue and the rest of the queue follows unchanged (deviation 216: a real
    /// rewrite of the tail needs a player API that does not exist). `always`: a lasting change of what the app recommends, which is the
    /// app's own taste store (`AssistantHost.steer`).
    public func steer(change: String, target: String, scope: String) async -> AssistantSteerOutcome {
        if scope != "session" {
            var song: Song?
            var name = target
            if AssistantRules.parseRef(target) != nil {
                song = await songForRef(target)
                if let s = song { name = BrainLibraryIndex.primaryArtistName(s) }
            }
            return await host.steer(change: change, target: name, scope: scope, song: song)
        }
        var query = AssistantRules.Query(
            title: "", seedRefs: [], genreIds: [], moodIds: [], yearFrom: 0, yearTo: 0, energy: AssistantRules.anyWord,
            tempo: AssistantRules.anyWord, novelty: AssistantRules.anyWord, noveltySharePct: AssistantRules.shareUnset, count: Self.steerCount,
            excludeArtistRefs: [])
        if let current = await host.nowPlaying(), let ref = await refFor(current, EngineTrack(queueSong: current)) {
            if issued[ref] == nil {
                remember(Issued(ref: ref, song: current, rid: 0, track: nil, primaryArtist: BrainLibraryIndex.primaryArtistName(current),
                                tag: nil, servedX: nil))
            }
            query.seedRefs = [ref]
        }
        switch change {
        case "energy_down": query.energy = AssistantRules.lower
        case "energy_up": query.energy = AssistantRules.higher
        case "more_familiar": query.novelty = AssistantRules.familiar
        case "more_new": query.novelty = AssistantRules.new
        case "more_genre":
            guard let id = Int(BrainText.trim(target)), id > 0 else { return AssistantSteerOutcome(applied: false, note: "The genre is not known: use an id from lookup_genre.") }
            query.genreIds = [id]
        case "less_genre":
            guard let id = Int(BrainText.trim(target)), id > 0 else { return AssistantSteerOutcome(applied: false, note: "The genre is not known: use an id from lookup_genre.") }
            query.excludeGenreIds = [id]
        case "more_artist":
            guard let ref = AssistantRules.parseRef(target)?.text, issued[ref] != nil else {
                return AssistantSteerOutcome(applied: false, note: "Give the artist as the ref of one of their tracks that a tool returned.")
            }
            query.seedRefs = [ref]
        case "less_artist":
            guard let ref = AssistantRules.parseRef(target)?.text, issued[ref] != nil else {
                return AssistantSteerOutcome(applied: false, note: "Give the artist as the ref of one of their tracks that a tool returned.")
            }
            query.excludeArtistRefs = [ref]
        default:
            return AssistantSteerOutcome(applied: false, note: "That change is not one PixlAudio knows.")
        }
        guard let plan = await planFor(query, bump: 2), !plan.picks.isEmpty else {
            return AssistantSteerOutcome(applied: false, note: "PixlAudio could not find songs for that change.")
        }
        let picks = await picksOf(plan, surfaceId: "assistant", now: clock())
        let songs = plan.picks.prefix(picks.count).map(\.song)
        let engineTracks = plan.picks.compactMap(\.track)
        await register(engineTracks)
        let queued = await host.queueNext(Array(songs), tags: await tags(for: Array(songs)))
        return AssistantSteerOutcome(applied: queued > 0, tailChanged: queued,
                                     note: queued > 0 ? "Put \(queued) songs next in the queue; the rest of the queue follows unchanged." : "The queue could not take them.")
    }

    // MARK: explain_track

    public func explainTrack(ref: String) async -> AssistantTrackExplanation? {
        var key = ref
        if key == "now" {
            guard let current = await host.nowPlaying(), let r = await refFor(current, EngineTrack(queueSong: current)) else { return nil }
            if issued[r] == nil {
                remember(Issued(ref: r, song: current, rid: 0, track: nil, primaryArtist: BrainLibraryIndex.primaryArtistName(current),
                                tag: nil, servedX: nil))
            }
            key = r
        }
        guard let parsed = AssistantRules.parseRef(key), let song = await songOf(issued[key], key) else { return nil }
        let known = issued[key]
        let primary = known?.primaryArtist ?? BrainLibraryIndex.primaryArtistName(song)
        var rid = known?.rid ?? 0
        if rid == 0 { rid = await self.rid(of: song, ref: parsed, primary: primary) }
        if rid == 0 { return nil }
        let events = await engine.events().filter { $0.rid == rid }
        let newest = events.max { $0.startedAtMs < $1.startedAtMs }
        // The arm and the vector come from the pick made in this chat, else from the newest play of it.
        var arm = known?.tag?.arm
        if arm == nil, let n = newest, n.arm != Arm.none { arm = Arm.nameOf(n.arm) }
        let servedX = known?.servedX ?? newest?.servedX
        var factors: [AssistantRules.Factor]?
        if let x = ServedVector.dequantize(servedX) {
            let now = clock()
            let p0 = await engine.readAffinity { Affinity.p0($0, nowMs: now) }
            factors = AssistantRules.topFactors(x, Ranker.weights(p0: p0))
        }
        var genres: [String]?
        var year = song.year
        if let row = await parts?.dna?.track(rid) {
            if row.firstYear > 0 { year = row.firstYear }
            let tags = row.tagVector
            if !tags.isEmpty, let atlas = await parts?.atlas.atlas() {
                let names = tags.tags.compactMap { atlas.genre($0.atlasId)?.name }
                if !names.isEmpty { genres = names }
            }
        }
        let plays = events.filter { $0.playedMs > 0 || $0.endReason == EndReason.trackDone }.count
        let finished = events.filter { $0.endReason == EndReason.trackDone }.count
        return AssistantTrackExplanation(
            ref: key, title: song.title, artist: song.artist, arm: arm, whyKey: known?.tag?.whyKey,
            whyArgs: known?.tag?.whyArg.map { [$0] } ?? [], factors: factors, genres: genres, year: year,
            plays: events.isEmpty ? nil : plays,
            completionRate: plays >= AssistantTrackExplanation.minPlaysForRate ? Double(finished) / Double(plays) : nil)
    }

    // MARK: explain_taste

    private static let daypartNames = ["night", "early morning", "morning", "midday", "afternoon", "evening", "late evening", "late night"]

    public func explainTaste(scope: String) async -> AssistantTasteExplanation {
        guard let yourSound else {
            return AssistantTasteExplanation(scope: scope, lines: [], unknown: ["Your sound is not available on this device yet."])
        }
        let st = await yourSound.load()
        if st.isEmpty {
            return AssistantTasteExplanation(scope: scope, lines: [],
                                             unknown: ["PixlAudio has not seen enough plays to say anything about your taste yet."])
        }
        func pct(_ permille: Int) -> String { "\((permille + 5) / 10)% of plays" }
        var lines: [AssistantTasteLine] = []
        var unknown: [String] = []
        switch scope {
        case "islands":
            for i in st.islands {
                if let name = i.name {
                    lines.append(AssistantTasteLine(name: name, value: pct(i.permille), detail: i.topArtists.prefix(3).joined(separator: ", ")))
                }
            }
            if lines.isEmpty { unknown.append("Taste islands need about 20 plays in the last 28 days.") }
        case "genres":
            for g in st.genres.prefix(10) { lines.append(AssistantTasteLine(name: g.name, value: pct(g.permille))) }
            if lines.isEmpty { unknown.append("Genres are known only for tracks whose tags have been fetched. None are yet.") }
        case "dayparts":
            for d in st.dayparts where d.plays > 0 {
                let name = Self.daypartNames.indices.contains(d.daypart) ? Self.daypartNames[d.daypart] : "part \(d.daypart)"
                lines.append(AssistantTasteLine(name: name, value: "\(d.plays) plays", detail: d.leadingIsland ?? ""))
            }
            if lines.isEmpty { unknown.append("Times of day need more plays to say anything.") }
        case "recent_moves":
            for n in st.lately.up { lines.append(AssistantTasteLine(name: n, value: "up lately")) }
            for n in st.lately.down { lines.append(AssistantTasteLine(name: n, value: "down lately")) }
            if st.lately.isEmpty { unknown.append("Nothing has moved much in the last 14 days.") }
        case "model":
            let m = st.model
            switch m.kind {
            case ModelVoice.gettingToKnow:
                lines.append(AssistantTasteLine(name: "Recommendations", value: "using the standard recipe",
                                                detail: "still getting to know you: \(m.gradedPlays) clear plays so far"))
            case ModelVoice.standardRecipe:
                lines.append(AssistantTasteLine(name: "Recommendations", value: "using the standard recipe",
                                                detail: "\(m.gradedPlays) clear plays so far; the learned weights are not better yet"))
            default:
                lines.append(AssistantTasteLine(name: "Recommendations", value: "using weights learned from your plays",
                                                detail: "\(m.gradedPlays) clear plays so far"))
                if m.showsAccuracy, let now = m.accNowPercent, let prior = m.accPriorPercent {
                    lines.append(AssistantTasteLine(name: "Finishes and skips called right", value: "\(now)%",
                                                    detail: "the standard recipe: \(prior)%"))
                }
            }
            unknown.append("No accuracy figure is claimed beyond your own plays.")
        default:
            lines.append(AssistantTasteLine(name: "Plays counted", value: "\(st.plays)"))
            for i in st.islands.prefix(3) { if let name = i.name { lines.append(AssistantTasteLine(name: name, value: pct(i.permille))) } }
            for g in st.genres.prefix(3) { lines.append(AssistantTasteLine(name: g.name, value: pct(g.permille))) }
        }
        return AssistantTasteExplanation(scope: scope, lines: lines, unknown: unknown)
    }

    // MARK: lookup_genre

    public func lookupGenre(_ query: String) async -> AssistantGenreLookup {
        guard let atlas = await parts?.atlas.atlas() else { return AssistantGenreLookup() }
        func refs(_ ids: [Int]) -> [AssistantGenreRef] {
            ids.sorted().compactMap { id in atlas.genre(id).map { AssistantGenreRef(id: id, name: $0.name) } }
        }
        var id = GenreAtlas.none
        var isMood = false
        if let n = Int(BrainText.trim(query)), atlas.genre(n) != nil { id = n } else { id = atlas.idForName(query) }
        let key = BrainText.fold(query)
        if id == GenreAtlas.none, let m = atlas.moods.firstIndex(where: { BrainText.fold($0) == key }) {
            id = m + 1
            isMood = true
        }
        if id == GenreAtlas.none {
            // The nearest names: those that hold the words of the query (or are held by it), the shortest first.
            var near: [(ref: AssistantGenreRef, length: Int)] = []
            if !key.isEmpty {
                for gid in atlas.allIds {
                    guard let g = atlas.genre(gid) else { continue }
                    let name = BrainText.fold(g.name)
                    if name.contains(key) || key.contains(name) {
                        near.append((AssistantGenreRef(id: gid, name: g.name), name.utf16.count))
                    }
                }
            }
            near.sort { $0.length != $1.length ? $0.length < $1.length : $0.ref.id < $1.ref.id }
            return AssistantGenreLookup(genre: nil, nearest: near.prefix(Self.nearestGenres).map(\.ref))
        }
        if isMood { return AssistantGenreLookup(genre: AssistantGenreInfo(id: id, name: atlas.moods[id - 1], isMood: true), nearest: []) }
        guard let page = GenrePage.of(atlas, id), let g = atlas.genre(id) else { return AssistantGenreLookup() }
        let region = g.regions.filter { !BrainText.isBlank($0) }.prefix(2).joined(separator: ", ")
        return AssistantGenreLookup(
            genre: AssistantGenreInfo(
                id: id, name: page.name, description: page.description ?? "", parents: refs(page.parents), children: refs(page.children),
                related: refs(page.related), influences: refs(page.influences), region: region,
                era: (1000...2999).contains(g.eraStart) ? g.eraStart : 0, descriptors: []),
            nearest: [])
    }

    // MARK: similar_artists

    public func similarArtists(artist: String, count: Int, onlyUnplayed: Bool) async -> AssistantSimilarArtists {
        let key = BrainText.fold(artist)
        if key.isEmpty { return AssistantSimilarArtists(artists: [], note: "Give an artist's name.") }
        guard let dna = parts?.dna else {
            return AssistantSimilarArtists(artists: [], note: "PixlAudio has no similarity data yet.")
        }
        let all = await library()
        // The artist's recordings the graph knows: the library's own tracks by that artist.
        var requests: [TrackRequest] = []
        for s in BrainLibraryIndex(songs: all).byPrimaryArtist(key).prefix(40) {
            let keys = Ids.TrackKeys(spotifyId: Self.isRealSpotifyId(s.spotifyId) ? s.spotifyId : nil,
                                     videoId: TrackCatalog.videoId(ofSongId: s.id),
                                     nameKey: Ids.nameKey(primaryArtist: BrainLibraryIndex.primaryArtistName(s), rawTitle: s.title))
            requests.append(TrackRequest(keys: keys, durationMs: Int32(clamping: max(s.duration, 0))))
        }
        let rids = Set(await repository.resolveTracks(requests).filter { $0 != 0 })
        if rids.isEmpty {
            return AssistantSimilarArtists(artists: [], note: "PixlAudio has no recordings of that artist in its similarity graph.")
        }
        var weight: [Int64: Double] = [:]
        for e in await repository.edgesFor(Array(rids)) {
            if rids.contains(e.a) && !rids.contains(e.b) {
                weight[e.b, default: 0] += e.weight
            } else if rids.contains(e.b) && !rids.contains(e.a) {
                weight[e.a, default: 0] += e.weight
            }
        }
        struct Row { var name: String; var score: Double; var ref: String }
        var byArtist: [String: Row] = [:]
        for row in await dna.tracks(Array(weight.keys)) {
            let name = firstArtist(row.artistDisplay)
            let folded = BrainText.fold(name)
            if folded.isEmpty || folded == key { continue }
            var ref = ""
            if let video = row.ytAudioIds.split(separator: ",").map(String.init).first(where: { Self.isVideoId($0) }) {
                ref = AssistantRules.youTubeRef(video)
            } else if let id = row.spotifyId, Self.isRealSpotifyId(id) {
                ref = AssistantRules.spotifyRef(id)
            }
            var entry = byArtist[folded] ?? Row(name: name, score: 0, ref: ref)
            entry.score += weight[row.rid] ?? 0
            if entry.ref.isEmpty { entry.ref = ref }
            byArtist[folded] = entry
        }
        var ranked = byArtist.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.name.utf16.lexicographicallyPrecedes($1.name.utf16) }
        if onlyUnplayed {
            let played = Set(all.map { BrainLibraryIndex.artistKey(of: $0) })
            ranked = ranked.filter { !played.contains(BrainText.fold($0.name)) }
        }
        guard let top = ranked.first?.score, top > 0 else {
            return AssistantSimilarArtists(artists: [], note: "PixlAudio's graph has no artists close to that one yet.")
        }
        // Scores are relative to the closest.
        return AssistantSimilarArtists(artists: ranked.prefix(count).map {
            AssistantSimilarArtist(name: $0.name, ref: $0.ref, score: $0.score / top, sources: ["radio lists"])
        })
    }

    // MARK: new_releases

    public func newReleases(scope: String, count: Int) async -> AssistantReleaseList {
        if scope != "my_artists" {
            return AssistantReleaseList(releases: [], note: "PixlAudio only tracks new releases from the artists you play; \(scope) is not available.")
        }
        guard let releases = parts?.newReleases else {
            return AssistantReleaseList(releases: [], note: "PixlAudio has not looked for new releases yet.")
        }
        let taste = await mixes.sources.constraints()
        let cards = await releases.cards(blocked: taste.blocked, adjustments: taste.adjustments, library: BrainLibraryIndex(songs: await library()))
        var out: [AssistantRelease] = []
        var seen: Set<String> = []
        for card in cards {
            if !seen.insert(card.release.browseId).inserted { continue }
            let video = card.stored.row.videoId
            out.append(AssistantRelease(title: card.release.title, artist: card.release.artistName, type: card.release.kind.lowercased(),
                                        year: card.release.year, ref: Self.isVideoId(video) ? AssistantRules.youTubeRef(video) : ""))
            if out.count >= count { break }
        }
        return AssistantReleaseList(releases: out, note: out.isEmpty ? "PixlAudio has found no new releases from your artists lately." : "")
    }
}
