import PixlAudioCore
import PixlLibrary
import PixlModel
import XCTest
@testable import PixlAudio

/// The 2026-10-18 features: blocked artists in the queue and the store, Find in playlist's model, the gesture and
/// Music Haptics settings, and their place in a settings backup.
@MainActor
final class IosFeaturesTests: XCTestCase {
    private func song(_ i: Int, artist: String = "A", artistId: Int64 = 1) -> Song {
        Song(id: "s\(i)", title: "Song \(i)", artist: artist, artistId: artistId,
             artists: [ArtistRef(id: artistId, name: artist, isPrimary: true)], album: "Album", albumId: 1, path: "",
             contentUriString: "", albumArtUriString: nil, duration: 1000, mimeType: nil, bitrate: nil, sampleRate: nil)
    }

    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "pixlaudio.test.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func blocked(_ names: String...) -> BlockedArtistMatcher {
        BlockedArtistMatcher(entries: names.enumerated().map { BlockedArtist(artistId: Int64($0.offset + 100), name: $0.element) })
    }

    // MARK: Blocked artists in the queue

    func testQueueSkipsBlockedSongsWhenMovingOn() {
        var queue = PlaybackQueue()
        let list = [song(0), song(1, artist: "Bad", artistId: 2), song(2, artist: "Bad", artistId: 2), song(3), song(4)]
        queue.replace(with: list, startIndex: 0, shuffle: false)
        queue.blocklist = BlockedArtistMatcher(entries: [BlockedArtist(artistId: 2, name: "Bad")])
        XCTAssertEqual(queue.nextIndexForSkip, 3)
        XCTAssertEqual(queue.nextIndexForAutoAdvance, 3)
        XCTAssertEqual(queue.crossfadeTargetIndex, 3)
        queue.setCurrentIndex(3)
        XCTAssertEqual(queue.previousIndex, 0)
    }

    func testTheCurrentBlockedSongIsLeftAlone() {
        var queue = PlaybackQueue()
        queue.replace(with: [song(0, artist: "Bad", artistId: 2), song(1)], startIndex: 0, shuffle: false)
        queue.blocklist = BlockedArtistMatcher(entries: [BlockedArtist(artistId: 2, name: "Bad")])
        XCTAssertEqual(queue.current?.song.id, "s0")
        XCTAssertEqual(queue.nextIndexForSkip, 1)
        queue.repeatMode = .one
        XCTAssertEqual(queue.nextIndexForAutoAdvance, 0, "repeat-one keeps the song the person chose")
    }

    func testTheQueueEndsWhenEverythingAfterIsBlocked() {
        var queue = PlaybackQueue()
        queue.replace(with: [song(0), song(1, artist: "Bad", artistId: 2)], startIndex: 0, shuffle: false)
        queue.blocklist = BlockedArtistMatcher(entries: [BlockedArtist(artistId: 2, name: "Bad")])
        XCTAssertNil(queue.nextIndexForAutoAdvance)
        XCTAssertNil(queue.nextIndexForSkip)
        queue.repeatMode = .all
        XCTAssertEqual(queue.nextIndexForSkip, 0, "wrapping finds the first song that is not blocked")
    }

    func testAnEmptyBlocklistChangesNothing() {
        var queue = PlaybackQueue()
        queue.replace(with: [song(0), song(1), song(2)], startIndex: 2, shuffle: false)
        XCTAssertNil(queue.nextIndexForSkip)
        queue.repeatMode = .all
        XCTAssertEqual(queue.nextIndexForSkip, 0)
        XCTAssertEqual(queue.previousIndex, 1)
    }

    func testPlayStartsOnTheFirstSongThatIsNotBlocked() {
        let playback = PlaybackStore(engine: DemoPlaybackEngine())
        playback.setBlocklist(blocked("Bad"))
        let list = [song(0, artist: "Bad", artistId: 100), song(1, artist: "Bad", artistId: 100), song(2), song(3)]
        playback.play(list[0], in: list)
        XCTAssertEqual(playback.currentIndex, 2)
        playback.play(list[0], in: list, allowsBlockedStart: true)
        XCTAssertEqual(playback.currentIndex, 0)
    }

    func testPlayDoesNothingWhenEverySongIsBlockedButOneSongPlaysAsAsked() {
        let playback = PlaybackStore(engine: DemoPlaybackEngine())
        playback.setBlocklist(blocked("Bad"))
        let list = [song(0, artist: "Bad", artistId: 100), song(1, artist: "Bad", artistId: 100)]
        playback.play(list)
        XCTAssertNil(playback.currentIndex)
        playback.play(list[0])
        XCTAssertEqual(playback.currentIndex, 0)
    }

    func testShuffleLeavesBlockedSongsOut() {
        let playback = PlaybackStore(engine: DemoPlaybackEngine())
        playback.setBlocklist(blocked("Bad"))
        let list = (0..<20).map { i in i % 2 == 0 ? song(i, artist: "Bad", artistId: 100) : song(i) }
        playback.playShuffled(list)
        XCTAssertEqual(playback.queue.count, 10)
        XCTAssertTrue(playback.queue.allSatisfy { !playback.isBlocked($0) })
    }

    // MARK: The store

    func testTheStorePersistsAndReloads() {
        let defaults = freshDefaults()
        let store = BlockedArtistsStore(defaults: defaults)
        XCTAssertTrue(store.isEmpty)
        var told = 0
        store.onChange = { _ in told += 1 }
        store.block(artistId: 7, name: "Someone")
        store.block(artistId: 8, name: "Another")
        store.block(artistId: 9, name: "someone")
        XCTAssertEqual(store.count, 2, "the same name is one entry")
        XCTAssertEqual(told, 2)
        XCTAssertTrue(store.isBlocked(song(1, artist: "Someone", artistId: 7)))
        XCTAssertTrue(store.isBlocked(song(1, artist: "x", artistId: 55).with(artists: [ArtistRef(id: 55, name: "SOMEONE")])))
        let again = BlockedArtistsStore(defaults: defaults)
        XCTAssertEqual(again.entries.map(\.name), ["Another", "Someone"])
        again.unblock(artistId: 7, name: "Someone")
        XCTAssertEqual(again.count, 1)
        again.unblockAll()
        XCTAssertTrue(again.isEmpty)
        XCTAssertNil(defaults.string(forKey: PreferenceKeys.blockedArtists))
    }

    func testReloadAfterARestoreFollowsTheDefaults() {
        let defaults = freshDefaults()
        let store = BlockedArtistsStore(defaults: defaults)
        store.block(artistId: 1, name: "One")
        defaults.set(BlockedArtistCodec.encode([BlockedArtist(artistId: 2, name: "Two")]), forKey: PreferenceKeys.blockedArtists)
        store.reloadFromDefaults()
        XCTAssertEqual(store.entries.map(\.name), ["Two"])
    }

    func testTappingABlockedSongWaitsForPlayAnyway() {
        let playback = PlaybackStore(engine: DemoPlaybackEngine())
        let store = BlockedArtistsStore(defaults: freshDefaults())
        store.block(artistId: 100, name: "Bad")
        playback.setBlocklist(store.matcher)
        let list = [song(0), song(1, artist: "Bad", artistId: 100), song(2)]
        store.playTapped(list[0], in: list, using: playback)
        XCTAssertNil(store.pendingPlay)
        XCTAssertEqual(playback.currentIndex, 0)
        store.playTapped(list[1], in: list, using: playback)
        XCTAssertEqual(store.pendingPlay?.song.id, "s1")
        XCTAssertEqual(playback.currentIndex, 0, "nothing plays until the answer")
        store.confirmPlay(store.pendingPlay!, using: playback)
        XCTAssertNil(store.pendingPlay)
        XCTAssertEqual(playback.currentIndex, 1)
    }

    func testBlockingThePlayingArtistMovesPlaybackOn() {
        let playback = PlaybackStore(engine: DemoPlaybackEngine())
        let list = [song(0, artist: "Bad", artistId: 100), song(1), song(2)]
        playback.play(list)
        // The demo engine reports its events asynchronously: wait for the store to see the song playing.
        let seen = expectation(description: "playing")
        Task {
            for _ in 0..<50 where !playback.isPlaying { try? await Task.sleep(for: .milliseconds(20)) }
            seen.fulfill()
        }
        wait(for: [seen], timeout: 3)
        XCTAssertTrue(playback.isPlaying)
        playback.setBlocklist(blocked("Bad"))
        let moved = expectation(description: "moved on")
        Task {
            for _ in 0..<50 where playback.currentIndex == 0 { try? await Task.sleep(for: .milliseconds(20)) }
            moved.fulfill()
        }
        wait(for: [moved], timeout: 3)
        XCTAssertEqual(playback.currentIndex, 1)
    }

    // MARK: Settings

    func testGestureAndHapticDefaults() {
        let behavior = BehaviorSettings(defaults: freshDefaults())
        XCTAssertTrue(behavior.gesturePlayerArtworkSwipe)
        XCTAssertTrue(behavior.gesturePlayerArtworkDoubleTapLike)
        XCTAssertTrue(behavior.gesturePlayerArtworkLongPress)
        XCTAssertTrue(behavior.gestureMiniSwipeSkip)
        XCTAssertTrue(behavior.gestureMiniSwipeUpOpen)
        XCTAssertTrue(behavior.gestureMiniLongPress)
        XCTAssertTrue(behavior.gestureListSwipeQueue)
        XCTAssertFalse(behavior.musicHapticsEnabled, "Music Haptics is off by default")
        XCTAssertEqual(behavior.musicHapticsStrength, 100)
        XCTAssertEqual(behavior.musicHapticsMode, .everything)
    }

    func testSettingsPersistAndStrengthIsClamped() {
        let defaults = freshDefaults()
        let behavior = BehaviorSettings(defaults: defaults)
        behavior.gestureMiniSwipeSkip = false
        behavior.musicHapticsEnabled = true
        behavior.musicHapticsMode = .bass
        behavior.musicHapticsStrength = 999
        let again = BehaviorSettings(defaults: defaults)
        XCTAssertFalse(again.gestureMiniSwipeSkip)
        XCTAssertTrue(again.musicHapticsEnabled)
        XCTAssertEqual(again.musicHapticsMode, .bass)
        XCTAssertEqual(again.musicHapticsStrength, 200)
    }

    func testTheSettingsBackupCarriesTheNewKeys() {
        let defaults = freshDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.blocked.block(artistId: 4, name: "Someone")
        settings.behavior.gestureListSwipeQueue = false
        settings.behavior.musicHapticsEnabled = true
        settings.behavior.musicHapticsStrength = 140
        let exported = Dictionary(uniqueKeysWithValues: SettingsBackup.exportValues(defaults: defaults, keychain: { _ in nil })
            .map { ($0.key, $0.value) })
        guard case .string(let json)? = exported["blocked_artists_json"] else {
            return XCTFail("the blocked list is not exported")
        }
        XCTAssertEqual(BlockedArtistCodec.decode(json).map(\.name), ["Someone"])
        XCTAssertEqual(exported["gesture_list_swipe_queue"], .bool(false))
        XCTAssertEqual(exported["music_haptics_enabled"], .bool(true))
        XCTAssertEqual(exported["music_haptics_strength"], .int(140))
    }

    // MARK: Find in playlist

    func testFindFiltersInOrderAndClears() async throws {
        let model = ListFindModel()
        let list = [song(0), song(1, artist: "Dua Lipa", artistId: 2), song(2), song(3, artist: "Dua Lipa", artistId: 2)]
        model.setSongs(list)
        model.open()
        XCTAssertTrue(model.isOpen)
        XCTAssertNil(model.results)
        model.query = "dua"
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(model.results?.map(\.id), ["s1", "s3"])
        model.query = "zzz"
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(model.hasNoMatches)
        model.close()
        XCTAssertFalse(model.isOpen)
        XCTAssertEqual(model.query, "")
        XCTAssertNil(model.results)
    }

    func testFindFollowsAChangingList() async throws {
        let model = ListFindModel()
        model.setSongs([song(0, artist: "Dua Lipa", artistId: 2)])
        model.open()
        model.query = "dua"
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(model.results?.count, 1)
        model.setSongs([song(0, artist: "Dua Lipa", artistId: 2), song(1, artist: "Dua Lipa", artistId: 2)])
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(model.results?.count, 2)
    }
}

private extension Song {
    func with(artists: [ArtistRef]) -> Song {
        var copy = self
        copy.artists = artists
        return copy
    }
}
