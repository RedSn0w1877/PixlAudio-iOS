import Foundation
import PixlFoundation
import PixlModel
import Testing
@testable import PixlLibrary

/// Daily Mix and Your Mix with new music, end to end over the real record files in a temporary folder and a scripted
/// radio source (docs/brain-spec.md, 8.2, stage 2a): shape, stability across a restart, "Regenerate", the repetition
/// budget, the switch, the legacy fallback, and what the refresh seeds from. A port of Android's `BrainMixesTest`.
@Suite("Brain mixes")
struct BrainMixesTests {
    private final class Source: RadioSource, @unchecked Sendable {
        private let lock = NSLock()
        private var radios: [String: FetchedRadio] = [:]
        private var asked: [String] = []
        func set(_ videoId: String, _ radio: FetchedRadio) { lock.withLock { radios[videoId] = radio } }
        var calls: [String] { lock.withLock { asked } }
        func songRadio(videoId: String, continuations: Int) async -> FetchedRadio? { lock.withLock { asked.append(videoId); return radios[videoId] } }
        func related(browseId: String) async -> RelatedPage? { nil }
        func artistPage(channelId: String) async -> ArtistPage? { nil }
        func artistRadio(endpoint: RadioEndpoint) async -> FetchedRadio? { nil }
    }

    private final class Box<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
    }

    private static let start: Int64 = 1_736_514_000_000 // 2025-01-10 14:00 local at UTC+1

    /// The day the listener lives in: 60 library songs by 12 artists, thirty of them played through twice.
    private struct World {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("brain-mixes-\(UUID().uuidString)", isDirectory: true)
        let clock = Box<Int64>(BrainMixesTests.start)
        let source = Source()
        let library: [Song]
        let level = Box<Int>(Novelty.blend)
        let engineChoice = Box<Int>(BrainEngineChoice.brain)
        let blockedArtist = Box<String?>(nil)
        let libraryOverride = Box<[Song]?>(nil)
        let built = Box<Int>(0)

        init() {
            library = (0..<60).map { i in
                testSong("lib\(i)", title: "Library Song \(i)", artist: "Lib Artist \(i % 12)", duration: 200_000,
                         album: "Album \(i / 4)", spotifyId: "4iV5W9uYEdYUVa79Ax\(String(format: "%04d", i))")
            }
        }

        func tidy() { try? FileManager.default.removeItem(at: directory) }

        func repository() -> BrainRepository {
            let clock = self.clock
            return BrainRepository(directory: directory, radioSource: source, clock: { clock.value })
        }

        func engine(_ repository: BrainRepository) -> BrainEngine {
            let clock = self.clock
            return BrainEngine(directory: directory, repository: repository, sources: nil, clock: { clock.value })
        }

        /// Resolves the library into recordings and writes the listener's history: songs 0..<30 played to the end twice.
        func listen(_ repository: BrainRepository, songs: Range<Int> = 0..<30) async {
            let requests = library.map { TrackRequest(keys: TrackCatalog.facts(of: $0)!.keys, durationMs: 200_000) }
            let rids = await repository.resolveTracks(requests)
            let aids = await repository.resolveArtistNames(library.map { BrainLibraryIndex.primaryArtistName($0) })
            var events: [PlayEvent] = []
            var session: Int64 = 1
            let order = Array(songs) + Array(songs)
            for (round, i) in order.enumerated() {
                let at = BrainMixesTests.start - Int64(72 - round) * 3_600_000
                let key = "s:\(library[i].spotifyId ?? "")"
                events.append(PlayEvent(
                    eventId: PlayEvent.mintId(startedAtMs: at, origin: Origin.live, keyAtWrite: key + "#\(round)") { _ in nil },
                    origin: Origin.live, rid: rids[i], primaryAid: aids[i], keyAtWrite: key + "#\(round)", startedAtMs: at,
                    tzOffsetMin: 60, playedMs: 200_000, durationMs: 200_000, startReason: StartReason.tap,
                    endReason: EndReason.trackDone, surface: Surface.playlist, sessionId: session))
                if round % 10 == 9 { session += 1 }
            }
            let state = Replay.rebuild(events, facts: .empty, nowMs: BrainMixesTests.start)
            let log = BrainEventLog(directory: directory)
            log.insert(events)
            log.upsertAffinity(state.rows())
        }

        /// 45 rows after the seed, the seed's artist again at rows 3 and 9, every row a different recording.
        func radio(forLibrarySong i: Int) -> FetchedRadio {
            let artist = BrainLibraryIndex.primaryArtistName(library[i])
            let seedRow = RadioRow(videoId: "vid-lib\(i)", title: library[i].title,
                                   artists: [RadioArtistRef(name: artist, channelId: "UC\(artist)")], durationSec: 200, kind: .atv)
            var rows = [seedRow]
            for k in 0..<45 {
                let by = k == 2 || k == 8 ? artist : "Novel Artist \((i * 7 + k) % 23)"
                rows.append(RadioRow(videoId: "n\(i)x\(k)", title: "Novel \(i) \(k)",
                                     artists: [RadioArtistRef(name: by, channelId: "UC\(by)")], album: "Novel Album \(k / 3)",
                                     durationSec: 190 + k, kind: .atv))
            }
            return FetchedRadio(rows: rows, relatedBrowseId: "MPTRt_\(i)")
        }

        /// Caches the radios of songs `range` through the repository, the way listening and the refresh do.
        func fetchRadios(_ repository: BrainRepository, songs range: Range<Int> = 0..<30) async {
            for i in range {
                source.set("vid-lib\(i)", radio(forLibrarySong: i))
                let seed = RadioSeed(mediaId: library[i].id, videoId: "vid-lib\(i)", title: library[i].title,
                                     primaryArtist: BrainLibraryIndex.primaryArtistName(library[i]), durationMs: 200_000)
                _ = await repository.radioFor(seed: seed, allowNetwork: true)
            }
        }

        func mixes(_ repository: BrainRepository, _ engine: BrainEngine) -> BrainMixes {
            let clock = self.clock
            let all = library
            let level = self.level, choice = self.engineChoice, blocked = self.blockedArtist, override = self.libraryOverride
            let built = self.built
            let sources = MixSources(
                library: { override.value ?? all },
                librarySongs: { ids in
                    let wanted = Set(ids)
                    var out: [String: Song] = [:]
                    for song in override.value ?? all where wanted.contains(song.id) { out[song.id] = song }
                    return out
                },
                legacyPicks: { library, limit, _, _ in Array(library.prefix(limit)) },
                constraints: {
                    var adjustments = TasteAdjustmentSet.empty
                    var matcher = BlockedArtistMatcher.empty
                    if let name = blocked.value {
                        matcher = BlockedArtistMatcher(entries: [BlockedArtist(artistId: -1, name: name)])
                        adjustments = .empty
                    }
                    return MixConstraints(blocked: matcher, adjustments: adjustments, favoriteIds: [],
                                          signature: blocked.value ?? "")
                },
                engine: { choice.value },
                noveltyLevel: { level.value },
                tzOffsetMin: { _ in 60 },
                mixBuilt: { built.value += 1 })
            return BrainMixes(directory: directory, repository: repository, engine: engine, sources: sources, clock: { clock.value })
        }
    }

    private func ids(_ view: MixView?) -> [String] { view?.songs.map(\.id) ?? [] }

    // MARK: Shape

    @Test func aDailyMixHasThirtyTracksSomeFromOutsideTheLibraryAndYourMixSixty() async throws {
        let world = World()
        defer { world.tidy() }
        let repository = world.repository()
        await world.listen(repository)
        await world.fetchRadios(repository)
        let mixes = world.mixes(repository, world.engine(repository))
        let daily = try #require(await mixes.today(kind: MixPlanner.kindDaily))
        let your = try #require(await mixes.today(kind: MixPlanner.kindYour))
        #expect(daily.songs.count == 30)
        #expect(your.songs.count == 60)
        #expect(Set(ids(daily)).count == 30 && Set(ids(your)).count == 60, "each track once")
        // New music: about a quarter of the Daily Mix, a fifth of Your Mix; the rest the listener's own.
        #expect((5...10).contains(daily.novelIds.count), "novel in the daily mix: \(daily.novelIds.count)")
        // (This library has 60 songs and the Daily Mix took its own share of them first, so Your Mix runs out of
        // familiar tracks and the rest of its sixty is new music.)
        #expect(your.novelIds.count >= 6, "novel in your mix: \(your.novelIds.count)")
        for song in daily.songs {
            if daily.novelIds.contains(song.id) {
                #expect(song.id.hasPrefix("yt:") && song.contentUriString.hasPrefix("pixlstream://"))
            } else {
                #expect(song.id.hasPrefix("lib"))
            }
        }
        // A daily mix ends on a familiar track; a play of a row carries the surface, the arm and that the listener chose it.
        #expect(!daily.novelIds.contains(daily.songs.last!.id))
        let tag = try #require(daily.tags[daily.songs[0].id])
        #expect(tag.surface == "dailyMix" && tag.surfaceId == "daily" && tag.chosen && tag.recId == daily.recId && tag.slot == 0)
        #expect(your.tags[your.songs[0].id]?.surface == "yourMix")
        // A reason is shown only when it is a true sentence with a name; the mix register is the tracks' own.
        for (id, reason) in daily.reasons {
            #expect(!reason.arg.isEmpty || reason.key == "on_repeat", "\(id): \(reason.key)")
        }
        #expect(!daily.engineTracks.isEmpty && daily.engineTracks.count == daily.novelIds.count)
        #expect(world.built.value == 2, "the refresh is scheduled by a build, not before")
        let engineTrack = try #require(await repository.engineTrack(songId: daily.engineTracks[0].songId))
        #expect(engineTrack.videoId == daily.engineTracks[0].videoId, "a mix's outside tracks are in `playable`")
    }

    @Test func noTrackIsInTwoMixesOfOneDay() async throws {
        let world = World()
        defer { world.tidy() }
        let repository = world.repository()
        await world.listen(repository)
        await world.fetchRadios(repository)
        let mixes = world.mixes(repository, world.engine(repository))
        let daily = try #require(await mixes.today(kind: MixPlanner.kindDaily))
        let your = try #require(await mixes.today(kind: MixPlanner.kindYour))
        #expect(Set(ids(daily)).isDisjoint(with: Set(ids(your))))
    }

    // MARK: Stability

    @Test func aMixIsTheSameAllDayAndComesBackAfterARestartWithoutLoadingTheBrain() async throws {
        let world = World()
        defer { world.tidy() }
        let repository = world.repository()
        await world.listen(repository)
        await world.fetchRadios(repository)
        let engine = world.engine(repository)
        let first = world.mixes(repository, engine)
        let daily = try #require(await first.today(kind: MixPlanner.kindDaily))
        // Later the same day: the same list (asked, not rebuilt).
        world.clock.value += 5 * 3_600_000
        let later = try #require(await first.today(kind: MixPlanner.kindDaily))
        #expect(ids(later) == ids(daily))
        #expect(world.built.value == 1)

        // A restart: new objects over the same files; the saved mix needs no brain state at all.
        let restartedRepository = world.repository()
        let restartedEngine = world.engine(restartedRepository)
        let restarted = world.mixes(restartedRepository, restartedEngine)
        let saved = try #require(await restarted.saved(kind: MixPlanner.kindDaily))
        #expect(ids(saved) == ids(daily))
        #expect(saved.novelIds == daily.novelIds && saved.recId == daily.recId)
        #expect(await restartedEngine.isLoaded == false, "reading a saved mix does not load the brain")
        // The outside tracks of the saved mix are shown and played from the mix itself.
        #expect(saved.engineTracks.map(\.videoId) == daily.engineTracks.map(\.videoId))

        // The next day (after 04:00) is another list.
        world.clock.value = BrainMixesTests.start + 20 * 3_600_000
        #expect(await restarted.saved(kind: MixPlanner.kindDaily) == nil)
        let tomorrow = try #require(await restarted.today(kind: MixPlanner.kindDaily))
        #expect(ids(tomorrow) != ids(daily))
    }

    @Test func regenerateDrawsAnotherListAndTheServedLogCountsIt() async throws {
        let world = World()
        defer { world.tidy() }
        let repository = world.repository()
        await world.listen(repository)
        await world.fetchRadios(repository)
        let mixes = world.mixes(repository, world.engine(repository))
        let first = try #require(await mixes.today(kind: MixPlanner.kindYour))
        world.clock.value += 60_000
        let second = try #require(await mixes.today(kind: MixPlanner.kindYour, regenerate: true))
        world.clock.value += 60_000
        let third = try #require(await mixes.today(kind: MixPlanner.kindYour, regenerate: true))
        #expect(ids(first) != ids(second) && ids(second) != ids(third))
        // What the listener sees next is the newest list of the day.
        let back = try #require(await mixes.saved(kind: MixPlanner.kindYour))
        #expect(ids(back) == ids(third))
    }

    // MARK: The switch and the repetition budget

    @Test func theNoveltySwitchMovesTheShareOfNewMusic() async throws {
        let world = World()
        defer { world.tidy() }
        let repository = world.repository()
        await world.listen(repository)
        await world.fetchRadios(repository)
        let mixes = world.mixes(repository, world.engine(repository))
        var counts: [Int] = []
        for level in [Novelty.familiar, Novelty.blend, Novelty.discover] {
            world.level.value = level
            world.clock.value += 60_000
            let view = try #require(await mixes.today(kind: MixPlanner.kindDaily, regenerate: true))
            counts.append(view.novelIds.count)
        }
        #expect(counts[0] < counts[1] && counts[1] < counts[2], "\(counts)")
    }

    @Test func aTrackServedOftenLatelyIsPickedLessOnTheDaysThatFollow() async throws {
        let world = World()
        defer { world.tidy() }
        let repository = world.repository()
        await world.listen(repository)
        await world.fetchRadios(repository)
        let mixes = world.mixes(repository, world.engine(repository))
        var days: [[String]] = []
        for _ in 0..<5 {
            let view = try #require(await mixes.today(kind: MixPlanner.kindDaily))
            days.append(ids(view))
            world.clock.value += 24 * 3_600_000
        }
        let first = Set(days[0])
        // Not a ban, a penalty: but the next days are not the first day again.
        for next in days.dropFirst() { #expect(Set(next).intersection(first).count < 20, "day overlap \(Set(next).intersection(first).count)") }
        #expect(Set(days.flatMap { $0 }).count > 60, "five days serve well over two lists' worth of different tracks")
    }

    @Test func aBlockedArtistIsNeverInAMixAndASongThatLeftTheLibraryIsDroppedWhenItIsReadBack() async throws {
        let world = World()
        defer { world.tidy() }
        let repository = world.repository()
        await world.listen(repository)
        await world.fetchRadios(repository)
        let mixes = world.mixes(repository, world.engine(repository))
        let daily = try #require(await mixes.today(kind: MixPlanner.kindDaily))
        // Read back with some library songs gone: dropped, the rest stays.
        let leaving = Set(daily.songs.filter { $0.id.hasPrefix("lib") }.prefix(4).map(\.id))
        world.libraryOverride.value = world.library.filter { !leaving.contains($0.id) }
        let trimmed = try #require(await mixes.saved(kind: MixPlanner.kindDaily))
        #expect(trimmed.songs.count == 26 && Set(ids(trimmed)).isDisjoint(with: leaving))
        // Everything of the library gone: too little is left to be a mix, so the caller builds another.
        world.libraryOverride.value = []
        #expect(await mixes.saved(kind: MixPlanner.kindDaily) == nil)
        world.libraryOverride.value = nil

        // A blocked artist: not in the list that is built next, library or outside.
        world.blockedArtist.value = "Lib Artist 3"
        world.clock.value += 60_000
        let rebuilt = try #require(await mixes.today(kind: MixPlanner.kindDaily, regenerate: true))
        #expect(rebuilt.songs.allSatisfy { !($0.artist.contains("Lib Artist 3")) })
    }

    @Test func aSongTheListenerRemovedStaysOutAfterARestart() async throws {
        let world = World()
        defer { world.tidy() }
        let repository = world.repository()
        await world.listen(repository)
        await world.fetchRadios(repository)
        let mixes = world.mixes(repository, world.engine(repository))
        let daily = try #require(await mixes.today(kind: MixPlanner.kindDaily))
        let outside = try #require(daily.songs.first { daily.novelIds.contains($0.id) })
        let inside = try #require(daily.songs.first { !daily.novelIds.contains($0.id) })
        await mixes.removeItem(kind: MixPlanner.kindDaily, songId: outside.id)
        await mixes.removeItem(kind: MixPlanner.kindDaily, songId: inside.id)
        let restartedRepository = world.repository()
        let restarted = world.mixes(restartedRepository, world.engine(restartedRepository))
        let saved = try #require(await restarted.saved(kind: MixPlanner.kindDaily))
        #expect(saved.songs.count == 28)
        #expect(!ids(saved).contains(outside.id) && !ids(saved).contains(inside.id))
    }

    // MARK: Who owns the mixes, and the fallback

    @Test func theBrainOwnsTheMixesOnlyWhenItIsOnAndHasHeardTenTracks() async throws {
        let world = World()
        defer { world.tidy() }
        let repository = world.repository()
        // No history at all: the legacy mixes build as before.
        let cold = world.mixes(repository, world.engine(repository))
        #expect(await cold.ownsMixes() == false)
        await world.listen(repository, songs: 0..<9)
        let nine = world.mixes(world.repository(), world.engine(world.repository()))
        #expect(await nine.ownsMixes() == false, "nine different tracks is not enough")
        let more = World()
        defer { more.tidy() }
        let moreRepository = more.repository()
        await more.listen(moreRepository, songs: 0..<12)
        let enough = more.mixes(moreRepository, more.engine(moreRepository))
        #expect(await enough.ownsMixes() == true)
        more.engineChoice.value = BrainEngineChoice.legacy
        #expect(await enough.ownsMixes() == false, "the switch gives the old mixes back")
    }

    @Test func aMixBuiltWithNoRadiosHoldsOnlyTheLibraryAndIsBuiltAgainOnceRadiosAreCached() async throws {
        let world = World()
        defer { world.tidy() }
        let repository = world.repository()
        await world.listen(repository)
        let mixes = world.mixes(repository, world.engine(repository))
        let plain = try #require(await mixes.today(kind: MixPlanner.kindDaily))
        #expect(plain.novelIds.isEmpty && plain.seedLists == 0 && plain.songs.count == 30)
        // The same minute: it is the day's mix. Ten minutes on with radios cached: it is built again, once.
        await world.fetchRadios(repository)
        #expect(ids(try #require(await mixes.saved(kind: MixPlanner.kindDaily))) == ids(plain))
        world.clock.value += 11 * 60_000
        #expect(await mixes.saved(kind: MixPlanner.kindDaily) == nil, "stale: the caller builds it again")
        let again = try #require(await mixes.today(kind: MixPlanner.kindDaily))
        #expect(!again.novelIds.isEmpty && again.seedLists > 0)
        // And a mix with new music is the day's mix and stays.
        world.clock.value += 60 * 60_000
        #expect(ids(try #require(await mixes.saved(kind: MixPlanner.kindDaily))) == ids(again))
    }

    @Test func publishGivesBothMixesOrNothingAtAllWhenTheBrainDoesNotOwnThem() async throws {
        let world = World()
        defer { world.tidy() }
        let repository = world.repository()
        await world.listen(repository)
        await world.fetchRadios(repository)
        let mixes = world.mixes(repository, world.engine(repository))
        let pair = try #require(await mixes.publish())
        #expect(pair.daily.songs.count == 30 && pair.your.songs.count == 60)
        #expect(Set(ids(pair.daily)).isDisjoint(with: Set(ids(pair.your))), "Daily Mix is built first")
        // Asked again: the saved ones, not new ones.
        let again = try #require(await mixes.publish())
        #expect(ids(again.daily) == ids(pair.daily) && ids(again.your) == ids(pair.your))
        #expect(world.built.value == 2)
        // Regenerate draws both again.
        world.clock.value += 60_000
        let regenerated = try #require(await mixes.publish(regenerate: true))
        #expect(ids(regenerated.daily) != ids(pair.daily) && ids(regenerated.your) != ids(pair.your))
        // Your Mix alone.
        world.clock.value += 60_000
        let your = try #require(await mixes.regenerateYourMix())
        #expect(ids(your) != ids(regenerated.your))
        // The switch off: the legacy mixes build as before.
        world.engineChoice.value = BrainEngineChoice.legacy
        #expect(await mixes.publish() == nil)
        #expect(await mixes.regenerateYourMix() == nil)
    }

    @Test func withTooLittleHeardTheBrainLeavesTheMixesToTheLegacyEngine() async throws {
        let world = World()
        defer { world.tidy() }
        let repository = world.repository()
        await world.listen(repository, songs: 0..<6)
        let mixes = world.mixes(repository, world.engine(repository))
        #expect(await mixes.publish() == nil)
        #expect(world.built.value == 0, "nothing was built, so nothing was scheduled")
    }

    // MARK: The refresh's seeds

    @Test func theRefreshSeedsFromWhatTheListenerChoseAtMostTwentyFourTwoPerArtist() async throws {
        let world = World()
        defer { world.tidy() }
        let repository = world.repository()
        await world.listen(repository)
        let mixes = world.mixes(repository, world.engine(repository))
        let seeds = await mixes.seedsForRefresh()
        #expect(!seeds.isEmpty && seeds.count <= Seeds.maxPerDay)
        var perArtist: [Int64: Int] = [:]
        for seed in seeds where seed.aid != 0 { perArtist[seed.aid, default: 0] += 1 }
        #expect(perArtist.values.allSatisfy { $0 <= Seeds.maxPerArtist })
        #expect(seeds.allSatisfy { $0.song != nil }, "library tracks the listener played or could be offered")
        #expect(Set(seeds.map(\.rid)).count == seeds.count)
        // Lane 2: one track for each of the top artists, most played first, at most twenty.
        let artists = await mixes.topArtistSeeds()
        #expect(!artists.isEmpty && artists.count <= BrainMixes.topArtists)
        #expect(Set(artists.map(\.aid)).count == artists.count)
    }

    @Test func theRefreshWorkFindsTheVideoOfAYouTubeSongAndOfASpotifySongAndSkipsTheRest() async throws {
        let world = World()
        defer { world.tidy() }
        let repository = world.repository()
        await world.listen(repository)
        let mixes = world.mixes(repository, world.engine(repository))
        let matched = Box<[String: String]>([:])
        let work = BrainRefreshWork(mixes: mixes, repository: repository, budget: nil,
                                    matchedVideoId: { matched.value[$0] }, clock: { world.clock.value })
        #expect(await work.radioSeeds().isEmpty, "no seed has a known YouTube audio id yet: matching is the matcher's job")
        matched.value = Dictionary(uniqueKeysWithValues: world.library.compactMap { song in song.spotifyId.map { ($0, "vid-\(song.id)") } })
        let targets = await work.radioSeeds()
        #expect(!targets.isEmpty)
        #expect(targets.allSatisfy { $0.seed.videoId.hasPrefix("vid-lib") && $0.seed.spotifyId != nil })
        #expect(await work.requestsLeft() == BrainRefreshWork.workerDailyCeiling)
    }
}
