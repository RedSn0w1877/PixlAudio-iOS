import Foundation
import Observation
import PixlAudioCore
import PixlModel
import XCTest
@testable import PixlAudio

/// The cloud side as a stand-in: answers what a test says and records how it was asked. A main-actor class, as the
/// real implementations may be (PixlModel's protocols are `async` throughout for exactly that).
@MainActor
private final class FakeSpatialLibrary: SpatialLibrary {
    var applied: [CloudAudioSettings] = []
    var requests: [RenditionRequest] = []
    var statuses: [RenditionKey: RenditionStatus] = [:]
    /// What `request` answers (and records as the status).
    var requestAnswer = RenditionStatus.queued
    var usageNow = CloudAudioUsage(songsReady: 2, bytes: 52_000_000)
    var removals = 0
    let hub = SpatialEventHub<SpatialLibraryEvent>()

    func apply(_ settings: CloudAudioSettings) async { applied.append(settings) }
    func localRendition(_ key: RenditionKey) async -> LocalRendition? { nil }
    func localRenditions(videoId: String) async -> [LocalRendition] { [] }
    func status(_ key: RenditionKey) async -> RenditionStatus { statuses[key] ?? RenditionStatus.none }

    func request(_ request: RenditionRequest) async -> RenditionStatus {
        requests.append(request)
        statuses[request.key] = requestAnswer
        return requestAnswer
    }

    func markPlayed(_ key: RenditionKey) async {}
    func usage() async -> CloudAudioUsage { usageNow }

    func removeAll() async -> CloudAudioUsage {
        removals += 1
        statuses.removeAll()
        usageNow = .empty
        return usageNow
    }

    func events() async -> AsyncStream<SpatialLibraryEvent> { hub.stream() }
}

/// The engine side as a stand-in: a snapshot the test moves by hand.
@MainActor
private final class FakeSpatialPlayback: SpatialPlayback {
    var applied: [CloudAudioSettings] = []
    var current = SpatialPlaybackSnapshot.idle
    let hub = SpatialEventHub<SpatialPlaybackSnapshot>()

    func apply(_ settings: CloudAudioSettings) async { applied.append(settings) }
    func snapshot() async -> SpatialPlaybackSnapshot { current }
    func events() async -> AsyncStream<SpatialPlaybackSnapshot> { hub.stream() }

    func move(to snapshot: SpatialPlaybackSnapshot) {
        current = snapshot
        hub.send(snapshot)
    }
}

/// The two facts the model follows in Cloud Studio's settings, observable as the real ones are.
@MainActor
@Observable
private final class FakeCloudSwitches {
    var builtInKeys: Bool
    var studioOn: Bool

    init(builtInKeys: Bool, studioOn: Bool) {
        self.builtInKeys = builtInKeys
        self.studioOn = studioOn
    }
}

/// Spatial audio's model without a screen: the settings round trip, and the one piece of behaviour it owns, asking the
/// library for the playing song's render when the player wants it.
@MainActor
final class SpatialAudioModelTests: XCTestCase {
    private struct Rig {
        let defaults: UserDefaults
        let library: FakeSpatialLibrary
        let playback: FakeSpatialPlayback
        let switches: FakeCloudSwitches
        let model: SpatialAudioModel
        let song: Song
    }

    private static let videoId = "J7p4bzqLvCw"

    private func makeDefaults() -> UserDefaults {
        let name = "pixlaudio.spatial.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeRig(builtInCloudKeys: Bool = true, cloudStudioOn: Bool = true, defaults: UserDefaults? = nil,
                         currentSongId: String? = "sp:1") -> Rig {
        let defaults = defaults ?? makeDefaults()
        let library = FakeSpatialLibrary()
        let playback = FakeSpatialPlayback()
        let switches = FakeCloudSwitches(builtInKeys: builtInCloudKeys, studioOn: cloudStudioOn)
        let song = Song(id: "sp:1", title: "Song", artist: "Artist", artistId: 1, album: "Album", albumId: 1, path: "",
                        contentUriString: "spotify://1", albumArtUriString: nil, duration: 202_000, mimeType: nil,
                        bitrate: nil, sampleRate: nil)
        let model = SpatialAudioModel(defaults: defaults, library: library, playback: playback,
                                      currentSong: { currentSongId == song.id ? song : nil },
                                      builtInCloudKeys: { switches.builtInKeys },
                                      cloudStudioEnabled: { switches.studioOn })
        return Rig(defaults: defaults, library: library, playback: playback, switches: switches, model: model, song: song)
    }

    /// Waits (≤ 2 s) until `condition` holds; the model's work hops through a few tasks.
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("the condition never held", file: file, line: line)
    }

    private func playing(_ profile: SpatialProfile, audible: SpatialAudible? = nil, routePasses: Bool = true) -> SpatialPlaybackSnapshot {
        SpatialPlaybackSnapshot(songId: "sp:1", videoId: Self.videoId, selection: .profile(profile),
                                output: routePasses ? .bluetooth : .phoneSpeaker, routePasses: routePasses,
                                audible: audible ?? (routePasses ? .onDevice(profile) : .stereo))
    }

    // MARK: Settings

    func testTheSettingsStartAtTheSpecsDefaults() {
        let rig = makeRig()
        XCTAssertEqual(rig.model.settings, CloudAudioSettings(builtInCloudKeys: true))
        XCTAssertEqual(rig.model.selection, .off)
        XCTAssertTrue(rig.model.settings.cloud)
        XCTAssertEqual(rig.model.status, .none)
        XCTAssertEqual(rig.model.statusLine, .none)
        XCTAssertFalse(rig.model.isActive)
        // Without built-in keys the cloud starts off.
        XCTAssertFalse(makeRig(builtInCloudKeys: false).model.settings.cloud)
    }

    func testEveryChangeIsStoredUnderTheSpecsKeyAndReadBack() {
        let rig = makeRig()
        rig.model.select(.profile(.hall))
        rig.model.setCloud(false)
        rig.model.setPrepareAhead(false)
        rig.model.setRoute(.always)
        rig.model.setStorageMB(8192)
        rig.model.setMonthlyCapUSD(nil)
        rig.model.setDailyAhead(40)
        XCTAssertEqual(rig.defaults.string(forKey: "spatial.profile"), "hall")
        XCTAssertEqual(rig.defaults.string(forKey: "spatial.route"), "always")
        XCTAssertEqual(rig.defaults.object(forKey: "spatial.cloud") as? Bool, false)
        XCTAssertEqual(rig.defaults.object(forKey: "spatial.prepareAhead") as? Bool, false)
        XCTAssertEqual(rig.defaults.integer(forKey: "cloudAudio.storageMB"), 8192)
        XCTAssertEqual(rig.defaults.double(forKey: "cloudAudio.monthlyCapUSD"), -1)
        XCTAssertEqual(rig.defaults.integer(forKey: "cloudAudio.dailyAhead"), 40)

        // A second model on the same defaults (a relaunch) reads the same settings.
        let again = makeRig(defaults: rig.defaults).model
        XCTAssertEqual(again.settings, rig.model.settings)
        XCTAssertEqual(again.selection, .profile(.hall))
        XCTAssertNil(again.settings.monthlyCapUSD)
        XCTAssertEqual(again.settings.route, .always)
    }

    func testAValueNobodyTouchedKeepsFollowingItsDefault() {
        let rig = makeRig()
        rig.model.select(.profile(.studio))
        // Only the profile was written: the cloud switch still follows the built-in keys.
        XCTAssertNil(rig.defaults.object(forKey: "spatial.cloud"))
        XCTAssertFalse(makeRig(builtInCloudKeys: false, defaults: rig.defaults).model.settings.cloud)
        // Once the person switches it, the choice stays whatever the keys do.
        rig.model.setCloud(true)
        XCTAssertTrue(makeRig(builtInCloudKeys: false, defaults: rig.defaults).model.settings.cloud)
    }

    func testNumbersAreKeptInsideTheirRanges() {
        let rig = makeRig()
        rig.model.setStorageMB(1)
        rig.model.setDailyAhead(0)
        rig.model.setMonthlyCapUSD(5_000)
        XCTAssertEqual(rig.model.settings.storageMB, 256)
        XCTAssertEqual(rig.model.settings.dailyAhead, 1)
        XCTAssertEqual(rig.model.settings.monthlyCapUSD, 200)
    }

    // MARK: The two services

    func testStartGivesBothServicesTheSettingsAndEveryLaterChangeInOrder() async {
        let rig = makeRig()
        rig.model.select(.profile(.wide))
        rig.model.start()
        await eventually { rig.library.applied.count == 1 && rig.playback.applied.count == 1 }
        XCTAssertEqual(rig.library.applied.first?.profile, .profile(.wide))
        rig.model.select(.profile(.night))
        rig.model.setPrepareAhead(false)
        rig.model.select(.off)
        await eventually { rig.library.applied.count == 4 && rig.playback.applied.count == 4 }
        XCTAssertEqual(rig.playback.applied.map(\.profile), [.profile(.wide), .profile(.night), .profile(.night), .off])
        XCTAssertEqual(rig.library.applied.map(\.prepareAhead), [true, true, false, false])
        XCTAssertEqual(rig.library.applied, rig.playback.applied)
    }

    func testThePlayingSongsRenderIsAskedForOnceWhileThePlayerWantsIt() async {
        let rig = makeRig()
        rig.model.select(.profile(.studio))
        rig.model.start()
        await eventually { rig.playback.hub.subscriberCount == 1 && rig.library.hub.subscriberCount == 1 }
        rig.playback.move(to: playing(.studio))
        await eventually { rig.library.requests.count == 1 }
        let request = rig.library.requests[0]
        XCTAssertEqual(request.key, RenditionKey(videoId: Self.videoId, profile: .studio))
        XCTAssertEqual(request.song.id, "sp:1")
        XCTAssertEqual(request.reason, .playing)
        await eventually { rig.model.libraryStatus == .queued }
        XCTAssertEqual(rig.model.status, .queued)
        XCTAssertEqual(rig.model.statusLine, .onPhoneForNow)
        XCTAssertTrue(rig.model.isActive)

        // The same snapshot again (a route flicker, say) asks for nothing new.
        rig.playback.move(to: playing(.studio))
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(rig.library.requests.count, 1)

        // The render lands and the player switches to it: the line says so, and nothing more is wanted.
        rig.library.statuses[request.key] = RenditionStatus.ready
        rig.library.hub.send(.statusChanged(request.key, RenditionStatus.ready))
        await eventually { rig.model.libraryStatus == .ready }
        // Here, the switch has not happened yet.
        XCTAssertEqual(rig.model.statusLine, .gettingCloudVersion)
        rig.playback.move(to: playing(.studio, audible: .render(.studio)))
        await eventually { rig.model.statusLine == .cloudVersion }
        XCTAssertEqual(rig.library.requests.count, 1)
    }

    func testAnotherProfileIsAskedForWhenThePlayerFollowsTheSelection() async {
        let rig = makeRig()
        rig.model.select(.profile(.studio))
        rig.model.start()
        await eventually { rig.playback.hub.subscriberCount == 1 }
        rig.playback.move(to: playing(.studio))
        await eventually { rig.library.requests.count == 1 }
        rig.model.select(.profile(.hall))
        // Until the player has taken the new profile nothing is asked for it.
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(rig.library.requests.count, 1)
        rig.playback.move(to: playing(.hall))
        await eventually { rig.library.requests.count == 2 }
        XCTAssertEqual(rig.library.requests[1].key, RenditionKey(videoId: Self.videoId, profile: .hall))
    }

    func testNothingIsAskedForWhileSpatialAudioIsNotActive() async {
        let rig = makeRig()
        rig.model.select(.profile(.studio))
        rig.model.start()
        await eventually { rig.playback.hub.subscriberCount == 1 }
        // The phone's speaker: the route rule fails.
        rig.playback.move(to: playing(.studio, routePasses: false))
        await eventually { rig.model.statusLine == .headphonesOnly }
        // Sing's instrumental plays.
        var singing = playing(.studio)
        singing.singInstrumentalOn = true
        singing.audible = .stereo
        rig.playback.move(to: singing)
        await eventually { rig.model.statusLine == .pausedForSing }
        // A song without a YouTube video (nothing to key a render by).
        var local = playing(.studio)
        local.videoId = nil
        rig.playback.move(to: local)
        await eventually { rig.model.snapshot == local }
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(rig.library.requests.isEmpty)
        XCTAssertEqual(rig.model.libraryStatus, RenditionStatus.none)
    }

    func testASongTheStageCannotTakeAsksForItsRenderAndShowsNoLine() async {
        let rig = makeRig()
        rig.model.select(.profile(.studio))
        rig.model.start()
        await eventually { rig.playback.hub.subscriberCount == 1 }
        // Active, but its sample rate is not one the on-device stage takes: plain stereo until the render plays.
        rig.playback.move(to: playing(.studio, audible: .stereo))
        await eventually { rig.library.requests.count == 1 }
        XCTAssertEqual(rig.model.snapshot.blockedBy, .format)
        await eventually { rig.model.libraryStatus == .queued }
        // No line of its own (spec 6.3): none, as on Android.
        XCTAssertEqual(rig.model.status, .queued)
        XCTAssertEqual(rig.model.statusLine, .none)
        rig.playback.move(to: playing(.studio, audible: .render(.studio)))
        await eventually { rig.model.statusLine == .cloudVersion }
    }

    func testNothingIsAskedForASongThatIsNoLongerTheCurrentOne() async {
        let rig = makeRig(currentSongId: "sp:2")
        rig.model.select(.profile(.studio))
        rig.model.start()
        await eventually { rig.playback.hub.subscriberCount == 1 }
        rig.playback.move(to: playing(.studio))
        await eventually { rig.model.snapshot.songId == "sp:1" }
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(rig.library.requests.isEmpty)
    }

    func testTheLibrarysEventsReachTheScreens() async {
        let rig = makeRig()
        rig.model.select(.profile(.studio))
        rig.model.start()
        await eventually { rig.model.usage.songsReady == 2 }
        rig.library.requestAnswer = .processing
        rig.playback.move(to: playing(.studio))
        await eventually { rig.model.libraryStatus == .processing }
        let key = RenditionKey(videoId: Self.videoId, profile: .studio)
        // Another song's render: not this line's business.
        rig.library.hub.send(.statusChanged(RenditionKey(videoId: "AAAAAAAAAAA", profile: .studio), .failed))
        rig.library.hub.send(.usageChanged(CloudAudioUsage(songsReady: 3, bytes: 80_000_000)))
        await eventually { rig.model.usage.songsReady == 3 }
        XCTAssertEqual(rig.model.libraryStatus, .processing)
        // It cannot start yet: no allowed network, then the month's limit. Each has its own line.
        rig.library.hub.send(.statusChanged(key, .waitingForNetwork))
        await eventually { rig.model.statusLine == .waitingForWifi }
        XCTAssertEqual(rig.model.statusLine.text, "On your phone for now. The cloud version waits for Wi-Fi.")
        rig.library.hub.send(.statusChanged(key, .capReached))
        await eventually { rig.model.statusLine == .cloudLimitReached }
        XCTAssertEqual(rig.model.status, .capReached)
        XCTAssertTrue(rig.model.status.isQueued)
        // The render is coming down, then the try fails: each has its own line.
        rig.library.hub.send(.statusChanged(key, .downloading))
        await eventually { rig.model.status == .downloading }
        XCTAssertEqual(rig.model.statusLine, .gettingCloudVersion)
        rig.library.hub.send(.statusChanged(key, .failed))
        await eventually { rig.model.status == .failed }
        XCTAssertEqual(rig.model.statusLine, .cloudFailed)
        XCTAssertEqual(rig.model.statusLine.text, "The cloud version didn't work this time. Still playing on your phone.")
    }

    func testCloudRendersNeedBothSwitches() async {
        // Cloud Studio's own switch is off: Spatial's switch alone is not enough.
        let rig = makeRig(cloudStudioOn: false)
        rig.library.requestAnswer = RenditionStatus.none
        rig.model.select(.profile(.studio))
        XCTAssertTrue(rig.model.settings.cloud)
        XCTAssertFalse(rig.model.isCloudStudioOn)
        XCTAssertFalse(rig.model.cloudRendersOn)
        rig.model.start()
        await eventually { rig.playback.hub.subscriberCount == 1 }
        rig.playback.move(to: playing(.studio))
        await eventually { rig.model.snapshot.songId == "sp:1" }
        XCTAssertEqual(rig.model.statusLine, .onPhoneOnly)
        // The library was asked and said no (deciding is its job, with both switches in hand).
        await eventually { rig.library.requests.count == 1 }
        XCTAssertEqual(rig.model.libraryStatus, RenditionStatus.none)

        // The master is switched on: the model sees it and asks again for the playing song.
        rig.library.requestAnswer = .queued
        rig.switches.studioOn = true
        await eventually { rig.model.isCloudStudioOn }
        XCTAssertTrue(rig.model.cloudRendersOn)
        await eventually { rig.library.requests.count == 2 }
        await eventually { rig.model.statusLine == .onPhoneForNow }

        // Spatial's own switch off: on-device only again, whatever the library says.
        rig.model.setCloud(false)
        XCTAssertFalse(rig.model.cloudRendersOn)
        XCTAssertEqual(rig.model.statusLine, .onPhoneOnly)
    }

    func testTheDefaultOfTheCloudSwitchFollowsTheBuiltInKeys() async {
        let rig = makeRig(builtInCloudKeys: true)
        rig.model.start()
        XCTAssertTrue(rig.model.settings.cloud)
        // The built-in keys turn out not to open: the default flips, and both services hear of it.
        rig.switches.builtInKeys = false
        await eventually { !rig.model.hasBuiltInCloudKeys }
        XCTAssertFalse(rig.model.settings.cloud)
        await eventually { rig.library.applied.last?.cloud == false && rig.playback.applied.last?.cloud == false }
    }

    func testRemovingTheDownloadedRendersEmptiesTheCountAndAsksAgainForThePlayingSong() async {
        let rig = makeRig()
        rig.model.select(.profile(.studio))
        rig.model.start()
        await eventually { rig.playback.hub.subscriberCount == 1 }
        rig.playback.move(to: playing(.studio))
        await eventually { rig.library.requests.count == 1 }
        await rig.model.removeDownloadedRenders()
        XCTAssertEqual(rig.library.removals, 1)
        XCTAssertEqual(rig.model.usage, .empty)
        XCTAssertFalse(rig.model.isRemovingRenders)
        await eventually { rig.library.requests.count == 2 }
    }

    func testADemoStateStaysAsItWasSet() async {
        let rig = makeRig()
        rig.model.select(.profile(.surround))
        let demo = playing(.surround, audible: .render(.surround))
        rig.model.setDemo(snapshot: demo, libraryStatus: .ready, usage: CloudAudioUsage(songsReady: 12, bytes: 1_400_000_000))
        rig.model.start()
        rig.playback.move(to: playing(.surround))
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(rig.model.snapshot, demo)
        XCTAssertEqual(rig.model.statusLine, .cloudVersion)
        XCTAssertEqual(rig.model.usage.songsReady, 12)
        XCTAssertTrue(rig.library.requests.isEmpty)
    }

    // MARK: This song (Hoa, 2026-11-11)

    private static let spotifyId = "4uLU6hMCjMI75M1A2tKUQC"

    /// The sheet's "This song" switch: shown while a profile is on and a Spotify song plays; off is stored under
    /// `spatial.songsOff`, remembered across launches, clears the status line, reads Off on the player's button, and
    /// nothing more is asked of the cloud for the song. Back on, it is asked for again once the player wants it.
    func testThisSongTurnedOffIsRememberedAndAsksNothingOfTheCloud() async {
        let rig = makeRig()
        rig.model.select(.profile(.studio))
        rig.model.start()
        await eventually { rig.playback.hub.subscriberCount == 1 }
        XCTAssertFalse(rig.model.showsThisSong, "nothing plays")
        var on = playing(.studio)
        on.spotifyId = Self.spotifyId
        rig.playback.move(to: on)
        await eventually { rig.library.requests.count == 1 }
        await eventually { rig.model.statusLine == .onPhoneForNow }
        XCTAssertTrue(rig.model.showsThisSong)
        XCTAssertTrue(rig.model.isOnForCurrentSong)
        XCTAssertEqual(rig.model.currentSongSelection, .profile(.studio))

        rig.model.setOnForCurrentSong(false)
        XCTAssertFalse(rig.model.isOnForCurrentSong)
        XCTAssertEqual(rig.defaults.stringArray(forKey: "spatial.songsOff"), [Self.spotifyId])
        // At once, before the player has caught up: no line, Off on the button, the list keeps the profile.
        XCTAssertEqual(rig.model.statusLine, .none)
        XCTAssertEqual(rig.model.currentSongSelection, .off)
        XCTAssertEqual(rig.model.selection, .profile(.studio))
        XCTAssertTrue(rig.model.showsThisSong, "the switch stays, to turn it back on")
        await eventually { rig.playback.applied.last?.songsOff == [Self.spotifyId] }
        XCTAssertEqual(rig.library.applied.last?.songsOff, [Self.spotifyId])
        var off = on
        off.songOff = true
        off.audible = .stereo
        rig.playback.move(to: off)
        await eventually { rig.model.snapshot == off }
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(rig.library.requests.count, 1)
        XCTAssertEqual(rig.model.libraryStatus, RenditionStatus.none)
        XCTAssertEqual(rig.model.statusLine, .none)

        // A relaunch reads the same choice.
        XCTAssertTrue(makeRig(defaults: rig.defaults).model.settings.isOffFor(Self.spotifyId))

        rig.model.setOnForCurrentSong(true)
        XCTAssertTrue(rig.model.isOnForCurrentSong)
        XCTAssertEqual(rig.defaults.stringArray(forKey: "spatial.songsOff"), [])
        rig.playback.move(to: on)
        await eventually { rig.library.requests.count == 2 }
        XCTAssertEqual(rig.library.requests[1].key, RenditionKey(videoId: Self.videoId, profile: .studio))
    }

    /// No switch while Spatial audio is off, or for a song without a Spotify id.
    func testThisSongIsHiddenWithoutAProfileOrASpotifySong() async {
        let rig = makeRig()
        rig.model.start()
        await eventually { rig.playback.hub.subscriberCount == 1 }
        var snapshot = playing(.studio)
        snapshot.selection = .off
        snapshot.spotifyId = Self.spotifyId
        rig.playback.move(to: snapshot)
        await eventually { rig.model.snapshot == snapshot }
        XCTAssertFalse(rig.model.showsThisSong)
        rig.model.select(.profile(.studio))
        XCTAssertTrue(rig.model.showsThisSong)
        snapshot.spotifyId = nil
        rig.playback.move(to: snapshot)
        await eventually { rig.model.snapshot == snapshot }
        XCTAssertFalse(rig.model.showsThisSong)
        // Nothing to key the choice by: the setter does nothing.
        rig.model.setOnForCurrentSong(false)
        XCTAssertNil(rig.defaults.object(forKey: "spatial.songsOff"))
    }

    // MARK: The pieces the app is assembled from

    func testTheFactoriesGiveTheNoOpHalvesUntilTheRealOnesExist() async {
        let library = NoopSpatialLibrary()
        let key = RenditionKey(videoId: Self.videoId, profile: .studio)
        let found = await library.localRendition(key)
        XCTAssertNil(found)
        let snapshot = await NoopSpatialPlayback().snapshot()
        XCTAssertEqual(snapshot, .idle)
    }

    func testTheTableFileIsInTheAppAndDecodes() throws {
        let tables = try SpatialPreviewResource.loadNow()
        XCTAssertEqual(tables.engine, CloudLibrary.engineId)
        XCTAssertEqual(tables.headroomDb, SpatialLevel.defaultHeadroomDb)
        for profile in SpatialProfile.allCases {
            for rate in SpatialPreviewTables.sampleRates {
                let table = tables.table(for: profile, sampleRate: rate)
                XCTAssertNotNil(table, "\(profile.rawValue) \(rate)")
                XCTAssertEqual(table?.direct.count, table?.taps)
            }
        }
        // One delay ring serves every table.
        XCTAssertGreaterThan(tables.ringCapacity, tables.maxDelay)
        XCTAssertEqual(tables.ringCapacity & (tables.ringCapacity - 1), 0)
    }

    func testTheSettingsStoreReadsWhatItWroteAndForgetsOnReset() {
        let store = CloudAudioSettingsStore(defaults: makeDefaults())
        XCTAssertEqual(store.stored(), CloudAudioStoredSettings())
        store.setProfile(.profile(.intimate))
        store.setMonthlyCapUSD(75)
        store.setStorageMB(100_000_000)
        XCTAssertEqual(store.stored().profile, "intimate")
        XCTAssertEqual(store.stored().monthlyCapUSD, 75)
        XCTAssertEqual(store.stored().storageMB, 65_536)
        XCTAssertEqual(store.load(builtInCloudKeys: false).profile, .profile(.intimate))
        // `spatial.songsOff`: one song at a time, the rest of the list kept.
        store.setSongOff("b", off: true)
        store.setSongOff("a", off: true)
        store.setSongOff("b", off: false)
        XCTAssertEqual(store.stored().songsOff, ["a"])
        XCTAssertEqual(store.load(builtInCloudKeys: false).songsOff, ["a"])
        // A value of another type (an older build, a bad restore) reads as empty and never fails.
        store.defaults.set("not a list", forKey: CloudAudioSettingsKey.songsOff)
        XCTAssertEqual(store.stored().songsOff, [])
        XCTAssertEqual(store.load(builtInCloudKeys: false).songsOff, [])
        store.defaults.set(["c", 7] as [Any], forKey: CloudAudioSettingsKey.songsOff)
        XCTAssertEqual(store.load(builtInCloudKeys: false).songsOff, ["c"])
        store.reset()
        XCTAssertEqual(store.stored(), CloudAudioStoredSettings())
        XCTAssertEqual(store.load(builtInCloudKeys: true), CloudAudioSettings(builtInCloudKeys: true))
    }
}
