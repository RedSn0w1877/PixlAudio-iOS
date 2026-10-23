import Foundation
import PixlModel
import PixlNet
import XCTest
@testable import PixlAudio

/// The engine as a stand-in: answers what a test says and records how it was asked.
@MainActor
private final class FakeSwitcher: InstrumentalSwitching {
    struct Call {
        let url: URL?
        let hadPlacement: Bool
        let requireAligned: Bool
        /// What the placement answered when it was asked (the earliest start the fake offers is 10 s).
        let placed: (startSeconds: Double, fadeSeconds: Double)?
    }

    var rate: Float = 1
    var outcome: DualDeckEngine.SwitchOutcome = .switched
    private(set) var calls: [Call] = []

    func switchCurrentAudio(to url: URL?, placement: DualDeckEngine.SwitchPlacement?, requireAligned: Bool) async
        -> DualDeckEngine.SwitchOutcome {
        calls.append(Call(url: url, hadPlacement: placement != nil, requireAligned: requireAligned, placed: placement?(10)))
        return outcome
    }
}

/// Which songs have an instrumental "on disk" in a test.
@MainActor
private final class LandedFiles {
    var songIds: Set<String> = []

    func url(_ id: String) -> URL? { songIds.contains(id) ? URL(fileURLWithPath: "/instrumentals/\(id).wav") : nil }
}

/// The Sing button's controller without a screen: the wish lives in the controller, so what a view would do is
/// nothing here. The engine, the files and the lyrics are stand-ins; the cloud is Cloud Studio on its test fakes.
@MainActor
final class InstrumentalControllerTests: XCTestCase {
    private struct Rig {
        let playback: PlaybackStore
        let studio: TaisStudio
        let lyrics: LyricsController
        let switcher: FakeSwitcher
        let files: LandedFiles
        let controller: InstrumentalController
        let song: Song
    }

    private func makeRig(songs: [Song] = DemoLibrary.songs) -> Rig {
        let playback = PlaybackStore(engine: DemoPlaybackEngine())
        playback.play(songs, startIndex: 0, playWhenReady: false)
        let studio = TaisStudio(models: ModelManager(isDemo: true), dependencies: nil)
        let lyrics = LyricsController(store: LyricsStore(), settings: SettingsStore.ephemeral(), persistence: nil,
                                      isUITest: true)
        let switcher = FakeSwitcher()
        let files = LandedFiles()
        let controller = InstrumentalController(playback: playback, engine: switcher, studio: studio, lyrics: lyrics)
        controller.instrumentalURL = { files.url($0) }
        return Rig(playback: playback, studio: studio, lyrics: lyrics, switcher: switcher, files: files,
                   controller: controller, song: songs[0])
    }

    /// An instrumental lands for `songId`: the file is there and the studio says so.
    private func land(_ songId: String, in rig: Rig) {
        rig.files.songIds.insert(songId)
        rig.studio.noteInstrumentalImported()
    }

    // MARK: Tapping with an instrumental

    func testATapWithAnInstrumentalSwitchesAtOnceAndAnotherSwitchesBack() async throws {
        let rig = makeRig()
        land(rig.song.id, in: rig)
        let available = await waitUntil(timeout: 3) { rig.controller.isAvailable }
        XCTAssertTrue(available)

        await rig.controller.requestSing(for: rig.song)
        let on = await waitUntil(timeout: 3) { rig.controller.isActive }
        XCTAssertTrue(on)
        let first = try XCTUnwrap(rig.switcher.calls.first)
        XCTAssertFalse(first.hadPlacement, "an instrumental that is already there switches at the same position, now")
        XCTAssertFalse(first.requireAligned)
        XCTAssertEqual(rig.controller.singPhase, .on)

        await rig.controller.requestSing(for: rig.song)
        let off = await waitUntil(timeout: 3) { !rig.controller.isActive }
        XCTAssertTrue(off)
        XCTAssertNil(rig.switcher.calls.last?.url, "back to the song's own audio")
        XCTAssertEqual(rig.controller.singPhase, .idle)
    }

    // MARK: The wish

    func testWithoutTheCloudThePhoneRendersAndTheSwitchHappensWhenItLands() async throws {
        let rig = makeRig()
        await rig.controller.requestSing(for: rig.song)
        XCTAssertEqual(rig.controller.singPhase, .preparingDevice)
        XCTAssertEqual(rig.studio.state(.instrumental, songId: rig.song.id)?.phase, .queued, "the render was started")
        XCTAssertEqual(rig.lyrics.message, "Removing the vocals on this iPhone. The first time takes a few minutes.")
        XCTAssertTrue(rig.switcher.calls.isEmpty)

        land(rig.song.id, in: rig)
        let on = await waitUntil(timeout: 3) { rig.controller.isActive }
        XCTAssertTrue(on, "the controller switched on its own: no view was needed")
        let call = try XCTUnwrap(rig.switcher.calls.first)
        XCTAssertTrue(call.hadPlacement, "the wish switches at a gap between sung words")
        XCTAssertTrue(call.requireAligned)
        let placed = try XCTUnwrap(call.placed)
        XCTAssertEqual(placed.startSeconds, 10, accuracy: 0.001, "no lyrics timing: as soon as it can")
        XCTAssertEqual(placed.fadeSeconds, 0.7, accuracy: 0.001)
        XCTAssertEqual(rig.controller.singPhase, .on)
    }

    func testANewSongEndsTheWish() async throws {
        let rig = makeRig()
        await rig.controller.requestSing(for: rig.song)
        XCTAssertEqual(rig.controller.singPhase, .preparingDevice)

        rig.playback.play(DemoLibrary.songs, startIndex: 1, playWhenReady: false)
        let idle = await waitUntil(timeout: 3) { rig.controller.singPhase == .idle }
        XCTAssertTrue(idle)

        // The first song's instrumental lands now: it is just stored.
        land(rig.song.id, in: rig)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(rig.switcher.calls.isEmpty)
        XCTAssertFalse(rig.controller.isActive)
        XCTAssertFalse(rig.controller.isAvailable, "the new song has none")
    }

    func testASecondTapStopsOnlyTheWaiting() async throws {
        let rig = makeRig()
        await rig.controller.requestSing(for: rig.song)
        XCTAssertEqual(rig.controller.singPhase, .preparingDevice)

        await rig.controller.requestSing(for: rig.song)
        XCTAssertEqual(rig.controller.singPhase, .idle)
        XCTAssertEqual(rig.studio.state(.instrumental, songId: rig.song.id)?.phase, .queued, "the render goes on")
        XCTAssertEqual(rig.lyrics.message, "Okay. The instrumental will be ready next time.")

        land(rig.song.id, in: rig)
        let available = await waitUntil(timeout: 3) { rig.controller.isAvailable }
        XCTAssertTrue(available)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(rig.switcher.calls.isEmpty, "nothing is switched to without a wish")
        XCTAssertFalse(rig.controller.isActive)
    }

    func testAnEditorThatNeedsTheVocalsHoldsTheSwitchUntilItCloses() async throws {
        let rig = makeRig()
        await rig.controller.requestSing(for: rig.song)
        rig.controller.suspend(owner: "editor")

        land(rig.song.id, in: rig)
        let held = await waitUntil(timeout: 3) { rig.controller.singPhase == .readyToSwitch }
        XCTAssertTrue(held)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(rig.switcher.calls.isEmpty)

        rig.controller.resume(owner: "editor")
        let on = await waitUntil(timeout: 3) { rig.controller.isActive }
        XCTAssertTrue(on)
        XCTAssertEqual(rig.switcher.calls.count, 1)
    }

    func testASeekDuringTheSwitchLeavesTheInstrumentalReadyForATap() async throws {
        let rig = makeRig()
        rig.switcher.outcome = .abortedBySeek
        await rig.controller.requestSing(for: rig.song)
        land(rig.song.id, in: rig)
        let tried = await waitUntil(timeout: 3) { rig.switcher.calls.count == 1 }
        XCTAssertTrue(tried)
        let idle = await waitUntil(timeout: 3) { rig.controller.singPhase == .idle && !rig.controller.isSwitching }
        XCTAssertTrue(idle)
        XCTAssertFalse(rig.controller.isActive)
        XCTAssertTrue(rig.controller.isAvailable)
        XCTAssertEqual(rig.lyrics.message, "The instrumental is ready. Tap Sing to switch.")

        // The tap is the manual path: at once, no placement, no alignment check.
        rig.switcher.outcome = .switched
        await rig.controller.requestSing(for: rig.song)
        let on = await waitUntil(timeout: 3) { rig.controller.isActive }
        XCTAssertTrue(on)
        XCTAssertEqual(rig.switcher.calls.count, 2)
        XCTAssertFalse(rig.switcher.calls[1].hadPlacement)
        XCTAssertFalse(rig.switcher.calls[1].requireAligned)
    }

    func testAnInstrumentalThatDoesNotLineUpIsKeptAndSaysSo() async throws {
        let rig = makeRig()
        rig.switcher.outcome = .misaligned
        await rig.controller.requestSing(for: rig.song)
        land(rig.song.id, in: rig)
        let tried = await waitUntil(timeout: 3) { rig.switcher.calls.count == 1 && !rig.controller.isSwitching }
        XCTAssertTrue(tried)
        XCTAssertFalse(rig.controller.isActive)
        XCTAssertTrue(rig.controller.isAvailable)
        XCTAssertEqual(rig.controller.singPhase, .idle)
        XCTAssertEqual(rig.lyrics.message?.contains("may not line up"), true)
    }

    func testAFailedSwitchSaysSoAndKeepsTheSongsOwnAudio() async throws {
        let rig = makeRig()
        rig.switcher.outcome = .failed
        await rig.controller.requestSing(for: rig.song)
        land(rig.song.id, in: rig)
        let tried = await waitUntil(timeout: 3) { rig.switcher.calls.count == 1 && !rig.controller.isSwitching }
        XCTAssertTrue(tried)
        XCTAssertFalse(rig.controller.isActive)
        XCTAssertEqual(rig.controller.singPhase, .idle)
        XCTAssertEqual(rig.lyrics.message, "Couldn't switch to the instrumental. Tap Sing to try again.")
    }

    // MARK: The cloud

    func testACloudSingWaitsForItsJobAndIsDroppedQuietlyWhenTheJobIsCancelled() async throws {
        let h = CloudHarness()
        h.settings.useCellular = true
        let song = h.addSong("f:root/a.m4a")
        let rig = makeRig(songs: [song])
        rig.controller.cloud = h.studio

        await rig.controller.requestSing(for: song)
        guard case .preparingCloud(let jobKey) = rig.controller.singPhase else {
            return XCTFail("expected a cloud job, the phase is \(rig.controller.singPhase)")
        }
        XCTAssertEqual(h.studio.job(jobKey)?.songId, song.id)
        XCTAssertNil(rig.studio.state(.instrumental, songId: song.id), "nothing renders on the phone")
        XCTAssertNotNil(rig.controller.cloudStatus, "the button has the job's progress")

        await h.studio.cancel(jobKey)
        let idle = await waitUntil(timeout: 3) { rig.controller.singPhase == .idle }
        XCTAssertTrue(idle, "a cancelled job ends the wish")
        XCTAssertNil(rig.controller.cloudStatus)
        XCTAssertTrue(rig.switcher.calls.isEmpty)
    }

    func testACloudJobThatFailsSaysSoAndTheNextTapRendersOnThePhone() async throws {
        let h = CloudHarness()
        h.settings.useCellular = true
        // The worker takes songs up to 3 minutes; this one is 4: the job fails once it is prepared.
        h.settings.workerCaps = CloudWorkerCaps(maxInputMB: 160, maxAudioS: 180, hostsConfigured: 1)
        let song = h.addSong("f:root/a.m4a")
        h.host.facts[song.id] = CloudHarness.lineSyncedFacts
        let rig = makeRig(songs: [song])
        rig.controller.cloud = h.studio

        await rig.controller.requestSing(for: song)
        guard case .preparingCloud(let jobKey) = rig.controller.singPhase else {
            return XCTFail("expected a cloud job, the phase is \(rig.controller.singPhase)")
        }
        await h.studio.pump()
        await h.studio.settle()
        XCTAssertEqual(h.studio.job(jobKey)?.state, .failed)
        let idle = await waitUntil(timeout: 3) { rig.controller.singPhase == .idle }
        XCTAssertTrue(idle)
        XCTAssertEqual(rig.lyrics.message, "The cloud couldn't do this one. Tap Sing to remove vocals on this phone.")

        await rig.controller.requestSing(for: song)
        XCTAssertEqual(rig.controller.singPhase, .preparingDevice, "the next tap goes to the phone")
        XCTAssertEqual(rig.studio.state(.instrumental, songId: song.id)?.phase, .queued)
    }

    // MARK: Pure decisions

    func testTheFallbackTableTriesTheCloudFirstAndThePhoneSecond() {
        XCTAssertEqual(SingRoute.decide(.usable, cloudFailedBefore: false), .cloud)
        XCTAssertEqual(SingRoute.decide(.alreadyPending(jobKey: "k"), cloudFailedBefore: false), .cloud)
        XCTAssertEqual(SingRoute.decide(.off, cloudFailedBefore: false),
                       .device(reason: "Cloud processing is off — removing vocals on this phone instead."))
        XCTAssertEqual(SingRoute.decide(.notOnWiFi, cloudFailedBefore: false),
                       .device(reason: "Not on Wi-Fi — removing vocals on this phone instead."))
        XCTAssertEqual(SingRoute.decide(.overCap, cloudFailedBefore: false),
                       .device(reason: "This month's cloud budget is used up — removing vocals on this phone instead."))
        for availability in [SingCloudAvailability.notConfigured, .keysMissing, .tooLong] {
            guard case .device(let reason?) = SingRoute.decide(availability, cloudFailedBefore: false) else {
                return XCTFail("\(availability) should name why the phone does it")
            }
            XCTAssertTrue(reason.hasSuffix("removing vocals on this phone instead."), reason)
        }
        XCTAssertEqual(SingRoute.decide(.nothingToDo, cloudFailedBefore: false), .device(reason: nil))
    }

    func testAFailedCloudJobAndNoCloudBothGoToThePhoneWithoutExplaining() {
        XCTAssertEqual(SingRoute.decide(.usable, cloudFailedBefore: true), .device(reason: nil))
        XCTAssertEqual(SingRoute.decide(.alreadyPending(jobKey: "k"), cloudFailedBefore: true), .device(reason: nil))
        XCTAssertEqual(SingRoute.decide(nil, cloudFailedBefore: false), .device(reason: nil))
    }

    func testTheCloudRefusingAfterTheCheckNamesWhyOnlyWhenItIsTheSwitchOrTheBudget() {
        XCTAssertEqual(SingRoute.reason(after: .off), SingRoute.offReason)
        XCTAssertEqual(SingRoute.reason(after: .overCap), SingRoute.overCapReason)
        XCTAssertNil(SingRoute.reason(after: .started(1)))
        XCTAssertNil(SingRoute.reason(after: .nothingToDo("Nothing to process")))
    }

    func testAJobEndsTheWishOnlyWhenItIsFinished() {
        XCTAssertNil(SingJobEnd.end(of: .queued))
        XCTAssertNil(SingJobEnd.end(of: .uploading))
        XCTAssertNil(SingJobEnd.end(of: .running))
        XCTAssertNil(SingJobEnd.end(of: .downloading))
        XCTAssertEqual(SingJobEnd.end(of: .failed), .failed)
        XCTAssertEqual(SingJobEnd.end(of: .expired), .failed)
        XCTAssertEqual(SingJobEnd.end(of: .cancelled), .cancelled)
        XCTAssertEqual(SingJobEnd.end(of: .imported), .empty, "asked only when no instrumental came of it")
    }

    func testThePhaseKnowsWhoMakesTheInstrumental() {
        XCTAssertTrue(SingPhase.preparingCloud(jobKey: "k").isCloud)
        XCTAssertTrue(SingPhase.preparingCloud(jobKey: "k").isPreparing)
        XCTAssertTrue(SingPhase.preparingDevice.isPreparing)
        XCTAssertFalse(SingPhase.preparingDevice.isCloud)
        for phase in [SingPhase.idle, .readyToSwitch, .waitingForGap, .switching, .on] {
            XCTAssertFalse(phase.isPreparing, "\(phase)")
        }
    }

    // MARK: More of the cloud

    func testACloudSingSwitchesWhenItsInstrumentalLandsWhileTheJobIsStillAtWork() async throws {
        let h = CloudHarness()
        h.settings.useCellular = true
        let song = h.addSong("f:root/a.m4a")
        let rig = makeRig(songs: [song])
        rig.controller.cloud = h.studio
        await rig.controller.requestSing(for: song)
        guard case .preparingCloud = rig.controller.singPhase else {
            return XCTFail("expected a cloud job, the phase is \(rig.controller.singPhase)")
        }

        land(song.id, in: rig)
        let on = await waitUntil(timeout: 3) { rig.controller.isActive }
        XCTAssertTrue(on, "the instrumental is what the wish was for, whatever the job does next")
        let call = try XCTUnwrap(rig.switcher.calls.first)
        XCTAssertTrue(call.hadPlacement)
        XCTAssertTrue(call.requireAligned, "a cloud instrumental is checked against the song before it plays")
        XCTAssertEqual(rig.controller.singPhase, .on)
        XCTAssertNil(rig.controller.cloudStatus)
    }

    func testASecondTapOnACloudSingStopsOnlyTheWaitingAndAThirdJoinsTheJobAgain() async throws {
        let h = CloudHarness()
        h.settings.useCellular = true
        let song = h.addSong("f:root/a.m4a")
        let rig = makeRig(songs: [song])
        rig.controller.cloud = h.studio
        await rig.controller.requestSing(for: song)
        guard case .preparingCloud(let jobKey) = rig.controller.singPhase else {
            return XCTFail("expected a cloud job, the phase is \(rig.controller.singPhase)")
        }

        await rig.controller.requestSing(for: song)
        XCTAssertEqual(rig.controller.singPhase, .idle)
        XCTAssertEqual(rig.lyrics.message, "Okay. The instrumental will be ready next time.")
        XCTAssertEqual(h.studio.job(jobKey)?.state.isPending, true, "the job goes on")

        await rig.controller.requestSing(for: song)
        XCTAssertEqual(rig.controller.singPhase, .preparingCloud(jobKey: jobKey), "the tap joins the job it already has")
        XCTAssertEqual(h.studio.jobs.count, 1, "no second job")
    }

    func testASongWithAJobOfItsOwnAlreadyOnItsWayIsJoinedAndMadeTheFirstInLine() async throws {
        let h = CloudHarness()
        h.settings.useCellular = true
        let song = h.addSong("f:root/a.m4a")
        h.host.facts[song.id] = CloudHarness.lineSyncedFacts
        await h.studio.send(await h.studio.preview(songs: [song], title: "Test"))
        let existing = try XCTUnwrap(h.studio.jobs.first?.jobKey)
        XCTAssertNotEqual(h.studio.job(existing)?.effectiveOrigin, .sing)
        let rig = makeRig(songs: [song])
        rig.controller.cloud = h.studio

        await rig.controller.requestSing(for: song)
        XCTAssertEqual(rig.controller.singPhase, .preparingCloud(jobKey: existing))
        XCTAssertEqual(h.studio.jobs.count, 1, "the tap joined it")
        XCTAssertEqual(h.studio.job(existing)?.effectiveOrigin, .sing, "and it is a Sing job from now on")
    }

    func testWithTheCloudSwitchedOffTheTapRendersOnThePhoneAndSaysWhy() async throws {
        let h = CloudHarness()
        h.settings.isEnabled = false
        let song = h.addSong("f:root/a.m4a")
        let rig = makeRig(songs: [song])
        rig.controller.cloud = h.studio

        await rig.controller.requestSing(for: song)
        XCTAssertEqual(rig.controller.singPhase, .preparingDevice)
        XCTAssertEqual(rig.lyrics.message, SingRoute.offReason)
        XCTAssertEqual(rig.studio.state(.instrumental, songId: song.id)?.phase, .queued)
        XCTAssertTrue(h.studio.jobs.isEmpty, "nothing was sent")
    }

    // MARK: The button's words

    func testTheButtonSaysSingWhileNothingIsUnderWayAndTheVocalsAreOn() {
        XCTAssertEqual(face(.idle),
                       SingButtonFace(title: "Sing", value: "Vocals on", progress: nil, busy: false, showsIcon: true))
        XCTAssertEqual(face(.readyToSwitch).value, "Instrumental ready")
        XCTAssertEqual(face(.readyToSwitch).title, "Sing")
    }

    func testTheButtonSaysVocalsOffWhileTheInstrumentalPlays() {
        XCTAssertEqual(face(.on, active: true),
                       SingButtonFace(title: "Vocals off", value: "Vocals off", progress: nil, busy: false, showsIcon: true))
    }

    func testACloudSingShowsThePreparingStepAndFillsWithTheJobsWeight() {
        let uploading = SingCloudStatus(weight: 0.22, text: "Uploading 40%", waitingForWiFi: false)
        XCTAssertEqual(face(.preparingCloud(jobKey: "k"), cloud: uploading),
                       SingButtonFace(title: "Preparing…", value: "Preparing in the cloud — Uploading 40%", progress: 0.22,
                                      busy: false, showsIcon: false))
        // Before the controller has read the job.
        XCTAssertEqual(face(.preparingCloud(jobKey: "k")).title, "Preparing…")
        XCTAssertEqual(face(.preparingCloud(jobKey: "k")).value, "Preparing in the cloud")
        XCTAssertNil(face(.preparingCloud(jobKey: "k")).progress)
    }

    func testACloudSingThatCannotUploadSaysItIsWaitingForWiFi() {
        let waiting = SingCloudStatus(weight: 0.1, text: "Uploading", waitingForWiFi: true)
        let shown = face(.preparingCloud(jobKey: "k"), cloud: waiting)
        XCTAssertEqual(shown.title, "Waiting for Wi-Fi")
        XCTAssertEqual(shown.value, "Waiting for Wi-Fi")
        XCTAssertEqual(shown.progress, 0.1)
        XCTAssertFalse(shown.showsIcon)
    }

    func testARenderOnThePhoneShowsItsPercentageAndFillsWithIt() {
        let partway = face(.preparingDevice, rendering: true, renderPercent: 48)
        XCTAssertEqual(partway, SingButtonFace(title: "Removing vocals 48 %", value: "Removing vocals 48 %", progress: 0.48,
                                               busy: false, showsIcon: false))
        let unknown = face(.preparingDevice, rendering: true, renderPercent: nil)
        XCTAssertEqual(unknown, SingButtonFace(title: "Removing vocals…", value: "Removing vocals", progress: nil, busy: false,
                                               showsIcon: false))
        // The automatic studio's render has no wish behind it, yet the button shows it.
        XCTAssertEqual(face(.idle, rendering: true, renderPercent: 10).title, "Removing vocals 10 %")
    }

    func testTheSwitchShowsASpinnerAndWhatItWaitsFor() {
        let waiting = face(.waitingForGap)
        XCTAssertEqual(waiting.title, "Switching…")
        XCTAssertEqual(waiting.value, "Waiting for a quiet moment")
        XCTAssertTrue(waiting.busy)
        XCTAssertFalse(waiting.showsIcon)
        XCTAssertEqual(face(.switching).value, "Switching")
        XCTAssertTrue(face(.switching).busy)
    }

    private func face(_ phase: SingPhase, cloud: SingCloudStatus? = nil, rendering: Bool = false,
                      renderPercent: Int? = nil, active: Bool = false) -> SingButtonFace {
        SingButtonFace.make(phase: phase, cloudStatus: cloud, rendering: rendering, renderPercent: renderPercent,
                            active: active)
    }
}
