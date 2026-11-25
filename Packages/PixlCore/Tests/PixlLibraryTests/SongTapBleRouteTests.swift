import Foundation
import Testing
@testable import PixlLibrary

/// The Bluetooth route over fakes (Android `BleTransportTest`, spec 6): the receiver follows a sender and connects only inside the near
/// gate, reads the name and the signed offer before any tap, the tap detector fires from the signal (and the sensor), the one-sided tap
/// commits the other phone at once, the offer is checked against the receiver's own challenge, a sender serves only the phone the
/// listener said yes to, and every failure (drop, duplicate, late, cancel, Bluetooth off, permission) ends in a state the session
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

    static func hello(_ fill: UInt8 = 0) -> [UInt8] { SongTapWire.encodeHello(challenge: [UInt8](repeating: fill, count: 16))! }

    /// A receiver that has found a sender, got near, and connected: the state a tap happens in.
    static func connectedReceiver() -> BleRig {
        let rig = BleRig()
        rig.route.start(role: .receive)
        rig.settle("S", .send)
        rig.listener.onConnected(address: "S", ok: true)
        return rig
    }

    /// A connected receiver that already holds the sender's checked offer (the sender said yes and the fetch is done).
    static func receiverWithOfferInHand() -> BleRig {
        let rig = connectedReceiver()
        rig.listener.onOfferRead(address: "S", value: frame(rig.hellos.first!, ts: rig.clock.wall))
        #expect(rig.prefetched.count == 1)
        return rig
    }

    /// A sender that sees a receiver resting beside it (no yes yet).
    static func sender() -> BleRig {
        let rig = BleRig()
        rig.route.start(role: .send)
        rig.settle("R", .receive)
        return rig
    }

    /// A sender whose listener said yes to the receiver "R": the offer is published for that phone only.
    static func armedSender() -> (rig: BleRig, peer: Int) {
        let rig = sender()
        let peer = rig.founds.last!
        rig.route.publishOffer(peer: peer, payload: payloadBytes)
        return (rig, peer)
    }

    // MARK: Receiver

    @Test func aReceiverFollowsASenderAnnouncesItAndConnectsOnlyInsideTheNearGate() {
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
        // Before any tap: the name and the offer are asked for.
        #expect(rig.radio.calls.contains("readName:S"))
        #expect(rig.radio.count("readOffer") == 1)
    }

    @Test func aSignalThatIsOnlyInsideTheListGateCannotConnectOrTapHoweverItMoves() {
        let rig = BleRig()
        rig.route.start(role: .receive)
        rig.settle("S", .send, rssi: BleRig.listOnlyDbm, samples: 20)
        #expect(rig.radio.count("connect") == 0)
        #expect(rig.nears.isEmpty)
        rig.touch("S", .send, rssi: BleRig.listOnlyDbm + 8, samples: 10)
        #expect(rig.taps.isEmpty)
        #expect(rig.radio.count("connect") == 0)
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
        // The receiver tells the sender, in the same connection, that it felt a tap (the one-sided tap).
        #expect(rig.tapWrites == 1)
    }

    @Test func phonesBroughtTogetherGentlyAndHeldFireWithoutAnyBump() {
        let rig = Self.connectedReceiver()
        // A slow rise from resting distance to a few centimetres, half a dB a reading: no jump at any moment, no jerk, and still short of -45.
        for r in (-60 ... -47).flatMap({ [$0, $0] }) { rig.see("S", .send, r) }
        #expect(rig.taps.isEmpty)
        for _ in 0..<6 { rig.see("S", .send, -40) }
        #expect(rig.taps.count == 1)
        rig.settle("S", .send, rssi: -40, samples: 25)
        #expect(rig.taps.count == 1)
    }

    @Test func aJerkMakesTheSameJumpCountSoonerThanTheDwellDoes() {
        let dwell = Self.connectedReceiver()
        dwell.touch("S", .send, samples: 2)
        #expect(dwell.taps.isEmpty)

        let jerk = Self.connectedReceiver()
        jerk.clock.advance(100)
        jerk.impulses.jerk(atMs: jerk.clock.elapsed)
        jerk.touch("S", .send, samples: 2)
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

    @Test func theOfferIsFetchedAndCheckedBeforeTheTapAndTheTapReadsNothing() throws {
        let rig = Self.connectedReceiver()
        let peer = rig.founds.last!
        #expect(rig.radio.count("readOffer") == 1)
        // The sender's answer to the read that went out when the connection came up.
        rig.listener.onOfferRead(address: "S", value: Self.frame(rig.hellos.first!, ts: rig.clock.wall))
        let ahead = try #require(rig.prefetched.first)
        #expect(ahead.peer == peer)
        #expect(ahead.payload == Self.payloadBytes)
        #expect(ahead.senderKey != 0)
        #expect(rig.offers.isEmpty)
        // The next challenge is already out for the beam after this one.
        #expect(rig.hellos.count == 2)

        // The tap: the session already holds the offer (it has the event above), so nothing is read and nothing is waited for.
        rig.touch("S", .send)
        #expect(rig.taps.count == 1)
        let preAt = try #require(rig.events.firstIndex { if case .offerPrefetched = $0 { true } else { false } })
        let tapAt = try #require(rig.events.firstIndex { if case .tap = $0 { true } else { false } })
        #expect(preAt < tapAt)
        #expect(rig.radio.count("readOffer") == 1)
        #expect(rig.offers.isEmpty)
        // And a late fallback read after the tap does not hand out the same offer twice.
        rig.route.readOffer(peer: peer)
        #expect(rig.offers.isEmpty)
    }

    @Test func theSendersNotificationThatItHasAnOfferStartsTheFetchAndAQuietSenderIsAskedAgainLater() {
        let rig = Self.connectedReceiver()
        // It had nothing the first time.
        rig.listener.onOfferRead(address: "S", value: nil)
        #expect(rig.prefetched.isEmpty)
        #expect(rig.radio.count("readOffer") == 1)
        rig.listener.onNotified(address: "S", value: SongTapWire.encodeOfferReady())
        #expect(rig.radio.count("readOffer") == 2)
        rig.listener.onOfferRead(address: "S", value: nil)

        // No notification: it is asked again after a pause (the sender's word is the fast path, not the only one).
        rig.see("S", .send, BleRig.nearDbm, stepMs: SongTapBleTuning.prefetchRetryMs + 100)
        rig.advance(SongTapBleTuning.tickMs + 1)
        #expect(rig.radio.count("readOffer") == 3)
    }

    @Test func anOfferInHandIsLetGoWhenTheConnectionGoesOrTheSenderWithdrawsItOrAnswersARefreshWithNothing() {
        let rig = Self.connectedReceiver()
        let peer = rig.founds.last!
        rig.listener.onOfferRead(address: "S", value: Self.frame(rig.hellos.first!, ts: rig.clock.wall))
        #expect(rig.prefetched.count == 1)
        rig.listener.onNotified(address: "S", value: SongTapWire.encodeOfferWithdrawn())
        #expect(rig.gones == [peer])

        // The same when a refresh read finds the sender with nothing.
        rig.listener.onNotified(address: "S", value: SongTapWire.encodeOfferReady())
        rig.listener.onOfferRead(address: "S", value: Self.frame(rig.hellos.last!, ts: rig.clock.wall))
        #expect(rig.prefetched.count == 2)
        rig.listener.onNotified(address: "S", value: SongTapWire.encodeOfferReady())
        rig.listener.onOfferRead(address: "S", value: nil)
        #expect(rig.gones.count == 2)

        // And when the connection goes.
        rig.listener.onNotified(address: "S", value: SongTapWire.encodeOfferReady())
        rig.listener.onOfferRead(address: "S", value: Self.frame(rig.hellos.last!, ts: rig.clock.wall))
        #expect(rig.prefetched.count == 3)
        rig.listener.onDisconnected(address: "S")
        #expect(rig.gones.count == 3)
        // The tap after that has nothing in hand: the offer is read the slow way.
        rig.touch("S", .send)
        rig.route.readOffer(peer: peer)
        #expect(rig.offers.isEmpty)
    }

    @Test func anOfferThatFailsItsCheckAheadOfTheTapIsNotHeld() {
        let rig = Self.connectedReceiver()
        rig.listener.onOfferRead(address: "S", value: Self.frame([UInt8](repeating: 9, count: 16), ts: rig.clock.wall))
        #expect(rig.prefetched.isEmpty)
        #expect(rig.invalids == 0)
    }

    @Test func theSendersNameComesFromItsAdvertisementAndThenFromItsNameCharacteristic() {
        let rig = BleRig()
        rig.route.start(role: .receive)
        rig.settle("S", .send, samples: 2, name: "Zed")
        let peer = rig.founds.last!
        #expect(rig.names.last?.name == "Zed")
        #expect(rig.route.nameOf(peer) == "Zed")
        rig.listener.onConnected(address: "S", ok: true)
        rig.listener.onNameRead(address: "S", value: SongTapWire.encodeName("Zed's iPhone 17 Pro"))
        #expect(rig.names.last?.name == "Zed's iPhone 17 Pro")
        #expect(rig.route.nameOf(peer) == "Zed's iPhone 17 Pro")
        // A hostile name value changes nothing.
        rig.listener.onNameRead(address: "S", value: [1, 0x20])
        rig.listener.onNameRead(address: "S", value: nil)
        #expect(rig.route.nameOf(peer) == "Zed's iPhone 17 Pro")
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
        let before = rig.radio.count("readOffer")
        rig.route.readOffer(peer: rig.founds.last!)
        for i in 0..<SongTapBleTuning.maxReadAttempts {
            rig.listener.onOfferRead(address: "S", value: nil)
            // The last answer is the one the route gives up on; time passing after that would only start the ordinary prefetch again.
            if i < SongTapBleTuning.maxReadAttempts - 1 { rig.advance(SongTapBleTuning.readRetryMs + 1) }
        }
        #expect(rig.radio.count("readOffer") - before == SongTapBleTuning.maxReadAttempts)
        #expect(rig.invalids == 1)
    }

    @Test func ackGoesOutAsAWriteAndTheOldGoNotificationIsIgnored() {
        let rig = Self.connectedReceiver()
        rig.touch("S", .send)
        let peer = rig.founds.last!
        rig.route.sendAck(peer: peer)
        #expect(rig.lastControl == .ack)
        let before = rig.events.count
        rig.listener.onNotified(address: "S", value: SongTapWire.encodeGo())
        rig.listener.onNotified(address: "S", value: [0x55])
        #expect(rig.events.count == before)
    }

    @Test func losingTheConnectionInTheMiddleOfABeamIsALostPeerAndLateBytesAreHarmless() {
        let rig = Self.connectedReceiver()
        rig.touch("S", .send)
        let peer = rig.founds.last!
        rig.route.readOffer(peer: peer)
        rig.listener.onDisconnected(address: "S")
        #expect(rig.losts.contains(peer))
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
        #expect(diag.snapshot.profile == "high")
        #expect(diag.snapshot.offsetDb == 0 && diag.snapshot.normalised == -58)
        #expect(diag.snapshot.gate == "tap near" && diag.snapshot.mayConnect)
        #expect(diag.events.count <= SongTapDiagnostics.eventCapacity)
        let log = diag.copyLog(device: "test")
        #expect(log.contains("recent signal"))
        #expect(log.contains("gates: nearEnter=-70 nearExit=-78 listEnter=-85 listExit=-92 closeHold=-45 dBm for 250 ms, released below -55"))
        #expect(log.contains("signal offset: 0 dB"))
    }

    // MARK: Sender

    @Test func aSenderGivesNothingUntilAReceiverHasSaidHelloAndAnOfferIsPublishedForAPhone() throws {
        let rig = Self.sender()
        let peer = rig.founds.last!
        let client = "client-1"
        #expect(rig.route.serverOffer(client: client) == nil)
        // An offer for nobody (no yes to any phone) is served to nobody.
        rig.route.publishOffer(peer: 0, payload: Self.payloadBytes)
        let challenge = (0..<16).map { UInt8($0 + 1) }
        #expect(rig.route.serverControl(client: client, value: SongTapWire.encodeHello(challenge: challenge)!))
        #expect(rig.route.serverOffer(client: client) == nil)
        rig.route.publishOffer(peer: peer, payload: Self.payloadBytes)
        let signed = try #require(rig.route.serverOffer(client: client))
        let offer = try #require(SongTapSigning.decodeFrame(signed))
        #expect(SongTapSigning.check(offer, challenge: challenge, nowMs: rig.clock.wall, verifier: FakeVerifier()) == .ok)
        #expect(rig.reads == [peer])
        // A challenge answers one read.
        #expect(rig.route.serverOffer(client: client) == nil)
    }

    @Test func aSenderSignsWithAKeyOfItsOwnForEachSession() throws {
        let a = Self.sender()
        let b = Self.sender()
        let challenge = [UInt8](repeating: 7, count: 16)
        for rig in [a, b] {
            rig.route.publishOffer(peer: rig.founds.last!, payload: Self.payloadBytes)
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

    @Test func theSenderServesItsOwnNameCleanedAndAdvertisesIt() {
        let rig = BleRig()
        rig.route.setOwnName("  Hoa's    iPhone \u{202E} ")
        rig.route.start(role: .send)
        #expect(SongTapWire.decodeName(rig.route.serverName()) == "Hoa's iPhone")
        #expect(rig.radio.advertisedName == "Hoa's iPhone")
        // Nothing usable: the fallback, never an empty name.
        let blank = BleRig()
        blank.route.setOwnName("\u{202E}  ")
        blank.route.start(role: .receive)
        #expect(blank.radio.advertisedName == SongTapNames.fallback)
    }

    @Test func ackAndDeclineFromTheReceiverReachTheSession() {
        let (rig, peer) = Self.armedSender()
        _ = rig.route.serverControl(client: "c", value: Self.hello())
        #expect(rig.route.serverOffer(client: "c") != nil)
        _ = rig.route.serverControl(client: "c", value: SongTapWire.encodeAck())
        #expect(rig.acks == [peer])
        _ = rig.route.serverControl(client: "c", value: SongTapWire.encodeDecline())
        #expect(rig.declines == [peer])
    }

    @Test func ackAndDeclineBelongToThePhoneThatReadTheOfferAndNobodyElse() {
        let (rig, _) = Self.armedSender()
        _ = rig.route.serverControl(client: "reader", value: Self.hello(1))
        _ = rig.route.serverControl(client: "stranger", value: Self.hello(2))
        #expect(rig.route.serverOffer(client: "reader") != nil)
        // Once somebody has read it, nobody else is given it, and nobody else can answer for it.
        #expect(rig.route.serverOffer(client: "stranger") == nil)
        _ = rig.route.serverControl(client: "stranger", value: SongTapWire.encodeAck())
        _ = rig.route.serverControl(client: "stranger", value: SongTapWire.encodeDecline())
        #expect(rig.acks.isEmpty && rig.declines.isEmpty)
        _ = rig.route.serverControl(client: "reader", value: SongTapWire.encodeAck())
        #expect(rig.acks.count == 1)
    }

    @Test func aLateAckFromTheLastOffersReceiverIsNotAnAckForTheNextOffer() {
        let (rig, peer) = Self.armedSender()
        _ = rig.route.serverControl(client: "first", value: Self.hello(1))
        #expect(rig.route.serverOffer(client: "first") != nil)
        rig.route.withdrawOffer() // timed out
        rig.route.publishOffer(peer: peer, payload: Self.payloadBytes)
        _ = rig.route.serverControl(client: "first", value: SongTapWire.encodeAck())
        #expect(rig.acks.isEmpty)
        _ = rig.route.serverControl(client: "second", value: Self.hello(3))
        #expect(rig.route.serverOffer(client: "second") != nil)
        _ = rig.route.serverControl(client: "second", value: SongTapWire.encodeAck())
        #expect(rig.acks.count == 1)
    }

    @Test func publishingTellsThePhonesThatAreConnectedThereIsSomethingToRead() {
        let rig = Self.sender()
        _ = rig.route.serverControl(client: "c", value: Self.hello())
        #expect(rig.radio.notifications.isEmpty)
        rig.route.publishOffer(peer: rig.founds.last!, payload: Self.payloadBytes)
        #expect(rig.radio.notifications.map(\.client) == ["c"])
        #expect(SongTapWire.isOfferReady(rig.radio.notifications[0].value))
    }

    @Test func withdrawingTellsThePhonesThatAreConnectedToLetTheOfferGo() {
        let (rig, _) = Self.armedSender()
        _ = rig.route.serverControl(client: "c", value: Self.hello())
        rig.radio.notifications.removeAll()
        rig.route.withdrawOffer()
        #expect(rig.radio.notifications.map(\.client) == ["c"])
        #expect(SongTapWire.isOfferWithdrawn(rig.radio.notifications[0].value))
        // Nothing on offer, nothing to withdraw.
        rig.radio.notifications.removeAll()
        rig.route.withdrawOffer()
        #expect(rig.radio.notifications.isEmpty)
    }

    // MARK: The one-sided tap

    @Test func aReceiversTapMessageIsTakenAtOnceWithoutTheSendersOwnDetectorFromThePhoneThatReadTheOffer() {
        let (rig, peer) = Self.armedSender()
        _ = rig.route.serverControl(client: "reader", value: Self.hello(1))
        _ = rig.route.serverControl(client: "other", value: Self.hello(2))
        // Nobody has read the offer yet: the sender has not "said yes" to anybody's reading, so the message is not believed.
        _ = rig.route.serverControl(client: "reader", value: SongTapWire.encodeTap(ageMs: 30))
        #expect(rig.taps.isEmpty)
        #expect(rig.route.serverOffer(client: "reader") != nil)
        // A phone that did not read it is not the receiver.
        _ = rig.route.serverControl(client: "other", value: SongTapWire.encodeTap(ageMs: 30))
        #expect(rig.taps.isEmpty)
        // The reader's message counts although this phone's own signal for it has not moved at all (resting 20 to 30 cm apart).
        _ = rig.route.serverControl(client: "reader", value: SongTapWire.encodeTap(ageMs: 30))
        #expect(rig.taps == [peer])
        #expect(rig.route.lastPeerTapNote.contains("accept"))
    }

    @Test func aReceiversTapMessageIsIgnoredBelowTheNearGateOrFromAPhoneThatIsNotFollowed() {
        let (rig, peer) = Self.armedSender()
        _ = rig.route.serverControl(client: "c", value: Self.hello())
        #expect(rig.route.serverOffer(client: "c") != nil)
        // The followed phone drifts to a few metres (-80 is inside the list gate, outside the near gate): the message is not believed.
        for _ in 0..<6 { rig.see("R", .receive, BleRig.listOnlyDbm) }
        _ = rig.route.serverControl(client: "c", value: SongTapWire.encodeTap(ageMs: 30))
        #expect(rig.taps.isEmpty)
        #expect(rig.diag.events.last?.text.contains("too_weak") == true)
        // Another phone coming in strongly does not make a message count either: the sender follows the phone it said yes to.
        rig.settle("Q", .receive, rssi: -40)
        _ = rig.route.serverControl(client: "c", value: SongTapWire.encodeTap(ageMs: 30))
        #expect(rig.taps.isEmpty)
        // Back close: it counts.
        rig.settle("R", .receive, rssi: BleRig.nearDbm, samples: 6)
        _ = rig.route.serverControl(client: "c", value: SongTapWire.encodeTap(ageMs: 30))
        #expect(rig.taps == [peer])
    }

    @Test func theSenderAcceptsOneReceiverTapPer1200MsAndNoEchoGoesBack() {
        let (rig, _) = Self.armedSender()
        _ = rig.route.serverControl(client: "c", value: Self.hello())
        #expect(rig.route.serverOffer(client: "c") != nil)
        rig.radio.notifications.removeAll()
        _ = rig.route.serverControl(client: "c", value: SongTapWire.encodeTap(ageMs: 30))
        _ = rig.route.serverControl(client: "c", value: SongTapWire.encodeTap(ageMs: 30))
        #expect(rig.taps.count == 1)
        // This phone's own detector firing a moment later (the touch is real on both) tells nobody again.
        rig.touch("R", .receive, samples: 4)
        #expect(rig.radio.notifications.filter { SongTapWire.isTapEvent($0.value) }.isEmpty)
        rig.clock.advance(SongTapPeerTap.minGapMs + 100)
        _ = rig.route.serverControl(client: "c", value: SongTapWire.encodeTap(ageMs: 30))
        #expect(rig.taps.count >= 2)
    }

    @Test func aSendersOwnTapIsToldToThePhoneThatReadTheOfferAtOnceAsTheSingleByte04() {
        let (rig, _) = Self.armedSender()
        _ = rig.route.serverControl(client: "reader", value: Self.hello(1))
        // Nobody has read the offer: nobody is told.
        rig.touch("R", .receive, samples: 8)
        #expect(rig.taps.count == 1)
        #expect(rig.radio.notifications.filter { SongTapWire.isTapEvent($0.value) }.isEmpty)

        let (rig2, _) = Self.armedSender()
        _ = rig2.route.serverControl(client: "reader", value: Self.hello(1))
        #expect(rig2.route.serverOffer(client: "reader") != nil)
        rig2.radio.notifications.removeAll()
        rig2.touch("R", .receive, samples: 8)
        #expect(rig2.taps.count == 1)
        let told = rig2.radio.notifications.filter { SongTapWire.isTapEvent($0.value) }
        #expect(told.map(\.client) == ["reader"])
        #expect(told[0].value == [0x04])
        // Once only, however long the phones stay together.
        rig2.settle("R", .receive, rssi: BleRig.touchDbm, samples: 20)
        #expect(rig2.radio.notifications.filter { SongTapWire.isTapEvent($0.value) }.count == 1)
    }

    @Test func theSendersTapEventCommitsTheReceiverAtOnceWithThePhonesOnlyRestingBesideEachOther() {
        let rig = Self.receiverWithOfferInHand()
        #expect(rig.taps.isEmpty)
        rig.listener.onNotified(address: "S", value: SongTapWire.encodeTapEvent())
        #expect(rig.taps.count == 1)
        // The session holds the offer from here on; nothing is written back (the sender already knows).
        #expect(rig.tapWrites == 0)
        // The receiver's own detector firing a moment later does not tell the sender again.
        rig.touch("S", .send, samples: 6)
        #expect(rig.tapWrites == 0)
        #expect(rig.taps.count <= 2)
    }

    @Test func theSendersTapEventIsIgnoredWithNoOfferInHandBelowTheNearGateOrFromAPhoneThatIsNotFollowed() {
        // No offer in hand: the sender has not said yes.
        let noOffer = Self.connectedReceiver()
        noOffer.listener.onNotified(address: "S", value: SongTapWire.encodeTapEvent())
        #expect(noOffer.taps.isEmpty)
        #expect(noOffer.diag.events.last?.text.contains("no_yes") == true)

        // The sender is a few metres away: this phone's own signal is below the gate.
        let far = Self.receiverWithOfferInHand()
        for _ in 0..<5 { far.see("S", .send, BleRig.listOnlyDbm) }
        far.listener.onNotified(address: "S", value: SongTapWire.encodeTapEvent())
        #expect(far.taps.isEmpty)
        #expect(far.diag.events.last?.text.contains("too_weak") == true)

        // Not the followed phone: an address this phone never saw changes nothing.
        let rig = Self.receiverWithOfferInHand()
        rig.listener.onNotified(address: "stranger", value: SongTapWire.encodeTapEvent())
        #expect(rig.taps.isEmpty)
        // Garbage that merely starts with the byte is not an event.
        rig.listener.onNotified(address: "S", value: [0x04, 0x00])
        #expect(rig.taps.isEmpty)
    }

    @Test func aSecondTapEventInside1200MsIsIgnored() {
        let rig = Self.receiverWithOfferInHand()
        rig.listener.onNotified(address: "S", value: SongTapWire.encodeTapEvent())
        rig.listener.onNotified(address: "S", value: SongTapWire.encodeTapEvent())
        #expect(rig.taps.count == 1)
    }

    // MARK: Sensitivity

    @Test func theSensitivityIsAppliedLiveNormalNeedsAFirmerJumpThanHigh() {
        // A 12 dB step held for a second: nothing for normal (15 dB), a tap for high (9 dB).
        func tapsAt(_ profile: SongTapSensitivity) -> Int {
            let rig = BleRig()
            rig.route.setSensitivity(profile)
            rig.route.start(role: .receive)
            rig.settle("S", .send, rssi: -62, samples: 10)
            rig.touch("S", .send, rssi: -50, samples: 10)
            return rig.taps.count
        }
        #expect(tapsAt(.normal) == 0)
        #expect(tapsAt(.high) == 1)
        // Live: the sensor's profile follows, and the route reports it.
        let rig = BleRig()
        rig.route.start(role: .receive)
        #expect(rig.route.sensitivity() == .high && rig.impulses.profile == .high)
        rig.route.setSensitivity(.normal)
        #expect(rig.route.sensitivity() == .normal && rig.impulses.profile == .normal)
    }

    @Test func aJerkTheOtherPhoneClaimsShortensTheHoldOnlyWhenItIsClose() {
        let close = BleRig()
        close.route.start(role: .receive)
        close.settle("S", .send, rssi: -62)
        close.listener.onConnected(address: "S", ok: true)
        close.touch("S", .send, rssi: -40, samples: 1)
        close.listener.onInfoRead(address: "S", value: SongTapWire.encodeInfo(ageMs: 0))
        close.touch("S", .send, rssi: -40, samples: 1)
        #expect(close.taps.count == 1, "100 ms into the jump, the dwell is 200 and the jerk makes it 60")

        let far = BleRig()
        far.route.start(role: .receive)
        far.settle("S", .send, rssi: -90)
        far.listener.onConnected(address: "S", ok: true)
        far.touch("S", .send, rssi: -66, samples: 1)
        far.listener.onInfoRead(address: "S", value: SongTapWire.encodeInfo(ageMs: 0))
        far.touch("S", .send, rssi: -66, samples: 1)
        #expect(far.taps.isEmpty)
    }

    // MARK: Sender, more

    @Test func aSendersOwnDetectorFiresOnlyForThePhoneTheListenerSaidYesTo() {
        let (rig, peer) = Self.armedSender()
        rig.settle("Q", .receive, rssi: -90)
        rig.touch("Q", .receive, rssi: -45, samples: 8)
        #expect(rig.taps.isEmpty, "a stranger's touch is not a tap for a sender armed to another phone")
        rig.touch("R", .receive, samples: 8)
        #expect(rig.taps == [peer])
    }

    @Test func twoSendersTouchingRaiseTheBothSendingRoleEventForTheSession() {
        let rig = BleRig()
        rig.route.start(role: .send)
        rig.settle("X", .send)
        rig.touch("X", .send)
        #expect(rig.roles.contains(.send))
    }

    @Test func theReaderLeavingBeforeTheBeamIsALostReadAndALostPeerABystanderOrAnAcknowledgedReaderIsNothing() {
        let (rig, peer) = Self.armedSender()
        _ = rig.route.serverControl(client: "c", value: Self.hello())
        rig.route.serverClientGone(client: "c")
        #expect(rig.readsLost.isEmpty && rig.losts.isEmpty)

        _ = rig.route.serverControl(client: "c", value: Self.hello())
        _ = rig.route.serverControl(client: "bystander", value: Self.hello(9))
        rig.route.serverClientGone(client: "bystander")
        #expect(rig.losts.isEmpty, "a phone that never read the offer leaving is nothing")
        #expect(rig.route.serverOffer(client: "c") != nil)
        rig.route.serverClientGone(client: "c")
        #expect(rig.readsLost == [peer])
        #expect(rig.losts == [peer])

        let acked = Self.armedSender()
        _ = acked.rig.route.serverControl(client: "r", value: Self.hello(4))
        #expect(acked.rig.route.serverOffer(client: "r") != nil)
        _ = acked.rig.route.serverControl(client: "r", value: SongTapWire.encodeAck())
        acked.rig.route.serverClientGone(client: "r")
        #expect(acked.rig.losts.isEmpty && acked.rig.readsLost.isEmpty)
    }

    @Test func aFrameThatWouldNotFitOneAttributeIsSentWithoutItsArt() throws {
        let (rig, _) = Self.armedSender()
        // A payload at the cap: 400 bytes; the frame is 142 bytes more, over the 512 of one attribute.
        let big = try #require(SongTapPayloads.make(
            nowMs: Self.payload.ts, ytVideoId: "dQw4w9WgXcQ", spotifyId: "4uLU6hMCjMI75M1A2tKUQC", isrc: "GBARL9300135",
            title: String(repeating: "\u{6771}", count: 33), artist: String(repeating: "\u{6771}", count: 26), durationMs: 200_000,
            artUrl: "https://i.ytimg.com/" + String(repeating: "p", count: 50)))
        let bytes = try #require(SongTapPayloads.encode(big))
        #expect(bytes.count + SongTapBleTuning.frameOverheadBytes > SongTapSigning.maxFrameBytes)
        rig.route.publishOffer(peer: rig.founds.last!, payload: bytes)
        _ = rig.route.serverControl(client: "c", value: Self.hello(3))
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
        #expect(!receiver.route.serverControl(client: "c", value: Self.hello()))
        #expect(receiver.route.serverOffer(client: "c") == nil)

        let (s, _) = Self.armedSender()
        _ = s.route.serverControl(client: "c", value: Self.hello())
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

    @Test func theOfferIsServedOnlyWhileThePhoneItIsForIsInsideTheNearGate() {
        let (rig, _) = Self.armedSender()
        _ = rig.route.serverControl(client: "c", value: Self.hello())
        // A few metres away (inside the list gate only): nothing is served.
        for _ in 0..<8 { rig.see("R", .receive, BleRig.listOnlyDbm) }
        #expect(rig.route.serverOffer(client: "c") == nil)
        for _ in 0..<8 { rig.see("R", .receive, BleRig.nearDbm) }
        #expect(rig.route.serverOffer(client: "c") != nil)
    }

    @Test func whenTwoPhonesThatCouldBeTheReaderAreCloseNobodyIsServed() {
        let (rig, _) = Self.armedSender()
        _ = rig.route.serverControl(client: "c", value: Self.hello())
        rig.settle("Q", .receive, rssi: -62, samples: 6)
        rig.see("R", .receive, BleRig.nearDbm)
        #expect(rig.route.serverOffer(client: "c") == nil)
        // The other one leaves.
        rig.advance(SongTapBleTuning.peerTimeoutMs + 500)
        rig.settle("R", .receive, samples: 4)
        #expect(rig.route.serverOffer(client: "c") != nil)
    }

    @Test func thePhoneArmedToIsFollowedEvenWhenAnotherComesInStronger() {
        let (rig, peer) = Self.armedSender()
        rig.settle("Q", .receive, rssi: -45, samples: 10)
        rig.see("R", .receive, BleRig.nearDbm)
        let before = rig.founds.count
        #expect(rig.route.nearby.contains { $0.id == peer })
        #expect(rig.founds.count == before)
        _ = rig.route.serverControl(client: "c", value: Self.hello())
        #expect(rig.route.serverOffer(client: "c") == nil, "Q is close too: nobody is served")
    }

    @Test func theNearbyListIsBuiltFromAdvertisementsAloneStrongestFirstWithTheNamesTheyCarried() {
        let rig = BleRig()
        rig.route.start(role: .send)
        rig.settle("A", .receive, rssi: -75, samples: 3, name: "Ann")
        rig.settle("B", .receive, rssi: -66, samples: 3, name: "Bo")
        rig.settle("C", .receive, rssi: -95, samples: 3, name: "Far")
        rig.settle("D", .send, rssi: -60, samples: 3, name: "Sender")
        rig.advance(300)
        #expect(rig.route.nearby.map(\.name) == ["Bo", "Ann"])
        #expect(rig.radio.count("connect") == 0, "listing a phone never connects")
    }

    @Test func thePromptAppearsForAPhoneInsideTheNearGateAndNotBeforeAndNoSilencesItForAMinute() {
        let rig = BleRig()
        rig.route.start(role: .send)
        rig.settle("R", .receive, rssi: BleRig.listOnlyDbm, samples: 6, name: "Ann")
        rig.advance(300)
        #expect(rig.route.prompt == nil)
        #expect(rig.route.nearby.count == 1)
        rig.settle("R", .receive, rssi: BleRig.nearDbm, samples: 6, name: "Ann")
        rig.advance(300)
        let asked = rig.route.prompt
        #expect(asked?.name == "Ann")
        rig.route.ignorePrompt(asked!.id)
        #expect(rig.route.prompt == nil)
        for _ in 0..<50 { rig.see("R", .receive, BleRig.nearDbm, stepMs: 1_000, name: "Ann") }
        rig.advance(300)
        #expect(rig.route.prompt == nil, "still silenced after fifty seconds")
        for _ in 0..<15 { rig.see("R", .receive, BleRig.nearDbm, stepMs: 1_000, name: "Ann") }
        rig.advance(300)
        #expect(rig.route.prompt?.name == "Ann", "a minute after the no")
    }

    @Test func aPublishedOfferPinsThePhoneAndHidesThePrompt() {
        let rig = BleRig()
        rig.route.start(role: .send)
        rig.settle("R", .receive, samples: 6, name: "Ann")
        rig.advance(300)
        #expect(rig.route.prompt != nil)
        rig.route.publishOffer(peer: rig.founds.last!, payload: Self.payloadBytes)
        #expect(rig.route.prompt == nil)
        #expect(rig.route.nearby.count == 1)
        rig.route.withdrawOffer()
        rig.advance(300)
        #expect(rig.route.prompt != nil)
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

    @Test func aFloodOfMadeUpAddressesIsBoundedAndForgotten() {
        let rig = BleRig()
        rig.route.start(role: .receive)
        rig.settle("S", .send, rssi: -62)
        for i in 0..<(SongTapBleTuning.maxPeers * 3) {
            rig.see("fake\(i)", .send, -90)
            if i % 5 == 0 { rig.see("S", .send, -62) } // the phone being followed keeps being heard
        }
        #expect(rig.radio.count("forget:") >= SongTapBleTuning.maxPeers * 2 - 1)
        #expect(rig.route.glow > 0, "the phone being followed is never pushed out")
    }

    @Test func aConnectionThatNeverComesUpIsGivenUpAndAnOfferStillWaitingFailsTheBeam() {
        let rig = BleRig()
        rig.route.start(role: .receive)
        rig.settle("S", .send, rssi: -60)
        let peer = rig.founds.last!
        #expect(rig.radio.calls.contains("connect:S"))
        rig.route.readOffer(peer: peer)
        for _ in 0..<40 {
            rig.see("S", .send, -60) // the phone keeps advertising but never answers the connection
            rig.scheduler.pump()
        }
        #expect(rig.radio.calls.contains("disconnect:S"))
        #expect(rig.losts.contains(peer))
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

    // MARK: Follow-up 2: the phone, not the address (Android `BleTransportTest`, 2026-11-25)

    private func logged(_ rig: BleRig, _ text: String) -> Int { rig.diag.events.filter { $0.text.contains(text) }.count }

    @Test func aPhoneThatChangesItsAddressWhileArmedKeepsItsNumberStillGetsTheOfferAndItsTapIsAccepted() {
        let rig = BleRig()
        rig.route.start(role: .send)
        rig.settle("R1", .receive, name: "Ann")
        let peer = rig.founds.last!
        _ = rig.route.serverControl(client: "c", value: Self.hello(1))
        rig.route.publishOffer(peer: peer, payload: Self.payloadBytes)
        #expect(rig.radio.notifications.count == 1)

        // The old address goes quiet and the same name shows up under a new one.
        rig.clock.advance(2_000)
        rig.settle("R2", .receive, name: "Ann")

        #expect(rig.founds == [peer])
        #expect(rig.losts.isEmpty)
        #expect(logged(rig, "changed its address") == 1)
        #expect(rig.route.nearby.map(\.id) == [peer])
        // The phones that are connected are told again there is an offer.
        #expect(rig.radio.notifications.count == 2)
        #expect(SongTapWire.isOfferReady(rig.radio.notifications.last!.value))
        // It is served, and its tap message is believed.
        #expect(rig.route.serverOffer(client: "c") != nil)
        _ = rig.route.serverControl(client: "c", value: SongTapWire.encodeTap(ageMs: 30))
        #expect(rig.taps == [peer])
    }

    @Test func theNewAddressesOwnTapCountsForThePinnedPhone() {
        let rig = BleRig()
        rig.route.start(role: .send)
        rig.settle("R1", .receive, name: "Ann")
        let peer = rig.founds.last!
        rig.route.publishOffer(peer: peer, payload: Self.payloadBytes)
        rig.clock.advance(2_000)
        rig.settle("R2", .receive, name: "Ann")
        rig.touch("R2", .receive)
        #expect(rig.taps == [peer])
    }

    @Test func theOldAddressIsNotGivenUpForAPhoneThatIsStillBeingHeard() {
        let rig = BleRig()
        rig.route.start(role: .send)
        rig.settle("R1", .receive, name: "Ann")
        rig.route.publishOffer(peer: rig.founds.last!, payload: Self.payloadBytes)
        // The twin shows up at once, while the pinned address is still talking: nothing is re-pinned.
        rig.settle("R2", .receive, name: "Ann")
        #expect(logged(rig, "changed its address") == 0)
    }

    @Test func aStaleTwinOfTheSamePhoneDoesNotStopTheOfferBeingServed() {
        let rig = BleRig()
        rig.route.start(role: .send)
        rig.settle("R1", .receive, name: "Ann")
        let chosen = rig.founds.last!
        rig.settle("R2", .receive, name: "Ann")
        rig.route.publishOffer(peer: chosen, payload: Self.payloadBytes)
        _ = rig.route.serverControl(client: "c", value: Self.hello(5))
        #expect(rig.route.serverOffer(client: "c") != nil)
    }

    @Test func twoDifferentNamesNearStillServeNobody() {
        let rig = BleRig()
        rig.route.start(role: .send)
        rig.settle("R1", .receive, name: "Ann")
        let chosen = rig.founds.last!
        rig.settle("R2", .receive, name: "Bo")
        rig.route.publishOffer(peer: chosen, payload: Self.payloadBytes)
        _ = rig.route.serverControl(client: "c", value: Self.hello(5))
        #expect(rig.route.serverOffer(client: "c") == nil)
        // Even when one of them changes address and the other stays: a different name is a different phone.
        rig.clock.advance(2_000)
        rig.settle("R3", .receive, name: "Bo")
        #expect(logged(rig, "changed its address") == 0)
        #expect(rig.route.serverOffer(client: "c") == nil)
    }

    @Test func thePromptStaysUpWhileTheSameNamedPhoneChangesAddressAndNoSilencesEveryAddressItHas() {
        let rig = BleRig()
        rig.route.start(role: .send)
        rig.settle("R1", .receive, name: "Ann")
        rig.advance(300)
        #expect(rig.route.prompt?.name == "Ann")
        rig.clock.advance(2_000)
        var seen: [String?] = []
        for _ in 0..<6 {
            rig.see("R2", .receive, BleRig.nearDbm, name: "Ann")
            seen.append(rig.route.prompt?.name)
        }
        #expect(!seen.contains(nil), "the question never vanishes: \(seen)")

        rig.route.ignorePrompt(rig.route.prompt!.id)
        #expect(rig.route.prompt == nil)
        // A third address of the same phone is not asked about either.
        rig.clock.advance(2_000)
        for _ in 0..<6 { rig.see("R3", .receive, BleRig.nearDbm, name: "Ann") }
        rig.advance(300)
        #expect(rig.route.prompt == nil)
    }

    // MARK: Follow-up 2: taps with no yes are never silent

    @Test func aSenderThatFeltATapWithNoYesSaysSoInTheLogAndTheDiagnosticsAtMostEveryTwoSecondsAndAYesClearsIt() {
        let rig = BleRig()
        rig.diag.setEnabled(true)
        rig.route.start(role: .send)
        rig.settle("R", .receive, name: "Ann")
        rig.touch("R", .receive)
        #expect(rig.taps.isEmpty)
        #expect(logged(rig, "tap ignored: no yes yet") == 1)
        rig.see("R", .receive, BleRig.touchDbm, stepMs: 200)
        #expect(rig.diag.snapshot.needsYes)
        #expect(rig.diag.snapshot.tapNote.contains("tap ignored: no yes yet"))

        // Pull apart and touch again inside two seconds: counted, not logged again.
        rig.settle("R", .receive, samples: 8)
        rig.touch("R", .receive, samples: 4)
        #expect(logged(rig, "tap ignored: no yes yet") == 1)

        // Saying yes clears the hint.
        rig.route.publishOffer(peer: rig.founds.last!, payload: Self.payloadBytes)
        rig.see("R", .receive, BleRig.touchDbm, stepMs: 200)
        #expect(!rig.diag.snapshot.needsYes)
        #expect(rig.diag.snapshot.tapNote.isEmpty)
    }

    // MARK: Follow-up 2: the radio is not restarted, and a stalled connection gives up

    @Test func startingAgainWithTheSameRoleAndNameDoesNotRestartTheRadio() {
        let rig = BleRig()
        rig.route.start(role: .receive)
        rig.route.start(role: .receive)
        rig.route.start(role: .receive)
        #expect(rig.radio.count("start") == 1)
        #expect(rig.radio.count("stop") == 0)
        #expect(logged(rig, "advertising start (receive)") == 1)
        #expect(logged(rig, "not restarted") == 2)
        #expect(rig.route.status == .active)

        // A different role or name is a real change.
        rig.route.start(role: .send)
        #expect(rig.radio.count("start") == 2)
        #expect(logged(rig, "advertising stop (receive)") == 1)
        #expect(logged(rig, "advertising start (send)") == 1)
        rig.route.setOwnName("Zed")
        rig.route.start(role: .send)
        #expect(rig.radio.count("start") == 3)
        #expect(rig.radio.advertisedName == "Zed")
        // Bluetooth that never came up is tried again.
        let off = BleRig()
        off.radio.startStatus = .bluetoothOff
        off.route.start(role: .receive)
        off.radio.startStatus = .active
        off.route.start(role: .receive)
        #expect(off.radio.count("start") == 2)
    }

    @Test func aConnectionThatStallsIsGivenUpAfterThreeSecondsAndALateAnswerIsClosed() {
        let rig = BleRig()
        rig.route.start(role: .receive)
        rig.settle("S", .send)
        #expect(rig.radio.count("connect") == 1)
        // Nothing answers; the phone keeps advertising. Before the timeout it is still waited for.
        for _ in 0..<2 {
            rig.see("S", .send, BleRig.nearDbm, stepMs: 1_000)
            rig.scheduler.pump()
        }
        #expect(rig.radio.count("disconnect") == 0)
        for _ in 0..<2 {
            rig.see("S", .send, BleRig.nearDbm, stepMs: 1_000)
            rig.scheduler.pump()
        }
        #expect(rig.radio.count("disconnect") == 1)
        #expect(logged(rig, "took too long") == 1)
        #expect(rig.radio.count("connect") == 1)
        // The stalled attempt answers after all: closed, not mistaken for a connection.
        rig.listener.onConnected(address: "S", ok: true)
        #expect(rig.radio.count("readName") == 0)
        #expect(rig.hellos.isEmpty)
        #expect(rig.radio.count("disconnect") == 2)
        // A new attempt follows after the usual pause.
        rig.see("S", .send, BleRig.nearDbm, stepMs: SongTapBleTuning.reconnectMs + 100)
        #expect(rig.radio.count("connect") == 2)
    }
}
