import Foundation
import PixlFoundation
import PixlModel
import Testing
@testable import PixlLibrary

// Stage 2a, milestone 2 ("more ways in, more control"): the stations of 6.2, New releases of 6.3, the controls of 8.4
// and 8.5, the supporting facts of 8.8, repeat activation of 5.6 and the Spotify facts, against real record files in a
// temporary folder. The iOS twins of Android's `StationSourcesTest`, `BrainStations2aTest`, `NewReleasesTest`,
// `LearnExclusionTest`, `BrainFeedbackTest`, `ActivationFeaturesTest` and `BrainRefreshReleasesLaneTest`.

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64
    init(_ start: Int64) { value = start }
    var now: Int64 {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private let t0: Int64 = 1_760_000_000_000

private func makeDirectory(_ name: String) -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func radioRow(_ i: Int, _ artist: String, channel: String? = nil, title: String? = nil, seconds: Int = 200,
                       kind: MusicVideoKind = .atv) -> RadioRow {
    RadioRow(videoId: "vid" + String(repeating: "0", count: max(0, 7 - String(i).count)) + String(i),
             title: title ?? "Song \(i) of \(artist)",
             artists: [RadioArtistRef(name: artist, channelId: channel ?? "UC\(artist)")],
             durationSec: seconds, kind: kind)
}

// MARK: - A scripted source

private final class FakeSource: RadioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [String: ArtistPage] = [:]
    private var radios: [String: FetchedRadio] = [:]
    private var songRadios: [String: FetchedRadio] = [:]
    private var discographies: [String: [ReleaseRef]] = [:]
    private var tracks: [String: [RadioRow]] = [:]
    private var channels: [String: String] = [:]
    private var calls: [String] = []
    private var continuations: [String: FetchedRadio] = [:]

    func setContinuation(_ token: String, _ radio: FetchedRadio) { lock.lock(); continuations[token] = radio; lock.unlock() }

    func songRadioContinuation(token: String, pages: Int) async -> FetchedRadio? {
        note("continue:\(token):\(pages)")
        return locked { continuations[token] }
    }

    func setPage(_ id: String, _ page: ArtistPage) { lock.lock(); pages[id] = page; lock.unlock() }
    func setRadio(_ playlistId: String, _ radio: FetchedRadio) { lock.lock(); radios[playlistId] = radio; lock.unlock() }
    func setSongRadio(_ videoId: String, _ radio: FetchedRadio) { lock.lock(); songRadios[videoId] = radio; lock.unlock() }
    func setDiscography(_ id: String, _ list: [ReleaseRef]) { lock.lock(); discographies[id] = list; lock.unlock() }
    func setTracks(_ browseId: String, _ rows: [RadioRow]) { lock.lock(); tracks[browseId] = rows; lock.unlock() }
    func setChannel(_ name: String, _ id: String) { lock.lock(); channels[name] = id; lock.unlock() }
    var log: [String] { lock.lock(); defer { lock.unlock() }; return calls }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func note(_ s: String) { locked { calls.append(s) } }

    func songRadio(videoId: String, continuations: Int) async -> FetchedRadio? {
        note("song:\(videoId)")
        return locked { songRadios[videoId] }
    }
    func related(browseId: String) async -> RelatedPage? { note("related:\(browseId)"); return nil }
    func artistPage(channelId: String) async -> ArtistPage? {
        note("artist:\(channelId)")
        return locked { pages[channelId] }
    }
    func artistRadio(endpoint: RadioEndpoint) async -> FetchedRadio? {
        note("artistRadio:\(endpoint.playlistId)")
        return locked { radios[endpoint.playlistId] }
    }
    func discography(channelId: String) async -> [ReleaseRef]? {
        note("discography:\(channelId)")
        return locked { discographies[channelId] }
    }
    func releaseTracks(_ release: ReleaseRef) async -> [RadioRow]? {
        note("release:\(release.browseId)")
        return locked { tracks[release.browseId] }
    }
    func channelId(forArtist artistName: String) async -> String? {
        note("channel:\(artistName)")
        return locked { channels[artistName] }
    }
}

private func artistPage(_ name: String, tops: [RadioRow] = [], fans: [RadioArtistRef] = [], radio: RadioEndpoint? = nil,
                        albums: [ReleaseRef] = []) -> ArtistPage {
    ArtistPage(name: name, radio: radio, topSongs: tops, albums: albums, singles: [], fansAlsoLike: fans)
}

// MARK: - Stations (6.2)

@Suite("Brain stations from an album, a playlist, an artist with nothing in the library")
struct BrainStationSourcesTests {
    @Test func aSongStationKeepsItsOldIdAndAnAlbumStationHasItsOwn() {
        let song = Station.song(seedMediaId: "s1", title: "T", primaryArtist: "A", nowMs: t0)
        #expect(song.id == BrainSurfaces.hashedId("station|\(Session.seedStationSong)|s1"))
        #expect(song.source == Station.sourceSong && song.seedMediaIds == ["s1"])
        let artist = Station.artist(seedMediaId: "s1", artistName: "A", nowMs: t0)
        #expect(artist.source == Station.sourceArtist)
        let album = Station.fromSource(Station.sourceAlbum, seedMediaIds: ["s1", "s2", "s3"], title: "Album", nowMs: t0)
        let playlist = Station.fromSource(Station.sourcePlaylist, seedMediaIds: ["s1", "s2"], title: "List", nowMs: t0)
        #expect(album.id != song.id && album.id != playlist.id)
        #expect(album.seedMediaId == "s1" && album.kind == Session.seedStationSong && album.artistName.isEmpty)
        #expect(album.isSeed(mediaId: "s1", tag: album.seedTag))
    }

    @Test func aStationSavedBeforeTheSourcesExistedStillReads() {
        let old = ["3", "yt:abc", "A title", "An artist", "1760000000000"].joined(separator: "\u{1F}")
        let station = Station.decode(old)
        #expect(station?.seedMediaId == "yt:abc")
        #expect(station?.source == Station.sourceArtist)
        #expect(station?.seedMediaIds == ["yt:abc"])
        #expect(station?.id == Station.idOf(kind: Session.seedStationArtist, seedMediaId: "yt:abc"))
    }

    @Test func theNewFormRoundTripsWithItsSeedsAndSource() {
        let album = Station.fromSource(Station.sourceAlbum, seedMediaIds: ["a", "b", "c"], title: "Name", nowMs: t0)
        #expect(Station.decode(album.encode()) == album)
        let broken = album.encode().replacingOccurrences(of: "\u{1F}2\u{1F}", with: "\u{1F}9\u{1F}")
        #expect(Station.decode(broken) == nil)
        #expect(Station.decode("") == nil)
    }

    @Test func seedsAreTheMostPlayedThenTheFirstTwoPerArtist() {
        func song(_ id: String, _ artist: String) -> Song {
            testSong(id, artist: artist, artists: [ArtistRef(id: 1, name: artist, isPrimary: true)])
        }
        let songs = [song("a1", "A"), song("a2", "A"), song("a3", "A"), song("b1", "B"), song("c1", "C")]
        // Nothing played: the first, two per artist.
        #expect(StationSeeds.pick(songs: songs, plays: [:], max: 3).map(\.id) == ["a1", "a2", "b1"])
        // The most played lead, ties by the source's order; unplayed ones follow.
        let plays = ["c1": 5, "a3": 5, "b1": 1]
        #expect(StationSeeds.pick(songs: songs, plays: plays, max: 3).map(\.id) == ["a3", "c1", "b1"])
        #expect(StationSeeds.pick(songs: songs, plays: plays, max: 5).map(\.id) == ["a3", "c1", "b1", "a1"])
        #expect(StationSeeds.pick(songs: [], plays: [:], max: 3).isEmpty)
    }

    @Test func aLongStationIsReseededFromWhatItDidBestWithAtMostTwice() {
        let station = Station.fromSource(Station.sourcePlaylist, seedMediaIds: ["s1", "s2"], title: "L", nowMs: t0)
        func should(_ pool: Int, _ re: [String], _ best: String?, library: Bool = false) -> Bool {
            StationReseed.shouldReseed(poolFromLibrary: library, poolSize: pool, reseedIds: re, bestMediaId: best,
                                       seedMediaIds: station.seedMediaIds)
        }
        #expect(should(14, [], "x"))
        #expect(!should(15, [], "x"))
        #expect(!should(14, [], nil))
        #expect(!should(14, [], "s2"))
        #expect(!should(14, ["x"], "x"))
        #expect(should(14, ["x"], "y"))
        #expect(!should(14, ["x", "y"], "z"))
        #expect(!should(14, [], "x", library: true))
        #expect(StationReseed.seedIds(primary: "s1", station: station, reseedIds: ["x", "s1", "y"]) == ["s1", "s2", "x", "y"])
        #expect(StationReseed.isBest(finished: true, liked: false, mediaId: "x", station: station))
        #expect(!StationReseed.isBest(finished: true, liked: false, mediaId: "s1", station: station))
        #expect(!StationReseed.isBest(finished: false, liked: false, mediaId: "x", station: station))
    }

    private func entry(_ mediaId: String, rid: Int64) -> AutoplayPoolEntry {
        AutoplayPoolEntry(
            candidate: AutoplayPolicy.Candidate(mediaId: mediaId, rid: rid, artistKey: "a", albumKey: nil, durationMs: 200_000,
                                                versionFlags: 0, officialAudio: true, inLibrary: false, arm: Arm.radio,
                                                radioRank: 1),
            librarySong: nil, engineTrack: nil, whyArtist: "", brain: Candidate(rid: rid, aid: 1))
    }

    @Test func theFirstBatchOfAnAlbumStationLeavesOutTheAlbumsOwnSongsAndRefreshLeavesOutTheTail() {
        let station = Station.fromSource(Station.sourceAlbum, seedMediaIds: ["s1", "s2"], title: "Album", nowMs: t0)
        let pool = [entry("own1", rid: 1), entry("other", rid: 2), entry("own2", rid: 3)]
        func inputs(batches: Int, refreshing: Bool = false, tail: [AutoplayPoolEntry] = []) -> AutoplayPlanInputs {
            AutoplayPlanning.inputs(queue: [], tailStart: 0, tailEntries: tail, pool: pool, served: [:], recentlyPlayed: [],
                                    seeds: [], nowMs: t0, tzOffsetMin: 0, batch: 1, station: station, noveltyFactor: 1.0,
                                    stationBatches: batches, stationSourceIds: ["own1", "own2"], refreshing: refreshing,
                                    stationReseeded: false).inputs
        }
        #expect(inputs(batches: 0).excludedRids == [1, 3])
        #expect(inputs(batches: 1).excludedRids.isEmpty)
        // Several seeds: the closest of them counts.
        #expect(inputs(batches: 1).closestOfSeeds)
        // One seed and no re-seed: the first, as before; a re-seed makes it several.
        let single = Station.song(seedMediaId: "s", title: "T", primaryArtist: "A", nowMs: t0)
        let one = AutoplayPlanning.inputs(queue: [], tailStart: 0, tailEntries: [], pool: pool, served: [:], recentlyPlayed: [],
                                          seeds: [], nowMs: t0, tzOffsetMin: 0, batch: 1, station: single).inputs
        #expect(!one.closestOfSeeds)
        let reseeded = AutoplayPlanning.inputs(queue: [], tailStart: 0, tailEntries: [], pool: pool, served: [:],
                                               recentlyPlayed: [], seeds: [], nowMs: t0, tzOffsetMin: 0, batch: 1,
                                               station: single, stationReseeded: true).inputs
        #expect(reseeded.closestOfSeeds)
        // "Refresh picks": what the tail holds is not offered again, and the plan says it replaces all.
        let refreshed = inputs(batches: 1, refreshing: true, tail: [entry("t1", rid: 9)])
        #expect(refreshed.excludedRids.contains(9) && refreshed.replaceAll)
        #expect(!inputs(batches: 1).replaceAll)
    }
}

// MARK: - An artist with nothing in the library, similar artists, chips

@Suite("Brain artist station from YouTube, similar artists, chips")
struct BrainArtistStationTests {
    @Test func anArtistWithNothingInTheLibraryStartsFromTheArtistPagesOwnRadio() async throws {
        let dir = makeDirectory("artist-station")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = FakeSource()
        let clock = Clock(t0)
        let endpoint = RadioEndpoint(videoId: "vid0000001", playlistId: "RDEMx", params: "wAEB")
        source.setChannel("Zed", "UCZed")
        source.setPage("UCZed", artistPage("Zed", tops: (1...6).map { radioRow($0, "Zed", channel: "UCZed") }, radio: endpoint))
        source.setRadio("RDEMx", FetchedRadio(rows: [radioRow(1, "Zed", channel: "UCZed")]
                                              + (20..<60).map { radioRow($0, "Zed", channel: "UCZed") }))
        let repository = BrainRepository(directory: dir, radioSource: source, clock: { clock.now })
        let start = try #require(await repository.beginArtistStation(artistName: "Zed"))
        #expect(start.channelId == "UCZed")
        #expect(start.seedRow.videoId == "vid0000001")
        #expect(start.seedRid != 0)
        // Its list is stored under the seed, so the station's first pool is a cache hit.
        let cached = await repository.cachedArtistRadio(seedRid: start.seedRid)
        #expect(cached.count >= BrainRepository.minFallbackRows)
        // Nothing else was asked: one search, the page, the radio.
        #expect(source.log == ["channel:Zed", "artist:UCZed", "artistRadio:RDEMx"])
    }

    @Test func nothingFoundMeansNothingStartsAndAnEmptyNameIsNothing() async {
        let dir = makeDirectory("artist-station-none")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = FakeSource()
        let repository = BrainRepository(directory: dir, radioSource: source, clock: { t0 })
        #expect(await repository.beginArtistStation(artistName: "Nobody") == nil)
        #expect(await repository.beginArtistStation(artistName: "   ") == nil)
        #expect(source.log == ["channel:Nobody"])
    }

    @Test func similarArtistsTopSongsComeFromThreeOfTheFansAlsoLikeAndAreCachedForTwoWeeks() async throws {
        let dir = makeDirectory("similar")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = FakeSource()
        let clock = Clock(t0)
        let seedRow = radioRow(1, "Zed", channel: "UCZed")
        let fans = (1...5).map { RadioArtistRef(name: "Fan\($0)", channelId: "UCFan\($0)") }
        source.setPage("UCZed", artistPage("Zed", tops: [seedRow], fans: fans))
        for i in 1...5 {
            source.setPage("UCFan\(i)", artistPage("Fan\(i)", tops: (0..<4).map { radioRow(i * 10 + $0, "Fan\(i)") }))
        }
        // The channel is learned from the seed's song radio, which the source answers.
        source.setSongRadio(seedRow.videoId, FetchedRadio(rows: [seedRow] + (100..<145).map { i in
            i == 102 || i == 108 ? radioRow(i, "Zed", channel: "UCZed") : radioRow(i, "Other\(i % 9)")
        }, relatedBrowseId: "MPTRt_seed"))
        let repository = BrainRepository(directory: dir, radioSource: source, clock: { clock.now })
        let seed = RadioSeed(mediaId: "m", videoId: seedRow.videoId, title: seedRow.title, primaryArtist: "Zed",
                             durationMs: 200_000)
        // Without the network and with nothing cached: nothing.
        #expect(await repository.similarArtistSongs(seed: seed, allowNetwork: false).isEmpty)
        #expect(source.log.isEmpty)
        let rows = await repository.similarArtistSongs(seed: seed, allowNetwork: true)
        #expect(rows.count == 12)
        #expect(source.log.filter { $0.hasPrefix("artist:") } == ["artist:UCZed", "artist:UCFan1", "artist:UCFan2", "artist:UCFan3"])
        // A second ask is the cache: no request.
        let before = source.log.count
        #expect(await repository.similarArtistSongs(seed: seed, allowNetwork: true).count == 12)
        #expect(source.log.count == before)
    }

    @Test func deepeningAStationsRadioStartsFromTheStoredTokenAndDoesNotFetchPageOneAgain() async throws {
        let dir = makeDirectory("deepen")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = FakeSource()
        let seedRow = radioRow(1, "Zed", channel: "UCZed")
        let first = FetchedRadio(rows: [seedRow] + (100..<145).map { i in
            i == 102 || i == 108 ? radioRow(i, "Zed", channel: "UCZed") : radioRow(i, "Other\(i % 9)")
        }, relatedBrowseId: "MPTRt_seed", continuation: "TOKEN1")
        source.setSongRadio(seedRow.videoId, first)
        source.setContinuation("TOKEN1", FetchedRadio(rows: (200..<240).map { radioRow($0, "Other\($0 % 9)") }, requests: 2,
                                                      continuation: "TOKEN2"))
        let repository = BrainRepository(directory: dir, radioSource: source, clock: { t0 })
        let seed = RadioSeed(mediaId: "m", videoId: seedRow.videoId, title: seedRow.title, primaryArtist: "Zed", durationMs: 200_000)
        let page1 = try #require(await repository.radioFor(seed: seed, allowNetwork: true))
        #expect(page1.rows.count > 40)
        let deep = try #require(await repository.radioFor(seed: seed, allowNetwork: true, continuations: 2))
        #expect(deep.rows.count >= page1.rows.count + 35)
        #expect(deep.rows.contains { $0.row.videoId == "vid0000200" })
        #expect(Set(deep.rows.map(\.rid)).count == deep.rows.count)
        // One `next` for page one and one continuation call from the token; page one was not asked for twice.
        #expect(source.log.filter { $0.hasPrefix("song:") }.count == 1)
        #expect(source.log.contains("continue:TOKEN1:2"))
        // The deeper list keeps the next token; asked again it is the cache.
        let before = source.log.count
        #expect(try #require(await repository.radioFor(seed: seed, allowNetwork: true, continuations: 2)).rows.count == deep.rows.count)
        #expect(source.log.count == before)
        // A list stored by stage 1 has no token: the old path (page one again, with its continuations) still works.
        let old = RadioList(seedRid: 1, kind: RadioList.kindSong, chip: "", fetchedAt: t0, lastUsedAt: t0, healthy: true,
                            rows: [], chips: [])
        #expect(old.continuation == nil)
    }

    @Test func chipsOfARadioAreStoredAsTagsOnlyWhenTheyNameGenreDecadeOrMood() async throws {
        let dir = makeDirectory("chips")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = FakeSource()
        let seedRow = radioRow(1, "Zed", channel: "UCZed")
        let chips = ["Popular", "V-pop", "2010s", "Workout", "Some New Thing", "V-pop", "Deep cuts"]
            .map { RadioChip(label: $0, playlistId: "RDx\($0)") }
        source.setSongRadio(seedRow.videoId, FetchedRadio(rows: [seedRow] + (100..<145).map { i in
            i == 102 || i == 108 ? radioRow(i, "Zed", channel: "UCZed") : radioRow(i, "Other\(i % 9)")
        }, chips: chips, relatedBrowseId: "MPTRt_seed"))
        let repository = BrainRepository(directory: dir, radioSource: source, clock: { t0 })
        let seed = RadioSeed(mediaId: "m", videoId: seedRow.videoId, title: seedRow.title, primaryArtist: "Zed", durationMs: 200_000)
        let radio = try #require(await repository.radioFor(seed: seed, allowNetwork: true))
        let tags = await repository.chipTagsOf(seedRid: radio.seedRid)
        #expect(tags.map(\.kind) == [.genre, .decade, .mood])
        #expect(tags.map(\.key) == ["v pop", "2010s", "workout"])
        #expect(await repository.chipTagsOf(seedRid: 12345).isEmpty)
    }
}

// MARK: - New releases (6.3)

@Suite("Brain new releases")
struct BrainNewReleasesTests {
    private func release(_ id: String, _ title: String, year: Int = 2025) -> ReleaseRef {
        ReleaseRef(browseId: id, title: title, year: year, kind: .album, audioPlaylistId: "OLAK5uy_\(id)")
    }

    private func found(_ artist: String, _ rel: String, at ms: Int64, tracks: Int = 3, rid: Int64 = 100) -> FoundRelease {
        FoundRelease(channelId: "UC\(artist)", artistName: artist, browseId: rel, title: rel, year: 2025, kind: .album,
                     foundAtMs: ms,
                     rows: (0..<tracks).map { StoredRadioRow(row: radioRow(Int(rid) + $0, artist), rid: rid + Int64($0)) })
    }

    @Test func theFirstLookAtAnArtistIsABaselineAndSurfacesNothing() {
        let diff = NewReleaseRules.diff(known: nil, found: [release("MPREb_1", "One"), release("MPREb_2", "Two")],
                                        nowYear: 2025, nowMonth: 6)
        #expect(diff.baseline && diff.surfaced.isEmpty)
        #expect(diff.knownIds == ["MPREb_1", "MPREb_2"])
    }

    @Test func aNewIdOfThisYearIsNewsAReReleaseAndAWrongYearAreNot() {
        let known = ArtistReleaseState(channelId: "UCA", name: "A", knownIds: ["MPREb_1"],
                                       knownTitles: [NewReleaseRules.titleKey("One")])
        let found = [release("MPREb_9", "Fresh"), release("MPREb_8", "One (Deluxe)"), release("MPREb_7", "One"),
                     release("MPREb_6", "Old", year: 2019), release("MPREb_5", "Fresh"), release("MPREb_1", "One")]
        let diff = NewReleaseRules.diff(known: known, found: found, nowYear: 2025, nowMonth: 6)
        // "One (Deluxe)" and the second "One" are the old title again, the second "Fresh" repeats the first inside one
        // answer, and a 2019 release is not this year's.
        #expect(diff.surfaced.map(\.browseId) == ["MPREb_9"])
        #expect(!diff.baseline)
        // Every id seen is remembered, news or not, so it is judged once.
        #expect(Set(diff.knownIds) == ["MPREb_1", "MPREb_9", "MPREb_8", "MPREb_7", "MPREb_6", "MPREb_5"])
    }

    @Test func lastYearCountsOnlyInJanuary() {
        #expect(NewReleaseRules.isCurrentYear(2025, nowYear: 2026, nowMonth: 1))
        #expect(!NewReleaseRules.isCurrentYear(2025, nowYear: 2026, nowMonth: 2))
        #expect(NewReleaseRules.isCurrentYear(2026, nowYear: 2026, nowMonth: 12))
        #expect(!NewReleaseRules.isCurrentYear(2027, nowYear: 2026, nowMonth: 1))
    }

    @Test func theKnownIdsAreCapped() {
        let many = (0..<400).map { release("MPREb_\($0)", "Title \($0)") }
        let diff = NewReleaseRules.diff(known: nil, found: many, nowYear: 2025, nowMonth: 6)
        #expect(diff.knownIds.count == NewReleaseRules.maxKnownIds)
    }

    @Test func aCardIsOfficialAudioOfASaneLengthWithAnArtist() {
        #expect(NewReleaseRules.usable(radioRow(1, "A")))
        #expect(NewReleaseRules.usable(radioRow(1, "A", seconds: 0)))
        #expect(!NewReleaseRules.usable(radioRow(1, "A", seconds: 30)))
        #expect(!NewReleaseRules.usable(radioRow(1, "A", seconds: 1200)))
        #expect(!NewReleaseRules.usable(radioRow(1, "A", kind: .omv)))
        #expect(!NewReleaseRules.usable(RadioRow(videoId: "vidabcdefgh", title: "x", artists: [], durationSec: 200, kind: .atv)))
    }

    @Test func theRowTakesTwoPerArtistTwelveInAllAndOnlyFreshOnes() {
        let day: Int64 = 86_400_000
        let list = [found("A", "R1", at: t0, tracks: 5, rid: 100), found("A", "R2", at: t0 - day, tracks: 5, rid: 200),
                    found("B", "R3", at: t0 - 2 * day, tracks: 5, rid: 300), found("C", "R4", at: t0 - 40 * day, tracks: 5, rid: 400)]
        let cards = NewReleaseRules.cards(found: list, nowMs: t0)
        // A: R1 gives its first two (the artist's cap), R2 none; B: R3 two; C is older than 28 days.
        #expect(cards.map(\.stored.rid) == [100, 101, 300, 301])
        let many = (0..<10).map { found("X\($0)", "R\($0)", at: t0 - Int64($0), tracks: 3, rid: Int64(1000 + $0 * 10)) }
        #expect(NewReleaseRules.cards(found: many, nowMs: t0).count == 12)
        // A recording is in the row once.
        let twice = [found("A", "R1", at: t0, tracks: 2, rid: 100), found("B", "R2", at: t0 - 1, tracks: 2, rid: 100)]
        #expect(NewReleaseRules.cards(found: twice, nowMs: t0).map(\.stored.rid) == [100, 101])
    }

    @Test func theRowTagsCarryTheArmTheReasonAndTheSurface() {
        let track = EngineTrack(row: radioRow(1, "Zed"), rid: 5)
        let row = BrainReleaseRow(recId: BrainReleaseRow.recId(builtAtMs: t0),
                                  items: [BrainHomeItem(track: track, arm: Arm.new, slot: 0, retrQ: -1, radioRank: -1)],
                                  artistBySongId: [track.songId: "Zed"])
        let tag = row.tags()[track.songId]
        #expect(tag?.surface == Surface.nameOf(Surface.homeShelf))
        #expect(tag?.surfaceId == "brain_new_releases")
        #expect(tag?.arm == Arm.nameOf(Arm.new))
        #expect(tag?.whyKey == WhyLine.nameOf(WhyLine.newRelease))
        #expect(tag?.whyArg == "Zed" && tag?.chosen == true)
        #expect(row.recId & 0xff == 0xF2)
        #expect(row.cardReason(row.items[0]) == .newRelease("Zed"))
    }

    private func newReleases(_ dir: URL, _ source: FakeSource, clock: Clock) -> NewReleases {
        let repository = BrainRepository(directory: dir, radioSource: nil, clock: { clock.now })
        return NewReleases(store: AtomicReleaseFileStore(directory: dir), source: source, repository: repository,
                           clock: { clock.now }, yearAndMonth: { _ in (2025, 6) })
    }

    @Test func aCheckFindsABaselineThenAReleaseAndAnUnreadableOneIsTriedAgain() async {
        let dir = makeDirectory("new-releases")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = FakeSource()
        let clock = Clock(t0)
        let releases = newReleases(dir, source, clock: clock)
        source.setPage("UCA", artistPage("A", albums: [release("MPREb_1", "One")]))
        // The first look: a baseline, one request.
        #expect(await releases.check(channelId: "UCA", artistName: "A") == .network)
        #expect(source.log == ["artist:UCA"])
        #expect(await releases.requestsSince(0) == 1)
        // Asked again at once: nothing to do.
        #expect(await releases.isFresh("UCA"))
        #expect(await releases.check(channelId: "UCA", artistName: "A") == .cached)
        // A day later a new release is on the page, but its tracks cannot be read yet: not remembered, tried again.
        clock.now = t0 + 25 * 3_600_000
        source.setPage("UCA", artistPage("A", albums: [release("MPREb_2", "Two"), release("MPREb_1", "One")]))
        #expect(await releases.check(channelId: "UCA", artistName: "A") == .network)
        clock.now = t0 + 50 * 3_600_000
        source.setTracks("MPREb_2", (1...4).map { radioRow(500 + $0, "A") })
        #expect(await releases.check(channelId: "UCA", artistName: "A") == .network)
        #expect(source.log.filter { $0 == "release:MPREb_2" }.count == 2)
        // Fewer than six cards is no row.
        #expect(await releases.row(blocked: .empty, adjustments: .empty) == nil)
    }

    @Test func aFullCarouselReadsTheWholeDiscographyAndSixCardsMakeARow() async throws {
        let dir = makeDirectory("new-releases-row")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = FakeSource()
        let clock = Clock(t0)
        let releases = newReleases(dir, source, clock: clock)
        let ten = (1...10).map { release("MPREb_\($0)", "Title \($0)") }
        source.setPage("UCA", artistPage("A", albums: ten))
        source.setDiscography("UCA", ten + [release("MPREb_old", "Older", year: 2010)])
        #expect(await releases.check(channelId: "UCA", artistName: "A") == .network)
        #expect(source.log == ["artist:UCA", "discography:UCA"])
        // Three artists with a new release each, two cards each: a row.
        let names = ["B", "C", "D"]
        for name in names {
            source.setPage("UC\(name)", artistPage(name, albums: [release("MPREb_\(name)1", "Old \(name)")]))
            #expect(await releases.check(channelId: "UC\(name)", artistName: name) == .network)
        }
        clock.now = t0 + 25 * 3_600_000
        for (n, name) in names.enumerated() {
            source.setPage("UC\(name)", artistPage(name, albums: [release("MPREb_\(name)2", "New \(name)"),
                                                                  release("MPREb_\(name)1", "Old \(name)")]))
            source.setTracks("MPREb_\(name)2", (1...3).map { radioRow(700 + n * 10 + $0, name) })
            #expect(await releases.check(channelId: "UC\(name)", artistName: name) == .network)
        }
        let row = try #require(await releases.row(blocked: .empty, adjustments: .empty))
        #expect(row.items.count == 6)
        #expect(Set(row.artistBySongId.values) == Set(names))
        #expect(row.items.allSatisfy { $0.arm == Arm.new })
        // The order of checks: the one never checked first, then the longest ago.
        let order = await releases.checkOrder(["B", "A", "Never", "C"])
        #expect(order.first == "Never")
        #expect(await releases.channelOf("B") == "UCB")
    }

    @Test func aPageThatDoesNotLoadSendsTheArtistToTheBackOfTheOrder() async {
        let dir = makeDirectory("new-releases-miss")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = FakeSource()
        let clock = Clock(t0)
        let releases = newReleases(dir, source, clock: clock)
        // "Bad" has no page; "Good" was never looked at. Never-checked artists go first, so "Bad" would lead at every run.
        #expect(await releases.check(channelId: "UCBad", artistName: "Bad") == .none)
        let order = await releases.checkOrder(["Bad", "Good"])
        #expect(order == ["Good", "Bad"], "the one that failed is looked at after the ones never looked at")
        // An artist whose channel could not be found is a miss too, and a miss is not a channel.
        await releases.noteMiss(artistName: "Various Artists")
        #expect(await releases.checkOrder(["Various Artists", "Fresh"]) == ["Fresh", "Various Artists"])
        #expect(await releases.channelOf("Various Artists") == nil)
        // The lookup of a channel is a request of the day.
        let before = await releases.requestsSince(0)
        await releases.noteRequests(2)
        #expect(await releases.requestsSince(0) == before + 2)
    }

    @Test func aCheckNeverSpendsMoreThanItWasGiven() async {
        let dir = makeDirectory("new-releases-cap")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = FakeSource()
        let clock = Clock(t0)
        let releases = newReleases(dir, source, clock: clock)
        let ten = (1...10).map { release("MPREb_\($0)", "Title \($0)") }
        source.setPage("UCA", artistPage("A", albums: ten))
        source.setDiscography("UCA", ten)
        #expect(await releases.check(channelId: "UCA", artistName: "A") == .network)
        // A day later a new release: the page, the discography and the release's tracks would be three requests. Given two,
        // the tracks are not asked for, and the release stays "not seen" for the next check.
        clock.now = t0 + 25 * 3_600_000
        let fresh = release("MPREb_new", "New One")
        source.setPage("UCA", artistPage("A", albums: [fresh] + ten.dropLast()))
        source.setDiscography("UCA", [fresh] + ten)
        source.setTracks("MPREb_new", (1...4).map { radioRow(900 + $0, "A") })
        #expect(await releases.check(channelId: "UCA", artistName: "A", maxRequests: 2) == .network)
        #expect(await releases.requestsSince(clock.now) == 2, "the page and the discography, nothing more")
        #expect(!source.log.contains("release:MPREb_new"))
        // With room, the next check reads it.
        clock.now = t0 + 50 * 3_600_000
        #expect(await releases.check(channelId: "UCA", artistName: "A") == .network)
        #expect(source.log.contains("release:MPREb_new"))
    }
}


// MARK: - Feedback and the engine

private struct Harness {
    let directory: URL
    let clock: Clock
    let repository: BrainRepository
    let engine: BrainEngine

    init(sources: BrainEngine.Sources? = nil) {
        directory = makeDirectory("brain-m2")
        let clock = Clock(t0)
        self.clock = clock
        repository = BrainRepository(directory: directory, radioSource: nil, clock: { clock.now })
        engine = BrainEngine(directory: directory, repository: repository, sources: sources, clock: { clock.now })
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    func play(_ id: String, _ title: String, _ artist: String, at ms: Int64, played: Int64 = 200_000,
              end: Int32 = EndReason.trackDone) async {
        let context = PlayContext(title: title, artistDisplay: artist, artists: [artist], spotifyId: nil, videoId: "v" + id,
                                  inLibrary: false, startReason: StartReason.tap, tag: nil)
        _ = await engine.record(FinishedPlay(songId: "yt:v" + id, context: context, startedAtMs: ms, playedMs: played,
                                             durationMs: 200_000, endReason: end, flags: 0, tzOffsetMin: 0))
    }
}

@Suite("Brain feedback: Don't count this, Private session, a swipe, supporting facts, repeat activation")
struct BrainFeedbackActionsTests {
    @Test func dontCountTakesTheFinishedPlaysOutOfTheTablesAtOnceAndUndoCountsThemAgain() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        for i in 0..<3 { await h.play("1", "Song", "Zed", at: t0 + Int64(i) * 300_000) }
        await h.play("2", "Other", "Zed", at: t0 + 2_000_000)
        let events = await h.engine.events()
        let rid = try #require(events.first?.rid)
        let aid = try #require(events.first?.primaryAid)
        let before = await h.engine.readAffinity { $0.counter(Family.track, rid)?.posQ ?? 0 }
        let artistBefore = await h.engine.readAffinity { $0.counter(Family.artist, aid)?.posQ ?? 0 }
        #expect(before > 0)
        let excluded = try #require(await h.engine.excludeRecordings(rids: [rid], targetKind: FeedbackKinds.targetSong, targetId: rid))
        #expect(excluded.count == 3)
        let after = await h.engine.readAffinity { $0.counter(Family.track, rid)?.posQ ?? 0 }
        let artistAfter = await h.engine.readAffinity { $0.counter(Family.artist, aid)?.posQ ?? 0 }
        #expect(after < before)
        #expect(artistAfter < artistBefore)
        // The plays stay in the log, flagged; the other song's play is untouched.
        let flagged = await h.engine.events().filter { $0.has(EventFlags.learnExcluded) }
        #expect(flagged.count == 3 && flagged.allSatisfy { $0.rid == rid })
        #expect(await h.engine.eventCount() == 4)
        // A `feedback` row records it.
        #expect(await h.engine.activeFeedback().map(\.kind) == [FeedbackKinds.dontCount])
        // Once flagged they are not excluded twice.
        #expect(await h.engine.excludeRecordings(rids: [rid], targetKind: FeedbackKinds.targetSong, targetId: rid) == nil)
        // Undo: the flags go and the row is undone.
        await h.engine.undoExclusion(excluded)
        #expect(await h.engine.events().allSatisfy { !$0.has(EventFlags.learnExcluded) })
        #expect(await h.engine.activeFeedback().isEmpty)
    }

    @Test func theLastHourLeavesOutOnlyWhatStartedInIt() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let hour: Int64 = 3_600_000
        await h.play("1", "Old", "Zed", at: t0 - 3 * hour)
        await h.play("2", "Recent", "Zed", at: t0 - 20 * 60_000)
        let excluded = try #require(await h.engine.excludeLastHour())
        #expect(excluded.count == 1)
        let events = await h.engine.events()
        #expect(events.filter { $0.has(EventFlags.learnExcluded) }.count == 1)
        #expect(events.first { $0.has(EventFlags.learnExcluded) }?.startedAtMs == t0 - 20 * 60_000)
        #expect(await h.engine.excludeLastHour() == nil)
    }

    @Test func aPlayDuringAPrivateSessionIsLoggedAsExcludedAndOneAfterItIsNot() async {
        let h = Harness()
        defer { h.cleanUp() }
        #expect(await !h.engine.isPrivate)
        await h.engine.setPrivate(true)
        #expect(await h.engine.isPrivate)
        await h.play("1", "During", "Zed", at: t0 + 1_000)
        h.clock.now = t0 + 10_000
        await h.engine.setPrivate(false)
        await h.play("2", "After", "Zed", at: t0 + 60_000)
        let events = await h.engine.events()
        #expect(events.count == 2)
        #expect(events[0].has(EventFlags.learnExcluded))
        #expect(!events[1].has(EventFlags.learnExcluded))
        // Each switch is a `feedback` row, closed when the session ends.
        #expect(await h.engine.feedbackCount() == 1)
        #expect(await h.engine.activeFeedback().isEmpty)
        // The excluded play added nothing to the tables.
        let rid = events[0].rid
        #expect(await h.engine.readAffinity { $0.counter(Family.track, rid) } == nil)
    }

    @Test func privateSpansOverlapOnTheirEdgesAndOldOnesFallAway() {
        var spans = PrivateSpans()
        #expect(!spans.isActive && !spans.overlaps(startMs: 0, endMs: 1_000_000))
        spans.open(at: 1_000)
        #expect(spans.isActive)
        spans.open(at: 2_000) // already open
        spans.close(at: 5_000)
        #expect(!spans.isActive)
        #expect(spans.overlaps(startMs: 500, endMs: 1_000))
        #expect(spans.overlaps(startMs: 5_000, endMs: 6_000))
        #expect(!spans.overlaps(startMs: 5_001, endMs: 6_000))
        #expect(!spans.overlaps(startMs: 0, endMs: 999))
        for i in 0..<40 {
            spans.open(at: Int64(10_000 + i * 100))
            spans.close(at: Int64(10_050 + i * 100))
        }
        #expect(!spans.overlaps(startMs: 1_000, endMs: 1_500))
        #expect(PrivateSpans() == PrivateSpans())
    }

    @Test func aSwipeIsAWeakNegativeForTheSessionAndNothingElse() async {
        let h = Harness()
        defer { h.cleanUp() }
        // Nothing is loaded for a swipe.
        await h.engine.weakNegative(rid: 5, aid: 6)
        #expect(await !h.engine.isLoaded)
        await h.play("1", "Song", "Zed", at: t0)
        let before = await h.engine.sessionSnapshot()
        await h.engine.weakNegative(rid: 5, aid: 6)
        let after = await h.engine.sessionSnapshot()
        #expect(after.negCount == before.negCount + 1)
        #expect(after.recentNeg[0] == 5 && after.recentNegAid[0] == 6 && after.recentNegH[0] == Session.swipeH)
        #expect(after.skipRun == before.skipRun)
        #expect(await h.engine.eventCount() == 1)
    }

    @Test func theFactsUnderAReasonAreCountedFromTheListenersOwnPlays() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        for i in 0..<4 {
            await h.play("\(i)", "Song \(i)", "Zed", at: t0 + Int64(i) * 300_000, played: i == 3 ? 3_000 : 200_000,
                         end: i == 3 ? EndReason.next : EndReason.trackDone)
        }
        let e = try #require(await h.engine.events().first)
        let facts = await h.engine.whyFacts(rid: e.rid, aid: e.primaryAid, year: 2024)
        #expect(facts == [WhyFacts.Fact(key: WhyFacts.keyArtistFinished, a: 3, b: 4),
                          WhyFacts.Fact(key: WhyFacts.keyYear, a: 2024, b: 0)])
        // Another artist has no plays: no rate.
        #expect(await h.engine.whyFacts(rid: e.rid, aid: 999, year: 0).isEmpty)
    }

    @Test func theWhyFactsInputsSkipWhatDidNotSoundOrWasLeftOut() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        await h.play("1", "A", "Zed", at: t0)
        let base = try #require(await h.engine.events().first)
        func event(_ id: Int64, at: Int64, played: Int32, end: Int32, flags: Int32 = 0, origin: Int32 = Origin.live) -> PlayEvent {
            var e = base
            e.eventId = id
            e.startedAtMs = at
            e.playedMs = played
            e.endReason = end
            e.flags = flags
            e.origin = origin
            e.primaryAid = 7
            return e
        }
        let events = [event(1, at: 1_000, played: 200_000, end: EndReason.trackDone),
                      event(2, at: 2_000, played: 170_000, end: EndReason.next),
                      event(3, at: 3_000, played: 10_000, end: EndReason.next),
                      event(4, at: 4_000, played: 0, end: EndReason.next, flags: EventFlags.neverAudible),
                      event(5, at: 5_000, played: 200_000, end: EndReason.trackDone, flags: EventFlags.learnExcluded),
                      event(6, at: 6_000, played: 200_000, end: EndReason.trackDone, origin: Origin.importSpotify)]
        let stats = WhyFactsInputs.artistStats(events: events, aid: 7)
        #expect(stats.plays == 3 && stats.finished == 2)
        #expect(WhyFactsInputs.artistStats(events: events, aid: 7, limit: 2).plays == 2)
    }

    @Test func repeatActivationReadsTheLastThreeMonthsAndSkipsWhatDoesNotCount() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        await h.play("1", "Hot", "Zed", at: t0 - 3_600_000)
        await h.play("1", "Hot", "Zed", at: t0 - 1_800_000)
        await h.play("2", "Cold", "Zed", at: t0 - 80 * 86_400_000)
        let events = await h.engine.events()
        let hot = try #require(events.first { $0.startedAtMs == t0 - 1_800_000 }).rid
        let cold = try #require(events.first { $0.startedAtMs == t0 - 80 * 86_400_000 }).rid
        let activation = await h.engine.activation(rids: [hot, cold, 12345], nowMs: t0)
        let heat = try #require(activation[hot])
        #expect(heat > 0.3 && heat <= 1.0)
        // Long ago reads lower than just now; a recording never played has no entry.
        #expect((activation[cold] ?? 0) < heat)
        #expect(activation[12345] == nil)
        // A play left out of the picks does not count.
        let excluded = events.map { e -> PlayEvent in
            var copy = e
            copy.flags |= EventFlags.learnExcluded
            return copy
        }
        #expect(ActivationFeatures.compute(events: excluded, nowMs: t0).isEmpty)
    }

    @Test func theEventLogDecodesOffTheActorAndSortsByEventId() async {
        let h = Harness()
        defer { h.cleanUp() }
        for i in 0..<5 { await h.play("\(i)", "S\(i)", "Zed", at: t0 + Int64(i) * 300_000) }
        let log = BrainEventLog(directory: h.directory)
        let events = BrainEventLog.decodeSorted(log.allEventPayloads())
        #expect(events.count == 5)
        #expect(events.map(\.eventId) == events.map(\.eventId).sorted())
        #expect(BrainEventLog.decodeSorted(log.eventPayloads(startedSince: t0 + 600_000)).count == 3)
        #expect(BrainEventLog.decodeSorted([[0x7B], Array("not json".utf8)]).isEmpty)
    }

    // MARK: Review fixes (stage 2a, iOS)

    @Test func aPrivatePlayIsNeitherAHomeAnchorNorASeedNorAnIgnoreButAnOrdinaryOneIs() async {
        let h = Harness()
        defer { h.cleanUp() }
        await h.engine.setPrivate(true)
        await h.play("1", "Private song", "Zed", at: t0 + 1_000)
        h.clock.now = t0 + 400_000
        await h.engine.setPrivate(false)
        await h.play("2", "Ordinary song", "Zed", at: t0 + 600_000)
        let events = await h.engine.events()
        #expect(events.count == 2 && events[0].has(EventFlags.learnExcluded) && !events[1].has(EventFlags.learnExcluded))
        // Home anchors: only the ordinary play.
        let anchors = await h.engine.homeAnchors()
        #expect(anchors.map(\.title) == ["Ordinary song"])
        // The refresh's seeds: only the ordinary play, in both groups.
        let recent = SeedQueries.recentChosen(events, sinceMs: 0, limit: 10)
        #expect(recent.map(\.rid) == [events[1].rid])
        var liked = events
        for i in liked.indices { liked[i].flags |= EventFlags.likedDuring }
        #expect(SeedQueries.recentlySaved(liked, sinceMs: 0, limit: 10).map(\.rid) == [events[1].rid])
        // The ignore tally of 6.1: a flagged play counts for neither an ignore nor a clearing play.
        var skipped = events[0]
        skipped.arm = Arm.radio
        skipped.playedMs = 5_000
        skipped.endReason = EndReason.next
        #expect(IgnoreTally.counts(skipped) == false)
        skipped.flags &= ~EventFlags.learnExcluded
        #expect(IgnoreTally.counts(skipped) == true)
    }

    @Test func aPlayCutOffWhilePrivateIsSavedAsLeftOut() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let context = PlayContext(title: "Song", artistDisplay: "Zed", artists: ["Zed"], spotifyId: nil, videoId: "v1",
                                  inLibrary: false, startReason: StartReason.tap, tag: nil)
        let open = FinishedPlay(songId: "yt:v1", context: context, startedAtMs: t0, playedMs: 60_000, durationMs: 200_000,
                                endReason: EndReason.killed, flags: 0, tzOffsetMin: 0)
        await h.engine.setOpenPlay(open)
        var saved = try #require(await h.engine.storedValue(BrainEventLog.keyOpenPlay))
        #expect(try #require(OpenPlayCodec.decode(saved)).flags & EventFlags.learnExcluded == 0)
        await h.engine.setPrivate(true)
        await h.engine.setOpenPlay(open)
        saved = try #require(await h.engine.storedValue(BrainEventLog.keyOpenPlay))
        #expect(try #require(OpenPlayCodec.decode(saved)).flags & EventFlags.learnExcluded != 0)
    }

    @Test func anOpenPlayTakesAFlagBack() {
        let context = PlayContext(title: "Song", artistDisplay: "Zed", artists: ["Zed"], spotifyId: nil, videoId: "v1",
                                  inLibrary: false, startReason: StartReason.tap, tag: nil)
        var play = OpenPlay(songId: "yt:v1", context: context, startedAtEpochMs: t0, tzOffsetMin: 0, durationMs: 200_000,
                            isPlaying: true, realtimeMs: 0)
        play.mark(EventFlags.learnExcluded | EventFlags.likedDuring)
        play.unmark(EventFlags.learnExcluded)
        #expect(play.flags & EventFlags.learnExcluded == 0 && play.flags & EventFlags.likedDuring != 0)
    }

    private func dreams() -> (song: Song, imported: [ImportedPlay]) {
        let song = testSong("a", title: "Dreams", artist: "Fleetwood Mac", duration: 257_000, spotifyId: "4uLU6hMCjMI75M1A2tKUQC")
        let imported = (0..<3).map { i in
            ImportedPlay(source: .spotifyExport, timestampMs: t0 - Int64(10 - i) * 86_400_000, title: "Dreams", artist: "Fleetwood Mac",
                         spotifyTrackId: "4uLU6hMCjMI75M1A2tKUQC", msPlayed: 200_000, reasonEnd: "trackdone")
        }
        return (song, imported)
    }

    @Test func dontCountReachesTheImportedPlaysOfASongAndUndoBringsThemBack() async throws {
        let (song, imported) = dreams()
        let sources = BrainEngine.Sources(library: { [song] }, history: { [] }, importSignature: { "3|x" },
                                          imported: { (imported, ExternalTasteSnapshot()) }, adjustments: { [] })
        let h = Harness(sources: sources)
        defer { h.cleanUp() }
        // The state loads and the first rebuild reads the import.
        _ = await h.engine.heardTrackCount()
        await h.engine.awaitRebuild()
        let keys = try #require(TrackCatalog.facts(of: song)).keys
        let rid = await h.repository.resolveTracks([TrackRequest(keys: keys, durationMs: 257_000)])[0]
        #expect(await h.engine.readAffinity { $0.completions[rid] } == 3)
        // There is no stored play at all: only the import. The old code answered "nothing to leave out" here.
        let count = await h.engine.importedPlayCount(keys: keys)
        #expect(count == 3)
        let excluded = try #require(await h.engine.excludeRecordings(rids: [rid], targetKind: FeedbackKinds.targetSong,
                                                                     targetId: rid, importedPlays: count))
        #expect(excluded.count == 3 && excluded.eventIds.isEmpty)
        await h.engine.awaitRebuild()
        #expect(await h.engine.readAffinity { $0.completions[rid] } == nil, "the rebuild left the imported plays out")
        // Undo: the plays count again, from the rebuild that follows.
        await h.engine.undoExclusion(excluded)
        await h.engine.awaitRebuild()
        #expect(await h.engine.readAffinity { $0.completions[rid] } == 3)
    }

    @Test func nothingStoredNothingImportedAndNothingInFlightLeavesNothingToExclude() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        await h.play("1", "Song", "Zed", at: t0)
        let rid = try #require(await h.engine.events().first?.rid)
        let first = try #require(await h.engine.excludeRecordings(rids: [rid], targetKind: FeedbackKinds.targetSong, targetId: rid))
        #expect(first.count == 1)
        // Already flagged: no row, no rebuild.
        let rows = await h.engine.feedbackCount()
        #expect(await h.engine.excludeRecordings(rids: [rid], targetKind: FeedbackKinds.targetSong, targetId: rid) == nil)
        #expect(await h.engine.feedbackCount() == rows)
        // A play in flight alone is enough for a row (and an Undo), and asks for no rebuild.
        let inFlight = try #require(await h.engine.excludeRecordings(rids: [rid], targetKind: FeedbackKinds.targetSong, targetId: rid,
                                                                     flaggedSongId: "yt:v1"))
        #expect(inFlight.count == 1 && inFlight.flaggedSongId == "yt:v1" && inFlight.eventIds.isEmpty)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
        func bump() { lock.lock(); stored += 1; lock.unlock() }
    }

    @Test func aForcedRebuildAskedForWhileAnotherRunsIsNotDropped() async throws {
        let (song, imported) = dreams()
        let signatures = Counter()
        let slow = Counter()
        let sources = BrainEngine.Sources(
            library: { [song] }, history: { [] },
            importSignature: {
                signatures.bump()
                // The first run is slow to start, so the request below lands while it is in flight.
                if slow.value == 0 {
                    slow.bump()
                    try? await Task.sleep(for: .milliseconds(400))
                }
                return "3|x"
            },
            imported: { (imported, ExternalTasteSnapshot()) }, adjustments: { [] })
        let h = Harness(sources: sources)
        defer { h.cleanUp() }
        _ = await h.engine.heardTrackCount()
        for _ in 0..<100 where signatures.value == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(signatures.value == 1)
        await h.engine.requestRebuild(force: true)
        await h.engine.awaitRebuild()
        #expect(signatures.value == 2, "the forced request ran after the first rebuild instead of being dropped")
    }
}


// MARK: - The controls' decisions

@Suite("Brain feedback decisions")
struct BrainFeedbackDecisionTests {
    private let song = testSong("s1", title: "Title", artist: "Zed", artists: [ArtistRef(id: 1, name: "Zed", isPrimary: true)])

    @Test func moreLikeThisIsAFourteenDayBoostOnTheArtist() throws {
        let change = try #require(BrainFeedback.moreLikeChange(for: song))
        #expect(change.action == .boost && change.targetType == .artist && change.label == "Zed")
        #expect(change.expiresDays == 14 && change.source == .user)
        #expect(change.reason == "More like this")
        #expect(BrainFeedback.moreLikeChange(for: testSong("x", artist: "Unknown Artist")) == nil)
    }

    @Test func aSecondLessFromIsRecognisedFromTheActiveChanges() throws {
        let reduce = TasteAdjustment(kind: .reduce, strength: 2, targetType: .artist, key: TasteKey.of("Zed"), label: "Zed",
                                     reason: "x", source: .user, createdMs: t0)
        let boost = TasteAdjustment(kind: .boost, strength: 2, targetType: .artist, key: TasteKey.of("Zed"), label: "Zed",
                                    reason: "x", source: .user, createdMs: t0)
        #expect(BrainFeedback.isReduced(artistName: "Zed", in: [reduce]))
        #expect(BrainFeedback.isReduced(artistName: "zed", in: [reduce]))
        #expect(!BrainFeedback.isReduced(artistName: "Zed", in: [boost]))
        #expect(!BrainFeedback.isReduced(artistName: "Other", in: [reduce]))
        #expect(!BrainFeedback.isReduced(artistName: "", in: [reduce]))
        let mute = try #require(BrainFeedback.muteArtistChange(artistName: "Zed"))
        #expect(mute.action == .mute && mute.targetType == .artist && mute.expiresDays == nil)
        #expect(BrainFeedback.muteArtistChange(artistName: " ") == nil)
    }

    @Test func theBarOffersMuteAfterALessFromAndASecondOneAndUndoOnlyWhenThereIsSomethingToUndo() {
        let less = BrainNotice(serial: 1, kind: .lessFrom, adjustmentId: "id", artistName: "Zed")
        #expect(less.canMute && less.canUndo)
        let again = BrainNotice.alreadyReduced(serial: 2, artistName: "Zed")
        #expect(again.canMute && !again.canUndo)
        #expect(!BrainNotice(serial: 3, kind: .notForMe, adjustmentId: "id", artistName: "Zed").canMute)
        #expect(!BrainNotice(serial: 4, kind: .lessFrom, adjustmentId: "id", artistName: "").canMute)
        let counted = BrainNotice.afterDontCount(serial: 5, excluded: ExcludedPlays(feedbackId: 1, eventIds: [1, 2]))
        #expect(counted.kind == .dontCount && counted.canUndo && !counted.canMute)
        let nothing = BrainNotice.afterDontCount(serial: 6, excluded: nil)
        #expect(nothing.kind == .dontCountNothing && !nothing.canUndo)
        #expect(BrainNotice.afterMoreLike(serial: 7, outcome: nil, artistName: "Zed").kind == .notSaved)
    }

    @Test func theNewReasonLinesNeedANameAndAreKeyedLikeTheOthers() {
        #expect(WhyLineText.line(key: WhyLine.similarArtist, arg: "Zed") == .similarArtist("Zed"))
        #expect(WhyLineText.line(key: WhyLine.newRelease, arg: "Zed") == .newRelease("Zed"))
        #expect(WhyLineText.line(key: WhyLine.similarArtist, arg: " ") == nil)
        #expect(WhyLineText.line(keyName: "new_release", arg: "Zed") == .newRelease("Zed"))
    }

    @Test func theSpotifyFactsAreKeptInBatchesDroppedWhenTheSwitchIsOffAndClearedOnRequest() throws {
        let dir = makeDirectory("spotify-facts")
        defer { try? FileManager.default.removeItem(at: dir) }
        let on = Box(true)
        let store = SpotifyFactStore(directory: dir, enabled: { on.value }, clock: { t0 })
        store.record(SpotifyFactInput(spotifyId: "abc", isrc: "US1", artistIds: ["a1", "a2"], albumId: "alb",
                                      releaseDate: "2024-05-01", releasePrecision: "day", explicit: true))
        store.record(SpotifyFactInput(spotifyId: " ", artistIds: []))
        store.record(SpotifyFactInput(spotifyId: "abc", artistIds: ["a1"]))
        store.drain()
        #expect(store.count == 1)
        let row = try #require(store.get(["abc"]).first)
        #expect(row.artistIds == ["a2", "a1"] || row.artistIds == ["a1"] || row.artistIds == ["a1", "a2"])
        #expect(row.v == 1 && row.seenAtMs == t0)
        // Read back after a restart.
        let again = SpotifyFactStore(directory: dir, enabled: { true }, clock: { t0 })
        #expect(again.count == 1)
        // Switched off: what was queued is dropped, not kept.
        on.value = false
        store.record(SpotifyFactInput(spotifyId: "zzz"))
        store.drain()
        #expect(again.get(["zzz"]).isEmpty)
        store.clear()
        let cleared = SpotifyFactStore(directory: dir, enabled: { true }, clock: { t0 })
        #expect(cleared.count == 0)
    }
}

// MARK: - The releases lane of the refresh (3.7 lane 2, 6.3)

@Suite("Brain refresh, the releases lane")
struct BrainRefreshReleasesLaneTests {
    private final class Work: RefreshWork, @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String] = []
        var askedList: [String] { lock.withLock { asked } }

        private func note(_ s: String) { lock.withLock { asked.append(s) } }

        func radioSeeds() async -> [RefreshTarget] { [target("r1")] }
        func artistSeeds() async -> [RefreshTarget] { [target("a1")] }
        func requestsLeft() async -> Int { 100 }
        func radio(_ target: RefreshTarget) async -> RefreshFetch { note("radio"); return .network }
        func artist(_ target: RefreshTarget) async -> RefreshFetch { note("artist"); return .network }
        func releaseTargets() async -> [RefreshTarget] { [target("x1"), target("x2"), target("x3")] }
        func releases(_ target: RefreshTarget) async -> RefreshFetch {
            note("releases:\(target.artistName)")
            return target.artistName == "x2" ? .cached : (target.artistName == "x3" ? .none : .network)
        }

        private func target(_ name: String) -> RefreshTarget {
            RefreshTarget(seed: RadioSeed(mediaId: name, videoId: "v" + name, title: name, primaryArtist: name, durationMs: 1),
                          rid: 1, artistName: name)
        }
    }

    @Test func releasesGoAfterTheRadiosAndBeforeTheArtistListsAndAreCounted() async {
        let work = Work()
        let report = await BrainRefreshRunner(work: work, allowed: { true }, playing: { false }).run()
        #expect(work.askedList == ["radio", "releases:x1", "releases:x2", "releases:x3", "artist"])
        #expect(report.releasesFetched == 1 && report.releasesCached == 1 && report.missed == 1)
        #expect(report.fetched == 3)
        #expect(RefreshSchedule.note(nowMs: 5, report).contains("|n1+1|m1|"))
    }

    @Test func aWorkWithoutAReleasesLaneRunsAsBefore() async {
        struct Plain: RefreshWork {
            func radioSeeds() async -> [RefreshTarget] { [] }
            func artistSeeds() async -> [RefreshTarget] { [] }
            func requestsLeft() async -> Int { 5 }
            func radio(_ target: RefreshTarget) async -> RefreshFetch { .none }
            func artist(_ target: RefreshTarget) async -> RefreshFetch { .none }
        }
        let report = await BrainRefreshRunner(work: Plain(), allowed: { true }, playing: { false }).run()
        #expect(report.releasesFetched == 0 && report.releasesCached == 0 && report.stopped == .none)
    }

    @Test func theSwitchStopsTheLaneAtOnce() async {
        let flag = Box(true)
        let work = Work()
        let runner = BrainRefreshRunner(work: work, allowed: { flag.value }, playing: { false })
        flag.value = false
        let report = await runner.run()
        #expect(report.stopped == .off && work.askedList.isEmpty)
    }
}
