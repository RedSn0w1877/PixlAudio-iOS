import Foundation
import PixlFoundation
import PixlModel
import Testing
@testable import PixlLibrary

/// Milestone 1c of the music brain, "it shows" (docs/brain-spec.md, 8.1, 8.3, 8.4, 8.5, 8.8): stations, the Home
/// row, "Not for me" and the reason lines. The iOS twins of Android's `StationAndPlayTagsTest`,
/// `HomeAnchorStoreTest`, `BrainHomeRowsTest` and `BrainFeedbackTest`, against the real record files in a
/// temporary folder. The words on screen are checked in `BrainCopyTests`.

private final class ScriptedRadioSource: RadioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var songRadios: [String: FetchedRadio] = [:]
    private var artistPages: [String: ArtistPage] = [:]
    private var artistRadios: [String: FetchedRadio] = [:]
    private var recorded: [String] = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var calls: [String] { locked { recorded } }
    func setSongRadio(_ videoId: String, _ radio: FetchedRadio?) { locked { songRadios[videoId] = radio } }
    func setArtistPage(_ channelId: String, _ page: ArtistPage) { locked { artistPages[channelId] = page } }
    func setArtistRadio(_ playlistId: String, _ radio: FetchedRadio) { locked { artistRadios[playlistId] = radio } }

    func songRadio(videoId: String, continuations: Int) async -> FetchedRadio? {
        locked {
            recorded.append("song:\(videoId)")
            return songRadios[videoId]
        }
    }

    func related(browseId: String) async -> RelatedPage? { nil }

    func artistPage(channelId: String) async -> ArtistPage? {
        locked {
            recorded.append("artist:\(channelId)")
            return artistPages[channelId]
        }
    }

    func artistRadio(endpoint: RadioEndpoint) async -> FetchedRadio? {
        locked {
            recorded.append("artistRadio:\(endpoint.playlistId)")
            return artistRadios[endpoint.playlistId]
        }
    }
}

private final class StepClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(_ start: Int64) { value = start }

    var now: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ ms: Int64) {
        lock.lock()
        value += ms
        lock.unlock()
    }
}

private let t0: Int64 = 1_760_000_000_000

private struct World {
    let directory: URL
    let clock: StepClock
    let source: ScriptedRadioSource
    let repository: BrainRepository
    let engine: BrainEngine
    let rows: BrainHomeRows

    init() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("brain-surfaces-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directory = dir
        let clock = StepClock(t0)
        self.clock = clock
        let source = ScriptedRadioSource()
        self.source = source
        repository = BrainRepository(directory: dir, radioSource: source, clock: { clock.now })
        engine = BrainEngine(directory: dir, repository: repository, sources: nil, clock: { clock.now })
        rows = BrainHomeRows(directory: dir, repository: repository, engine: engine, clock: { clock.now })
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    /// A track the listener chose and heard out: what a Home row is built around.
    func hear(_ title: String, by artist: String, videoId: String, tag: BrainItemTag? = nil, flags: Int32 = 0,
              played: Int64 = 200_000, end: Int32 = EndReason.trackDone) async {
        let context = PlayContext(title: title, artistDisplay: artist, artists: [artist], videoId: videoId, inLibrary: false,
                                  startReason: tag?.arm == nil ? StartReason.tap : StartReason.autoplay, tag: tag)
        _ = await engine.record(FinishedPlay(songId: "yt:\(videoId)", context: context, startedAtMs: clock.now,
                                             playedMs: played, durationMs: 200_000, endReason: end, flags: flags,
                                             tzOffsetMin: 420))
        clock.advance(played + 1_000)
    }
}

private func radioRow(_ videoId: String, _ title: String, _ artist: String, channel: String? = nil,
                      seconds: Int = 200) -> RadioRow {
    RadioRow(videoId: videoId, title: title, artists: [RadioArtistRef(name: artist, channelId: channel)],
             durationSec: seconds, kind: .atv)
}

/// A healthy radio of `count` official-audio rows by ten artists behind its seed; the seed's artist shows up again.
private func radio(seedVideoId: String, seedTitle: String, seedArtist: String, prefix: String, count: Int = 45) -> FetchedRadio {
    var rows = [radioRow(seedVideoId, seedTitle, seedArtist)]
    for i in 1...count {
        let artist = i == 4 ? seedArtist : "\(prefix) Artist \(i % 10)"
        rows.append(radioRow("\(prefix)-v\(i)", "\(prefix) Song \(i)", artist))
    }
    return FetchedRadio(rows: rows)
}

@Suite("Brain stations")
struct BrainStationTests {
    @Test func startStationOnAPausedTrackPlaysIt() {
        #expect(StationRules.inPlaceStartMustPlay(isPlaying: false))
        #expect(!StationRules.inPlaceStartMustPlay(isPlaying: true))
    }

    @Test func aStationSurvivesBeingWrittenDownAndReadBack() {
        let song = Station.song(seedMediaId: "sp:4uLU6hMCjMI75M1A2tKUQC", title: "Espresso",
                                primaryArtist: "Sabrina Carpenter", nowMs: 42)
        #expect(Station.decode(song.encode()) == song)
        #expect(song.kind == Session.seedStationSong && song.title == "Espresso" && !song.isArtist)

        let artist = Station.artist(seedMediaId: "sp:4uLU6hMCjMI75M1A2tKUQC", artistName: "Sơn Tùng M-TP", nowMs: 43)
        #expect(Station.decode(artist.encode()) == artist)
        #expect(artist.isArtist && artist.title == "Sơn Tùng M-TP")

        // The same seed is a different station as a song and as an artist, and the id is not the seed's id.
        #expect(song.id != artist.id)
        #expect(song.id.count <= BrainItemTag.maxSurfaceIdLength)
        #expect(!song.id.contains("4uLU6hMCjMI75M1A2tKUQC"))
        // Android writes the same id: lower-case hex of FNV-1a 64 over "station|<kind>|<seed>".
        #expect(Station.idOf(kind: 2, seedMediaId: "seed") == BrainSurfaces.hashedId("station|2|seed"))
    }

    @Test func nonsenseIsNotAStation() {
        #expect(Station.decode(nil) == nil)
        #expect(Station.decode("") == nil)
        #expect(Station.decode("2") == nil)
        #expect(Station.decode("9\u{1F}seed\u{1F}t\u{1F}a\u{1F}1") == nil)
        #expect(Station.decode("2\u{1F}\u{1F}t\u{1F}a\u{1F}1") == nil)
        // A title that holds the separator cannot break the line.
        let odd = Station.song(seedMediaId: "seed", title: "A\u{1F}B", primaryArtist: "X", nowMs: 1)
        #expect(Station.decode(odd.encode())?.title == "A B")
    }

    @Test func theQueueIsTheStationsWhileItHoldsTheTaggedSeed() {
        let station = Station.song(seedMediaId: "seed", title: "Ditto", primaryArtist: "NewJeans", nowMs: 7)
        #expect(station.seedTag.surface == "station" && station.seedTag.surfaceId == station.id)
        #expect(!station.seedTag.isEngineOwned)
        #expect(station.isSeed(mediaId: "seed", tag: station.seedTag))
        // The same song started any other way is not the station's seed: any other play ends the station.
        #expect(!station.isSeed(mediaId: "seed", tag: nil))
        #expect(!station.isSeed(mediaId: "seed", tag: BrainSurfaces.tag(Surface.album)))
        #expect(!station.isSeed(mediaId: "other", tag: station.seedTag))
        let other = Station.song(seedMediaId: "seed2", title: "OMG", primaryArtist: "NewJeans", nowMs: 8)
        #expect(!station.isSeed(mediaId: "seed", tag: other.seedTag))
        // An engine pick under the station's surface is a pick, not the seed.
        let pick = BrainItemTag(surface: "station", surfaceId: station.id, recId: 1, slot: 0, arm: "RADIO")
        #expect(!station.isSeed(mediaId: "seed", tag: pick))

        #expect(StationRules.state(holdsSeed: true, queueIsEmpty: false, isRestoring: false) == .running)
        #expect(StationRules.state(holdsSeed: false, queueIsEmpty: false, isRestoring: false) == .ended)
        // Before a saved queue is back nothing is decided: a restored queue is still a station.
        #expect(StationRules.state(holdsSeed: false, queueIsEmpty: true, isRestoring: false) == .unknown)
        #expect(StationRules.state(holdsSeed: false, queueIsEmpty: false, isRestoring: true) == .unknown)
    }

    @Test func theNoveltySwitchIsPointFourOneAndTwoAndAnythingElseIsBlend() {
        #expect(Novelty.factor(Novelty.familiar) == 0.4)
        #expect(Novelty.factor(Novelty.blend) == 1.0)
        #expect(Novelty.factor(Novelty.discover) == 2.0)
        #expect(Novelty.clamp(7) == Novelty.blend && Novelty.clamp(-1) == Novelty.blend)
        #expect(Novelty.clamp(Novelty.discover) == Novelty.discover)
    }

    @Test func aStationOpensWithTwentyThenFiveAndLeansFurtherOut() {
        #expect(StationRules.batchSize(isStation: true, batchesSoFar: 0) == 20)
        #expect(StationRules.batchSize(isStation: true, batchesSoFar: 1) == AutoplayPolicy.batchSize)
        #expect(StationRules.batchSize(isStation: false, batchesSoFar: 0) == AutoplayPolicy.batchSize)
        #expect(StationRules.surfaceNu(isStation: true, listenerItems: 1) == 1.2)
        #expect(StationRules.surfaceNu(isStation: false, listenerItems: 1) == 1.0)
        #expect(StationRules.surfaceNu(isStation: false, listenerItems: 12) == 0.8)
    }

    @Test func anArtistStationStartsOnTheListenersMostPlayedTrackByThem() {
        func song(_ id: String, _ artists: [String]) -> Song {
            testSong(id, title: "T \(id)", artist: artists.joined(separator: ", "),
                     artists: artists.enumerated().map { ArtistRef(id: Int64($0.offset), name: $0.element, isPrimary: $0.offset == 0) })
        }
        let library = [song("a", ["Sơn Tùng M-TP"]), song("b", ["SON TUNG M-TP"]), song("c", ["Other", "Sơn Tùng M-TP"]),
                       song("d", ["Other"])]
        let plays = ["a": 3, "b": 9, "c": 50]
        // The primary artist's own tracks first, by play count; folding joins the spellings.
        #expect(StationRules.artistSeed(artistName: "Sơn Tùng M-TP", songs: library, playCount: { plays[$0] ?? 0 })?.id == "b")
        // Never played: the first of the library.
        #expect(StationRules.artistSeed(artistName: "son tung m-tp", songs: library, playCount: { _ in 0 })?.id == "a")
        // Only credited: a track that names them.
        #expect(StationRules.artistSeed(artistName: "Sơn Tùng M-TP", songs: [library[2], library[3]], playCount: { _ in 0 })?.id == "c")
        #expect(StationRules.artistSeed(artistName: "Nobody", songs: library, playCount: { _ in 0 }) == nil)
        #expect(StationRules.artistSeed(artistName: "  ", songs: library, playCount: { _ in 0 }) == nil)
        #expect(StationRules.primaryArtist(of: library[2]) == "Other")
        #expect(StationRules.primaryArtist(of: testSong("x", artist: EngineTrack.unknownArtist)) == "")
    }

    private func entry(_ id: String, rid: Int64, aid: Int64, rank: Int32) -> AutoplayPoolEntry {
        AutoplayPoolEntry(
            candidate: AutoplayPolicy.Candidate(mediaId: id, rid: rid, artistKey: "a\(aid)", albumKey: nil, durationMs: 200_000,
                                                versionFlags: 0, officialAudio: true, inLibrary: false, arm: Arm.radio,
                                                radioRank: rank),
            librarySong: nil, engineTrack: nil, whyArtist: "Seed Artist", primaryArtist: "Artist \(aid)",
            brain: Candidate(rid: rid, aid: aid, inLibrary: false))
    }

    @Test func aStationPlanRunsInStationModeUnderTheStationsSurface() async {
        let w = World()
        defer { w.cleanUp() }
        let station = Station.song(seedMediaId: "seed", title: "Ditto", primaryArtist: "Seed Artist", nowMs: t0)
        var pool: [AutoplayPoolEntry] = []
        for n in 0..<30 { pool.append(entry("p\(n)", rid: Int64(100 + n), aid: Int64(10 + n), rank: Int32(n + 1))) }
        let seeds = [Retrieval.SeedList(seedRid: 1, seedAid: 5, rids: pool.map(\.candidate.rid))]
        let queue = [AutoplayQueueItem(mediaId: "seed", engineOwned: false)]
        let context = AutoplayPlanning.inputs(queue: queue, tailStart: 1, tailEntries: [], pool: pool, served: [:],
                                              recentlyPlayed: [], seeds: seeds, nowMs: t0, tzOffsetMin: 0, batch: 1,
                                              station: station, noveltyFactor: Novelty.factor(Novelty.discover))
        #expect(context.inputs.station == station)
        #expect(context.inputs.nuMultiplier == 2.0 * 1.2)
        let count = StationRules.batchSize(isStation: true, batchesSoFar: 0)
        let plan = await w.engine.plan(context.inputs, count: count, bridge: false, tail: nil)
        #expect(plan?.picks.count == 20, "a station opens with twenty picks")
        // The session knows it is a station: its seed artist is thinned out after skips, never blocked.
        let session = await w.engine.sessionSnapshot()
        #expect(session.seedKind == Session.seedStationSong && session.seed == 1 && session.seedAid == 5)
        let items = AutoplayPlanning.items(plan: plan!, context: context, surfaceId: "seed", artistNames: [5: "Seed Artist"],
                                           likedTitles: [:], station: station)
        #expect(items.count == 20)
        #expect(items.allSatisfy { $0.tag.surface == "station" && $0.tag.surfaceId == station.id && $0.tag.isEngineOwned })
        #expect(items[0].tag.whyKey == "radio_fans" && items[0].tag.whyArg == "Seed Artist")

        // Plain autoplay again: the seed is forgotten.
        let plain = AutoplayPlanning.inputs(queue: queue, tailStart: 1, tailEntries: [], pool: pool, served: [:],
                                            recentlyPlayed: [], seeds: seeds, nowMs: t0, tzOffsetMin: 0, batch: 2)
        _ = await w.engine.plan(plain.inputs, count: 5, bridge: true, tail: nil)
        let after = await w.engine.sessionSnapshot()
        #expect(after.seedKind == Session.seedNone && after.seed == 0)
        let autoplayItem = AutoplayPlanning.tag(entry: pool[0], pick: nil, recId: 9, slot: 0, surfaceId: "seed",
                                                artistNames: [:], likedTitles: [:])
        #expect(autoplayItem.surface == "autoplay" && autoplayItem.surfaceId == "seed")
        // A pick in pool order from an anchor's radio still says whose listeners play it.
        #expect(autoplayItem.whyKey == "radio_fans" && autoplayItem.whyArg == "Seed Artist")
    }

    @Test func anArtistStationLeadsWithTheArtistsTopSongsAndRadio() async throws {
        let w = World()
        defer { w.cleanUp() }
        let seedRow = radioRow("seedvid", "Seed Song", "The Artist", channel: "UCartist")
        var songRadio = radio(seedVideoId: "seedvid", seedTitle: "Seed Song", seedArtist: "The Artist", prefix: "S")
        songRadio.rows[0] = seedRow
        songRadio.rows[4] = radioRow("S-v4", "S Song 4", "The Artist", channel: "UCartist")
        w.source.setSongRadio("seedvid", songRadio)
        var top: [RadioRow] = []
        for i in 1...5 { top.append(radioRow("top\(i)", "Top \(i)", "The Artist", channel: "UCartist", seconds: 0)) }
        w.source.setArtistPage("UCartist", ArtistPage(name: "The Artist",
                                                      radio: RadioEndpoint(videoId: nil, playlistId: "RDartist"),
                                                      topSongs: top, albums: [], singles: [], fansAlsoLike: []))
        var artistRows: [RadioRow] = []
        for i in 1...45 {
            artistRows.append(radioRow("ar\(i)", "Radio \(i)", i % 5 == 0 ? "The Artist" : "Near \(i % 7)",
                                       channel: i % 5 == 0 ? "UCartist" : nil))
        }
        w.source.setArtistRadio("RDartist", FetchedRadio(rows: artistRows))

        let seed = RadioSeed(mediaId: "yt:seedvid", videoId: "seedvid", title: "Seed Song", primaryArtist: "The Artist",
                             durationMs: 200_000)
        let stored = try #require(await w.repository.artistRadio(seed: seed, allowNetwork: true))
        #expect(stored.kind == RadioList.kindArtist && !stored.fromCache)
        #expect(stored.rows.prefix(5).map(\.row.videoId) == ["top1", "top2", "top3", "top4", "top5"])
        #expect(stored.rows.count == 50)
        // The channel id came from one `next` (nothing was cached), then the page, then the radio.
        #expect(w.source.calls == ["song:seedvid", "artist:UCartist", "artistRadio:RDartist"])
        // The second time it is the cache.
        let again = try #require(await w.repository.artistRadio(seed: seed, allowNetwork: true))
        #expect(again.fromCache && again.rows == stored.rows)
        #expect(w.source.calls.count == 3)
        // Offline with nothing cached for another seed: nothing.
        let unknown = RadioSeed(mediaId: "yt:zzz", videoId: "zzz", title: "Zed", primaryArtist: "Nobody", durationMs: 1)
        #expect(await w.repository.artistRadio(seed: unknown, allowNetwork: false) == nil)

        // The pool of an artist station: the artist's own tracks are "more from" them and lead the lists.
        let anchorSong = testSong("yt:seedvid", title: "Seed Song", artist: "The Artist",
                                  artists: [ArtistRef(id: 1, name: "The Artist", isPrimary: true)])
        var request = AutoplayPoolRequest(anchors: [AutoplayAnchor(song: anchorSong, videoId: "seedvid", spotifyId: nil)],
                                          deepen: false, allowNetwork: true, library: [], everPlayed: [])
        request.station = Station.artist(seedMediaId: "yt:seedvid", artistName: "The Artist", nowMs: t0)
        request.nowMs = t0
        let pool = await AutoplayPool.build(request, index: BrainLibraryIndex(songs: []), repository: w.repository,
                                            engine: w.engine)
        #expect(pool.seeds.count == 2, "the artist's list, then the seed's own radio")
        #expect(pool.seeds[0].rids.first == stored.rows[0].rid)
        let own = pool.entries.filter { $0.candidate.arm == Arm.artist }
        #expect(!own.isEmpty && own.allSatisfy { $0.primaryArtist == "The Artist" && $0.brain?.fromArtistRadio == true })
        #expect(pool.entries.contains { $0.candidate.arm == Arm.radio })
    }

    @Test func aTasteChangeNamesTheHeldTracksItExcludes() {
        let muted = testSong("yt:m", title: "Muted", artist: "Someone")
        var list = TasteAdjustmentList()
        list.apply(BrainFeedback.muteChange(for: muted), nowMs: 1)
        let held = [
            AutoplayPoolEntry(candidate: AutoplayPolicy.Candidate(mediaId: "yt:m", rid: 1, artistKey: "someone", albumKey: nil,
                                                                  durationMs: 1, versionFlags: 0, officialAudio: true,
                                                                  inLibrary: true, arm: Arm.fav, radioRank: 0),
                              librarySong: muted, engineTrack: nil, whyArtist: ""),
            AutoplayPoolEntry(candidate: AutoplayPolicy.Candidate(mediaId: "yt:k", rid: 2, artistKey: "x", albumKey: nil,
                                                                  durationMs: 1, versionFlags: 0, officialAudio: true,
                                                                  inLibrary: true, arm: Arm.fav, radioRank: 0),
                              librarySong: testSong("yt:k", title: "Kept", artist: "Else"), engineTrack: nil, whyArtist: ""),
        ]
        #expect(AutoplayTasteFilter.excludedIds(held: held, blocked: .empty, adjustments: list.set(nowMs: 2)) == ["yt:m"])
        #expect(AutoplayTasteFilter.excludedIds(held: held, blocked: .empty, adjustments: .empty).isEmpty)
    }

    @Test func lessFromAnArtistChangesTheScoresOfWhatTheEngineAlreadyHolds() throws {
        func entry(_ id: String, _ artist: String, rid: Int64, scored: Bool = true) -> AutoplayPoolEntry {
            AutoplayPoolEntry(candidate: AutoplayPolicy.Candidate(mediaId: id, rid: rid, artistKey: BrainText.fold(artist),
                                                                  albumKey: nil, durationMs: 200_000, versionFlags: 0,
                                                                  officialAudio: true, inLibrary: true, arm: Arm.fav, radioRank: 1),
                              librarySong: testSong(id, title: "Song \(id)", artist: artist,
                                                    artists: [ArtistRef(id: 1, name: artist, isPrimary: true)]),
                              engineTrack: nil, whyArtist: "", primaryArtist: artist,
                              brain: scored ? Candidate(rid: rid, aid: 0, inLibrary: true) : nil)
        }
        let held = [entry("a", "Loud Band", rid: 1), entry("b", "Else", rid: 2), entry("c", "Loud Band", rid: 3, scored: false)]
        var list = TasteAdjustmentList()
        list.apply(try #require(BrainFeedback.lessFromChange(artistName: "Loud Band")), nowMs: 1)
        let boosts = AutoplayTasteFilter.boosts(held: held, adjustments: list.set(nowMs: 2))
        // The pool was built before the change: its entries still score as if nothing was said.
        #expect(held[0].brain?.boostLn == 0.0)
        #expect((boosts["a"] ?? 0.0) < 0.0, "a reduce is a negative term in the planner's score")
        #expect(boosts["b"] == 0.0)
        #expect(boosts["c"] == nil, "an entry the planner does not score has no boost")
        let applied = AutoplayTasteFilter.applying(boosts, to: held)
        #expect(applied.changed)
        #expect(applied.entries[0].brain?.boostLn == boosts["a"])
        #expect(applied.entries[1].brain?.boostLn == 0.0)
        // Applied twice nothing moves, so the tail is not planned again for nothing.
        #expect(!AutoplayTasteFilter.applying(boosts, to: applied.entries).changed)
        // Undo: the boost goes back to none.
        let undone = AutoplayTasteFilter.applying(AutoplayTasteFilter.boosts(held: applied.entries, adjustments: .empty),
                                                  to: applied.entries)
        #expect(undone.changed && undone.entries[0].brain?.boostLn == 0.0)
    }
}

@Suite("Brain Home rows")
struct BrainHomeRowTests {
    private func anchor(_ rid: Int64, _ artist: String, heardAt: Int64, aid: Int64? = nil) -> HomeAnchor {
        HomeAnchor(rid: rid, aid: aid ?? rid, mediaId: "m\(rid)", title: "T\(rid)", primaryArtist: artist,
                   spotifyId: "s\(rid)", heardAtMs: heardAt)
    }

    @Test func aTrackTheListenerChoseAndHeardOutIsAnAnchorWithWhatARadioRequestNeeds() async {
        let w = World()
        defer { w.cleanUp() }
        await w.hear("Espresso", by: "Sabrina Carpenter", videoId: "esp")
        let anchors = await w.engine.homeAnchors()
        #expect(anchors.count == 1)
        #expect(anchors.first?.mediaId == "yt:esp" && anchors.first?.title == "Espresso")
        #expect(anchors.first?.primaryArtist == "Sabrina Carpenter" && anchors.first?.videoId == "esp")
        #expect(anchors.first?.rid != 0 && anchors.first?.aid != 0)
        #expect(anchors.first?.heardAtMs == t0 + 200_000)
    }

    @Test func aSkipAnAutoplayPlayThroughANotForMeAndASilentPlayAreNotAnchors() async {
        let w = World()
        defer { w.cleanUp() }
        let autoplay = BrainItemTag(surface: "autoplay", surfaceId: "seed", recId: 99, slot: 2, arm: "RADIO")
        await w.hear("Skipped", by: "A", videoId: "v1", played: 4_000, end: EndReason.next)
        await w.hear("Played Through", by: "B", videoId: "v2", tag: autoplay)
        await w.hear("Not Mine", by: "C", videoId: "v3", flags: EventFlags.notForMe, end: EndReason.next)
        await w.hear("Silent", by: "D", videoId: "v4", flags: EventFlags.neverAudible, played: 0, end: EndReason.error)
        #expect(await w.engine.homeAnchors().isEmpty)
        // An engine pick the listener liked is one.
        await w.hear("Liked Pick", by: "E", videoId: "v5", tag: autoplay, flags: EventFlags.likedDuring)
        #expect(await w.engine.homeAnchors().map(\.mediaId) == ["yt:v5"])
        // So is a play with a surface and no arm.
        await w.hear("From A Playlist", by: "F", videoId: "v6", tag: BrainItemTag(surface: "playlist", arm: "NONE"))
        #expect(await w.engine.homeAnchors().map(\.mediaId) == ["yt:v6", "yt:v5"])
    }

    @Test func newestFirstOneEntryPerRecordingEightAtMost() {
        var list: [HomeAnchor] = []
        for i in 1...12 { list = HomeAnchors.push(list, anchor(Int64(i), "A\(i)", heardAt: Int64(i))) }
        #expect(list.count == HomeAnchors.max && list.first?.rid == 12)
        list = HomeAnchors.push(list, anchor(9, "A9", heardAt: 99))
        #expect(list.first?.rid == 9 && list.filter { $0.rid == 9 }.count == 1)
        #expect(HomeAnchors.decode(HomeAnchors.encode(list)) == list)
        #expect(!HomeAnchors.encode(list).contains("\n"))
        #expect(HomeAnchors.decode(nil).isEmpty && HomeAnchors.decode("{").isEmpty && HomeAnchors.decode("not json").isEmpty)
    }

    @Test func aPageGetsTheTwoNewestAnchorsByDifferentArtistsOfTheLastSevenDays() {
        let day: Int64 = 24 * 60 * 60 * 1000
        let now = t0
        let list = [
            anchor(1, "Sabrina Carpenter", heardAt: now - 1_000, aid: 10),
            anchor(2, "Sabrina Carpenter", heardAt: now - 2_000, aid: 10),
            anchor(3, "sabrina carpenter", heardAt: now - 3_000, aid: 0),
            anchor(4, "NewJeans", heardAt: now - 8 * day, aid: 11),
            anchor(5, "d4vd", heardAt: now - 2 * day, aid: 12),
            anchor(6, "Nirvana", heardAt: now - 3 * day, aid: 13),
        ]
        #expect(HomeAnchors.pick(list, nowMs: now, count: 2).map(\.rid) == [1, 5])
        #expect(HomeAnchors.pick([], nowMs: now, count: 2).isEmpty)
    }

    @Test func nothingIsBuiltBeforeTheBrainWasUsedInThisProcess() async {
        let w = World()
        defer { w.cleanUp() }
        #expect(!(await w.engine.isLoaded))
        let built = await w.rows.refreshIfDue(tasteRevision: 0, blockedCount: 0) {
            Issue.record("the inputs are not asked for before the brain is loaded")
            return HomeRowInputs(library: [], allowNetwork: true)
        }
        #expect(built == nil)
        #expect(w.source.calls.isEmpty)
        #expect(await w.rows.cached().isEmpty)
    }

    @Test func aRowIsTwelveTracksTheListenerDoesNotHaveTwoPerArtistAtMostEachWithItsTags() async throws {
        let w = World()
        defer { w.cleanUp() }
        w.source.setSongRadio("esp", radio(seedVideoId: "esp", seedTitle: "Espresso", seedArtist: "Sabrina Carpenter", prefix: "A"))
        await w.hear("Espresso", by: "Sabrina Carpenter", videoId: "esp")
        // The library already has one of the radio's rows: it is not a card.
        let owned = testSong("lib", title: "A Song 3", artist: "A Artist 3", duration: 200_000,
                             artists: [ArtistRef(id: 1, name: "A Artist 3", isPrimary: true)])
        let inputs: @Sendable () async -> HomeRowInputs = { HomeRowInputs(library: [owned], allowNetwork: true, tzOffsetMin: 420) }

        let built = try #require(await w.rows.refreshIfDue(tasteRevision: 0, blockedCount: 0, inputs: inputs))
        #expect(built.count == 1)
        let row = built[0]
        let espresso = try #require(await w.engine.homeAnchors().first)
        #expect(row.id == BrainHomeRow.idOf(anchorRid: espresso.rid) && row.id.hasPrefix("because_"))
        #expect(row.anchor.title == "Espresso")
        #expect(row.items.count == BrainHomeRows.cards)
        #expect(!row.items.contains { $0.track.title == "A Song 3" })
        var perArtist: [String: Int] = [:]
        for item in row.items { perArtist[item.track.artists[0].name, default: 0] += 1 }
        #expect(perArtist.values.allSatisfy { $0 <= 2 })
        #expect(row.items.map(\.slot) == Array(0..<BrainHomeRows.cards))
        // Every card is a track from outside the library, playable as an engine track.
        #expect(row.items.allSatisfy { $0.track.songId.hasPrefix("yt:") && $0.track.contentUri.hasPrefix("pixlstream://") })

        let tags = row.tags()
        #expect(tags.count == BrainHomeRows.cards)
        let first = try #require(tags[row.items[0].track.songId])
        #expect(first.surface == "homeShelf" && first.surfaceId == row.id && first.recId == row.recId && first.slot == 0)
        #expect(first.arm == "RADIO" && first.whyKey == "because_listened" && first.whyArg == "Espresso")
        // The listener plays the row themselves: its tracks are theirs in the queue, not the engine's tail.
        #expect(first.chosen && !first.isEngineOwned)
        #expect(row.cardReason(row.items[0]) == .radioFans("Sabrina Carpenter"))

        // The same anchors and the same taste: nothing is rebuilt, and the saved rows are what Home shows.
        #expect(await w.rows.refreshIfDue(tasteRevision: 0, blockedCount: 0, inputs: inputs) == nil)
        #expect(w.source.calls == ["song:esp"])
        #expect(await w.rows.cached().first?.items.map(\.track.songId) == row.items.map(\.track.songId))
        // And what another process reads from the file.
        let reopened = BrainHomeRows(directory: w.directory, repository: w.repository, engine: w.engine, clock: { t0 + 400_000 })
        #expect(await reopened.cached().first?.items.map(\.track.songId) == row.items.map(\.track.songId))
        // A week later the anchor is too old to show.
        let later = BrainHomeRows(directory: w.directory, repository: w.repository, engine: w.engine,
                                  clock: { t0 + 8 * 24 * 60 * 60 * 1000 })
        #expect(await later.cached().isEmpty)
    }

    @Test func twoAnchorsGiveTwoRowsAndATrackIsOnThePageOnce() async throws {
        let w = World()
        defer { w.cleanUp() }
        // Both radios hold the same tracks behind their own seed.
        w.source.setSongRadio("ditto", radio(seedVideoId: "ditto", seedTitle: "Ditto", seedArtist: "NewJeans", prefix: "A", count: 60))
        w.source.setSongRadio("esp", radio(seedVideoId: "esp", seedTitle: "Espresso", seedArtist: "Sabrina Carpenter", prefix: "A", count: 60))
        await w.hear("Ditto", by: "NewJeans", videoId: "ditto")
        await w.hear("Espresso", by: "Sabrina Carpenter", videoId: "esp")
        let built = try #require(await w.rows.refreshIfDue(tasteRevision: 0, blockedCount: 0) {
            HomeRowInputs(library: [], allowNetwork: true)
        })
        #expect(built.map(\.anchor.title) == ["Espresso", "Ditto"])
        let all = built.flatMap { $0.items.map(\.track.rid) }
        #expect(all.count == Set(all).count)
        #expect(built[0].recId != built[1].recId)
    }

    @Test func aRadioWithTooLittleToShowGivesNoRowAndIsNotAskedAgainAtOnce() async {
        let w = World()
        defer { w.cleanUp() }
        // Offline with nothing cached: no radio, no row.
        await w.hear("Espresso", by: "Sabrina Carpenter", videoId: "esp")
        let offline: @Sendable () async -> HomeRowInputs = { HomeRowInputs(library: [], allowNetwork: false) }
        #expect(await w.rows.refreshIfDue(tasteRevision: 0, blockedCount: 0, inputs: offline) == nil)
        #expect(await w.rows.cached().isEmpty)
        let asked = ScriptedFlag()
        #expect(await w.rows.refreshIfDue(tasteRevision: 0, blockedCount: 0) {
            asked.set()
            return HomeRowInputs(library: [], allowNetwork: false)
        } == nil)
        #expect(!asked.isSet, "a row that could not be built is tried again later, not on every visit")
    }

    @Test func aTasteChangeRebuildsTheRowsAndMutedMusicIsNotACard() async throws {
        let w = World()
        defer { w.cleanUp() }
        w.source.setSongRadio("esp", radio(seedVideoId: "esp", seedTitle: "Espresso", seedArtist: "Sabrina Carpenter", prefix: "A"))
        await w.hear("Espresso", by: "Sabrina Carpenter", videoId: "esp")
        let before = try #require(await w.rows.refreshIfDue(tasteRevision: 0, blockedCount: 0) {
            HomeRowInputs(library: [], allowNetwork: true)
        }).first
        // "Not for me" on the first card.
        let muted = try #require(before?.items.first?.track)
        var list = TasteAdjustmentList()
        list.apply(BrainFeedback.muteChange(for: muted.song()), nowMs: t0)
        let set = list.set(nowMs: t0 + 1)
        let after = try #require(await w.rows.refreshIfDue(tasteRevision: 1, blockedCount: 0) {
            HomeRowInputs(library: [], adjustments: set, allowNetwork: true)
        }).first
        #expect(after?.items.contains { $0.track.songId == muted.songId } == false)
        #expect(after?.items.count == BrainHomeRows.cards)
    }
}

private final class ScriptedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

@Suite("Brain feedback")
struct BrainFeedbackTests {
    private func song(_ title: String, _ artists: [String], display: String? = nil) -> Song {
        testSong("id-\(title)", title: title, artist: display ?? artists.joined(separator: ", "),
                 artists: artists.enumerated().map { ArtistRef(id: Int64($0.offset), name: $0.element, isPrimary: $0.offset == 0) })
    }

    @Test func notForMeIsAMuteOfTheRecordingThatCanBeTakenBack() {
        let espresso = song("Espresso", ["Sabrina Carpenter"])
        let change = BrainFeedback.muteChange(for: espresso)
        #expect(change.action == .mute && change.targetType == .song && change.source == .user)
        #expect(change.key == TasteKey.recording(espresso))
        #expect(change.label == "Espresso — Sabrina Carpenter" && change.reason == "Not for me")

        var list = TasteAdjustmentList()
        let outcome = list.apply(change, nowMs: 10)
        let id = BrainFeedback.adjustmentId(of: outcome)
        #expect(id != nil)
        // Muted in everything the app picks by itself, whichever way the recording comes in.
        let set = list.set(nowMs: 11)
        #expect(set.isExcluded(espresso))
        #expect(set.isExcluded(testSong("yt:other-id", title: "Espresso", artist: "Sabrina Carpenter")))
        #expect(!set.isExcluded(song("Taste", ["Sabrina Carpenter"])))
        // Undo takes the change back.
        let removed = list.remove(id: id ?? "")
        #expect(removed)
        #expect(!list.set(nowMs: 12).isExcluded(espresso))
    }

    @Test func lessFromIsTheExistingReduceOnTheArtist() {
        let change = BrainFeedback.lessFromChange(artistName: "Doja Cat")
        #expect(change?.action == .reduce && change?.targetType == .artist && change?.key == TasteKey.of("Doja Cat"))
        #expect(change?.label == "Doja Cat" && change?.reason == "Less from this artist" && change?.source == .user)
        #expect(BrainFeedback.lessFromChange(artistName: "  ") == nil)
        var list = TasteAdjustmentList()
        list.apply(change!, nowMs: 1)
        #expect(list.set(nowMs: 2).factor(for: song("Woman", ["Doja Cat"])) < 1.0)
    }

    @Test func theArtistOfATrackIsItsPrimaryCredit() {
        #expect(BrainFeedback.artistOf(song("A", ["Tyler, The Creator", "Kali Uchis"])) == "Tyler, The Creator")
        // A song rebuilt from a queue snapshot has only its display line.
        #expect(BrainFeedback.artistOf(song("B", [], display: "Doja Cat, SZA")) == "Doja Cat")
        #expect(BrainFeedback.artistOf(song("C", [], display: EngineTrack.unknownArtist)) == "")
        #expect(BrainFeedback.artistOf(song("D", [], display: "  ")) == "")
    }

    @Test func theBarOffersUndoAndAfterNotForMeTheStepToTheArtist() {
        var list = TasteAdjustmentList()
        let stored = list.apply(BrainFeedback.muteChange(for: song("Espresso", ["Sabrina Carpenter"])), nowMs: 1)
        let notice = BrainNotice.afterNotForMe(serial: 1, outcome: stored, artistName: "Sabrina Carpenter")
        #expect(notice.kind == .notForMe && notice.canUndo && notice.canLessFrom && notice.visibleMs == 7_000)
        // A track that names nobody: Undo only.
        #expect(!BrainNotice.afterNotForMe(serial: 2, outcome: stored, artistName: "").canLessFrom)
        // The list is full: nothing was stored, nothing to undo.
        let failed = BrainNotice.afterNotForMe(serial: 3, outcome: .listFull, artistName: "X")
        #expect(failed.kind == .notSaved && !failed.canUndo && !failed.canLessFrom)
        let less = BrainNotice.afterLessFrom(serial: 4, outcome: stored, artistName: "X")
        #expect(less.kind == .lessFrom && less.canUndo && !less.canLessFrom)
        #expect(BrainNotice(serial: 5, kind: .undone, adjustmentId: nil, artistName: "").visibleMs == 2_500)
    }

    @Test func aReasonLineIsATrueStatementOrNothing() {
        #expect(WhyLineText.line(keyName: "radio_fans", arg: "d4vd") == .radioFans("d4vd"))
        #expect(WhyLineText.line(keyName: "because_liked", arg: "Woman") == .becauseLiked("Woman"))
        #expect(WhyLineText.line(keyName: "because_listened", arg: " Espresso ") == .becauseListened("Espresso"))
        #expect(WhyLineText.line(keyName: "artist_more", arg: "Chappell Roan") == .artistMore("Chappell Roan"))
        #expect(WhyLineText.line(keyName: "on_repeat", arg: "") == .onRepeat)
        // A sentence that needs a name is not shown without one.
        #expect(WhyLineText.line(keyName: "radio_fans", arg: "") == nil)
        #expect(WhyLineText.line(keyName: "because_liked", arg: "  ") == nil)
        #expect(WhyLineText.line(keyName: "artist_more", arg: nil) == nil)
        // Keys of arms stage 1 does not serve, and nonsense, show nothing.
        #expect(WhyLineText.line(keyName: "new_release", arg: "X") == nil)
        #expect(WhyLineText.line(keyName: "nonsense", arg: "X") == nil)
        #expect(WhyLineText.line(keyName: nil, arg: "X") == nil)
    }

    @Test func theQueuesReasonsAreKeptByMediaId() {
        let pick = BrainItemTag(surface: "autoplay", recId: 1, slot: 0, arm: "RADIO", whyArg: "d4vd", whyKey: "radio_fans")
        let nameless = BrainItemTag(surface: "autoplay", recId: 1, slot: 1, arm: "RADIO", whyKey: "radio_fans")
        let card = BrainItemTag(surface: "homeShelf", arm: "RADIO", whyArg: "Espresso", whyKey: "because_listened", chosen: true)
        let entries: [(mediaId: String, tag: BrainItemTag?)] = [("own", nil), ("a", pick), ("b", nameless), ("c", card),
                                                                 ("d", BrainSurfaces.tag(Surface.album))]
        let why = QueueWhy.map(entries)
        #expect(why == ["a": QueueWhy(key: "radio_fans", arg: "d4vd"), "c": QueueWhy(key: "because_listened", arg: "Espresso")])
        #expect(why["a"]?.line == .radioFans("d4vd"))
    }
}

@Suite("Brain ignored three times")
struct BrainIgnoredTests {
    private func event(rid: Int64, at ms: Int64, played: Int32, arm: Int32 = Arm.radio, end: Int32 = EndReason.next,
                       flags: Int32 = 0) -> PlayEvent {
        PlayEvent(eventId: ms, origin: Origin.live, rid: rid, primaryAid: 1, otherAids: [], keyAtWrite: "y:\(rid)",
                  startedAtMs: ms, tzOffsetMin: 0, playedMs: played, durationMs: 200_000, startReason: StartReason.autoplay,
                  endReason: end, flags: flags, surface: Surface.autoplay, surfaceId: "", recId: 1, slot: 0, arm: arm,
                  sessionId: 1, posInSession: 0, passiveRun: 0, route: Route.unknown, retrQ: -1, radioRank: -1)
    }

    @Test func threePicksTheListenerSkippedAndNoLongPlayKeepASongAwayForSixtyDaysFromTheLastSkip() {
        let day: Int64 = 24 * 60 * 60 * 1000
        var tally = IgnoreTally()
        let first = tally.note(event(rid: 7, at: t0, played: 3_000))
        #expect(first == IgnoreTally.Row(shorts: [t0]))
        tally.note(event(rid: 7, at: t0 + day, played: 29_999, end: EndReason.pickedOther))
        #expect(tally.ignored(nowMs: t0 + 2 * day).isEmpty, "twice is not three times")
        tally.note(event(rid: 7, at: t0 + 2 * day, played: 1_000, end: EndReason.queueEdit))
        #expect(tally.ignored(nowMs: t0 + 2 * day) == [7])
        // The same play handed over again changes nothing.
        let again = tally.note(event(rid: 7, at: t0 + 2 * day, played: 1_000))
        #expect(again == nil && tally.rows[7]?.shorts.count == 3)
        // The 60 days run from the LAST of the three (day 2), not the first.
        #expect(tally.ignored(nowMs: t0 + 61 * day) == [7])
        #expect(tally.ignored(nowMs: t0 + 62 * day + 1).isEmpty)
        // One play of 30 s or more clears it, from anywhere: here the listener's own play (no arm).
        tally.note(event(rid: 7, at: t0 + 3 * day, played: 30_000, arm: Arm.none, end: EndReason.trackDone))
        #expect(tally.ignored(nowMs: t0 + 4 * day).isEmpty)
        // The newest three are kept, in order, whatever order they arrive in.
        var late = IgnoreTally()
        for offset in [5, 1, 3, 9, 7] as [Int64] { late.note(event(rid: 9, at: t0 + offset, played: 1)) }
        #expect(late.rows[9]?.shorts == [t0 + 5, t0 + 7, t0 + 9])
        // The stored form round-trips.
        let row = IgnoreTally.Row(shorts: [1, 2, 3], longAtMs: 9)
        let numbers = BrainEventLog.decodeNumbers(ArraySlice(IgnoreTally.encode(row)))
        #expect(numbers.flatMap(IgnoreTally.decode) == row)
        #expect(late.expired(nowMs: t0 + 61 * day) == [9])
    }

    @Test func aPickThatNeverSoundedOrThatTheListenerDidNotEndIsNotAnIgnore() {
        var tally = IgnoreTally()
        // A load that failed three times, a pick cut by the app being closed, by a stop, or that played out short.
        for (i, end) in [EndReason.error, EndReason.error, EndReason.error, EndReason.killed, EndReason.stopped,
                         EndReason.trackDone, EndReason.unknown, EndReason.prev].enumerated() {
            #expect(tally.note(event(rid: 7, at: t0 + Int64(i), played: 4_000, end: end)) == nil)
        }
        // Skipped before it made a sound: nothing was heard, so nothing was rejected.
        #expect(tally.note(event(rid: 7, at: t0 + 20, played: 0)) == nil)
        #expect(tally.note(event(rid: 7, at: t0 + 21, played: 2_000, flags: EventFlags.neverAudible)) == nil)
        // A track the listener chose (no arm) and a play of unknown length never count.
        #expect(tally.note(event(rid: 7, at: t0 + 22, played: 1_000, arm: Arm.none)) == nil)
        #expect(tally.note(event(rid: 7, at: t0 + 23, played: -1)) == nil)
        #expect(tally.rows.isEmpty && tally.ignored(nowMs: t0 + 100).isEmpty)
        #expect(!IgnoreTally.isIgnore(event(rid: 0, at: t0, played: 1_000)))
        // A long play of music the engine never offered leaves no row behind.
        #expect(tally.note(event(rid: 8, at: t0, played: 90_000, arm: Arm.none, end: EndReason.trackDone)) == nil)
        #expect(IgnoreTally.counts(event(rid: 8, at: t0, played: 90_000, arm: Arm.none, end: EndReason.trackDone)))
        // One the engine served does.
        #expect(tally.note(event(rid: 8, at: t0, played: 90_000, end: EndReason.trackDone)) == IgnoreTally.Row(longAtMs: t0))
    }

    @Test func theEngineKeepsTheTallyAsPlaysAreRecordedAndAcrossARestart() async {
        let w = World()
        defer { w.cleanUp() }
        let pick = BrainItemTag(surface: "autoplay", surfaceId: "seed", recId: 5, slot: 0, arm: "RADIO")
        for _ in 0..<2 { await w.hear("Skip Me", by: "Nope", videoId: "skip", tag: pick, played: 2_000, end: EndReason.next) }
        #expect(await w.engine.ignoredRids(nowMs: w.clock.now).isEmpty, "twice is not three times")
        await w.hear("Skip Me", by: "Nope", videoId: "skip", tag: pick, played: 2_000, end: EndReason.next)
        await w.hear("Heard", by: "Yes", videoId: "heard", tag: pick)
        await w.hear("Own Skip", by: "Mine", videoId: "own", played: 2_000, end: EndReason.next)
        let skipped = await w.repository.resolveTrack(Ids.TrackKeys(videoId: "skip"), durationMs: 200_000)
        #expect(await w.engine.ignoredRids(nowMs: w.clock.now) == [skipped])
        // Another process reads the same answer from the files, without the events being read again.
        let clock = w.clock
        let second = BrainEngine(directory: w.directory, repository: w.repository, sources: nil, clock: { clock.now })
        #expect(await second.ignoredRids(nowMs: w.clock.now) == [skipped])
    }

    @Test func aLogWrittenBeforeTheTallyExistedIsFoldedInOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("brain-ignored-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = BrainEventLog(directory: directory)
        log.insert([event(rid: 7, at: t0 + 1, played: 1_000), event(rid: 7, at: t0 + 2, played: 1_000),
                    event(rid: 7, at: t0 + 3, played: 1_000), event(rid: 8, at: t0 + 4, played: 90_000),
                    event(rid: 9, at: t0 + 5, played: 1_000, arm: Arm.none)])
        // The listener's own play has no arm: it is skipped on its bytes, never decoded.
        #expect(log.engineServedEvents().map(\.rid).sorted() == [7, 7, 7, 8])
        #expect(log.value(BrainEventLog.keyIgnoreTally) == nil)
        #expect(log.loadIgnoreTally(nowMs: t0 + 10).ignored(nowMs: t0 + 10) == [7])
        #expect(log.value(BrainEventLog.keyIgnoreTally) != nil)
        // From then on the tally's own file answers.
        let reopened = BrainEventLog(directory: directory)
        let tally = reopened.loadIgnoreTally(nowMs: t0 + 10)
        #expect(tally.ignored(nowMs: t0 + 10) == [7] && tally.rows[8]?.longAtMs == t0 + 4)
        // Rows older than the window are dropped when the file is read.
        let later = BrainEventLog(directory: directory).loadIgnoreTally(nowMs: t0 + 61 * 24 * 60 * 60 * 1000)
        #expect(later.rows.isEmpty)
    }
}

@Suite("Queue snapshot reason fields")
struct QueueSnapshotReasonFieldsTests {
    private func item(_ id: String) -> PlaybackQueueItemSnapshot {
        PlaybackQueueItemSnapshot(mediaId: id, uri: "pixlstream://J7p4bzqLvCw", title: "Title \(id)", artist: "Artist")
    }

    @Test func aRestoredQueueStillSaysWhy() throws {
        let tag = BrainItemTag(surface: "autoplay", surfaceId: "seed", recId: 7, slot: 2, arm: "RADIO", whyArg: "d4vd",
                               radioRank: 4, retrQ: 812, whyKey: "radio_fans", primaryArtist: "Clovis Reyes")
        let restored = try JSONDecoder().decode(PlaybackQueueItemSnapshot.self,
                                                from: JSONEncoder().encode(item("engine").withBrainTag(tag)))
        #expect(restored.brainTag() == tag)
        #expect(restored.brainWhyKey == "radio_fans" && restored.brainWhyArg == "d4vd")
        #expect(restored.brainPrimaryArtist == "Clovis Reyes" && restored.brainRetrQ == 812 && restored.brainRadioRank == 4)
        #expect(restored.brainChosen == nil && restored.brainTag()?.isEngineOwned == true)
        // The field names are Android's: a queue it saved decodes here.
        let android = #"{"mediaId":"-3000123","uri":"spotify://0123456789abcdef012345","brainSurface":"autoplay","brainArm":"RADIO","brainWhyKey":"radio_fans","brainWhyArg":"d4vd","brainPrimaryArtist":"X","brainRetrQ":5,"brainRadioRank":2}"#
        let shared = try JSONDecoder().decode(PlaybackQueueItemSnapshot.self, from: Data(android.utf8))
        #expect(shared.brainTag()?.whyKey == "radio_fans" && shared.brainTag()?.radioRank == 2)
    }

    @Test func aHomeRowsCardComesBackAsTheListenersItem() throws {
        let card = BrainItemTag(surface: "homeShelf", surfaceId: "because_1f", recId: 5, slot: 0, arm: "RADIO",
                                whyArg: "Espresso", whyKey: "because_listened", chosen: true)
        let restored = try JSONDecoder().decode(PlaybackQueueItemSnapshot.self,
                                                from: JSONEncoder().encode(item("card").withBrainTag(card)))
        #expect(restored.brainChosen == true)
        #expect(restored.brainTag() == card && restored.brainTag()?.isEngineOwned == false)
        // A station's seed keeps the tag that makes the queue the station's.
        let station = Station.song(seedMediaId: "seed", title: "Ditto", primaryArtist: "NewJeans", nowMs: 1)
        let seed = try JSONDecoder().decode(PlaybackQueueItemSnapshot.self,
                                            from: JSONEncoder().encode(item("seed").withBrainTag(station.seedTag)))
        #expect(station.isSeed(mediaId: "seed", tag: seed.brainTag()))
        let encoded = String(decoding: try JSONEncoder().encode(item("seed").withBrainTag(station.seedTag)), as: UTF8.self)
        #expect(!encoded.contains("brainChosen") && !encoded.contains("brainWhyKey"), "\(encoded)")
    }
}
