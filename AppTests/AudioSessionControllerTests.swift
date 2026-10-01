import AVFoundation
import PixlAudioCore
import XCTest
@testable import PixlAudio

/// Interruptions (PixlAudioCore's `AudioFocusResumeState`), route changes and media-services resets as seen by
/// `AudioSessionController`, including parsing of the real notification payloads.
@MainActor
final class AudioSessionControllerTests: XCTestCase {
    private func makeController(playing: Bool) -> (AudioSessionController, () -> [AudioSessionController.Command]) {
        let controller = AudioSessionController()
        var commands: [AudioSessionController.Command] = []
        controller.deckSnapshot = {
            DeckPlaybackSnapshot(masterPlayWhenReady: playing, masterIsPlaying: playing, transitionRunning: false)
        }
        controller.onCommand = { commands.append($0) }
        return (controller, { commands })
    }

    func testInterruptionPausesAndResumesWhenTheSystemSaysSo() {
        let (controller, commands) = makeController(playing: true)
        controller.handleInterruption(began: true, shouldResume: false)
        XCTAssertEqual(commands(), [.focus([.pauseMaster, .pauseAuxiliary])])
        XCTAssertTrue(controller.focus.isFocusLossPause)
        controller.handleInterruption(began: false, shouldResume: true)
        XCTAssertEqual(commands().last, .focus([.resumeMaster]))
        XCTAssertFalse(controller.focus.isFocusLossPause)
    }

    func testInterruptionEndedWithoutShouldResumeStaysPaused() {
        let (controller, commands) = makeController(playing: true)
        controller.handleInterruption(began: true, shouldResume: false)
        controller.handleInterruption(began: false, shouldResume: false)
        XCTAssertEqual(commands().count, 1)
        XCTAssertFalse(controller.focus.isFocusLossPause)
    }

    func testInterruptionWhilePausedNeverResumes() {
        let (controller, commands) = makeController(playing: false)
        controller.handleInterruption(began: true, shouldResume: false)
        controller.handleInterruption(began: false, shouldResume: true)
        XCTAssertEqual(commands(), [.focus([.pauseMaster, .pauseAuxiliary])])
    }

    func testCrossfadeInterruptionResumesBothDecks() {
        let controller = AudioSessionController()
        var commands: [AudioSessionController.Command] = []
        controller.deckSnapshot = {
            DeckPlaybackSnapshot(masterPlayWhenReady: false, masterIsPlaying: false, transitionRunning: true,
                                 auxiliaryPlayWhenReady: true, auxiliaryIsPlaying: true)
        }
        controller.isTransitionRunning = { true }
        controller.onCommand = { commands.append($0) }
        controller.handleInterruption(began: true, shouldResume: false)
        controller.handleInterruption(began: false, shouldResume: true)
        XCTAssertEqual(commands.last, .focus([.resumeMaster, .resumeAuxiliary]))
    }

    func testRouteLossPausesAndReconnectResumesOnlyWhenEnabled() {
        let (controller, commands) = makeController(playing: true)
        controller.handleRouteChange(reason: .oldDeviceUnavailable)
        XCTAssertEqual(commands(), [.pauseForRouteLoss])
        controller.handleRouteChange(reason: .newDeviceAvailable)
        XCTAssertEqual(commands(), [.pauseForRouteLoss, .routeChanged])

        let (resuming, resumingCommands) = makeController(playing: true)
        resuming.resumeOnHeadsetReconnect = true
        resuming.handleRouteChange(reason: .oldDeviceUnavailable)
        resuming.handleRouteChange(reason: .newDeviceAvailable)
        XCTAssertEqual(resumingCommands(), [.pauseForRouteLoss, .resumeForRouteReturn, .routeChanged])
    }

    func testMediaServicesResetAsksForARebuild() {
        let (controller, commands) = makeController(playing: true)
        controller.handleInterruption(began: true, shouldResume: false)
        controller.handleMediaServicesReset()
        XCTAssertEqual(commands().last, .rebuildAfterReset)
        XCTAssertFalse(controller.focus.isFocusLossPause)
    }

    func testParsesSystemNotificationPayloads() {
        let began = Notification(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
            AVAudioSessionInterruptionTypeKey: NSNumber(value: AVAudioSession.InterruptionType.began.rawValue),
        ])
        XCTAssertTrue(AudioSessionController.interruptionInfo(began).began)
        let ended = Notification(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
            AVAudioSessionInterruptionTypeKey: NSNumber(value: AVAudioSession.InterruptionType.ended.rawValue),
            AVAudioSessionInterruptionOptionKey: NSNumber(value: AVAudioSession.InterruptionOptions.shouldResume.rawValue),
        ])
        let info = AudioSessionController.interruptionInfo(ended)
        XCTAssertFalse(info.began)
        XCTAssertTrue(info.shouldResume)
        let route = Notification(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: [
            AVAudioSessionRouteChangeReasonKey: NSNumber(value: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue),
        ])
        XCTAssertEqual(AudioSessionController.routeChangeReason(route), .oldDeviceUnavailable)
    }

    func testPostedInterruptionNotificationReachesTheController() async {
        let session = AVAudioSession.sharedInstance()
        let controller = AudioSessionController(session: session)
        var commands: [AudioSessionController.Command] = []
        controller.deckSnapshot = {
            DeckPlaybackSnapshot(masterPlayWhenReady: true, masterIsPlaying: true, transitionRunning: false)
        }
        controller.onCommand = { commands.append($0) }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: session, userInfo: [
            AVAudioSessionInterruptionTypeKey: NSNumber(value: AVAudioSession.InterruptionType.began.rawValue),
        ])
        let received = await waitUntil(timeout: 2) { !commands.isEmpty }
        XCTAssertTrue(received)
        XCTAssertEqual(commands.first, .focus([.pauseMaster, .pauseAuxiliary]))
    }
}
