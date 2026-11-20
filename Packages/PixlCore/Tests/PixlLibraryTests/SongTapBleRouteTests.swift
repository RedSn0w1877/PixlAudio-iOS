import Foundation
import Testing
@testable import PixlLibrary

/// The Bluetooth route over fakes (Android `BleTransportTest`): the receiver follows a sender and connects when it is near,
/// the tap detector fires from the signal (and the sensor), the offer is read and checked against the receiver's own
/// challenge, and every failure (drop, duplicate, late, cancel, Bluetooth off, permission) ends in a state the session
/// understands.
@MainActor
@Suite("Song Tap Bluetooth route")
struct SongTapBleRouteTests {
    static let payload = SongTapPayload(
        v: 1, ts: 1_763_600_000_000, ytVideoId: "dQw4w9WgXcQ", spotifyId: "4uLU6hMCjMI75M1A2tKUQC", isrc: nil,
        title: "Never Gonna Give You Up", artist: "Rick Astley", durationMs: 213_000, artUrl: "https://i.ytimg.com/vi/x/y.jpg")
    static let payloadBytes = SongTapPayloads.encode(payload)!

    /// What a sender's GATT server would answer an Offer read with.
    static func frame(_ challenge: [UInt8], ts: Int64, signer: FakeSigner = FakeSigner(), body: [UInt8] = payloadBytes) -> [UInt8] {
        let message = SongTapSigning.signingBytes(payload: body, challenge: challenge, timestampMs: ts)!
        return SongTapSigning.encodeFrame(SongTapSignedOffer(payload: body, timestampMs: ts, publicKey: signer.publicKey, signature: signer.sign(message)!))!
    }

    /// A receiver that has found a sender, got near, and connected: the state a tap happens in.
    static func connectedReceiver() -> BleRig {
        let rig = BleRig()
        rig.route.start(role: .receive)
        rig.settle("S", .send)
        rig.listener.onConnected(address: "S", ok: true)
        return rig
    }

    static func sender() -> BleRig {
        let rig = BleRig()
        rig.route.start(role: .send)
        rig.settle("R", .receive)
        return rig
    }

    // MARK: Receiver

    @Test func aReceiverFollowsASenderAnnouncesItAndConnectsOnlyWhenItIsNear() {
        let rig = BleRig()
        rig.route.start(role: .receive)
        #expect(rig.route.status == .active)
        #expect(rig.impulses.running)

        rig.see("S", .send, -88)
        #expect(rig.founds.count == 1)
        #expect(rig.radio.count("connect") == 0)

        rig.settle("S", .send, rssi: -60)
        #expect(!rig.nears.isEmpty)
        #expect(rig.radio.calls.contains("connect:S"))
        #expect(rig.route.glow > 0)

        rig.listener.onConnected(address: "S", ok: true)
        #expect(rig.hellos.count == 1)
        #expect(rig.hellos[0].count == SongTapSigning.challengeBytes)
    }

    @Test func aSteadySignalFiresNothingAJumpThatHoldsFiresATapWithTheSendersRoleFirst() throws {
        let rig = Self.connectedReceiver()
        #expect(rig.taps.isEmpty)
        rig.touch("S", .send)
        #expect(rig.roles == [.send])
        #expect(rig.taps.count == 1)
        let roleAt = try #require(rig.events.firstIndex { if case .peerRole = $0 { true } else { false } })
        let tapAt = try #require(rig.events.firstIndex { if case .tap = $0 { true } else { false } })
        #expect(roleAt < tapAt)
        // The receiver tells the sender, in the same connection, that it felt a tap.
        #expect(rig.tapWrites == 1)
    }

    @Test func aJerkMakesTheSameJumpCountSoonerThanTheDwellDoes() {
        let dwell = Self.connectedReceiver()
        dwell.touch("S", .send, samples: 4)
        #expect(dwell.taps.isEmpty)

        let jerk = Self.connectedReceiver()
        jerk.clock.advance(100)
        jerk.impulses.jerk(atMs: jerk.clock.elapsed)
        jerk.touch("S", .send, samples: 4)
        #expect(jerk.taps.count == 1)
    }

    @Test func twoReceiversBesideEachOtherDoNothingForEachOther() {
        let rig = BleRig()
        rig.route.start(role: .receive)
        rig.settle("R", .receive)
        rig.touch("R", .receive)
        #expect(Set(rig.roles) == [.receive])
        #expect(rig.taps.isEmpty)
        #expect(rig.radio.count("connect") == 0)
    }

    @Test func readingAnOfferChecksTheSignatureAgainstTheChallengeThisReceiverGave() {
        let rig = Self.connectedReceiver()
        rig.touch("S", .send)
        let peer = rig.founds.last!
        rig.route.readOffer(peer: peer)
        #expect(rig.radio.calls.contains("readOffer:S"))

        rig.listener.onOfferRead(address: "S", value: Self.frame(rig.hellos.first!, ts: rig.clock.wall))
        #expect(rig.offers.count == 1)
        #expect(rig.offers[0].payload == Self.payloadBytes)
        #expect(rig.offers[0].senderKey != 0)
        #expect(rig.invalids == 0)
        // A fresh challenge is put out for the next beam.
        #expect(rig.hellos.count == 2)
    }

    @Test func anOfferSignedForAnotherChallengeIsRefused() {
        let rig = Self.connectedReceiver()
        rig.touch("S", .send)
        rig.route.readOffer(peer: rig.founds.last!)
        rig.listener.onOfferRead(address: "S", value: Self.frame([UInt8](repeating: 9, count: 16), ts: rig.clock.wall))
        #expect(rig.offers.isEmpty)
        #expect(rig.invalids == 1)
    }

    @Test func anOfferReplayedAfterItsChallengeWasUsedIsRefused() {
        let rig = Self.connectedReceiver()
        rig.touch("S", .send)
        let peer = rig.founds.last!
        let signed = Self.frame(rig.hellos.first!, ts: rig.clock.wall)
        rig.route.readOffer(peer: peer)
        rig.listener.onOfferRead(address: "S", value: signed)
        #expect(rig.offers.count == 1)
        // The same bytes again: the challenge is spent, the receiver has given a new one.
        rig.route.readOffer(peer: peer)
        rig.listener.onOfferRead(address: "S", value: signed)
        #expect(rig.offers.count == 1)
        #expect(rig.invalids == 1)
    }

    @Test func anOfferMadeAMinuteAgoAnAlteredPayloadAndGarbageAreRefused() {
        let rig = Self.connectedReceiver()
        rig.touch("S", .send)
        let peer = rig.founds.last!

        func attempt(_ bytes: [UInt8]) {
            rig.route.readOffer(peer: peer)
            rig.listener.onOfferRead(address: "S", value: bytes)
        }
        attempt(Self.frame(rig.hellos.first!, ts: rig.clock.wall - 60_000))
        let good = Self.frame(rig.hellos.last!, ts: rig.clock.wall)
        var altered = good
        altered[10] = altered[10] &+ 1
        attempt(altered)
        attempt([UInt8](repeating: 1, count: 40))
        #expect(rig.offers.isEmpty)
        #expect(rig.invalids == 3)
    }

    @Test func aSenderThatHasNoOfferYetIsAskedAgainThenGivenUpOn() {
        let rig = Self.connectedReceiver()
        rig.touch("S", .send)
        rig.route.readOffer(peer: rig.founds.last!)
        for _ in 0..<SongTapBleTuning.maxReadAttempts {
            rig.listener.onOfferRead(address: "S", value: nil)
            rig.advance(SongTapBleTuning.readRetryMs + 1)
        }
        #expect(rig.radio.count("readOffer") == SongTapBleTuning.maxReadAttempts)
        #expect(rig.invalids == 1)
    }

    @Test func ackGoesOutAsAWriteItsRoundTripIsMeasuredAndGoIsPassedOnWithIt() {
        let rig = Self.connectedReceiver()
        rig.touch("S", .send)
        let peer = rig.founds.last!
        rig.route.sendAck(peer: peer)
        #expect(rig.lastControl == .ack)
        rig.clock.advance(46)
        rig.listener.onControlWritten(address: "S", ok: true) // the Hello's answer (first in line)
        rig.listener.onControlWritten(address: "S", ok: true) // the Tap's
        rig.listener.onControlWritten(address: "S", ok: true) // the Ack's
        rig.listener.onNotified(address: "S", value: SongTapWire.encodeGo())
        #expect(rig.gos.count == 1)
        #expect(rig.gos[0].peer == peer)
        #expect(rig.gos[0].rttMs == 46)
    }

    @Test func losingTheConnectionInTheMiddleOfABeamIsALostPeerAndADuplicateGoIsHarmless() {
        let rig = Self.connectedReceiver()
        rig.touch("S", .send)
        let peer = rig.founds.last!
        rig.route.readOffer(peer: peer)
        rig.listener.onDisconnected(address: "S")
        #expect(rig.losts.contains(peer))

        // Late and duplicate notifications after the drop are ignored or passed once each, never crash.
        rig.listener.onNotified(address: "S", value: SongTapWire.encodeGo())
        rig.listener.onNotified(address: "S", value: [0x55])
        rig.listener.onOfferRead(address: "S", value: [0, 0, 0])
        #expect(rig.offers.isEmpty)
    }

    @Test func cancellingMidTransferClosesTheConnectionAndStopsAskingForTheOffer() {
        let rig = Self.connectedReceiver()
        rig.touch("S", .send)
        let peer = rig.founds.last!
        rig.route.readOffer(peer: peer)
        rig.route.abort(peer: peer)
        #expect(rig.radio.calls.contains("disconnect:S"))
        rig.listener.onOfferRead(address: "S", value: Self.frame(rig.hellos.first!, ts: rig.clock.wall))
        #expect(rig.offers.isEmpty)
    }

    @Test func aFailedConnectionIsRetriedAfterAPauseNotAtOnce() {
        let rig = BleRig()
        rig.route.start(role: .receive)
        rig.settle("S", .send)
        #expect(rig.radio.count("connect") == 1)
        rig.listener.onConnected(address: "S", ok: false)
        rig.see("S", .send, -60, stepMs: 100)
        #expect(rig.radio.count("connect") == 1)
        rig.see("S", .send, -60, stepMs: SongTapBleTuning.reconnectMs)
        #expect(rig.radio.count("connect") == 2)
    }

    @Test func thePhoneBeingFollowedLeavingIsALostPeerAndAQuietConnectionIsClosed() {
        let rig = Self.connectedReceiver()
        let peer = rig.founds.last!
        rig.advance(SongTapBleTuning.peerTimeoutMs + 1_000)
        #expect(rig.losts.contains(peer))
        #expect(rig.radio.calls.contains("disconnect:S"))
        #expect(rig.route.glow == 0)
    }

    @Test func resyncAnnouncesThePhoneThatIsCloseAgain() {
        let rig = Self.connectedReceiver()
        let before = rig.founds.count
        rig.route.resync()
        #expect(rig.founds.count == before + 1)
        #expect(!rig.nears.isEmpty)
    }

    @Test func theDiagnosticsSeeTheSignalWhileTheScreenIsOpenAndCostNothingOtherwise() {
        let diag = SongTapDiagnostics()
        let rig = BleRig(diag: diag)
        rig.route.start(role: .receive)
        rig.settle("S", .send, rssi: -60)
        #expect(diag.snapshot.rssi == 0)
        diag.setEnabled(true)
        rig.see("S", .send, -58)
        #expect(diag.snapshot.rssi == -58)
        #expect(diag.snapshot.focus.contains("sending"))
        #expect(diag.events.count <= SongTapDiagnostics.eventCapacity)
        #expect(diag.copyLog(device: "test").contains("recent signal"))
    }

    // MARK: Sender

    @Test func aSenderGivesNothingUntilAReceiverHasSaidHelloAndAnOfferIsPublished() throws {
        let rig = Self.sender()
        let client = "client-1"
        #expect(rig.route.serverOffer(client: client) == nil)
        rig.route.publishOffer(peer: 0, payload: Self.payloadBytes)
        #expect(rig.route.serverOffer(client: client) == nil) // no challenge yet
        let challenge = (0..<16).map { UInt8($0 + 1) }
        #expect(rig.route.serverControl(client: client, value: SongTapWire.encodeHello(challenge: challenge)!))
        let signed = try #require(rig.route.serverOffer(client: client))
        let offer = try #require(SongTapSigning.decodeFrame(signed))
        #expect(SongTapSigning.check(offer, challenge: challenge, nowMs: rig.clock.wall, verifier: FakeVerifier()) == .ok)
        // A challenge answers one read.
        #expect(rig.route.serverOffer(client: client) == nil)
    }

    @Test func aSenderSignsWithAKeyOfItsOwnForEachSession() throws {
        let a = Self.sender()
        let b = Self.sender()
        let challenge = [UInt8](repeating: 7, count: 16)
        for rig in [a, b] {
            rig.route.publishOffer(peer: 0, payload: Self.payloadBytes)
            _ = rig.route.serverControl(client: "c", value: SongTapWire.encodeHello(challenge: challenge)!)
        }
        let frameA = try #require(a.route.serverOffer(client: "c"))
        let frameB = try #require(b.route.serverOffer(client: "c"))
        let keyA = try #require(SongTapSigning.decodeFrame(frameA)).publicKey
        let keyB = try #require(SongTapSigning.decodeFrame(frameB)).publicKey
        #expect(keyA != keyB)
    }

    @Test func theInfoASenderServesIsHowLongAgoItWasJerked() {
        let rig = Self.sender()
        #expect(SongTapWire.decodeInfo(rig.route.serverInfo()) == -1)
        rig.clock.advance(50)
        rig.impulses.jerk(atMs: rig.clock.elapsed)
        rig.clock.advance(120)
        #expect(SongTapWire.decodeInfo(rig.route.serverInfo()) == 120)
    }

    @Test func ackAndDeclineFromTheReceiverReachTheSessionAndGoIsSentToThatReceiver() {
        let rig = Self.sender()
        let peer = rig.founds.last!
        _ = rig.route.serverControl(client: "c", value: SongTapWire.encodeHello(challenge: [UInt8](repeating: 0, count: 16))!)
        _ = rig.route.serverControl(client: "c", value: SongTapWire.encodeAck())
        #expect(rig.acks == [peer])
        rig.route.sendGo(peer: peer, startMs: 5)
        #expect(rig.radio.goNotifications == ["c"])
        _ = rig.route.serverControl(client: "c", value: SongTapWire.encodeDecline())
        #expect(rig.declines == [peer])
    }

    @Test func aReceiversTapMessageCountsOnlyWhenTheSendersOwnSignalJumpedToo() {
        let quiet = Self.sender()
        _ = quiet.route.serverControl(client: "c", value: SongTapWire.encodeTap(ageMs: 30))
        #expect(quiet.taps.isEmpty)

        let jumped = Self.sender()
        jumped.touch("R", .receive, samples: 3) // the jump has started but has not held long enough to fire alone
        _ = jumped.route.serverControl(client: "c", value: SongTapWire.encodeTap(ageMs: 30))
        #expect(!jumped.taps.isEmpty)
    }

    @Test func aSenderWhoseOwnDetectorFiresOffersByItself() {
        let rig = Self.sender()
        rig.touch("R", .receive)
        #expect(rig.taps.count == 1)
        #expect(rig.roles == [.receive])
    }

    @Test func twoSendersTouchingRaiseTheBothSendingRoleEventForTheSession() {
        let rig = BleRig()
        rig.route.start(role: .send)
        rig.settle("X", .send)
        rig.touch("X", .send)
        #expect(rig.roles.contains(.send))
    }

    @Test func aReceiverLeavingAfterAnOfferWasPublishedIsALostPeerBeforeThatItIsNothing() {
        let rig = Self.sender()
        _ = rig.route.serverControl(client: "c", value: SongTapWire.encodeHello(challenge: [UInt8](repeating: 0, count: 16))!)
        rig.route.serverClientGone(client: "c")
        #expect(rig.losts.isEmpty)

        _ = rig.route.serverControl(client: "c", value: SongTapWire.encodeHello(challenge: [UInt8](repeating: 0, count: 16))!)
        rig.route.publishOffer(peer: 0, payload: Self.payloadBytes)
        rig.route.serverClientGone(client: "c")
        #expect(rig.losts.count == 1)
    }

    @Test func aFrameThatWouldNotFitOneAttributeIsSentWithoutItsArt() throws {
        let rig = Self.sender()
        // A payload at the cap: 400 bytes; the frame is 142 bytes more, over the 512 of one attribute.
        let big = try #require(SongTapPayloads.make(
            nowMs: Self.payload.ts, ytVideoId: "dQw4w9WgXcQ", spotifyId: "4uLU6hMCjMI75M1A2tKUQC", isrc: "GBARL9300135",
            title: String(repeating: "\u{6771}", count: 33), artist: String(repeating: "\u{6771}", count: 26), durationMs: 200_000,
            artUrl: "https://i.ytimg.com/" + String(repeating: "p", count: 50)))
        let bytes = try #require(SongTapPayloads.encode(big))
        #expect(bytes.count + SongTapBleTuning.frameOverheadBytes > SongTapSigning.maxFrameBytes)
        rig.route.publishOffer(peer: 0, payload: bytes)
        _ = rig.route.serverControl(client: "c", value: SongTapWire.encodeHello(challenge: [UInt8](repeating: 3, count: 16))!)
        let signed = try #require(rig.route.serverOffer(client: "c"))
        let decoded = try #require(SongTapSigning.decodeFrame(signed))
        guard case .ok(let inside) = SongTapPayloads.decode(decoded.payload) else { Issue.record("payload did not decode"); return }
        #expect(inside.artUrl == nil)
        #expect(inside.title == big.title)
    }

    @Test func aReceiverDoesNotServeAndASenderWithAWithdrawnOfferGivesNothing() {
        let receiver = BleRig()
        receiver.route.start(role: .receive)
        receiver.route.publishOffer(peer: 0, payload: Self.payloadBytes)
        #expect(!receiver.route.serverControl(client: "c", value: SongTapWire.encodeHello(challenge: [UInt8](repeating: 0, count: 16))!))
        #expect(receiver.route.serverOffer(client: "c") == nil)

        let s = Self.sender()
        s.route.publishOffer(peer: 0, payload: Self.payloadBytes)
        _ = s.route.serverControl(client: "c", value: SongTapWire.encodeHello(challenge: [UInt8](repeating: 0, count: 16))!)
        s.route.withdrawOffer()
        #expect(s.route.serverOffer(client: "c") == nil)
    }

    @Test func malformedControlWritesAreRefusedAndChangeNothing() {
        let rig = Self.sender()
        #expect(!rig.route.serverControl(client: "c", value: []))
        #expect(!rig.route.serverControl(client: "c", value: [0x7f, 1, 2]))
        #expect(!rig.route.serverControl(client: "c", value: [UInt8(SongTapWire.opHello), 1, 2]))
        #expect(rig.events.filter { if case .peerFound = $0 { false } else if case .peerNear = $0 { false } else { true } }.isEmpty)
    }

    // MARK: Lifecycle

    @Test func stoppingStopsTheRadioAndTheSensorAndForgetsEveryone() {
        let rig = Self.connectedReceiver()
        rig.route.stop()
        #expect(rig.radio.calls.last == "stop")
        #expect(!rig.impulses.running)
        #expect(!rig.scheduler.isTicking)
        #expect(rig.route.status == .idle)
        #expect(rig.route.glow == 0)
        // Scan results that arrive late are ignored.
        let before = rig.events.count
        rig.see("S", .send, -40)
        #expect(rig.events.count == before)
    }

    @Test func withoutThePermissionNothingRunsAndItStartsWhenThePermissionArrives() {
        let rig = BleRig()
        rig.radio.startStatus = .noPermission
        rig.route.start(role: .receive)
        #expect(rig.route.status == .noPermission)
        #expect(!rig.impulses.running)

        rig.radio.startStatus = .active
        rig.route.restart()
        #expect(rig.route.status == .active)
        #expect(rig.impulses.running)
    }

    @Test func aRadioThatLearnsItsStateLaterStartsWhenItSaysSo() {
        // CoreBluetooth reports `.active` at once and the truth a moment after: not allowed, then allowed.
        let rig = BleRig()
        rig.route.start(role: .receive)
        rig.listener.onStatus(.noPermission)
        #expect(rig.route.status == .noPermission)
        #expect(!rig.impulses.running)
        rig.listener.onStatus(.active)
        #expect(rig.route.status == .active)
        #expect(rig.impulses.running)
        #expect(rig.scheduler.isTicking)
    }

    @Test func bluetoothSwitchedOffMidBeamLosesThePeerAndStopsTheSensorAndSwitchedOnAgainResumes() {
        let rig = Self.connectedReceiver()
        let peer = rig.founds.last!
        rig.listener.onStatus(.bluetoothOff)
        #expect(rig.losts.contains(peer))
        #expect(rig.route.status == .bluetoothOff)
        #expect(!rig.impulses.running)

        rig.listener.onStatus(.active)
        #expect(rig.route.status == .active)
        #expect(rig.impulses.running)
    }

    @Test func changingRoleStartsTheRadioAgainWithTheNewRole() {
        let rig = BleRig()
        rig.route.start(role: .send)
        rig.route.start(role: .receive)
        #expect(rig.radio.calls.filter { $0.hasPrefix("start") } == ["start:send", "start:receive"])
        #expect(rig.radio.calls.contains("stop"))
    }

    @Test func eventsReachTheEngineAfterTheCallThatRaisedThemAndInOrder() {
        // The engine may call straight back into the route from an event; nothing is delivered in the middle of a call.
        let rig = Self.connectedReceiver()
        var depth = 0
        var nested = 0
        rig.route.onEvent = { event in
            depth += 1
            if case .tap(let peer) = event { rig.route.readOffer(peer: peer) }
            if depth > 1 { nested += 1 }
            depth -= 1
            rig.events.append(event)
        }
        rig.touch("S", .send)
        #expect(nested == 0)
        #expect(rig.radio.calls.contains("readOffer:S"))
    }
}
