import AVFoundation
import Foundation
import PixlAudioCore
import PixlModel
import XCTest
@testable import PixlAudio

/// A library that holds what a test puts in it and tells the player when a render lands.
@MainActor
private final class StubSpatialLibrary: SpatialLibrary {
    var renditions: [RenditionKey: LocalRendition] = [:]
    private(set) var played: [RenditionKey] = []
    let hub = SpatialEventHub<SpatialLibraryEvent>()

    func apply(_ settings: CloudAudioSettings) async {}
    func localRendition(_ key: RenditionKey) async -> LocalRendition? { renditions[key] }
    func localRenditions(videoId: String) async -> [LocalRendition] {
        renditions.values.filter { $0.key.videoId == videoId }
    }
    func status(_ key: RenditionKey) async -> RenditionStatus {
        renditions[key] == nil ? RenditionStatus.none : RenditionStatus.ready
    }
    @discardableResult
    func request(_ request: RenditionRequest) async -> RenditionStatus { RenditionStatus.none }
    func markPlayed(_ key: RenditionKey) async { played.append(key) }
    func usage() async -> CloudAudioUsage { .empty }
    @discardableResult
    func removeAll() async -> CloudAudioUsage { .empty }
    func events() async -> AsyncStream<SpatialLibraryEvent> { hub.stream() }

    /// A verified render arrives (spec 6.2 step 4).
    func land(_ rendition: LocalRendition) {
        renditions[rendition.key] = rendition
        hub.send(.statusChanged(rendition.key, .ready))
        hub.send(.renditionReady(rendition))
    }
}

/// Spatial audio's player side (cloud audio spec 6.3 and 7): the route rule's reading of the session's ports, the
/// stage's vDSP path against its portable one, the stage inside the processing tap (offline), and the controller on
/// the real engine: which audio a song starts on, the switch to a render that lands mid-song, and the way back.
@MainActor
final class SpatialPlaybackTests: XCTestCase {
    private static let videoId = "J7p4bzqLvCw"

    // MARK: The route rule

    func testHeadphonesAreWiredBluetoothAndUSBOutputs() {
        let cases: [(AVAudioSession.Port?, SpatialOutputKind)] = [
            (.headphones, .wiredHeadphones), (.usbAudio, .usbHeadset), (.bluetoothA2DP, .bluetooth),
            (.bluetoothLE, .bluetooth), (.builtInSpeaker, .phoneSpeaker), (.builtInReceiver, .phoneSpeaker),
            (nil, .phoneSpeaker), (.airPlay, .airPlay), (.carAudio, .car), (.bluetoothHFP, .other), (.lineOut, .other),
            (.HDMI, .other),
        ]
        for (port, kind) in cases {
            XCTAssertEqual(SpatialOutputRoute.kind(of: port), kind, String(describing: port))
        }
        XCTAssertEqual(SpatialOutputRoute.kind(of: .headphones, remoteDevicePlays: true), .remote)
        // A Bluetooth speaker counts (the phone cannot tell); the phone's speaker does not, unless the mode is always.
        XCTAssertTrue(SpatialActivation.routePasses(mode: .headphones, output: SpatialOutputRoute.kind(of: .bluetoothA2DP)))
        XCTAssertFalse(SpatialActivation.routePasses(mode: .headphones,
                                                     output: SpatialOutputRoute.kind(of: .builtInSpeaker)))
        XCTAssertTrue(SpatialActivation.routePasses(mode: .always, output: SpatialOutputRoute.kind(of: .builtInSpeaker)))
    }

    /// The route rule follows the output live: every route change reaches Spatial audio, after the command it caused
    /// (an unplug has paused playback by then, so a render swaps back silently).
    func testEveryRouteChangeReachesSpatialAudioAfterItsCommand() {
        let session = AudioSessionController()
        var events: [String] = []
        session.deckSnapshot = {
            DeckPlaybackSnapshot(masterPlayWhenReady: true, masterIsPlaying: true, transitionRunning: false)
        }
        session.onCommand = { command in events.append("\(command)") }
        session.onRouteChange = { events.append("route") }
        session.handleRouteChange(reason: .oldDeviceUnavailable)
        session.handleRouteChange(reason: .categoryChange)
        XCTAssertEqual(events, ["pauseForRouteLoss", "route", "routeChanged", "route"])
    }

    // MARK: The stage's vDSP path

    /// The bundled tables decode, and the stage's vDSP path (what the phone runs) gives what its portable path gives
    /// (what PixlCore's golden test checks on Windows and Linux), past the longest room and through the ring's wrap.
    func testTheVDSPPathOfTheStageMatchesItsPortablePath() throws {
        let coefficients = SpatialStageCoefficients(try SpatialPreviewResource.loadNow())
        let frames = 9_000
        var state: UInt64 = 5
        var input = [Float](repeating: 0, count: frames * 2)
        for i in input.indices {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            input[i] = Float(Double(state >> 11) / Double(1 << 53) * 0.6 - 0.3)
        }
        for profile in SpatialProfile.allCases {
            for rate in [44_100.0, 48_000.0] {
                let fast = try XCTUnwrap(SpatialStage(coefficients: coefficients, sampleRate: rate))
                let portable = try XCTUnwrap(SpatialStage(coefficients: coefficients, sampleRate: rate, accelerated: false))
                let index = SpatialStageCoefficients.index(of: profile)
                let a = Self.run(fast, input, frames: frames, target: index)
                let b = Self.run(portable, input, frames: frames, target: index)
                var worst: Float = 0
                for i in a.indices { worst = max(worst, abs(a[i] - b[i])) }
                XCTAssertLessThanOrEqual(worst, 1e-5, "\(profile.rawValue) at \(rate)")
            }
        }
    }

    /// Interleaved stereo through a stage (no limiter) in buffers of 1000 frames.
    private static func run(_ stage: SpatialStage, _ input: [Float], frames: Int, target: Int) -> [Float] {
        stage.limits = false
        var samples = input
        samples.withUnsafeMutableBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            var done = 0
            while done < frames {
                let n = min(1_000, frames - done)
                stage.begin(frames: n, target: target)
                stage.process(left: base + 2 * done, right: base + 2 * done + 1, stride: 2, frames: n)
                done += n
            }
        }
        return samples
    }

    // MARK: The stage in the tap (offline)

    private func effects(playing profile: SpatialProfile?) throws -> AudioEffectsParameters {
        let effects = AudioEffectsParameters()
        effects.spatial.install(SpatialStageCoefficients(try SpatialPreviewResource.loadNow()))
        effects.spatial.play(profile)
        return effects
    }

    private func item(role: Int, headroomDb: Double = 0, volume: Float = 1) -> TapItemParameters {
        let item = TapItemParameters()
        item.spatialRole.store(role, ordering: .relaxed)
        item.spatialHeadroomDb.store(headroomDb)
        item.replayGainVolume.store(volume)
        return item
    }

    private func rmsRatio(_ output: [Float], _ reference: [Float], skip: Int = 4_410) -> Double {
        let frames = min(output.count, reference.count) / 2
        return TapOfflineRenderer.rms(output, channel: 0, frames: skip..<frames)
            / TapOfflineRenderer.rms(reference, channel: 0, frames: skip..<frames)
    }

    /// The song's own audio runs the stage while a profile plays (never past full scale: the limiter), and is exactly
    /// what it was without Spatial audio when the stage is bypassed.
    func testTheStageRunsOnTheSongsOwnAudioInTheTap() async throws {
        let url = try TestAudio.noise(seconds: 1.5, amplitude: 0.3)
        let plain = try await TapOfflineRenderer.render(url, effects: AudioEffectsParameters(), item: TapItemParameters())
        let parameters = item(role: SpatialItemRole.stage)
        let spatial = try await TapOfflineRenderer.render(url, effects: try effects(playing: .studio), item: parameters)
        XCTAssertEqual(parameters.spatialFormat.load(ordering: .relaxed), SpatialItemFormat.supported)
        XCTAssertEqual(parameters.spatialEngagement.load(), 1)
        XCTAssertEqual(spatial.count, plain.count)
        XCTAssertTrue(zip(spatial, plain).contains { abs($0 - $1) > 1e-3 }, "the stage changed nothing")
        XCTAssertLessThanOrEqual(spatial.map { abs($0) }.max() ?? 0, 1)

        let bypassed = try await TapOfflineRenderer.render(url, effects: try effects(playing: nil),
                                                           item: item(role: SpatialItemRole.stage))
        XCTAssertEqual(bypassed, plain, "a bypassed stage leaves the sound untouched")
    }

    /// Spec 6.3: a render is never spatialized again, and plays `min(1, gain × 1.585)`: with no normalisation (gain 1)
    /// exactly as it is, with a ReplayGain volume of 0.5 at 0.79. Sing's audio with the same settings: just the volume.
    func testARenderIsNeverSpatializedAgainAndGetsItsHeadroomBack() async throws {
        let url = try TestAudio.noise(seconds: 1, amplitude: 0.3)
        let effects = try effects(playing: .hall)
        let plain = try await TapOfflineRenderer.render(url, effects: AudioEffectsParameters(), item: TapItemParameters())
        let render = try await TapOfflineRenderer.render(url, effects: effects,
                                                         item: item(role: SpatialItemRole.render, headroomDb: 4))
        XCTAssertEqual(render, plain)
        let quiet = try await TapOfflineRenderer.render(url, effects: effects,
                                                        item: item(role: SpatialItemRole.render, headroomDb: 4, volume: 0.5))
        XCTAssertEqual(rmsRatio(quiet, plain), 0.5 * pow(10, 4.0 / 20), accuracy: 0.01)
        let sing = try await TapOfflineRenderer.render(url, effects: effects,
                                                       item: item(role: SpatialItemRole.none, volume: 0.5))
        XCTAssertEqual(rmsRatio(sing, plain), 0.5, accuracy: 0.01)
    }

    /// Spec 6.3 "Level" for the on-device stage: the spatial sound plays at `min(1, gain × 1.585)` of the ReplayGain
    /// gain, so with a volume of 0.5 the fully engaged stage is 0.79 of what it is at volume 1 (and 1 stays 1).
    func testTheLevelRuleGivesTheStagesHeadroomBack() async throws {
        let url = try TestAudio.noise(seconds: 1.5, amplitude: 0.2)
        let full = try await TapOfflineRenderer.render(url, effects: try effects(playing: .studio),
                                                       item: item(role: SpatialItemRole.stage))
        let half = try await TapOfflineRenderer.render(url, effects: try effects(playing: .studio),
                                                       item: item(role: SpatialItemRole.stage, volume: 0.5))
        XCTAssertEqual(rmsRatio(half, full), 0.5 * pow(10, 4.0 / 20), accuracy: 0.01)
    }

    // MARK: The controller on the real engine

    private struct Files {
        let song: Song
        let render: LocalRendition
    }

    /// A song whose own audio is a download (`…/Downloads/<videoId>.wav`, so its video is known) and its studio render
    /// of the same length (another tone, so the two are told apart).
    private func makeFiles(seconds: Double, renderSeconds: Double? = nil) throws -> Files {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pixlaudio-spatial-\(UUID().uuidString)", isDirectory: true)
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        let renders = root.appendingPathComponent("CloudAudio/\(Self.videoId)", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renders, withIntermediateDirectories: true)
        let own = downloads.appendingPathComponent("\(Self.videoId).wav")
        let renderURL = renders.appendingPathComponent("sp-studio.wav")
        try FileManager.default.moveItem(at: try TestAudio.sine(frequency: 440, seconds: seconds), to: own)
        try FileManager.default.moveItem(at: try TestAudio.sine(frequency: 660, seconds: renderSeconds ?? seconds),
                                         to: renderURL)
        let key = RenditionKey(videoId: Self.videoId, profile: .studio)
        let manifest = CloudLibraryManifest(
            videoId: Self.videoId, profile: SpatialProfile.studio.rawValue,
            audio: .init(key: "lib/v1/\(Self.videoId)/sp-studio.flac", bytes: 1, sha256: String(repeating: "0", count: 64),
                         sampleRate: TestAudio.sampleRate, durationMs: Int64((renderSeconds ?? seconds) * 1000)),
            loudness: .init(headroomDb: 4))
        return Files(song: TestAudio.song(own, id: "sp:test", seconds: seconds),
                     render: LocalRendition(key: key, fileURL: renderURL, manifest: manifest))
    }

    private struct Rig {
        let engine: DualDeckEngine
        let library: StubSpatialLibrary
        let controller: SpatialPlaybackController
    }

    /// The real engine with Spatial audio set to `profile` in the `always` route mode (the simulator plays through
    /// its speaker).
    private func makeRig(_ profile: SpatialProfile?, renders: [LocalRendition] = []) -> Rig {
        let engine = DualDeckEngine(session: AudioSessionController())
        let library = StubSpatialLibrary()
        for render in renders { library.renditions[render.key] = render }
        let controller = SpatialPlaybackController(
            engine: engine, library: library, settings: settings(profile),
            inputs: .init(remoteDevicePlays: { false }, sing: { (on: false, switching: false) },
                          gaps: { _ in (index: nil, offsetMs: 0) }))
        return Rig(engine: engine, library: library, controller: controller)
    }

    private func settings(_ profile: SpatialProfile?) -> CloudAudioSettings {
        var settings = CloudAudioSettings(builtInCloudKeys: false)
        settings.profile = profile.map(SpatialSelection.profile) ?? .off
        settings.route = .always
        return settings
    }

    /// Waits for the current item's tap to process audio; skips when the simulator renders nothing (no audio device).
    private func waitForAudio(_ engine: DualDeckEngine, timeout: TimeInterval = 8) async throws {
        let rendering = await waitUntil(timeout: timeout) {
            engine.activeItem?.tap.hasProcessed.load(ordering: .relaxed) == true
                && (engine.activeItem?.positionSeconds ?? 0) > 0.05
        }
        if !rendering {
            throw XCTSkip("The simulator rendered no audio (no output device?) — playback tests need a running clock")
        }
    }

    /// Spec 6.3: with a profile on and the route passing, a song starts on its local render, with the stage bypassed
    /// for it, and the library hears that it was played.
    func testASongStartsOnItsLocalRenderWithTheStageBypassed() async throws {
        let files = try makeFiles(seconds: 6)
        let rig = makeRig(.studio, renders: [files.render])
        defer { rig.engine.stop() }
        rig.engine.setQueue([files.song], startIndex: 0, startPositionMs: 0, playWhenReady: false)
        let loaded = await waitUntil(timeout: 5) { rig.engine.activeItem != nil }
        XCTAssertTrue(loaded)
        let item = try XCTUnwrap(rig.engine.activeItem)
        XCTAssertEqual(item.audio, .render(files.render.key))
        XCTAssertEqual(item.asset.url, files.render.fileURL)
        XCTAssertEqual(item.tap.spatialRole.load(ordering: .relaxed), SpatialItemRole.render)
        XCTAssertEqual(rig.engine.effects.spatial.playing, .studio, "the stage target is on (the render item ignores it)")
        let reported = await waitUntil(timeout: 2) { rig.controller.current.audible == .render(.studio) }
        XCTAssertTrue(reported)
        XCTAssertEqual(rig.controller.current.videoId, Self.videoId)
        XCTAssertNil(rig.controller.current.wantedRender, "nothing to ask the cloud for")
        let played = await waitUntil(timeout: 2) { rig.library.played == [files.render.key] }
        XCTAssertTrue(played)
    }

    /// With Spatial audio off the song plays its own audio (the stage bypassed, nothing wanted); picking a profile turns
    /// the stage on at once, and the render already on the phone switches in (paused: silently).
    func testPickingAProfileTurnsTheStageOnAndSwitchesToALocalRender() async throws {
        let files = try makeFiles(seconds: 30)
        let rig = makeRig(nil, renders: [files.render])
        defer { rig.engine.stop() }
        rig.engine.setQueue([files.song], startIndex: 0, startPositionMs: 0, playWhenReady: false)
        let loaded = await waitUntil(timeout: 5) { rig.engine.activeItem != nil }
        XCTAssertTrue(loaded)
        let item = try XCTUnwrap(rig.engine.activeItem)
        XCTAssertEqual(item.audio, .own(videoId: Self.videoId))
        XCTAssertEqual(item.tap.spatialRole.load(ordering: .relaxed), SpatialItemRole.stage)
        XCTAssertNil(rig.engine.effects.spatial.playing)
        let idle = await waitUntil(timeout: 2) { rig.controller.current.songId == files.song.id }
        XCTAssertTrue(idle)
        XCTAssertEqual(rig.controller.current.audible, .stereo)
        XCTAssertNil(rig.controller.current.wantedRender)

        await rig.controller.apply(settings(.studio))
        XCTAssertEqual(rig.engine.effects.spatial.playing, .studio)
        let switched = await waitUntil(timeout: 10) { rig.engine.activeItem?.audio == .render(files.render.key) }
        XCTAssertTrue(switched, "the local render switches in")
        XCTAssertEqual(rig.engine.activeItem?.entry.song.id, files.song.id, "the queue entry stays the same")
    }

    /// The switch itself: about 250 ms of linear crossfade, the 20 s rule, and the way back to the song's own audio.
    func testTheRenditionSwitchFadesForAQuarterSecondAndKeepsTheTwentySecondRule() async throws {
        let files = try makeFiles(seconds: 30)
        let engine = DualDeckEngine(session: AudioSessionController())
        defer { engine.stop() }
        engine.setQueue([files.song], startIndex: 0, startPositionMs: 0, playWhenReady: true)
        try await waitForAudio(engine)
        let first = try XCTUnwrap(engine.activeItem)

        let refused = await engine.switchCurrentRendition(to: .render(files.render), placement: nil,
                                                          minimumSecondsLeft: 40, requireAligned: true)
        XCTAssertEqual(refused, .failed, "less than the minimum is left")
        XCTAssertTrue(engine.activeItem === first)

        let outcome = await engine.switchCurrentRendition(to: .render(files.render), placement: nil,
                                                          minimumSecondsLeft: SpatialRenditionRules.minimumSecondsLeft,
                                                          requireAligned: true)
        XCTAssertEqual(outcome, .switched)
        let second = try XCTUnwrap(engine.activeItem)
        XCTAssertEqual(second.audio, .render(files.render.key))
        let incoming = try XCTUnwrap(second.tap.ramp.read(), "the render fades in")
        XCTAssertEqual(incoming.curve, .linear)
        XCTAssertEqual(incoming.duration, SpatialRenditionRules.switchFadeSeconds, accuracy: 0.001)
        let outgoing = try XCTUnwrap(first.tap.ramp.read(), "the song's own audio fades out")
        XCTAssertEqual(outgoing.duration, SpatialRenditionRules.switchFadeSeconds, accuracy: 0.001)

        let back = await engine.switchCurrentRendition(to: .ownAudio, placement: nil, minimumSecondsLeft: 0,
                                                       requireAligned: false)
        XCTAssertEqual(back, .switched)
        XCTAssertEqual(engine.activeItem?.audio, .own(videoId: Self.videoId))
        XCTAssertEqual(engine.activeItem?.tap.spatialRole.load(ordering: .relaxed), SpatialItemRole.stage)
    }

    /// A render of another length does not line up with the song: it is not switched in (the next play uses it).
    func testARenderOfAnotherLengthIsNotSwitchedIn() async throws {
        let files = try makeFiles(seconds: 30, renderSeconds: 31)
        let engine = DualDeckEngine(session: AudioSessionController())
        defer { engine.stop() }
        engine.setQueue([files.song], startIndex: 0, startPositionMs: 0, playWhenReady: true)
        try await waitForAudio(engine)
        let outcome = await engine.switchCurrentRendition(to: .render(files.render), placement: nil,
                                                          minimumSecondsLeft: SpatialRenditionRules.minimumSecondsLeft,
                                                          requireAligned: true)
        XCTAssertEqual(outcome, .misaligned)
        XCTAssertEqual(engine.activeItem?.audio, .own(videoId: Self.videoId))
    }

    /// Spec 6.3: a render that lands while its song plays (with 20 s left, nothing in flight) switches in; turning
    /// Spatial audio off swaps back to the song's own audio and bypasses the stage.
    func testARenderThatLandsMidSongSwitchesInAndSpatialOffSwapsBack() async throws {
        let files = try makeFiles(seconds: 30)
        let rig = makeRig(.studio)
        defer { rig.engine.stop() }
        rig.engine.setQueue([files.song], startIndex: 0, startPositionMs: 0, playWhenReady: true)
        try await waitForAudio(rig.engine)
        let first = try XCTUnwrap(rig.engine.activeItem)
        XCTAssertEqual(first.audio, .own(videoId: Self.videoId))
        let engaged = await waitUntil(timeout: 3) { first.tap.spatialEngagement.load() == 1 }
        XCTAssertTrue(engaged, "the on-device stage plays")
        let onDevice = await waitUntil(timeout: 2) { rig.controller.current.audible == .onDevice(.studio) }
        XCTAssertTrue(onDevice)
        XCTAssertEqual(rig.controller.current.wantedRender, files.render.key, "the cloud render is wanted")

        rig.library.land(files.render)
        let switched = await waitUntil(timeout: 10) { rig.engine.activeItem?.audio == .render(files.render.key) }
        XCTAssertTrue(switched, "the render switches in")
        let reported = await waitUntil(timeout: 2) { rig.controller.current.audible == .render(.studio) }
        XCTAssertTrue(reported)

        await rig.controller.apply(settings(nil))
        XCTAssertNil(rig.engine.effects.spatial.playing, "the stage bypasses at once")
        let back = await waitUntil(timeout: 10) {
            if case .own? = rig.engine.activeItem?.audio { return true }
            return false
        }
        XCTAssertTrue(back, "the render is swapped back to the song's own audio")
    }
}
