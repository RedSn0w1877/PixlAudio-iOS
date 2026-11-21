import Foundation
import Testing
@testable import PixlLibrary

/// What the Bluetooth tap added to the engine (Android `SongTapStateHolder`, milestone 2): the beam's own timer, the tap on the
/// sending side, the Bluetooth status, the resync after a result, the notice for a failure that had none, and the one-buzz rule.
@MainActor
@Suite("Song Tap engine, the beam")
struct SongTapEngineBeamTests {
    typealias Port = SongTapFlowTests.FakePort

    static func armed(_ role: SongTapRole, askFirst: Bool = false) -> (SongTapEngine, Port) {
        let port = Port()
        let engine = SongTapFlowTests.engine(port)
        engine.arm(role, askFirst: askFirst)
        return (engine, port)
    }

    /// A sender whose listener said yes to the phone near: found, near, yes, the phone read the offer, the two touch.
    static func senderCommitted() -> (SongTapEngine, Port) {
        let (engine, port) = armed(.send)
        engine.handle(.peerFound(3))
        engine.handle(.peerNear(3))
        engine.handle(.peerRole(peer: 3, role: .receive))
        engine.approve(peer: 3, name: "Ann", payload: SongTapFlowTests.offerPayload(at: port.now))
        engine.handle(.offerRead(peer: 3))
        engine.handle(.tap(peer: 3))
        return (engine, port)
    }

    /// ... and the receiver's acknowledgement arrives.
    static func senderBeaming() -> (SongTapEngine, Port) {
        let (engine, port) = senderCommitted()
        engine.handle(.ack(peer: 3))
        return (engine, port)
    }

    @Test func aTapCommitsAtOnceOnBothSidesAndANonPrefetchedReceiverJustReads() {
        let (sender, senderPort) = Self.armed(.send)
        sender.handle(.peerFound(3))
        sender.handle(.peerNear(3))
        sender.approve(peer: 3, name: "Ann", payload: SongTapFlowTests.offerPayload(at: senderPort.now))
        sender.handle(.offerRead(peer: 3))
        senderPort.log.removeAll()
        sender.handle(.tap(peer: 3))
        // No payload is asked for and nothing waits: the haptic and the beam start with the tap.
        #expect(senderPort.log.contains("haptic:tick") && senderPort.log.contains("schedule:ack:45000"))
        #expect(sender.ui.beamRole == .send)
        #expect(sender.session.phase == .transferring)

        let (receiver, receiverPort) = Self.armed(.receive)
        receiver.handle(.peerFound(4))
        receiver.handle(.peerRole(peer: 4, role: .send))
        receiver.handle(.tap(peer: 4))
        #expect(receiverPort.log.contains("read:4"))
    }

    @Test func theSendersBeamIsTheWholeSendAndEndsTheSession() {
        let (engine, port) = Self.senderBeaming()
        #expect(engine.ui.beamRole == .send)
        #expect(engine.ui.beamReduced == false)
        #expect(port.log.contains { $0.hasPrefix("beamEnd:") && $0 != "beamEnd:cancel" })
        engine.beamTimerFired()
        #expect(engine.ui.beamRole == nil)
        #expect(engine.session.phase == .saved)
    }

    @Test func aSendersBluetoothOfferIsKeptThroughTheBeamAndLetGoAfterIt() {
        let (engine, port) = Self.senderCommitted()
        #expect(engine.session.phase == .transferring)
        #expect(port.log.last { $0.hasPrefix("withdraw") } == "withdraw:keep", "the receiver's answer still has to be matched to the phone that read it")
        engine.handle(.ack(peer: 3))
        engine.beamTimerFired()
        #expect(engine.session.phase == .saved)
        #expect(port.log.last { $0.hasPrefix("withdraw") } == "withdraw")
    }

    @Test func aBeamEndsAtOnceWhenTheSessionFails() {
        let (engine, port) = Self.senderCommitted()
        #expect(engine.ui.beamRole == .send)
        engine.handle(.peerLost(3))
        #expect(engine.ui.beamRole == nil)
        #expect(engine.ui.beamStartMs == 0)
        #expect(port.log.contains("beamEnd:cancel"))
    }

    @Test func aFailureWithoutANoticeOfItsOwnIsWordedFromItsReason() {
        let (engine, _) = Self.senderCommitted()
        engine.handle(.peerLost(3))
        #expect(engine.session.phase == .failed)
        #expect(engine.ui.notice == .peerLost)
    }

    @Test func theBluetoothStatusIsShownToTheScreen() {
        let (engine, _) = Self.armed(.receive)
        #expect(engine.ui.bluetooth == .idle)
        engine.setBluetooth(.noPermission)
        #expect(engine.ui.bluetooth == .noPermission)
        engine.setBluetooth(.active)
        #expect(engine.ui.bluetooth == .active)
    }

    @Test func bluetoothGoingAwayUnderASenderArmedToAPhoneCancelsTheOffer() {
        let (engine, _) = Self.armed(.send)
        engine.handle(.peerFound(3))
        engine.handle(.peerNear(3))
        engine.approve(peer: 3, name: "Ann", payload: SongTapFlowTests.offerPayload(at: 1_763_600_000_000))
        #expect(engine.session.phase == .offered && engine.session.target == 3)
        engine.setBluetooth(.bluetoothOff)
        #expect(engine.session.phase == .armed, "cancelled, then dismissed")
        #expect(engine.ui.bluetooth == .bluetoothOff)
    }

    @Test func backToWaitingAfterAResultAsksTheRouteToAnnounceThePhoneThatIsClose() {
        let (engine, port) = Self.armed(.receive)
        engine.scanned(SongTapFlowTests.link(for: SongTapFlowTests.offerPayload(at: port.now)))
        engine.saveFinished(.notFound, for: port.saved[0])
        #expect(engine.session.phase == .failed)
        port.log.removeAll()
        engine.dismissTimerFired()
        #expect(engine.session.phase == .armed)
        #expect(port.log.contains("resync"))
    }

    @Test func theSessionsSuccessBuzzIsSkippedWhileABluetoothBeamPlaysSoItNeverBuzzesTwice() {
        let (engine, port) = Self.senderBeaming()
        engine.beamTimerFired()
        #expect(!port.log.contains("haptic:success"))
        #expect(engine.ui.notice == nil)
    }

    @Test func anEventRaisedInTheMiddleOfAnotherWaitsForItsTurn() {
        // The transport may answer the call the engine just made with an event of its own: the state machine never sees two at once.
        let (engine, port) = Self.armed(.receive)
        engine.handle(.peerFound(4))
        engine.handle(.peerRole(peer: 4, role: .send))
        engine.handle(.tap(peer: 4))
        #expect(port.log.contains("read:4"))
        #expect(engine.session.phase == .transferring || engine.session.phase == .offered || engine.session.phase == .near || engine.session.phase == .found)
    }
}
