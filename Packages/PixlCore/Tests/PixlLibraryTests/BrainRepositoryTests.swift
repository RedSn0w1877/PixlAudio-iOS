import Foundation
import PixlFoundation
import PixlModel
import Testing
@testable import PixlLibrary

/// A scripted `RadioSource` that records what it was asked.
private final class FakeRadioSource: RadioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var songRadios: [String: FetchedRadio] = [:]
    private var relatedPages: [String: RelatedPage] = [:]
    private var artistPages: [String: ArtistPage] = [:]
    private var artistRadios: [String: FetchedRadio] = [:]
    private var recorded: [String] = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var calls: [String] { locked { recorded } }
    func clearCalls() { locked { recorded.removeAll() } }
    func setSongRadio(_ videoId: String, _ radio: FetchedRadio?) { locked { songRadios[videoId] = radio } }
    func setRelated(_ browseId: String, _ page: RelatedPage) { locked { relatedPages[browseId] = page } }
    func setArtistPage(_ channelId: String, _ page: ArtistPage) { locked { artistPages[channelId] = page } }
    func setArtistRadio(_ playlistId: String, _ radio: FetchedRadio) { locked { artistRadios[playlistId] = radio } }

    func songRadio(videoId: String, continuations: Int) async -> FetchedRadio? {
        locked {
            recorded.append("song:\(videoId):\(continuations)")
            return songRadios[videoId]
        }
    }

    func related(browseId: String) async -> RelatedPage? {
        locked {
            recorded.append("related:\(browseId)")
            return relatedPages[browseId]
        }
    }

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

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 1_000_000_000_000
    var now: Int64 {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

private func row(_ i: Int, _ artist: String, channel: String?? = nil, title: String? = nil, seconds: Int = 200,
                 kind: MusicVideoKind = .atv) -> RadioRow {
    let channelId: String? = channel ?? "UC\(artist)"
    return RadioRow(videoId: "vid" + String(repeating: "0", count: max(0, 7 - String(i).count)) + String(i),
                    title: title ?? "Song \(i)", artists: [RadioArtistRef(name: artist, channelId: channelId)],
                    durationSec: seconds, kind: kind)
}

/// 45 rows after the seed, the seed's artist again at rows 3 and 9: a healthy radio.
private func healthyRadio(_ seed: RadioRow) -> FetchedRadio {
    FetchedRadio(rows: [seed] + (0..<45).map { i in
        i == 2 || i == 8 ? row(100 + i, seed.artists[0].name, channel: seed.artists[0].channelId) : row(100 + i, "Other\(i % 9)")
    }, relatedBrowseId: "MPTRt_seed")
}

private func seedOf(_ row: RadioRow, spotifyId: String? = "4uLU6hMCjMI75M1A2tKUQC") -> RadioSeed {
    RadioSeed(mediaId: "sp:seed", videoId: row.videoId, title: row.title, primaryArtist: row.artists[0].name,
              durationMs: Int64(row.durationSec) * 1000, spotifyId: spotifyId)
}

/// The radio cache: what is fetched, what is stored, and the junk fallbacks (docs/brain-spec.md, 3.3). Port of
/// Android's `BrainRepositoryTest`, over the real record files in a temporary folder.
@Suite("Brain repository")
struct BrainRepositoryTests {
    private let source = FakeRadioSource()
    private let clock = TestClock()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("brain-repo-\(UUID().uuidString)", isDirectory: true)

    private func makeRepository() -> BrainRepository {
        let clock = self.clock
        return BrainRepository(directory: directory, radioSource: source, clock: { clock.now })
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    /// The rows of a real radio, from the file the Android and iOS parser tests both check their parsers against.
    private func fixtureRadio() throws -> FetchedRadio {
        let url = try #require(Bundle.module.url(forResource: "radio_song.expected", withExtension: "json",
                                                 subdirectory: "Fixtures/brain"))
        let root = try JSONParser().parse(try String(contentsOf: url, encoding: .utf8))
        let rows = (root["rows"]?.arrayValue ?? []).map { item in
            RadioRow(videoId: item["videoId"]?.stringValue ?? "", title: item["title"]?.stringValue ?? "",
                     artists: (item["artists"]?.arrayValue ?? []).map {
                         RadioArtistRef(name: $0["name"]?.stringValue ?? "", channelId: $0["id"]?.stringValue)
                     },
                     album: item["album"]?.stringValue, albumBrowseId: item["albumId"]?.stringValue,
                     year: Int(item["year"]?.int64Value ?? 0), durationSec: Int(item["durationSec"]?.int64Value ?? 0),
                     thumbnailUrl: item["thumb"]?.stringValue, explicit: item["explicit"]?.boolValue ?? false,
                     kind: MusicVideoKind(rawValue: item["type"]?.stringValue ?? "") ?? .unknown)
        }
        return FetchedRadio(rows: rows, relatedBrowseId: root["relatedBrowseId"]?.stringValue)
    }

    @Test func aRealRadioIsStoredWithoutItsSeedAndThenServedFromTheCache() async throws {
        defer { cleanUp() }
        let repository = makeRepository()
        let fetched = try fixtureRadio()
        let seedRow = try #require(fetched.rows.first)
        source.setSongRadio(seedRow.videoId, fetched)

        let first = try #require(await repository.radioFor(seed: seedOf(seedRow), allowNetwork: true))
        #expect(!first.fromCache)
        #expect(first.kind == RadioList.kindSong)
        #expect(first.rows.count == 49)
        #expect(!first.rows.contains { $0.row.videoId == seedRow.videoId })
        #expect(first.rows.allSatisfy { $0.rid != 0 })
        #expect(Set(first.rows.map(\.rid)).count == first.rows.count, "one row per recording")
        #expect(first.rows.map(\.row.videoId) == fetched.rows.dropFirst().map(\.videoId), "radio order is kept")
        #expect(source.calls == ["song:\(seedRow.videoId):0"])

        let second = try #require(await repository.radioFor(seed: seedOf(seedRow), allowNetwork: true))
        #expect(second.fromCache)
        #expect(first.rows == second.rows)
        #expect(source.calls.count == 1, "no second request")

        // After a restart the list is still there, and the rows come back as they were stored.
        let restarted = makeRepository()
        let third = try #require(await restarted.radioFor(seed: seedOf(seedRow), allowNetwork: false))
        #expect(third.fromCache && third.rows == first.rows && third.seedRid == first.seedRid)
    }

    @Test func theSeedIsOneRecordingWhetherAskedByItsSpotifyIdOrMetAsARadioRow() async throws {
        defer { cleanUp() }
        let repository = makeRepository()
        let seed = row(1, "Adele", title: "Hello")
        source.setSongRadio(seed.videoId, healthyRadio(seed))
        let radio = try #require(await repository.radioFor(seed: seedOf(seed), allowNetwork: true))
        // The same recording under another audio id, in someone else's radio, is the same rid.
        let viaName = await repository.resolveTrack(
            Ids.TrackKeys(videoId: "otherAudioId", nameKey: Ids.nameKey(primaryArtist: "ADELE", rawTitle: "Hello (Remastered)")),
            durationMs: 200_500)
        #expect(radio.seedRid == viaName)
    }

    @Test func twoRowsThatAreOneRecordingUnderTwoAudioIdsAreStoredOnce() async throws {
        defer { cleanUp() }
        let repository = makeRepository()
        let seed = row(1, "Seed")
        var healthy = healthyRadio(seed)
        var duplicate = healthy.rows[5]
        duplicate.videoId = "anotherAudio"
        healthy.rows.append(duplicate)
        source.setSongRadio(seed.videoId, healthy)
        let radio = try #require(await repository.radioFor(seed: seedOf(seed), allowNetwork: true))
        #expect(radio.rows.count == 45)
        #expect(!radio.rows.contains { $0.row.videoId == "anotherAudio" })
    }

    @Test func offlineAnswersFromTheCacheOnlyHoweverOld() async throws {
        defer { cleanUp() }
        let repository = makeRepository()
        let seed = row(1, "Seed")
        #expect(await repository.radioFor(seed: seedOf(seed), allowNetwork: false) == nil)
        #expect(source.calls.isEmpty)
        source.setSongRadio(seed.videoId, healthyRadio(seed))
        _ = await repository.radioFor(seed: seedOf(seed), allowNetwork: true)
        source.clearCalls()
        clock.now += 90 * 24 * 60 * 60 * 1000 // far past the two-week freshness
        let stale = try #require(await repository.radioFor(seed: seedOf(seed), allowNetwork: false))
        #expect(stale.fromCache)
        #expect(source.calls.isEmpty)
    }

    @Test func anAnswerWithNoRadioInItIsNothingLearnedTheStoredListStaysAndTheSeedIsNotMarkedJunk() async throws {
        defer { cleanUp() }
        let repository = makeRepository()
        let seed = row(1, "Adele", title: "Hello")
        source.setSongRadio(seed.videoId, healthyRadio(seed))
        let good = try #require(await repository.radioFor(seed: seedOf(seed), allowNetwork: true))
        // Two weeks on the list is stale, and upstream answers with a valid page that holds no rows.
        clock.now += BrainRepository.cacheTtlMs + 1
        source.setSongRadio(seed.videoId, FetchedRadio(rows: [], relatedBrowseId: nil))
        let stale = try #require(await repository.radioFor(seed: seedOf(seed), allowNetwork: true))
        #expect(stale.fromCache)
        #expect(stale.rows == good.rows, "the stored list was not overwritten")
        // The seed is left alone for a while, not hammered ...
        let calls = source.calls.count
        _ = await repository.radioFor(seed: seedOf(seed), allowNetwork: true)
        #expect(source.calls.count == calls)
        // ... and asked again long before a junk seed's day is over.
        clock.now += BrainRepository.emptyAnswerRetryMs + 1
        source.setSongRadio(seed.videoId, healthyRadio(seed))
        let fresh = try #require(await repository.radioFor(seed: seedOf(seed), allowNetwork: true))
        #expect(!fresh.fromCache)
    }

    @Test func anEmptyAnswerForASeedWithNothingStoredIsNotRememberedAsJunk() async throws {
        defer { cleanUp() }
        let repository = makeRepository()
        let seed = row(1, "Adele", title: "Hello")
        source.setSongRadio(seed.videoId, FetchedRadio(rows: [], relatedBrowseId: nil))
        #expect(await repository.radioFor(seed: seedOf(seed), allowNetwork: true) == nil)
        // Half an hour later a real answer is taken; a junk mark would have kept the seed out for a day.
        clock.now += BrainRepository.emptyAnswerRetryMs + 1
        source.setSongRadio(seed.videoId, healthyRadio(seed))
        #expect(await repository.radioFor(seed: seedOf(seed), allowNetwork: true) != nil)
    }

    @Test func aStaleListIsRefetchedWhenTheNetworkIsAllowed() async throws {
        defer { cleanUp() }
        let repository = makeRepository()
        let seed = row(1, "Seed")
        source.setSongRadio(seed.videoId, healthyRadio(seed))
        _ = await repository.radioFor(seed: seedOf(seed), allowNetwork: true)
        clock.now += BrainRepository.cacheTtlMs + 1
        let again = try #require(await repository.radioFor(seed: seedOf(seed), allowNetwork: true))
        #expect(!again.fromCache)
        #expect(source.calls.count == 2)
    }

    @Test func aTransportFailureStoresNothingAndIsNotRememberedAsJunk() async throws {
        defer { cleanUp() }
        let repository = makeRepository()
        let seed = row(1, "Seed")
        #expect(await repository.radioFor(seed: seedOf(seed), allowNetwork: true) == nil)
        #expect(await repository.radioListCount() == 0)
        // The next attempt asks again.
        source.setSongRadio(seed.videoId, healthyRadio(seed))
        #expect(await repository.radioFor(seed: seedOf(seed), allowNetwork: true) != nil)
    }

    @Test func aJunkRadioFallsBackToTheRelatedTabMinusOtherPerformances() async throws {
        defer { cleanUp() }
        let repository = makeRepository()
        let seed = row(1, "Seed")
        source.setSongRadio(seed.videoId, FetchedRadio(rows: [seed] + (0..<20).map { row(200 + $0, "Stranger\($0)") },
                                                      relatedBrowseId: "MPTRt_seed"))
        let alsoLike = (0..<20).map { row(300 + $0, "Related\($0)", seconds: 0) }
        source.setRelated("MPTRt_seed", RelatedPage(youMightAlsoLike: alsoLike, otherPerformances: [alsoLike[0], alsoLike[1]],
                                                    similarArtists: []))
        let radio = try #require(await repository.radioFor(seed: seedOf(seed), allowNetwork: true))
        #expect(radio.kind == RadioList.kindRelated)
        #expect(radio.rows.count == 18)
        #expect(source.calls == ["song:\(seed.videoId):0", "related:MPTRt_seed"])
        // The junk marker keeps the seed from being asked again for a day; the fallback list answers.
        source.clearCalls()
        let again = try #require(await repository.radioFor(seed: seedOf(seed), allowNetwork: true))
        #expect(again.fromCache && again.kind == RadioList.kindRelated)
        #expect(source.calls.isEmpty)
    }

    @Test func aRadioOfMusicVideosTakesTheJunkPathToTheRelatedTab() async throws {
        defer { cleanUp() }
        let repository = makeRepository()
        var seed = row(1, "Seed")
        seed.kind = .omv
        // Long enough and full of the seed's artist, but every row is a music video.
        var videos = healthyRadio(seed)
        videos.rows = videos.rows.map { var copy = $0; copy.kind = .omv; return copy }
        source.setSongRadio(seed.videoId, videos)
        source.setRelated("MPTRt_seed", RelatedPage(youMightAlsoLike: (0..<20).map { row(300 + $0, "Related\($0)", seconds: 0) },
                                                    otherPerformances: [], similarArtists: []))
        let radio = try #require(await repository.radioFor(seed: seedOf(seed), allowNetwork: true))
        #expect(radio.kind == RadioList.kindRelated)
        #expect(radio.rows.allSatisfy { $0.row.isOfficialAudio })
    }

    @Test func anEmptyRadioIsJunkTooRememberedAndTheRelatedTabIsTried() async throws {
        defer { cleanUp() }
        let repository = makeRepository()
        let seed = row(1, "Seed")
        source.setSongRadio(seed.videoId, FetchedRadio(rows: [], relatedBrowseId: "MPTRt_seed"))
        source.setRelated("MPTRt_seed", RelatedPage(youMightAlsoLike: (0..<12).map { row(300 + $0, "Related\($0)", seconds: 0) },
                                                    otherPerformances: [], similarArtists: []))
        let radio = try #require(await repository.radioFor(seed: seedOf(seed), allowNetwork: true))
        #expect(radio.kind == RadioList.kindRelated)
        #expect(radio.rows.count == 12)
        // The empty radio left its marker: the seed is not asked again.
        source.clearCalls()
        #expect(await repository.radioFor(seed: seedOf(seed), allowNetwork: true)?.fromCache == true)
        #expect(source.calls.isEmpty)
    }

    @Test func junkWithNoRelatedTabFallsBackToTheArtistRadio() async throws {
        defer { cleanUp() }
        let repository = makeRepository()
        let seed = row(1, "Seed", channel: "UCseedArtist")
        source.setSongRadio(seed.videoId, FetchedRadio(rows: [seed] + (0..<10).map { row(200 + $0, "Stranger\($0)") }))
        source.setArtistPage("UCseedArtist", ArtistPage(name: "Seed",
                                                        radio: RadioEndpoint(videoId: "vidRadio", playlistId: "RDEMseed", params: "wAEB"),
                                                        topSongs: [], albums: [], singles: [], fansAlsoLike: []))
        source.setArtistRadio("RDEMseed", FetchedRadio(rows: (0..<46).map { i in
            i % 5 == 0 ? row(400 + i, "Seed", channel: "UCseedArtist") : row(400 + i, "Near\(i % 6)")
        }))
        let radio = try #require(await repository.radioFor(seed: seedOf(seed), allowNetwork: true))
        #expect(radio.kind == RadioList.kindArtist)
        #expect(source.calls == ["song:\(seed.videoId):0", "artist:UCseedArtist", "artistRadio:RDEMseed"])
        #expect(radio.rows.count >= 40)
    }

    @Test func junkWithNoFallbackGivesNothingAndIsNotAskedAgainForADay() async throws {
        defer { cleanUp() }
        let repository = makeRepository()
        let seed = row(1, "Seed", channel: .some(nil))
        source.setSongRadio(seed.videoId, FetchedRadio(rows: [seed] + (0..<10).map { row(200 + $0, "Stranger\($0)") }))
        #expect(await repository.radioFor(seed: seedOf(seed), allowNetwork: true) == nil)
        source.clearCalls()
        #expect(await repository.radioFor(seed: seedOf(seed), allowNetwork: true) == nil)
        #expect(source.calls.isEmpty, "junk is remembered")
        clock.now += BrainRepository.junkRetryMs + 1
        _ = await repository.radioFor(seed: seedOf(seed), allowNetwork: true)
        #expect(source.calls.count == 1)
    }

    @Test func noMoreThanSixtyRadiosAreFetchedInADay() async throws {
        defer { cleanUp() }
        let repository = makeRepository()
        for i in 0..<HostBudget.dailyLimit {
            let seed = row(1000 + i, "Artist\(i)", title: "Title \(i)")
            source.setSongRadio(seed.videoId, healthyRadio(seed))
            #expect(await repository.radioFor(seed: seedOf(seed, spotifyId: nil), allowNetwork: true) != nil, "seed \(i)")
        }
        let extra = row(5000, "Extra", title: "One too many")
        source.setSongRadio(extra.videoId, healthyRadio(extra))
        source.clearCalls()
        #expect(await repository.radioFor(seed: seedOf(extra, spotifyId: nil), allowNetwork: true) == nil)
        #expect(source.calls.isEmpty)
        // A day later the budget is back.
        clock.now += HostBudget.dayMs + 1
        #expect(await repository.radioFor(seed: seedOf(extra, spotifyId: nil), allowNetwork: true) != nil)
    }

    @Test func aDeeperRequestIsFetchedOnceAndThenCachedBesideTheFirstPageList() async throws {
        defer { cleanUp() }
        let repository = makeRepository()
        let seed = row(1, "Seed")
        source.setSongRadio(seed.videoId, healthyRadio(seed))
        _ = await repository.radioFor(seed: seedOf(seed), allowNetwork: true)
        #expect(await repository.radioFor(seed: seedOf(seed), allowNetwork: true, continuations: 2) != nil)
        #expect(source.calls == ["song:\(seed.videoId):0", "song:\(seed.videoId):2"])
        #expect(await repository.radioFor(seed: seedOf(seed), allowNetwork: true, continuations: 2)?.fromCache == true)
        #expect(source.calls.count == 2)
        #expect(await repository.radioListCount() == 2)
        // Offline, a first-page list still answers a request for more.
        let other = row(2, "Other", title: "Else")
        source.setSongRadio(other.videoId, healthyRadio(other))
        _ = await repository.radioFor(seed: seedOf(other, spotifyId: nil), allowNetwork: true)
        #expect(await repository.radioFor(seed: seedOf(other, spotifyId: nil), allowNetwork: false, continuations: 2) != nil)
    }

    @Test func twoCallersForOneSeedShareOneRequest() async throws {
        defer { cleanUp() }
        let repository = makeRepository()
        let seed = row(1, "Seed")
        source.setSongRadio(seed.videoId, healthyRadio(seed))
        async let first = repository.radioFor(seed: seedOf(seed), allowNetwork: true)
        async let second = repository.radioFor(seed: seedOf(seed), allowNetwork: true)
        let results = await [first, second]
        #expect(results.allSatisfy { $0 != nil })
        #expect(source.calls.count == 1)
    }

    @Test func anEngineTrackIsKeptForRecentlyPlayedAndForSaving() async throws {
        defer { cleanUp() }
        let repository = makeRepository()
        let track = EngineTrack(row: row(7, "Someone", title: "Outside"), rid: 77)
        await repository.registerPlayable([track], nowMs: 5)
        #expect(await repository.engineTrack(songId: track.songId) == track)
        #expect(await repository.engineTrack(songId: "sp:library") == nil)
        let restarted = makeRepository()
        #expect(await restarted.engineTracks() == [track])
        #expect(await restarted.prunePlayable(keepSongIds: [], nowMs: 5 + BrainTables.playableRetentionMs + 1) == 1)
        #expect(await restarted.playableCount() == 0)
    }
}

/// The pool Autoplay picks from: radio order, library tracks where the listener has the recording, the filters of
/// 6.1, and the library-only pool.
@Suite("Autoplay pool")
struct AutoplayPoolTests {
    private let source = FakeRadioSource()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("brain-pool-\(UUID().uuidString)", isDirectory: true)

    private func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    private func librarySong(_ id: String, _ title: String, _ artist: String, album: String = "Album", durationMs: Int64 = 200_000) -> Song {
        Song(id: id, title: title, artist: artist, artistId: 1, artists: [ArtistRef(id: 1, name: artist, isPrimary: true)],
             album: album, albumId: 1, path: "", contentUriString: "spotify://x", albumArtUriString: nil, duration: durationMs,
             mimeType: nil, bitrate: nil, sampleRate: nil, spotifyId: String(id.dropFirst(3)))
    }

    @Test func thePoolIsTheAnchorsRadioInRadioOrderWithLibraryTracksPlayedFromTheLibrary() async throws {
        defer { cleanUp() }
        let repository = BrainRepository(directory: directory, radioSource: source, clock: { 1_000 })
        let seedRow = row(1, "Seed", title: "Anchor")
        var radio = healthyRadio(seedRow)
        radio.rows[1].title = "Owned Song"           // the listener has this one
        radio.rows[2].title = "Night Out (Karaoke)"   // never
        radio.rows[3].title = "Night Out (Live)"      // only when a seed is live
        radio.rows[4].durationSec = 30                // too short
        radio.rows[5].kind = .omv                     // a music video
        source.setSongRadio(seedRow.videoId, radio)

        let anchorSong = librarySong("sp:anchor", "Anchor", "Seed")
        let owned = librarySong("sp:owned", "Owned Song", radio.rows[1].artists[0].name)
        let blockedName = radio.rows[6].artists[0].name
        let request = AutoplayPoolRequest(
            anchors: [AutoplayAnchor(song: anchorSong, videoId: seedRow.videoId, spotifyId: "anchor")],
            deepen: false, allowNetwork: true, library: [anchorSong, owned], everPlayed: ["sp:owned"],
            blocked: BlockedArtistMatcher(entries: [BlockedArtist(artistId: 0, name: blockedName)]))
        let pool = await AutoplayPool.build(request, index: BrainLibraryIndex(songs: request.library), repository: repository)

        #expect(!pool.fromLibrary)
        let ids = pool.entries.map(\.candidate.mediaId)
        #expect(ids.first == "sp:owned", "the best row is a library track and plays from the library")
        #expect(pool.entries.first?.librarySong == owned && pool.entries.first?.engineTrack == nil)
        #expect(pool.entries.first?.candidate.arm == Arm.fav)
        for dropped in [radio.rows[2], radio.rows[3], radio.rows[4], radio.rows[5]] {
            #expect(!ids.contains("yt:\(dropped.videoId)"), "\(dropped.title)")
        }
        #expect(!pool.entries.contains { $0.engineTrack?.artists.first?.name == blockedName }, "a blocked artist never gets in")
        let outside = pool.entries.dropFirst()
        #expect(!outside.isEmpty && outside.allSatisfy { $0.engineTrack != nil && $0.librarySong == nil })
        #expect(outside.allSatisfy { $0.candidate.arm == Arm.radio && $0.whyArtist == "Seed" })
        // Radio order: the ranks only ever go up.
        let ranks = pool.entries.map(\.candidate.radioRank)
        #expect(ranks == ranks.sorted())
        #expect(!ids.contains("sp:anchor") && !ids.contains("yt:\(seedRow.videoId)"), "the seed is not a candidate")
    }

    @Test func offlineWithNothingCachedThePoolIsTheLibraryTheAnchorsArtistFirst() async throws {
        defer { cleanUp() }
        let repository = BrainRepository(directory: directory, radioSource: source, clock: { 1_000 })
        let anchor = librarySong("sp:anchor", "Anchor", "Seed")
        let sameArtist = [librarySong("sp:s1", "One", "Seed"), librarySong("sp:s2", "Two", "SEED"), librarySong("sp:s3", "Three", "Seed")]
        let picks = [librarySong("sp:p1", "Pick", "Else"), sameArtist[0], librarySong("sp:short", "Short", "Else", durationMs: 20_000)]
        let muted = librarySong("sp:blocked", "Muted", "Seed")
        let library = [anchor] + sameArtist + picks + [muted]
        let request = AutoplayPoolRequest(
            anchors: [AutoplayAnchor(song: anchor, videoId: "vid0000001", spotifyId: "anchor")], deepen: false,
            allowNetwork: false, library: library, everPlayed: ["sp:s1"],
            blocked: .empty, adjustments: .empty, libraryPicks: { picks })
        let pool = await AutoplayPool.build(request, index: BrainLibraryIndex(songs: library), repository: repository)
        #expect(pool.fromLibrary)
        #expect(source.calls.isEmpty, "offline never asks the network")
        let ids = pool.entries.map(\.candidate.mediaId)
        #expect(Set(ids.prefix(4)) == ["sp:s1", "sp:s2", "sp:s3", "sp:blocked"], "the anchor's artist first")
        #expect(ids.count == 5 && ids.last == "sp:p1", "then the ranking's picks, once each, without the short one")
        #expect(!ids.contains("sp:anchor"))
        #expect(pool.entries.allSatisfy { $0.candidate.rid == 0 && $0.candidate.inLibrary && $0.engineTrack == nil })
        #expect(pool.entries.first { $0.candidate.mediaId == "sp:s1" }?.candidate.arm == Arm.fav)
        #expect(pool.entries.first { $0.candidate.mediaId == "sp:s2" }?.candidate.arm == Arm.deep)
        // The order is fixed for a set of anchors.
        let again = await AutoplayPool.build(request, index: BrainLibraryIndex(songs: library), repository: nil)
        #expect(again.entries.map(\.candidate.mediaId) == ids)
    }

    @Test func withNoNetworkOnlyLibraryTracksWithACopyOnThePhoneAreQueuedAndCachedRadiosAreNotRead() async throws {
        defer { cleanUp() }
        let repository = BrainRepository(directory: directory, radioSource: source, clock: { 1_000 })
        let seedRow = row(1, "Seed", title: "Anchor")
        source.setSongRadio(seedRow.videoId, healthyRadio(seedRow))
        let anchor = librarySong("sp:anchor", "Anchor", "Seed")
        let library = [anchor, librarySong("sp:s1", "One", "Seed"), librarySong("sp:s2", "Two", "Seed"),
                       librarySong("sp:p1", "Pick", "Else")]
        let seeds = [AutoplayAnchor(song: anchor, videoId: seedRow.videoId, spotifyId: "anchor")]
        // Online first: the radio is fetched and cached, and the pool holds music from outside the library.
        let online = AutoplayPoolRequest(anchors: seeds, deepen: false, allowNetwork: true, library: library, everPlayed: [])
        let radioPool = await AutoplayPool.build(online, index: BrainLibraryIndex(songs: library), repository: repository)
        #expect(!radioPool.fromLibrary && !radioPool.offline && !radioPool.fellBack)
        #expect(radioPool.entries.contains { $0.engineTrack != nil })
        source.clearCalls()

        // Airplane mode. The cached radio would name tracks that need the network to play: it is not read.
        var offline = AutoplayPoolRequest(anchors: seeds, deepen: false, allowNetwork: false, library: library, everPlayed: [],
                                          libraryPicks: { [library[3]] })
        offline.offline = true
        offline.offlinePlayable = { songs in
            // Asked about the pool's own songs only, never the whole library or the anchor.
            Set(songs.map(\.id)).intersection(["sp:s2", "sp:p1", "sp:anchor"])
        }
        let pool = await AutoplayPool.build(offline, index: BrainLibraryIndex(songs: library), repository: repository)
        #expect(pool.fromLibrary && pool.offline && !pool.fellBack)
        #expect(source.calls.isEmpty)
        #expect(pool.entries.allSatisfy { $0.engineTrack == nil && $0.librarySong != nil })
        #expect(pool.entries.map(\.candidate.mediaId) == ["sp:s2", "sp:p1"], "only what plays from the phone, never the anchor")

        // Nothing on the phone: nothing is queued, and the queue ends as it always did.
        offline.offlinePlayable = { _ in [] }
        let none = await AutoplayPool.build(offline, index: BrainLibraryIndex(songs: library), repository: repository)
        #expect(none.entries.isEmpty && none.fromLibrary && none.offline)

        // The YouTube source switched off but online: the library alone, and its streamed tracks may play.
        let sourceOff = AutoplayPoolRequest(anchors: seeds, deepen: false, allowNetwork: false, library: library, everPlayed: [],
                                            libraryPicks: { [library[3]] })
        let off = await AutoplayPool.build(sourceOff, index: BrainLibraryIndex(songs: library), repository: repository)
        #expect(off.fromLibrary && !off.offline)
        #expect(Set(off.entries.map(\.candidate.mediaId)) == ["sp:s1", "sp:s2", "sp:p1"])
        #expect(source.calls.isEmpty)
    }

    @Test func onlyTheNewestAnchorMayCostARequestTheOlderOnesAnswerFromTheCache() async throws {
        defer { cleanUp() }
        let repository = BrainRepository(directory: directory, radioSource: source, clock: { 1_000 })
        let rows = [row(1, "First", title: "Newest"), row(2, "Second", title: "Older"), row(3, "Third", title: "Oldest")]
        for seedRow in rows { source.setSongRadio(seedRow.videoId, healthyRadio(seedRow)) }
        let songs = [librarySong("sp:n", "Newest", "First"), librarySong("sp:o", "Older", "Second"),
                     librarySong("sp:z", "Oldest", "Third")]
        func anchors(_ order: [Int]) -> [AutoplayAnchor] {
            order.map { AutoplayAnchor(song: songs[$0], videoId: rows[$0].videoId, spotifyId: String(songs[$0].id.dropFirst(3))) }
        }
        // An album ended: three anchors nobody asked about yet. One request, not three.
        let first = AutoplayPoolRequest(anchors: anchors([0, 1, 2]), deepen: false, allowNetwork: true, library: songs, everPlayed: [])
        let pool = await AutoplayPool.build(first, index: BrainLibraryIndex(songs: songs), repository: repository)
        #expect(source.calls == ["song:\(rows[0].videoId):0"])
        #expect(pool.seeds.count == 1 && !pool.fromLibrary && !pool.fellBack)
        // Later the second track leads: its radio is asked, and the first one's joins it from the cache.
        source.clearCalls()
        let second = AutoplayPoolRequest(anchors: anchors([1, 0, 2]), deepen: false, allowNetwork: true, library: songs, everPlayed: [])
        let wider = await AutoplayPool.build(second, index: BrainLibraryIndex(songs: songs), repository: repository)
        #expect(source.calls == ["song:\(rows[1].videoId):0"])
        #expect(wider.seeds.count == 2)
    }

    @Test func aLibraryPoolThatStandsInForRadiosSaysSo() async throws {
        defer { cleanUp() }
        // The request budget is spent, or the request failed: the source answers nil.
        let repository = BrainRepository(directory: directory, radioSource: source, clock: { 1_000 })
        let anchor = librarySong("sp:anchor", "Anchor", "Seed")
        let other = librarySong("sp:o", "Other", "Seed")
        let request = AutoplayPoolRequest(anchors: [AutoplayAnchor(song: anchor, videoId: "vid0000001", spotifyId: "anchor")],
                                          deepen: false, allowNetwork: true, library: [anchor, other], everPlayed: [])
        let pool = await AutoplayPool.build(request, index: BrainLibraryIndex(songs: request.library), repository: repository)
        #expect(source.calls.count == 1)
        #expect(pool.fromLibrary && pool.fellBack && !pool.offline)
        #expect(AutoplayPolicy.poolTtlMs(offline: pool.offline, fellBack: pool.fellBack) == AutoplayPolicy.fallbackPoolTtlMs)
    }

    @Test func anAnchorWithoutAKnownAudioIdHasNoRadioAndTheLibraryAnswers() async throws {
        defer { cleanUp() }
        let repository = BrainRepository(directory: directory, radioSource: source, clock: { 1_000 })
        let anchor = librarySong("sp:anchor", "Anchor", "Seed")
        let other = librarySong("sp:o", "Other", "Seed")
        let request = AutoplayPoolRequest(anchors: [AutoplayAnchor(song: anchor, videoId: nil, spotifyId: "anchor")],
                                          deepen: false, allowNetwork: true, library: [anchor, other], everPlayed: [])
        let pool = await AutoplayPool.build(request, index: BrainLibraryIndex(songs: request.library), repository: repository)
        #expect(pool.fromLibrary && pool.entries.map(\.candidate.mediaId) == ["sp:o"])
        #expect(source.calls.isEmpty)
        #expect(AutoplayPool.key(of: ["a", "b"]) == "a|b")
    }
}
