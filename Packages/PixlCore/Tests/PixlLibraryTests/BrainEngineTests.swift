import Foundation
import PixlFoundation
import PixlModel
import Testing
@testable import PixlLibrary

/// The event recorder, the migration and the session reactions of the music brain (docs/brain-spec.md, 4.2, 4.4,
/// 7.3), against real record files in a temporary folder. The iOS twins of Android's `BrainEventRecorderTest`,
/// `BrainMigrationTest`, `PlayReasonsTest` and `ListeningStatsTrackerBrainTest`.
private final class EngineClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(_ start: Int64) { value = start }

    var now: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ ms: Int64) {
        lock.lock()
        value = ms
        lock.unlock()
    }
}

private struct Harness {
    let directory: URL
    let clock: EngineClock
    let repository: BrainRepository
    let engine: BrainEngine

    static let t0: Int64 = 1_760_000_000_000

    init(sources: BrainEngine.Sources? = nil, directory: URL? = nil, now: Int64 = Harness.t0) {
        let dir = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("brain-engine-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directory = dir
        let clock = EngineClock(now)
        self.clock = clock
        repository = BrainRepository(directory: dir, radioSource: nil, clock: { clock.now })
        engine = BrainEngine(directory: dir, repository: repository, sources: sources, clock: { clock.now })
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

private func context(_ title: String, _ artist: String, spotifyId: String? = nil, videoId: String? = nil,
                     inLibrary: Bool = true, start: Int32 = StartReason.tap, tag: BrainItemTag? = nil) -> PlayContext {
    PlayContext(title: title, artistDisplay: artist, artists: [artist], spotifyId: spotifyId, videoId: videoId,
                inLibrary: inLibrary, startReason: start, tag: tag)
}

private func play(_ id: String, _ context: PlayContext, at startedAtMs: Int64, played: Int64, duration: Int64 = 200_000,
                  end: Int32 = EndReason.trackDone, flags: Int32 = 0) -> FinishedPlay {
    FinishedPlay(songId: id, context: context, startedAtMs: startedAtMs, playedMs: played, durationMs: duration,
                 endReason: end, flags: flags, tzOffsetMin: 420)
}

private func librarySong(_ id: String, _ title: String, _ artist: String, spotifyId: String? = nil,
                         duration: Int64 = 200_000, favorite: Bool = false) -> Song {
    testSong(id, title: title, artist: artist, duration: duration, isFavorite: favorite, spotifyId: spotifyId,
             artists: [ArtistRef(id: 1, name: artist, isPrimary: true)])
}

@Suite("Brain event recorder")
struct BrainEventRecorderTests {
    @Test func aSkipAfterTwoSecondsIsInTheLogWithEndReasonNext() async {
        let h = Harness()
        defer { h.cleanUp() }
        let reaction = await h.engine.record(play("s1", context("Dreams", "Fleetwood Mac", spotifyId: "4uLU6hMCjMI75M1A2tKUQC"),
                                                   at: Harness.t0, played: 2_000, end: EndReason.next))
        let events = await h.engine.events()
        #expect(events.count == 1)
        #expect(events.first?.endReason == EndReason.next)
        #expect(events.first?.playedMs == 2_000)
        #expect(events.first?.keyAtWrite == "s:4uLU6hMCjMI75M1A2tKUQC")
        #expect(events.first?.origin == Origin.live)
        #expect(events.first?.tzOffsetMin == 420)
        #expect(reaction?.graded.isSkip == true)
        #expect(reaction?.graded.h == 1.0)
    }

    @Test func theQueueEntrysTagTravelsIntoTheEvent() async {
        let h = Harness()
        defer { h.cleanUp() }
        let tag = BrainItemTag(surface: "autoplay", surfaceId: "yt:seed", recId: 7_700, slot: 3, arm: "RADIO",
                               radioRank: 4, retrQ: 812, primaryArtist: "Stevie Nicks")
        var ctx = context("Edge of Seventeen", "Stevie Nicks", videoId: "abc123XYZ_0", inLibrary: false,
                          start: StartReason.autoplay, tag: tag)
        ctx.shuffle = true
        _ = await h.engine.record(play("yt:abc123XYZ_0", ctx, at: Harness.t0, played: 200_000))
        let e = await h.engine.events().first
        #expect(e?.surface == Surface.autoplay)
        #expect(e?.surfaceId == "yt:seed")
        #expect(e?.recId == 7_700)
        #expect(e?.slot == 3)
        #expect(e?.arm == Arm.radio)
        #expect(e?.retrQ == 812)
        #expect(e?.radioRank == 4)
        #expect(e?.startReason == StartReason.autoplay)
        #expect(e?.keyAtWrite == "y:abc123XYZ_0")
        #expect(e?.has(EventFlags.shuffle) == true)
        #expect(e?.primaryAid != 0)
    }

    @Test func theEventAndTheAffinityRowsItTouchedAreWrittenAndReadBack() async {
        let h = Harness()
        defer { h.cleanUp() }
        _ = await h.engine.record(play("s1", context("Dreams", "Fleetwood Mac"), at: Harness.t0, played: 200_000))
        let rows = await h.engine.affinityRows()
        // The track, its artist, the key `all`, their three sums and one completion count.
        #expect(rows.count == 7)
        // A second process reads the same rows from the files.
        let again = Harness(directory: h.directory)
        #expect(await again.engine.affinityRows() == rows)
        #expect(await again.engine.eventCount() == 1)
    }

    @Test func theSamePlayHandedOverTwiceIsOneEvent() async {
        let h = Harness()
        defer { h.cleanUp() }
        let p = play("s1", context("Dreams", "Fleetwood Mac"), at: Harness.t0, played: 200_000)
        #expect(await h.engine.record(p) != nil)
        let rows = await h.engine.affinityRows()
        #expect(await h.engine.record(p) == nil)
        #expect(await h.engine.eventCount() == 1)
        #expect(await h.engine.affinityRows() == rows)
    }

    @Test func playsAreStampedWithTheirSessionAndASessionEndsAfterThirtyIdleMinutes() async {
        let h = Harness()
        defer { h.cleanUp() }
        let ctx = context("Dreams", "Fleetwood Mac")
        _ = await h.engine.record(play("s1", ctx, at: Harness.t0, played: 100_000))
        _ = await h.engine.record(play("s2", context("Sara", "Fleetwood Mac", start: StartReason.autoAdvance),
                                       at: Harness.t0 + 110_000, played: 100_000))
        _ = await h.engine.record(play("s3", context("Gypsy", "Fleetwood Mac"),
                                       at: Harness.t0 + 210_000 + Session.gapMs + 1, played: 100_000))
        let events = await h.engine.events()
        #expect(events.map(\.posInSession) == [0, 1, 0])
        #expect(events.map(\.passiveRun) == [0, 1, 0])
        #expect(events[0].sessionId == events[1].sessionId)
        #expect(events[2].sessionId != events[0].sessionId)
    }

    @Test func onlyTheListenersChoicesBecomeAnchorsWithWhatARadioRequestNeeds() async {
        let h = Harness()
        defer { h.cleanUp() }
        let chosen = await h.engine.record(play("s1", context("Dreams", "Fleetwood Mac", spotifyId: "4uLU6hMCjMI75M1A2tKUQC"),
                                                 at: Harness.t0, played: 200_000))
        #expect(chosen?.anchors.map(\.mediaId) == ["s1"])
        #expect(chosen?.anchors.first?.primaryArtist == "Fleetwood Mac")
        #expect(chosen?.anchors.first?.spotifyId == "4uLU6hMCjMI75M1A2tKUQC")
        // An engine pick that merely played through is not an anchor.
        let tag = BrainItemTag(surface: "autoplay", arm: "RADIO")
        let engine = await h.engine.record(play("yt:v2", context("Sara", "Stevie Nicks", videoId: "v2", inLibrary: false,
                                                                  start: StartReason.autoplay, tag: tag),
                                                 at: Harness.t0 + 210_000, played: 200_000))
        #expect(engine?.anchors.map(\.mediaId) == ["s1"])
        // One the listener liked is.
        let liked = await h.engine.record(play("yt:v3", context("Landslide", "Stevie Nicks", videoId: "v3", inLibrary: false,
                                                                 start: StartReason.autoplay, tag: tag),
                                                at: Harness.t0 + 420_000, played: 200_000, flags: EventFlags.likedDuring))
        #expect(liked?.liked == true)
        #expect(liked?.anchors.map(\.mediaId) == ["yt:v3", "s1"])
        #expect(liked?.anchors.first?.videoId == "v3")
    }

    @Test func threeHardSkipsInARowChangeDirectionToTheNextAnchorOnly() async {
        let h = Harness()
        defer { h.cleanUp() }
        var t = Harness.t0
        for (id, title) in [("a1", "One"), ("a2", "Two")] {
            _ = await h.engine.record(play(id, context(title, "Artist \(id)"), at: t, played: 200_000))
            t += 205_000
        }
        var last: Reaction?
        for n in 0..<3 {
            last = await h.engine.record(play("k\(n)", context("Skip \(n)", "Skipped \(n)", start: StartReason.next),
                                              at: t, played: 3_000, end: EndReason.next))
            t += 4_000
            if n < 2 { #expect(last?.changedDirection == false) }
        }
        #expect(last?.changedDirection == true)
        #expect(last?.turned == true)
        // Newest first is a2, a1; turned by one place the engine follows a1 alone.
        #expect(last?.anchors.map(\.mediaId) == ["a1"])
        #expect(last?.needsOtherDirection == false)
        let session = await h.engine.sessionSnapshot()
        #expect(session.reseedCount == 1)
        #expect(session.skipRun == 0)
    }

    @Test func aPlayThatWasCutOffByAProcessDeathIsRecordedAsKilled() async {
        let h = Harness()
        defer { h.cleanUp() }
        let open = play("s1", context("Dreams", "Fleetwood Mac"), at: Harness.t0, played: 41_000, end: EndReason.unknown)
        await h.engine.setOpenPlay(open)
        // The next process finds it.
        let next = Harness(directory: h.directory)
        await next.engine.recoverKilledPlay()
        let events = await next.engine.events()
        #expect(events.count == 1)
        #expect(events.first?.endReason == EndReason.killed)
        #expect(events.first?.playedMs == 41_000)
        // Once.
        await next.engine.recoverKilledPlay()
        let third = Harness(directory: h.directory)
        await third.engine.recoverKilledPlay()
        #expect(await third.engine.eventCount() == 1)
    }

    @Test func theOpenPlayCodecKeepsWhatTheRecorderNeeds() {
        let tag = BrainItemTag(surface: "autoplay", surfaceId: "x", recId: 5, slot: 2, arm: "FAV", radioRank: 9, retrQ: 100,
                               primaryArtist: "Một")
        var ctx = context("Chúng Ta Của Hiện Tại", "Sơn Tùng M-TP", spotifyId: "sp1", videoId: "v1", inLibrary: false,
                          start: StartReason.autoplay, tag: tag)
        ctx.artists = ["Sơn Tùng M-TP", "Khác"]
        ctx.repeatOne = true
        let p = play("yt:v1", ctx, at: 123, played: 456, duration: 789, end: EndReason.killed, flags: EventFlags.likedDuring)
        let decoded = OpenPlayCodec.decode(OpenPlayCodec.encode(p))
        #expect(decoded == p)
        #expect(OpenPlayCodec.decode("not json") == nil)
    }

    @Test func aTrackNobodyCanNameIsNotRecorded() async {
        let h = Harness()
        defer { h.cleanUp() }
        #expect(await h.engine.record(play("x", context("", ""), at: Harness.t0, played: 10_000)) == nil)
        #expect(await h.engine.eventCount() == 0)
    }

    @Test func theRecorderHandsPlaysOverInOrder() async {
        let h = Harness()
        defer { h.cleanUp() }
        let (stream, continuation) = AsyncStream<Int32>.makeStream()
        let recorder = BrainRecorder(engine: h.engine) { reaction in continuation.yield(reaction.event.posInSession) }
        for n in 0..<6 {
            recorder.playFinished(play("s\(n)", context("Song \(n)", "Artist"), at: Harness.t0 + Int64(n) * 1_000,
                                       played: 900, end: EndReason.next))
        }
        var seen: [Int32] = []
        for await position in stream {
            seen.append(position)
            if seen.count == 6 { break }
        }
        #expect(seen == [0, 1, 2, 3, 4, 5])
        #expect(await h.engine.eventCount() == 6)
    }
}

@Suite("Brain play context")
struct BrainPlayContextTests {
    @Test func theReasonTable() {
        typealias R = PlayReasons.Reasons
        func reasons(_ reason: Int32, old: Int = 3, new: Int = 4, oldSize: Int = 10, newSize: Int = 10,
                     engine: Bool = false, restoring: Bool = false) -> R {
            PlayReasons.forTransition(reason: reason, oldIndex: old, newIndex: new, oldQueueSize: oldSize,
                                      newQueueSize: newSize, newItemIsEnginePick: engine, isRestoring: restoring)
        }
        #expect(reasons(PlayReasons.transitionAuto) == R(end: EndReason.trackDone, start: StartReason.autoAdvance))
        #expect(reasons(PlayReasons.transitionAuto, engine: true) == R(end: EndReason.trackDone, start: StartReason.autoplay))
        #expect(reasons(PlayReasons.transitionRepeat) == R(end: EndReason.trackDone, start: StartReason.autoAdvance))
        #expect(reasons(PlayReasons.transitionSeek, old: 3, new: 4) == R(end: EndReason.next, start: StartReason.next))
        #expect(reasons(PlayReasons.transitionSeek, old: 3, new: 2) == R(end: EndReason.prev, start: StartReason.prev))
        #expect(reasons(PlayReasons.transitionSeek, old: 3, new: 8) == R(end: EndReason.pickedOther, start: StartReason.tap))
        #expect(reasons(PlayReasons.transitionSeek, old: -1, new: 0) == R(end: EndReason.pickedOther, start: StartReason.tap))
        #expect(reasons(PlayReasons.transitionPlaylistChanged, oldSize: 10, newSize: 30)
            == R(end: EndReason.pickedOther, start: StartReason.tap))
        #expect(reasons(PlayReasons.transitionPlaylistChanged, oldSize: 10, newSize: 9)
            == R(end: EndReason.queueEdit, start: StartReason.tap))
        #expect(reasons(PlayReasons.transitionPlaylistChanged, oldSize: 0, newSize: 9, restoring: true)
            == R(end: EndReason.pickedOther, start: StartReason.restore))
        #expect(reasons(99) == R(end: EndReason.unknown, start: StartReason.unknown))
        #expect(PlayReasons.afterFailure(newItemIsEnginePick: true) == R(end: EndReason.error, start: StartReason.autoplay))
        #expect(PlayReasons.kind(automatic: true, queueChanged: true) == PlayReasons.transitionAuto)
        #expect(PlayReasons.kind(automatic: false, queueChanged: true) == PlayReasons.transitionPlaylistChanged)
        #expect(PlayReasons.kind(automatic: false, queueChanged: false) == PlayReasons.transitionSeek)
    }

    @Test func surfaceTags() {
        let playlist = BrainSurfaces.playlist(id: "37i9dQZF1DXcBWIGoYBM5M")
        #expect(playlist.surface == "playlist")
        #expect(playlist.surfaceId != "37i9dQZF1DXcBWIGoYBM5M")
        #expect(playlist.surfaceId == BrainSurfaces.hashedId("37i9dQZF1DXcBWIGoYBM5M"))
        #expect(BrainSurfaces.hashedId("") == "cbf29ce484222325")
        #expect(BrainSurfaces.manualQueue.surface == "manualQueue")
        #expect(!BrainSurfaces.manualQueue.isEngineOwned)
        #expect(BrainSurfaces.tag(Surface.album).surface == "album")
    }

    @Test func anOpenPlayCountsAudibleTimeOnlyAndHasNoFiveSecondFloor() {
        let ctx = context("Dreams", "Fleetwood Mac")
        var open = OpenPlay(songId: "s1", context: ctx, startedAtEpochMs: 1_000, tzOffsetMin: 60, durationMs: 200_000,
                            isPlaying: true, realtimeMs: 10_000)
        let pauseIsWrittenDown = open.update(realtimeMs: 11_500, playing: false)
        #expect(pauseIsWrittenDown)
        // Paused time is not listening.
        let resumeIsWrittenDown = open.update(realtimeMs: 60_000, playing: true)
        #expect(!resumeIsWrittenDown)
        let finished = open.finish(endReason: EndReason.next, realtimeMs: 60_500)
        #expect(finished?.playedMs == 2_000)
        #expect(finished?.endReason == EndReason.next)
        #expect(finished?.flags == 0)
        #expect(finished?.tzOffsetMin == 60)
    }

    @Test func anItemThatNeverSoundedIsOnlyAPlayWhenTheListenerOrAnErrorEndedIt() {
        let ctx = context("Dreams", "Fleetwood Mac")
        func fresh() -> OpenPlay {
            OpenPlay(songId: "s1", context: ctx, startedAtEpochMs: 1_000, tzOffsetMin: 0, durationMs: 0, isPlaying: false,
                     realtimeMs: 10_000)
        }
        var restored = fresh()
        #expect(restored.finish(endReason: EndReason.stopped, realtimeMs: 99_000) == nil)
        var done = fresh()
        #expect(done.finish(endReason: EndReason.trackDone, realtimeMs: 99_000) == nil)
        var skipped = fresh()
        let skip = skipped.finish(endReason: EndReason.next, realtimeMs: 12_000)
        #expect(skip?.playedMs == 0)
        #expect(skip.map { $0.flags & EventFlags.neverAudible != 0 } == true)
        var failed = fresh()
        #expect(failed.finish(endReason: EndReason.error, realtimeMs: 12_000) != nil)
    }

    @Test func seeksBecomeReplayAndSeekBackOnlyAfterThirtySecondsOfListening() {
        let ctx = context("Dreams", "Fleetwood Mac")
        var early = OpenPlay(songId: "s1", context: ctx, startedAtEpochMs: 0, tzOffsetMin: 0, durationMs: 200_000,
                             isPlaying: true, realtimeMs: 0)
        early.seek(fromPositionMs: 20_000, toPositionMs: 0, realtimeMs: 20_000)
        #expect(early.flags == 0)
        var replay = early
        replay.seek(fromPositionMs: 45_000, toPositionMs: 1_000, realtimeMs: 45_000)
        #expect(replay.flags == EventFlags.replayed)
        var back = early
        back.seek(fromPositionMs: 90_000, toPositionMs: 70_000, realtimeMs: 45_000)
        #expect(back.flags == EventFlags.seekBack)
        var forward = early
        forward.seek(fromPositionMs: 40_000, toPositionMs: 90_000, realtimeMs: 45_000)
        #expect(forward.flags == 0)
        early.mark(EventFlags.likedDuring)
        #expect(early.flags == EventFlags.likedDuring)
    }

    @Test func aSongsFactsAndAContextsFactsAgree() {
        let song = testSong("s1", title: "Dreams (2004 Remaster)", artist: "Fleetwood Mac, Someone", duration: 257_000,
                            spotifyId: "4uLU6hMCjMI75M1A2tKUQC",
                            artists: [ArtistRef(id: 1, name: "Fleetwood Mac", isPrimary: true),
                                      ArtistRef(id: 2, name: "Someone", isPrimary: false)])
        let fromSong = TrackCatalog.facts(of: song)
        let ctx = PlayContext.of(song: song, inLibrary: true, videoId: nil, tag: nil, startReason: StartReason.tap,
                                 shuffle: false, repeatOne: false)
        let fromContext = TrackCatalog.facts(of: ctx, durationMs: 257_000)
        #expect(fromSong?.keyAtWrite == "s:4uLU6hMCjMI75M1A2tKUQC")
        #expect(fromContext?.keyAtWrite == fromSong?.keyAtWrite)
        #expect(fromContext?.keys.n == fromSong?.keys.n)
        #expect(fromContext?.primaryArtist == "Fleetwood Mac")
        #expect(fromContext?.otherArtists == ["Someone"])
        // A YouTube Music import carries a synthetic id, which is not a Spotify key.
        var imported = song
        imported.spotifyId = "0123456789abcdef012345"
        #expect(TrackCatalog.facts(of: imported)?.keys.s == nil)
        #expect(TrackCatalog.isSyntheticId("0123456789abcdef012345"))
        #expect(!TrackCatalog.isSyntheticId("4uLU6hMCjMI75M1A2tKUQC"))
        #expect(TrackCatalog.videoId(ofSongId: "yt:abc") == "abc")
        #expect(TrackCatalog.videoId(ofSongId: "abc") == nil)
        // A track from outside the library resolves by its audio id.
        let outside = PlayContext(title: "Sara", artistDisplay: "Stevie Nicks", artists: ["Stevie Nicks"], videoId: "v9",
                                  inLibrary: false)
        #expect(TrackCatalog.facts(of: outside, durationMs: 0)?.keyAtWrite == "y:v9")
    }
}

@Suite("Brain migration")
struct BrainMigrationTests {
    private func resolved(_ id: String, rid: Int64, aid: Int64 = 9, duration: Int32 = 200_000) -> (BrainKey, ResolvedTrack) {
        (BrainKey(id), ResolvedTrack(rid: rid, primaryAid: aid, key: "n:artist|\(id)|0", durationMs: duration))
    }

    @Test func theCopyWritesOneMigratedEventPerOldPlayWithTheFactsItHasAndNoMore() {
        let rows = [PlaybackEvent(songId: "a", timestamp: 100_000, durationMs: 60_000),
                    PlaybackEvent(songId: "gone", timestamp: 200_000, durationMs: 60_000),
                    PlaybackEvent(songId: "a", timestamp: 0, durationMs: 60_000),
                    PlaybackEvent(songId: "b", timestamp: 400_000, durationMs: 30_000, endTimestamp: 390_000)]
        let map = Dictionary(uniqueKeysWithValues: [resolved("a", rid: 11), resolved("b", rid: 12, duration: 0)])
        let events = LegacyMigration.events(rows: rows, cutoffMs: 1_000_000, resolved: map, identityAt: { _ in nil })
        #expect(events.count == 2)
        #expect(events[0].origin == Origin.migratedHistory)
        #expect(events[0].startedAtMs == 40_000)
        #expect(events[0].playedMs == 60_000)
        #expect(events[0].durationMs == 200_000)
        #expect(events[0].startReason == StartReason.unknown && events[0].endReason == EndReason.unknown)
        #expect(events[0].surface == Surface.unknown && events[0].tzOffsetMin == PlayEvent.tzUnknown)
        #expect(events[1].startedAtMs == 360_000)
        #expect(events[1].durationMs == 0)
    }

    @Test func playsFromAfterTheBrainsFirstUseAreNotCopied() {
        let rows = [PlaybackEvent(songId: "a", timestamp: 100_000, durationMs: 60_000),
                    PlaybackEvent(songId: "a", timestamp: 500_000, durationMs: 60_000)]
        let map = Dictionary(uniqueKeysWithValues: [resolved("a", rid: 11)])
        let events = LegacyMigration.events(rows: rows, cutoffMs: 500_000, resolved: map, identityAt: { _ in nil })
        #expect(events.map(\.startedAtMs) == [40_000])
    }

    @Test func theCopyIsIdempotentAndTwoPlaysInTheSameMillisecondKeepBoth() {
        let rows = [PlaybackEvent(songId: "a", timestamp: 100_000, durationMs: 60_000),
                    PlaybackEvent(songId: "b", timestamp: 100_000, durationMs: 60_000),
                    PlaybackEvent(songId: "a", timestamp: 100_000, durationMs: 60_000)]
        let map = Dictionary(uniqueKeysWithValues: [resolved("a", rid: 11), resolved("b", rid: 12)])
        let first = LegacyMigration.events(rows: rows, cutoffMs: 1_000_000, resolved: map, identityAt: { _ in nil })
        // The same row twice is the same play: one id. Another song at the same instant gets its own.
        #expect(Set(first.map(\.eventId)).count == 2)
        #expect(first[0].eventId == first[2].eventId)
        var stored: [Int64: String] = [:]
        for e in first { stored[e.eventId] = PlayEvent.identityOf(origin: e.origin, keyAtWrite: e.keyAtWrite) }
        let again = LegacyMigration.events(rows: rows, cutoffMs: 1_000_000, resolved: map, identityAt: { stored[$0] })
        #expect(again.map(\.eventId) == first.map(\.eventId))
    }

    @Test func importedPlaysBecomeEvents() {
        let plays = [
            ImportedPlay(source: .spotifyExport, timestampMs: 500_000, title: "Dreams", artist: "Fleetwood Mac",
                         spotifyTrackId: "4uLU6hMCjMI75M1A2tKUQC", msPlayed: 200_000, reasonEnd: "trackdone"),
            ImportedPlay(source: .spotifyExport, timestampMs: 900_000, title: "Dreams", artist: "Fleetwood Mac",
                         spotifyTrackId: "4uLU6hMCjMI75M1A2tKUQC", msPlayed: 4_000, skipped: true, reasonEnd: "fwdbtn"),
            ImportedPlay(source: .ytmusic, timestampMs: 700_000, title: "Sara", artist: "Stevie Nicks", videoId: "v2"),
            ImportedPlay(source: .spotifyAPI, timestampMs: 800_000, title: "", artist: ""),
        ]
        var map: [BrainKey: ResolvedTrack] = [:]
        for p in plays.prefix(3) {
            guard let keys = ImportedPlayAdapter.keys(p) else { continue }
            map[BrainKey(ImportedPlayAdapter.cacheKey(p))] = ResolvedTrack(rid: p.videoId == nil ? 11 : 12, primaryAid: 5, key: keys.key)
        }
        #expect(ImportedPlayAdapter.keys(plays[3]) == nil)
        let events = ImportedPlayAdapter.events(plays: plays, resolved: map, durationOfRid: { $0 == 11 ? 257_000 : 0 })
        #expect(events.count == 3)
        #expect(events[0].origin == Origin.importSpotify && events[0].endReason == EndReason.trackDone)
        #expect(events[0].startedAtMs == 300_000 && events[0].playedMs == 200_000 && events[0].durationMs == 257_000)
        #expect(events[0].keyAtWrite == "s:4uLU6hMCjMI75M1A2tKUQC")
        #expect(events[1].endReason == EndReason.next && events[1].playedMs == 4_000)
        // No `ms_played`: -1, and the start is the imported time itself.
        #expect(events[2].origin == Origin.importYtm && events[2].playedMs == -1 && events[2].startedAtMs == 700_000)
        #expect(events[2].endReason == EndReason.unknown && events[2].durationMs == 0)
        #expect(events[2].keyAtWrite == "y:v2")
    }

    private func event(_ rid: Int64, start: Int64, played: Int32 = 200_000, origin: Int32 = Origin.live) -> PlayEvent {
        PlayEvent(eventId: PlayEvent.mintId(startedAtMs: start, origin: origin, keyAtWrite: "n:t|\(rid)", identityAt: { _ in nil }),
                  origin: origin, rid: rid, primaryAid: 100 + rid, keyAtWrite: "n:t|\(rid)", startedAtMs: start,
                  playedMs: played, durationMs: 200_000, endReason: EndReason.trackDone, sessionId: 1)
    }

    @Test func anImportedPlayThatIsTheSameListenAsAStoredOneIsDropped() {
        let now: Int64 = 10_000_000_000
        let stored = [event(1, start: 1_000_000)]
        let imported = [event(1, start: 1_000_000 + 60_000, origin: Origin.importSpotify),      // ends 60 s later: the same listen
                        event(1, start: 1_000_000 + 600_000, origin: Origin.importSpotify),     // another listen
                        event(2, start: 1_000_000 + 60_000, origin: Origin.importSpotify)]      // another recording
        let result = ReplayMerger.rebuild(stored: stored, imported: imported, facts: .empty, nowMs: now, survivorOf: { $0 })
        #expect(result.importedDropped == 1)
        #expect(result.importedUsed == 2)
        #expect(result.state.completions[1] == 2)
        #expect(result.state.completions[2] == 1)
    }

    @Test func aRebuildIsTheSameWhateverOrderTheImportsArriveInAndLateEventsLandWhereTheyBelong() {
        let now: Int64 = 20_000_000_000
        let stored = [event(1, start: 9_000_000_000), event(2, start: 9_500_000_000)]
        // Imports older than every live play.
        let imported = (0..<20).map { event(Int64(3 + $0 % 4), start: 1_000_000_000 + Int64($0) * 7_000_000, origin: Origin.importYtm) }
        let a = ReplayMerger.rebuild(stored: stored, imported: imported, facts: .empty, nowMs: now, survivorOf: { $0 })
        let b = ReplayMerger.rebuild(stored: stored, imported: imported.reversed(), facts: .empty, nowMs: now, survivorOf: { $0 })
        #expect(a.state.rows() == b.state.rows())
        #expect(a.state.newestMs == 9_500_000_000)
        // A play recorded while the rebuild ran is told apart by its id.
        #expect(a.recentEventIds.isEmpty)
        let recent = ReplayMerger.rebuild(stored: stored, imported: [], facts: .empty, nowMs: 9_500_000_000 + 1_000,
                                          survivorOf: { $0 })
        // Only plays that started in the rebuild's last day are told apart by id.
        #expect(recent.recentEventIds == [stored[1].eventId])
    }

    @Test func aClockJumpAndMergedRecordings() {
        // Events from the future are clamped to now.
        let now: Int64 = 5_000_000_000
        let future = [event(1, start: 4_000_000_000), event(2, start: 90_000_000_000)]
        let clamped = ReplayMerger.rebuild(stored: future, imported: [], facts: .empty, nowMs: now, survivorOf: { $0 })
        #expect(clamped.state.newestMs == now)
        #expect(!Affinity.clockJumpedBack(clamped.state, nowMs: now))
        // A merged recording is folded into its survivor.
        let merged = ReplayMerger.rebuild(stored: [event(1, start: 1_000_000_000), event(7, start: 2_000_000_000)], imported: [],
                                          facts: .empty, nowMs: now, survivorOf: { $0 == 7 ? 1 : $0 })
        #expect(merged.state.completions[1] == 2)
        #expect(merged.state.completions[7] == nil)
    }

    @Test func factsFromTheLibraryTheTopListsAndTheTasteAdjustments() {
        let library = [librarySong("a", "Dreams", "Fleetwood Mac", favorite: true), librarySong("b", "Sara", "Stevie Nicks")]
        let taste = ExternalTasteSnapshot(
            topTracks: [.init(range: .shortTerm, rank: 0, title: "Sara", artist: "Stevie Nicks", spotifyTrackId: "sp")],
            topArtists: [.init(range: .shortTerm, rank: 0, name: "Fleetwood Mac"), .init(range: .shortTerm, rank: 1, name: "Nobody"),
                         .init(range: .longTerm, rank: 0, name: "Fleetwood Mac")],
            followedArtists: ["Stevie Nicks"])
        let adjustments = [
            TasteAdjustment(kind: .boost, strength: 3, targetType: .artist, key: "stevie nicks", label: "Stevie Nicks",
                            reason: "", source: .user, createdMs: 0),
            TasteAdjustment(kind: .reduce, strength: 1, targetType: .song, key: TasteKey.recording(library[0]), label: "Dreams",
                            reason: "", source: .user, createdMs: 0),
            TasteAdjustment(kind: .block, strength: 1, targetType: .artist, key: "x", label: "Blocked", reason: "",
                            source: .user, createdMs: 0),
            TasteAdjustment(kind: .boost, strength: 1, targetType: .genre, key: "rock", label: "Rock", reason: "",
                            source: .user, createdMs: 0),
        ]
        let names = LibraryFactsBuilder.names(library: library, taste: taste, adjustments: adjustments)
        #expect(names.artists == ["Fleetwood Mac", "Nobody", "Stevie Nicks"])
        #expect(names.topTracks.count == 1)
        let aidByName: [BrainKey: Int64] = [BrainKey("Fleetwood Mac"): 1, BrainKey("Stevie Nicks"): 2]
        let facts = LibraryFactsBuilder.build(library: library, ridBySongId: [BrainKey("a"): 11, BrainKey("b"): 12], taste: taste,
                                              adjustments: adjustments, aidByName: aidByName, topTrackRids: [12])
        #expect(facts.liked.map(\.rid) == [11])
        #expect(facts.liked.first?.primaryAid == 1)
        // An artist with no id is left out; the list size is the range's own.
        #expect(facts.topArtists.map(\.aid) == [1, 1])
        #expect(facts.topArtists.map(\.listSize) == [2, 1])
        #expect(facts.topTracks.first?.rid == 12 && facts.topTracks.first?.primaryAid == 2)
        #expect(facts.followed == [2])
        #expect(facts.adjustments.count == 2)
        #expect(facts.adjustments[0].family == Family.artist && facts.adjustments[0].more && facts.adjustments[0].strength == 3)
        #expect(facts.adjustments[1].family == Family.track && facts.adjustments[1].key == 11 && !facts.adjustments[1].more)
    }

    @Test func theFirstUseTriggersTheRebuildOnceAndPlaysRecordedMeanwhileAreNotLostOrDoubled() async {
        let library = [librarySong("a", "Dreams", "Fleetwood Mac", spotifyId: "4uLU6hMCjMI75M1A2tKUQC", favorite: true),
                       librarySong("b", "Sara", "Stevie Nicks")]
        let old = Harness.t0 - 5 * 86_400_000
        let history = [PlaybackEvent(songId: "a", timestamp: old, durationMs: 200_000),
                       PlaybackEvent(songId: "b", timestamp: old + 300_000, durationMs: 9_000),
                       PlaybackEvent(songId: "missing", timestamp: old + 600_000, durationMs: 200_000)]
        let imported = [ImportedPlay(source: .spotifyExport, timestampMs: old - 86_400_000, title: "Dreams", artist: "Fleetwood Mac",
                                     spotifyTrackId: "4uLU6hMCjMI75M1A2tKUQC", msPlayed: 200_000, reasonEnd: "trackdone")]
        let sources = BrainEngine.Sources(
            library: { library }, history: { history }, importSignature: { "1|x" },
            imported: { (imported, ExternalTasteSnapshot(followedArtists: ["Stevie Nicks"])) }, adjustments: { [] })
        let h = Harness(sources: sources)
        defer { h.cleanUp() }
        // The first play that ends loads the state and starts the rebuild.
        let live = play("a", PlayContext.of(song: library[0], inLibrary: true, videoId: nil, tag: nil, startReason: StartReason.tap,
                                            shuffle: false, repeatOne: false),
                        at: Harness.t0, played: 200_000)
        #expect(await h.engine.record(live) != nil)
        await h.engine.awaitRebuild()
        let events = await h.engine.events()
        // Two migrated plays (the third song is gone) and the live one; the import is not copied.
        #expect(events.count == 3)
        #expect(events.filter { $0.origin == Origin.migratedHistory }.count == 2)
        #expect(await h.engine.storedValue(BrainEventLog.keySpecVersion) == String(Brain.specVersion))
        #expect(await h.engine.storedValue(BrainEventLog.keyImportCount) == "1|x")
        #expect(await h.engine.storedValue(BrainEventLog.keyHistoryMigrated) != nil)
        let rows = await h.engine.affinityRows()
        let rid = events.first { $0.origin == Origin.live }!.rid
        // "Dreams": the migrated play, the imported play and the live one, each exactly once.
        #expect(rows.first { $0.family == Family.completions && $0.key == rid }?.counter.posQ == 3)
        // The favourite and the followed artist are pseudo-counts.
        #expect(rows.contains { $0.family == Family.priorBase + Family.track && $0.key == rid })
        #expect(rows.filter { $0.family == Family.priorBase + Family.artist }.count == 2)

        // The next process: nothing to do, and the state it loads is the one that was stored.
        let next = Harness(sources: sources, directory: h.directory, now: Harness.t0 + 60_000)
        #expect(await next.engine.affinityRows() == rows)
        await next.engine.awaitRebuild()
        #expect(await next.engine.eventCount() == 3)
        #expect(await next.engine.affinityRows() == rows)
        // A changed import asks for another rebuild; it adds no event.
        let changed = BrainEngine.Sources(library: { library }, history: { history }, importSignature: { "2|y" },
                                          imported: { (imported + imported, ExternalTasteSnapshot()) }, adjustments: { [] })
        let third = Harness(sources: changed, directory: h.directory, now: Harness.t0 + 120_000)
        _ = await third.engine.affinityRows()
        await third.engine.awaitRebuild()
        #expect(await third.engine.eventCount() == 3)
        #expect(await third.engine.storedValue(BrainEventLog.keyImportCount) == "2|y")
    }
}

@Suite("Brain autoplay planning")
struct BrainAutoplayPlanningTests {
    private func entry(_ id: String, rid: Int64, aid: Int64, inLibrary: Bool = false, rank: Int32 = 1) -> AutoplayPoolEntry {
        AutoplayPoolEntry(
            candidate: AutoplayPolicy.Candidate(mediaId: id, rid: rid, artistKey: "a\(aid)", albumKey: nil, durationMs: 200_000,
                                                versionFlags: 0, officialAudio: true, inLibrary: inLibrary,
                                                arm: inLibrary ? Arm.deep : Arm.radio, radioRank: rank),
            librarySong: nil, engineTrack: nil, whyArtist: "Anchor Artist", primaryArtist: "Artist \(aid)",
            brain: Candidate(rid: rid, aid: aid, inLibrary: inLibrary))
    }

    @Test func rescoreStartLeavesTheCurrentTrackAndTheWarmedOnesAlone() {
        // Queue: 0 current (listener), 1..5 engine.
        func start(size: Int, current: Int, warmed: Int, listenerAt: Set<Int> = [0]) -> Int {
            AutoplayPolicy.rescoreStart(queueSize: size, currentAbsoluteIndex: current, warmedAhead: warmed,
                                        engineOwned: { !listenerAt.contains($0) })
        }
        #expect(start(size: 6, current: 0, warmed: 1) == 2)
        #expect(start(size: 6, current: 0, warmed: 2) == 3)
        #expect(start(size: 6, current: 0, warmed: 0) == 2)
        #expect(start(size: 2, current: 0, warmed: 1) == -1)
        #expect(start(size: 0, current: -1, warmed: 1) == -1)
        // A track the listener queued behind engine items: only what follows it is the engine's.
        #expect(start(size: 6, current: 0, warmed: 1, listenerAt: [0, 3]) == 4)
        #expect(start(size: 6, current: 0, warmed: 1, listenerAt: [0, 5]) == -1)
        #expect(AutoplayPolicy.warmedAhead(unmeteredWifi: true) == 2)
        #expect(AutoplayPolicy.warmedAhead(unmeteredWifi: false) == 1)
        // One anchor only, for the time before the session has any.
        #expect(AutoplayPolicy.anchorIndices(currentAbsoluteIndex: 2, queueSize: 3, engineOwned: { _ in false },
                                             mediaIdAt: { "m\($0)" }, max: 1) == [2])
    }

    @Test func planInputsKeepWhatIsQueuedOutAndCountTheListenersOwnItems() {
        let served = [BrainKey("e1"): entry("e1", rid: 101, aid: 1), BrainKey("e2"): entry("e2", rid: 102, aid: 2)]
        let pool = [entry("p1", rid: 201, aid: 3), entry("p2", rid: 202, aid: 4), entry("lib", rid: 203, aid: 5, inLibrary: true),
                    entry("played", rid: 204, aid: 6), entry("e1", rid: 101, aid: 1)]
        let queue = [AutoplayQueueItem(mediaId: "lib", engineOwned: false), AutoplayQueueItem(mediaId: "e1", engineOwned: true),
                     AutoplayQueueItem(mediaId: "e2", engineOwned: true)]
        // A top-up: nothing of the queue is replaced.
        let top = AutoplayPlanning.inputs(queue: queue, tailStart: queue.count, tailEntries: [], pool: pool, served: served,
                                          recentlyPlayed: [BrainKey("played")], seeds: [], nowMs: 1_000, tzOffsetMin: 0, batch: 3)
        #expect(top.inputs.candidates.map(\.rid) == [201, 202])
        #expect(top.inputs.excludedRids == [101, 102, 203, 204])
        #expect(top.inputs.prior.map(\.rid) == [101, 102])
        #expect(top.inputs.nuMultiplier == 1.0)
        // A re-score of the last engine item: it competes with the pool for its own slot.
        let tail = AutoplayPlanning.tailEntries(queue: queue, start: 2, served: served)
        #expect(tail?.map(\.candidate.mediaId) == ["e2"])
        let patch = AutoplayPlanning.inputs(queue: queue, tailStart: 2, tailEntries: tail ?? [], pool: pool, served: served,
                                            recentlyPlayed: [], seeds: [], nowMs: 1_000, tzOffsetMin: 0, batch: 3)
        #expect(patch.inputs.candidates.map(\.rid) == [102, 201, 202, 204])
        #expect(patch.inputs.prior.map(\.rid) == [101])
        // An engine item this process did not serve: the tail is left alone.
        #expect(AutoplayPlanning.tailEntries(queue: queue + [AutoplayQueueItem(mediaId: "old", engineOwned: true)], start: 2,
                                             served: served) == nil)
        // After an album autoplay stays closer to home.
        let album = AutoplayPlanning.inputs(queue: [AutoplayQueueItem(mediaId: "x", engineOwned: false)] + queue,
                                            tailStart: 4, tailEntries: [], pool: pool, served: served, recentlyPlayed: [],
                                            seeds: [], nowMs: 1_000, tzOffsetMin: 0, batch: 3)
        #expect(album.inputs.nuMultiplier == 0.8)
    }

    @Test func aPlanOnTheEngineIsRadioOrderForANewListenerAndASkippedArtistLeavesTheTail() async {
        let h = Harness()
        defer { h.cleanUp() }
        let seedRid: Int64 = 1
        var pool: [AutoplayPoolEntry] = []
        for n in 0..<12 {
            let rid = Int64(100 + n)
            let aid = Int64(10 + n)
            pool.append(entry("p\(n)", rid: rid, aid: aid, rank: Int32(n + 1)))
        }
        let poolRids: [Int64] = pool.map { $0.candidate.rid }
        let seeds = [Retrieval.SeedList(seedRid: seedRid, seedAid: 5, rids: poolRids)]
        let queue = [AutoplayQueueItem(mediaId: "seed", engineOwned: false)]
        let context = AutoplayPlanning.inputs(queue: queue, tailStart: 1, tailEntries: [], pool: pool, served: [:],
                                              recentlyPlayed: [], seeds: seeds, nowMs: Harness.t0, tzOffsetMin: 0, batch: 1)
        let firstPlan: StationPlanner.Plan? = await h.engine.plan(context.inputs, count: 5, bridge: true, tail: nil)
        guard let plan = firstPlan else {
            Issue.record("no plan")
            return
        }
        // No history at all: the radio's own order.
        let planned: [Int64] = plan.picks.map { $0.rid }
        #expect(planned == [100, 101, 102, 103, 104])
        let items: [AutoplayPlannedItem] = AutoplayPlanning.items(plan: plan, context: context, surfaceId: "seed",
                                                                  artistNames: [5: "Seed Artist"], likedTitles: [:])
        let itemIds: [String] = items.map { $0.entry.candidate.mediaId }
        #expect(itemIds == ["p0", "p1", "p2", "p3", "p4"])
        #expect(items[0].tag.arm == "RADIO" && items[0].tag.isEngineOwned)
        #expect(items[0].tag.whyKey == "radio_fans" && items[0].tag.whyArg == "Seed Artist")
        #expect(items[0].tag.recId == (Harness.t0 << 8) | 1)
        let slots: [Int] = items.map { $0.tag.slot }
        #expect(slots == [0, 1, 2, 3, 4])
        #expect(items[2].tag.radioRank == 3 && items[2].tag.primaryArtist == "Artist 12")

        // The listener skips p3's artist hard, twice: it is gone from a re-scored tail.
        var served: [BrainKey: AutoplayPoolEntry] = [:]
        for item in items { served[BrainKey(item.entry.candidate.mediaId)] = item.entry }
        var t = Harness.t0
        for n in 0..<2 {
            let ctx = PlayContext(title: "Skipped \(n)", artistDisplay: "Artist 13", artists: ["Artist 13"], inLibrary: false,
                                  startReason: StartReason.autoplay, tag: BrainItemTag(surface: "autoplay", arm: "RADIO"))
            _ = await h.engine.record(play("x\(n)", ctx, at: t, played: 2_000, end: EndReason.next))
            t += 400_000
        }
        let aid13 = await h.repository.resolveArtistNames(["Artist 13"])[0]
        var poolWithIds = pool
        poolWithIds[3].brain?.aid = aid13
        served[BrainKey("p3")] = poolWithIds[3]
        let fullQueue = queue + items.map { AutoplayQueueItem(mediaId: $0.entry.candidate.mediaId, engineOwned: true) }
        let start = AutoplayPolicy.rescoreStart(queueSize: fullQueue.count, currentAbsoluteIndex: 0, warmedAhead: 1,
                                                engineOwned: { fullQueue[$0].engineOwned })
        #expect(start == 2)
        guard let tail: [AutoplayPoolEntry] = AutoplayPlanning.tailEntries(queue: fullQueue, start: start, served: served) else {
            Issue.record("no tail")
            return
        }
        let remaining: [AutoplayPoolEntry] = poolWithIds.filter { served[BrainKey($0.candidate.mediaId)] == nil }
        let patchContext = AutoplayPlanning.inputs(queue: fullQueue, tailStart: start, tailEntries: tail, pool: remaining,
                                                   served: served, recentlyPlayed: [], seeds: seeds, nowMs: t, tzOffsetMin: 0,
                                                   batch: 2)
        var tailRids: [Int64] = []
        for item in tail { tailRids.append(item.brain?.rid ?? 0) }
        #expect(tailRids.contains(103))
        let patched: StationPlanner.Plan? = await h.engine.plan(patchContext.inputs, count: tail.count, bridge: false,
                                                                tail: tailRids)
        guard let patch = patched else {
            Issue.record("the tail was left alone")
            return
        }
        let newTail: [Int64] = patch.picks.map { $0.rid }
        #expect(newTail.count == tail.count)
        #expect(!newTail.contains(103))
        // Nothing changed since: the same question again answers "leave it".
        let again: StationPlanner.Plan? = await h.engine.plan(patchContext.inputs, count: newTail.count, bridge: false,
                                                              tail: newTail)
        #expect(again == nil)
    }
}

extension StationPlanner.Plan: Equatable {
    public static func == (lhs: StationPlanner.Plan, rhs: StationPlanner.Plan) -> Bool {
        lhs.picks.map(\.rid) == rhs.picks.map(\.rid) && lhs.poolSize == rhs.poolSize
    }
}

extension Reaction: Equatable {
    public static func == (lhs: Reaction, rhs: Reaction) -> Bool { lhs.event.eventId == rhs.event.eventId }
}
