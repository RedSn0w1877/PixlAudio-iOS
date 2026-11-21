import Foundation
import Testing
@testable import PixlLibrary

/// Hand-written tests of Song Tap's pure core at spec 5 and 6 (Android's SessionTest, DetectorTest, PeerTapTest, NamesNearbyTest and
/// WireTest in Swift Testing): prefetch and commit, the one-sided tap, the gates, the two sensitivity profiles, names and the nearby
/// list. The golden files cover the same functions with Android's numbers; these state the rules.
@Suite("Song Drop core (spec 5 and 6)")
struct SongTapDropCoreTests {
    static let v1 = "dQw4w9WgXcQ"
    static let v2 = "aaaaaaaaaaa"

    static func run(_ ask: Bool, _ events: [SongTapSessionEvent]) -> [SongTapReduction] {
        SongTapSession.run(start: .initial(askFirst: ask), events: events)
    }

    static func fx(_ r: SongTapReduction) -> [String] { r.effects.map { $0.describe() } }

    // MARK: The sender

    @Test func theSendersHappyPath() {
        let r = Self.run(true, [.arm(role: .send, askFirst: true), .peerFound(1), .peerNear(1), .approve(peer: 1, videoId: Self.v1),
                                .offerRead(peer: 1, nowMs: 900), .tapDetected(peer: 1, videoId: Self.v1, nowMs: 1000),
                                .ackReceived(nowMs: 1100, rttMs: 80), .beamFinished])
        #expect(Self.fx(r[0]) == ["startTransport(send)"])
        #expect(r[2].state.phase == .near)
        // The yes publishes the offer for that phone only, before any tap.
        #expect(Self.fx(r[3]) == ["publishOffer(1,\(Self.v1))", "scheduleTimeout(target,60000)"])
        #expect(r[3].state.phase == .offered && r[3].state.target == 1)
        #expect(r[4].state.offerRead)
        // The tap is the commit: the haptic and the beam start right there, no go, no delay.
        #expect(Self.fx(r[5]) == ["haptic(tick)", "startBeam(send,1000)", "scheduleTimeout(ack,45000)"])
        #expect(r[5].state.phase == .transferring)
        #expect(r[6].state.acked)
        #expect(r[7].state.phase == .saved)
        #expect(Self.fx(r[7]) == ["haptic(success)"])
    }

    @Test func theSendersBeamWaitsForTheAcknowledgementWhenItEndsFirst() {
        let r = Self.run(true, [.arm(role: .send, askFirst: true), .peerFound(1), .peerNear(1), .approve(peer: 1, videoId: Self.v1),
                                .offerRead(peer: 1, nowMs: 900), .tapDetected(peer: 1, videoId: Self.v1, nowMs: 1000), .beamFinished,
                                .ackReceived(nowMs: 5000, rttMs: 0)])
        #expect(r[6].state.phase == .transferring && r[6].state.beamDone)
        #expect(r[6].effects.isEmpty)
        #expect(r[7].state.phase == .saved)
        #expect(Self.fx(r[7]) == ["haptic(success)"])
    }

    @Test func aTapBeforeTheOfferWasReadWaitsForTheReadAndATapWithoutAYesDoesNothing() {
        let early = Self.run(true, [.arm(role: .send, askFirst: true), .peerFound(1), .peerNear(1), .approve(peer: 1, videoId: Self.v1),
                                    .tapDetected(peer: 1, videoId: Self.v1, nowMs: 1000), .offerRead(peer: 1, nowMs: 1300)])
        #expect(early[4].effects.isEmpty && early[4].state.tapSeen)
        #expect(Self.fx(early[5]) == ["haptic(tick)", "startBeam(send,1300)", "scheduleTimeout(ack,45000)"])
        let noYes = Self.run(true, [.arm(role: .send, askFirst: true), .peerFound(1), .peerNear(1),
                                    .tapDetected(peer: 1, videoId: Self.v1, nowMs: 1000), .offerRead(peer: 1, nowMs: 1100),
                                    .ackReceived(nowMs: 1200, rttMs: 0)])
        for i in 3...5 {
            #expect(noYes[i].effects.isEmpty)
            #expect(noYes[i].state.phase == .near)
        }
    }

    @Test func theBeamOnlyEverReachesThePhoneTheListenerSaidYesTo() {
        let r = Self.run(true, [.arm(role: .send, askFirst: true), .peerFound(1), .peerFound(2), .peerNear(1), .approve(peer: 1, videoId: Self.v1),
                                .offerRead(peer: 2, nowMs: 900), .tapDetected(peer: 2, videoId: Self.v1, nowMs: 1000),
                                .offerRead(peer: 1, nowMs: 1010), .tapDetected(peer: 1, videoId: Self.v1, nowMs: 1020)])
        // The other phone's read and tap change nothing; the chosen phone's do.
        #expect(!r[5].state.offerRead)
        #expect(r[6].effects.isEmpty)
        #expect(r[7].state.offerRead)
        #expect(Self.fx(r[8]) == ["haptic(tick)", "startBeam(send,1020)", "scheduleTimeout(ack,45000)"])
    }

    @Test func theSenderStaysArmedWhenThePhonesLinkDropsAndGivesUpAfterTheTargetTimeout() {
        let r = Self.run(true, [.arm(role: .send, askFirst: true), .peerFound(1), .peerNear(1), .approve(peer: 1, videoId: Self.v1),
                                .offerRead(peer: 1, nowMs: 900), .peerLost(1), .tapDetected(peer: 1, videoId: Self.v1, nowMs: 1000),
                                .offerRead(peer: 1, nowMs: 1200), .timeout(.target)])
        #expect(r[5].state.phase == .offered && !r[5].state.offerRead)
        #expect(r[6].state.tapSeen)
        #expect(r[7].state.phase == .transferring)
        #expect(r[8].state.phase == .transferring)
        let idle = Self.run(true, [.arm(role: .send, askFirst: true), .peerFound(1), .peerNear(1), .approve(peer: 1, videoId: Self.v1),
                                   .timeout(.target)])
        #expect(idle.last!.state.phase == .cancelled)
        #expect(Self.fx(idle.last!) == ["abortTransfer(1)"])
    }

    @Test func aNewSongOrARefreshPublishesAgainAndNeedsANewRead() {
        let r = Self.run(true, [.arm(role: .send, askFirst: true), .peerFound(1), .peerNear(1), .approve(peer: 1, videoId: Self.v1),
                                .offerRead(peer: 1, nowMs: 900), .republish(videoId: Self.v2), .republish(videoId: "")])
        #expect(Self.fx(r[5]) == ["publishOffer(1,\(Self.v2))"])
        #expect(!r[5].state.offerRead)
        #expect(r[5].state.videoId == Self.v2)
        #expect(r[6].effects.isEmpty)
    }

    @Test func nothingToSendIsANoticeAndNotAnOffer() {
        let r = Self.run(true, [.arm(role: .send, askFirst: true), .peerFound(1), .peerNear(1), .approve(peer: 1, videoId: "")])
        #expect(r.last!.state.fail == .nothingToSend)
        let q = Self.run(true, [.arm(role: .send, askFirst: true), .qrShown(videoId: "")])
        #expect(q.last!.state.fail == .nothingToSend)
    }

    @Test func aSendersDeclineReachesTheSender() {
        let r = Self.run(true, [.arm(role: .send, askFirst: true), .peerFound(1), .peerNear(1), .approve(peer: 1, videoId: Self.v1),
                                .peerDeclined(2), .peerDeclined(1)])
        #expect(r[4].state.phase == .offered)
        #expect(r[5].state.phase == .declined)
    }

    // MARK: The receiver

    @Test func aBeamTheLimitsRefuseAtTheCommitTellsTheSenderWhoseBeamHasAlreadyStarted() {
        let r = Self.run(false, [.arm(role: .receive, askFirst: false), .offerReceived(peer: 0, videoId: Self.v1, senderKey: 3, nowMs: 10_000),
                                 .saveResult(.saved, nowMs: 10_100), .dismiss, .peerFound(1), .peerNear(1),
                                 .offerPrefetched(peer: 1, videoId: Self.v2, senderKey: 3), .tapDetected(peer: 1, videoId: "", nowMs: 11_000)])
        #expect(Self.fx(r.last!) == ["sendDecline(1)", "notice(too_soon)", "haptic(warn)"])
    }

    @Test func theReceiverThatFetchedTheOfferBeforeTheTapCommitsAtTheTapWithNothingLeftToWaitFor() {
        let r = Self.run(false, [.arm(role: .receive, askFirst: false), .peerFound(1), .peerNear(1),
                                 .offerPrefetched(peer: 1, videoId: Self.v1, senderKey: 7), .tapDetected(peer: 1, videoId: "", nowMs: 2000),
                                 .saveResult(.saved, nowMs: 2100)])
        #expect(r[3].state.pre && r[3].effects.isEmpty)
        // Haptic first, then the save and the beam in the same step: no read, no ack, no go in between.
        #expect(Self.fx(r[4]) == ["haptic(tick)", "saveSong(\(Self.v1))", "scheduleTimeout(save,20000)", "startBeam(receive,2000)"])
        #expect(r[4].state.phase == .transferring && !r[4].state.pre)
        #expect(Self.fx(r[5]) == ["sendAck(1)", "haptic(success)"])
    }

    @Test func aPrefetchedFirstBeamAsksAtTheTapAndStartsTheBeamWhenTheListenerSaysAdd() {
        let r = Self.run(true, [.arm(role: .receive, askFirst: true), .peerFound(1), .peerNear(1),
                                .offerPrefetched(peer: 1, videoId: Self.v1, senderKey: 7), .tapDetected(peer: 1, videoId: "", nowMs: 2000),
                                .accept(nowMs: 4000)])
        #expect(Self.fx(r[4]) == ["haptic(tick)", "scheduleTimeout(consent,20000)"])
        #expect(r[4].state.phase == .offered)
        #expect(Self.fx(r[5]) == ["saveSong(\(Self.v1))", "scheduleTimeout(save,20000)", "startBeam(receive,4000)"])
    }

    @Test func aPrefetchedOfferIsDroppedWhenWithdrawnReplacedOrTheSenderLeavesAndTheLimitsStillApply() {
        let gone = Self.run(false, [.arm(role: .receive, askFirst: false), .peerFound(1), .peerNear(1),
                                    .offerPrefetched(peer: 1, videoId: Self.v1, senderKey: 7), .offerGone(peer: 1),
                                    .tapDetected(peer: 1, videoId: "", nowMs: 2000)])
        #expect(!gone[4].state.pre)
        #expect(Self.fx(gone[5]) == ["readOffer(1)", "scheduleTimeout(read,8000)"])
        let left = Self.run(false, [.arm(role: .receive, askFirst: false), .peerFound(1), .peerNear(1),
                                    .offerPrefetched(peer: 1, videoId: Self.v1, senderKey: 7), .peerLost(1), .peerFound(1), .peerNear(1),
                                    .tapDetected(peer: 1, videoId: "", nowMs: 2000)])
        #expect(!left[4].state.pre && left[4].state.videoId == "")
        #expect(Self.fx(left.last!) == ["readOffer(1)", "scheduleTimeout(read,8000)"])
        let stranger = Self.run(false, [.arm(role: .receive, askFirst: false), .peerFound(1), .peerNear(1),
                                        .offerPrefetched(peer: 2, videoId: Self.v1, senderKey: 7)])
        #expect(!stranger.last!.state.pre)
        let newer = Self.run(false, [.arm(role: .receive, askFirst: false), .peerFound(1), .peerNear(1),
                                     .offerPrefetched(peer: 1, videoId: Self.v1, senderKey: 7),
                                     .offerPrefetched(peer: 1, videoId: Self.v2, senderKey: 7), .tapDetected(peer: 1, videoId: "", nowMs: 2000)])
        #expect(Self.fx(newer.last!)[1] == "saveSong(\(Self.v2))")
        let sender = Self.run(true, [.arm(role: .send, askFirst: true), .peerFound(1), .peerNear(1),
                                     .offerPrefetched(peer: 1, videoId: Self.v1, senderKey: 7)])
        #expect(!sender.last!.state.pre)
    }

    @Test func theReceiverAsksTheFirstTimeAndSavesAfterAYes() {
        let r = Self.run(true, [.arm(role: .receive, askFirst: true), .peerFound(1), .peerNear(1), .tapDetected(peer: 1, videoId: "", nowMs: 900),
                                .offerReceived(peer: 1, videoId: Self.v1, senderKey: 7, nowMs: 1000), .accept(nowMs: 1500),
                                .saveResult(.saved, nowMs: 1800)])
        // No offer in hand at the tap: it is read now, and the haptic waits for the moment the data is here.
        #expect(Self.fx(r[3]) == ["readOffer(1)", "scheduleTimeout(read,8000)"])
        #expect(r[4].state.phase == .offered)
        #expect(Self.fx(r[4]) == ["haptic(tick)", "scheduleTimeout(consent,20000)"])
        // The beam starts with the save, not after the sender's answer; the sender is told only once the song is saved.
        #expect(Self.fx(r[5]) == ["saveSong(\(Self.v1))", "scheduleTimeout(save,20000)", "startBeam(receive,1500)"])
        #expect(!r[5].state.askFirst)
        #expect(r[6].state.phase == .saved)
        #expect(Self.fx(r[6]) == ["sendAck(1)", "haptic(success)"])
    }

    @Test func laterBeamsSaveAtOnceAndUndoWorksOnce() {
        let r = Self.run(false, [.arm(role: .receive, askFirst: false), .peerFound(1), .peerNear(1), .tapDetected(peer: 1, videoId: "", nowMs: 900),
                                 .offerReceived(peer: 1, videoId: Self.v1, senderKey: 7, nowMs: 1000), .saveResult(.saved, nowMs: 1400),
                                 .undo(nowMs: 3000), .undo(nowMs: 3100)])
        #expect(Self.fx(r[4]) == ["haptic(tick)", "saveSong(\(Self.v1))", "scheduleTimeout(save,20000)", "startBeam(receive,1000)"])
        #expect(Self.fx(r[5]) == ["sendAck(1)", "haptic(success)"])
        #expect(Self.fx(r[6]) == ["undoSave(\(Self.v1))"])
        #expect(r[6].state.phase == .armed)
        #expect(r[7].effects.isEmpty)
    }

    @Test func aQrBeamHasNoHandshake() {
        let r = Self.run(false, [.arm(role: .receive, askFirst: false), .offerRejected, .offerReceived(peer: 0, videoId: Self.v1, senderKey: 0, nowMs: 5000),
                                 .saveResult(.saved, nowMs: 5100)])
        #expect(Self.fx(r[1]) == ["noticeInvalidCode"])
        #expect(r[1].state.phase == .armed)
        #expect(Self.fx(r[2]) == ["saveSong(\(Self.v1))", "scheduleTimeout(save,20000)", "startBeam(receive,5000)"])
        #expect(r[3].state.phase == .saved)
    }

    @Test func aSongTheListenerAlreadyHadHasNothingToUndo() {
        let r = Self.run(false, [.arm(role: .receive, askFirst: false), .offerReceived(peer: 0, videoId: Self.v1, senderKey: 0, nowMs: 5000),
                                 .saveResult(.alreadyHad, nowMs: 5100), .undo(nowMs: 5200)])
        #expect(r[2].state.alreadyHad)
        #expect(r[3].state.phase == .saved && r[3].effects.isEmpty)
    }

    @Test func aNotFoundSaveSavesNothingAndTheSenderIsToldAndTheLimitsCountIt() {
        let r = Self.run(false, [.arm(role: .receive, askFirst: false), .peerFound(1), .peerNear(1), .tapDetected(peer: 1, videoId: "", nowMs: 9_000),
                                 .offerReceived(peer: 1, videoId: Self.v1, senderKey: 7, nowMs: 10_000), .saveResult(.notFound, nowMs: 10_100), .dismiss,
                                 .tapDetected(peer: 1, videoId: "", nowMs: 10_500), .offerReceived(peer: 1, videoId: Self.v2, senderKey: 7, nowMs: 11_000)])
        #expect(Self.fx(r[5]) == ["sendDecline(1)", "notice(not_found)", "haptic(warn)"])
        #expect(r.last!.state.fail == .tooSoon)
    }

    @Test func bothPhonesSendingIsAConflict() {
        let a = Self.run(true, [.arm(role: .send, askFirst: true), .peerFound(1), .peerNear(1), .peerRole(peer: 1, role: .send)])
        #expect(a.last!.state.fail == .bothSending)
        let b = Self.run(true, [.arm(role: .send, askFirst: true), .peerFound(1), .peerNear(1), .approve(peer: 1, videoId: Self.v1),
                                .offerReceived(peer: 1, videoId: Self.v2, senderKey: 5, nowMs: 1000)])
        #expect(b.last!.state.fail == .bothSending)
        #expect(Self.fx(b.last!).contains("abortTransfer(1)"))
    }

    @Test func aDroppedPeerFailsABeamThatWasStillBeingReadAndAbortsIt() {
        let r = Self.run(false, [.arm(role: .receive, askFirst: false), .peerFound(1), .peerNear(1), .tapDetected(peer: 1, videoId: "", nowMs: 900), .peerLost(1)])
        #expect(r.last!.state.fail == .peerLost)
        #expect(Self.fx(r.last!) == ["abortTransfer(1)", "haptic(warn)"])
    }

    @Test func aReceiverThatHoldsACheckedOfferKeepsSavingWhenThePhonesComeApart() {
        let r = Self.run(false, [.arm(role: .receive, askFirst: false), .peerFound(1), .peerNear(1), .tapDetected(peer: 1, videoId: "", nowMs: 900),
                                 .offerReceived(peer: 1, videoId: Self.v1, senderKey: 7, nowMs: 1000), .peerLost(1), .saveResult(.saved, nowMs: 1500)])
        #expect(r[5].state.phase == .transferring && r[5].state.peer == 0 && r[5].effects.isEmpty)
        // There is no one to answer, so nobody is acknowledged, and the song is still saved.
        #expect(r[6].state.phase == .saved)
        #expect(Self.fx(r[6]) == ["haptic(success)"])
    }

    @Test func theFirstBeamsAddStillWorksAfterThePhonesComeApartAndTheBeamPlaysAtOnce() {
        let r = Self.run(true, [.arm(role: .receive, askFirst: true), .peerFound(1), .peerNear(1), .tapDetected(peer: 1, videoId: "", nowMs: 900),
                                .offerReceived(peer: 1, videoId: Self.v1, senderKey: 7, nowMs: 1000), .peerLost(1), .accept(nowMs: 9_000),
                                .saveResult(.saved, nowMs: 9_200)])
        #expect(r[5].state.phase == .offered && r[5].state.videoId == Self.v1 && r[5].effects.isEmpty)
        #expect(Self.fx(r[6]) == ["saveSong(\(Self.v1))", "scheduleTimeout(save,20000)", "startBeam(receive,9000)"])
        #expect(r[7].state.phase == .saved)
    }

    @Test func aTeardownNeverUndoesASongTheListenerMayHave() {
        let cancel = Self.run(false, [.arm(role: .receive, askFirst: false), .peerFound(1), .peerNear(1), .tapDetected(peer: 1, videoId: "", nowMs: 900),
                                      .offerReceived(peer: 1, videoId: Self.v1, senderKey: 7, nowMs: 1000), .cancel])
        #expect(Self.fx(cancel.last!).allSatisfy { !$0.hasPrefix("undoSave") })
        let timeout = Self.run(false, [.arm(role: .receive, askFirst: false), .offerReceived(peer: 0, videoId: Self.v1, senderKey: 0, nowMs: 1000), .timeout(.save)])
        #expect(Self.fx(timeout.last!).allSatisfy { !$0.hasPrefix("undoSave") })
    }

    @Test func cancelMidTransferStopsTheTransferAndALateResultIsIgnored() {
        let r = Self.run(false, [.arm(role: .receive, askFirst: false), .peerFound(1), .peerNear(1), .tapDetected(peer: 1, videoId: "", nowMs: 900),
                                 .offerReceived(peer: 1, videoId: Self.v1, senderKey: 7, nowMs: 1000), .cancel, .saveResult(.saved, nowMs: 1100)])
        #expect(r[5].state.phase == .cancelled)
        #expect(Self.fx(r[5]) == ["abortTransfer(1)"])
        #expect(r[6].state.phase == .cancelled && r[6].effects.isEmpty)
    }

    @Test func lateAndDuplicateEventsChangeNothing() {
        let r = Self.run(true, [.arm(role: .send, askFirst: true), .peerFound(1), .peerNear(1), .approve(peer: 1, videoId: Self.v1), .cancel,
                                .ackReceived(nowMs: 900, rttMs: 50), .tapDetected(peer: 1, videoId: Self.v1, nowMs: 1000)])
        #expect(r[6].state.phase == .cancelled)
        #expect(r[5].effects.isEmpty && r[6].effects.isEmpty)
        let d = Self.run(false, [.arm(role: .receive, askFirst: false), .peerFound(1), .peerNear(1), .tapDetected(peer: 1, videoId: "", nowMs: 900),
                                 .offerReceived(peer: 1, videoId: Self.v1, senderKey: 7, nowMs: 1000),
                                 .offerReceived(peer: 1, videoId: Self.v2, senderKey: 7, nowMs: 1010)])
        #expect(d.last!.state.videoId == Self.v1 && d.last!.effects.isEmpty)
        let idle = Self.run(true, [.peerFound(1), .tapDetected(peer: 1, videoId: Self.v1, nowMs: 0),
                                   .offerReceived(peer: 0, videoId: Self.v1, senderKey: 1, nowMs: 0), .accept(nowMs: 0), .undo(nowMs: 0), .dismiss,
                                   .cancel, .timeout(.ack), .approve(peer: 1, videoId: Self.v1), .offerRead(peer: 1, nowMs: 0)])
        for step in idle {
            #expect(step.state.phase == .idle)
            #expect(step.effects.isEmpty)
        }
    }

    @Test func timeoutsOnlyFireInThePhaseThatWaitsForThem() {
        let a = Self.run(true, [.arm(role: .send, askFirst: true), .peerFound(1), .peerNear(1), .approve(peer: 1, videoId: Self.v1),
                                .offerRead(peer: 1, nowMs: 900), .tapDetected(peer: 1, videoId: Self.v1, nowMs: 1000), .timeout(.read), .timeout(.ack)])
        #expect(a[6].state.phase == .transferring)
        #expect(a[7].state.fail == .timeout)
        let c = Self.run(true, [.arm(role: .receive, askFirst: true), .offerReceived(peer: 0, videoId: Self.v1, senderKey: 1, nowMs: 0), .timeout(.consent)])
        #expect(c.last!.state.phase == .declined)
    }

    @Test func switchingRoleRestartsTheTransportOnlyWhileNothingIsOffered() {
        let r = Self.run(true, [.arm(role: .send, askFirst: true), .setRole(.receive), .peerFound(1), .peerNear(1), .tapDetected(peer: 1, videoId: "", nowMs: 0),
                                .setRole(.send)])
        #expect(Self.fx(r[1]) == ["stopTransport", "startTransport(receive)"])
        #expect(r[5].state.role == .receive && r[5].effects.isEmpty)
    }

    @Test func disarmTearsEverythingDown() {
        let r = Self.run(false, [.arm(role: .receive, askFirst: false), .peerFound(1), .peerNear(1), .tapDetected(peer: 1, videoId: "", nowMs: 900),
                                 .offerReceived(peer: 1, videoId: Self.v1, senderKey: 7, nowMs: 1000), .disarm, .disarm])
        #expect(r[5].state.phase == .idle)
        #expect(Self.fx(r[5]) == ["abortTransfer(1)", "stopTransport"])
        #expect(r[6].effects.isEmpty)
        // A target and a held offer are cleared with it.
        #expect(r[5].state.target == 0 && !r[5].state.pre)
    }

    @Test func theDescriptionAppendsTheDropWordsOnlyWhenSet() {
        let plain = SongTapSessionState.initial()
        #expect(plain.describe() == "idle role=send peer=0 vid=- fail=- ask=1 had=0 key=0")
        var s = plain
        s.target = 4; s.offerRead = true; s.tapSeen = true; s.acked = true; s.beamDone = true; s.pre = true
        #expect(s.describe().hasSuffix(" tgt=4 read=1 tapseen=1 acked=1 beamdone=1 pre=1"))
    }

    @Test func everyRandomStreamEndsInAStateThatCanStillBeLeft() {
        var rng = SongTapCoreTests.SplitMix64(state: 99)
        for _ in 0..<300 {
            var state = SongTapSessionState.initial(askFirst: rng.int(2) == 0)
            var now: Int64 = 0
            for _ in 0..<40 {
                now += Int64(rng.int(5000))
                let e: SongTapSessionEvent
                switch rng.int(10) {
                case 0: e = .arm(role: SongTapRole.allCases[rng.int(2)], askFirst: true)
                case 1: e = .peerFound(1 + rng.int(2))
                case 2: e = .peerNear(1 + rng.int(2))
                case 3:
                    if rng.int(3) == 0 { e = .approve(peer: 1 + rng.int(2), videoId: Self.v1) }
                    else if rng.int(2) == 0 { e = .offerPrefetched(peer: 1 + rng.int(2), videoId: Self.v1, senderKey: 1) }
                    else { e = .tapDetected(peer: 1 + rng.int(2), videoId: rng.int(2) == 0 ? Self.v1 : "", nowMs: now) }
                case 4: e = .offerReceived(peer: rng.int(2), videoId: Self.v1, senderKey: Int32(rng.int(3)), nowMs: now)
                case 5: e = rng.int(2) == 0 ? .ackReceived(nowMs: now, rttMs: 10) : .offerRead(peer: 1 + rng.int(2), nowMs: now)
                case 6: e = .saveResult(SongTapSaveOutcome.allCases[rng.int(4)], nowMs: now)
                case 7: e = .cancel
                case 8: e = .accept(nowMs: now)
                default: e = .dismiss
                }
                state = SongTapSession.reduce(state, e).state
            }
            let out = SongTapSession.reduce(SongTapSession.reduce(state, .cancel).state, .disarm).state
            #expect(SongTapSession.reduce(out, .disarm).state.phase == .idle)
        }
    }

    // MARK: Detector

    /// Runs `rssi` (already on the reference scale) at 100 ms spacing; `impulseAt` is when a jerk happened (known from then on).
    static func fires(_ rssi: [Int], impulseAt: Int64 = -1, profile: SongTapSensitivity = .normal) -> [(t: Int64, reason: SongTapFireReason)] {
        var state = SongTapDetectorState.initial
        var out: [(Int64, SongTapFireReason)] = []
        for (i, r) in rssi.enumerated() {
            let t = Int64(i) * 100
            let step = SongTapDetector.step(state, SongTapRssiSample(tMs: t, rssi: r), impulseMs: impulseAt >= 0 && impulseAt <= t ? impulseAt : -1,
                                            profile: profile)
            state = step.state
            if step.fire != .none { out.append((t, step.fire)) }
        }
        return out
    }

    static func series(_ parts: (Int, Int)...) -> [Int] { parts.flatMap { Array(repeating: $0.1, count: $0.0) } }

    @Test func theProfilesAreTheOwnersNumbers() {
        let n = SongTapSensitivity.normal
        #expect([n.baselineShift, n.fastShift, n.jumpDb, n.freezeDb] == ([3, 1, 15, 6] as [Int]))
        #expect([n.holdMs, n.dwellMs, n.impulseWindowMs, n.cooldownMs] == ([150, 400, 400, 2_000] as [Int64]))
        #expect(n.jerkMilliG == 1_800)
        let h = SongTapSensitivity.high
        #expect([h.baselineShift, h.fastShift, h.jumpDb, h.freezeDb] == ([3, 1, 9, 6] as [Int]))
        #expect([h.holdMs, h.dwellMs, h.impulseWindowMs, h.cooldownMs] == ([60, 200, 400, 1_200] as [Int64]))
        #expect(h.jerkMilliG == 900)
        #expect(SongTapSensitivity.default == .high)
        #expect(SongTapSensitivity.fromCode(nil) == .high)
        #expect(SongTapSensitivity.fromCode("loud") == .high)
        #expect(SongTapSensitivity.fromCode("normal") == .normal)
        #expect(SongTapTuning.nearEnterDbm == -70 && SongTapTuning.nearExitDbm == -78)
        #expect(SongTapTuning.listEnterDbm == -85 && SongTapTuning.listExitDbm == -92)
        #expect(SongTapTuning.closeHoldDbm == -45 && SongTapTuning.closeHoldMs == 250 && SongTapTuning.closeReleaseDbm == -55)
    }

    @Test func aSteadySignalNeverFires() {
        for p in SongTapSensitivity.allCases {
            #expect(Self.fires(Self.series((60, -60)), profile: p).isEmpty)
            #expect(Self.fires(Self.series((20, -95), (30, -80)), profile: p).isEmpty)
        }
    }

    @Test func phonesBroughtCloseGentlyAndHeldFireAsHoldOnceWithNoJumpAndNoJerk() {
        // From far to a few cm over 15 seconds (no 15 dB jump at any moment), then held at -40: the old rules never fire here.
        let f = Self.fires((0..<150).map { -90 + $0 / 3 } + Self.series((30, -40)))
        #expect(f.count == 1)
        #expect(f.first?.reason == .hold)
    }

    @Test func aSignalHeldJustOutsideTheHoldLevelDoesNotFire() {
        #expect(Self.fires((0..<120).map { -90 + $0 / 3 } + Self.series((40, -47))).isEmpty)
    }

    @Test func theHoldNeverFiresAtRestRestingIsAboutMinus60() {
        for p in SongTapSensitivity.allCases {
            #expect(Self.fires(Self.series((200, -60)), profile: p).isEmpty)
            #expect(Self.fires(Self.series((200, -50)), profile: p).isEmpty, "-50 is still a couple of cm away, not a hold")
            #expect(Self.fires(Self.series((200, -46)), profile: p).isEmpty)
        }
    }

    @Test func aSteadyStrongSignalFiresTheHoldOnceAndAgainOnlyAfterThePhonesCameApart() {
        let f = Self.fires(Self.series((80, -40)))
        #expect(f.count == 1 && f[0].reason == .hold)
        #expect(f[0].t >= SongTapTuning.closeHoldMs)
        // Resting 20 to 30 cm apart (-60) is apart for the hold: a second touch counts.
        let again = Self.fires(Self.series((30, -62), (12, -40), (40, -62), (25, -40)))
        #expect(again.count == 2)
        #expect(again[1].t - again[0].t >= SongTapSensitivity.normal.cooldownMs)
        // Sliding off to -52 only (not below -55) does not re-arm it.
        #expect(Self.fires(Self.series((30, -62), (12, -40), (40, -52), (25, -40))).count == 1)
    }

    @Test func aPhoneSeenOnlyInsideTheListGateButOutsideTheNearGateCannotFire() {
        #expect(Self.fires(Self.series((20, -95), (20, -73)), impulseAt: 2_000).isEmpty)
    }

    @Test func aJumpThatHoldsWithAJerkFiresAsImpulse() {
        let f = Self.fires(Self.series((20, -64), (10, -44)), impulseAt: 2_050)
        #expect(f.count == 1 && f[0].reason == .impulse)
        #expect((2_100...2_700).contains(f[0].t))
    }

    @Test func aGentleTapWithNoJerkFiresOnlyAfterTheDwell() {
        // -64 to -46: an 18 dB jump that never reaches the hold level (-45).
        let f = Self.fires(Self.series((20, -64), (10, -46)))
        #expect(f.count == 1 && f[0].reason == .dwell)
        let withJerk = Self.fires(Self.series((20, -64), (10, -46)), impulseAt: 2_050)
        #expect(withJerk[0].reason == .impulse)
        #expect(f[0].t > withJerk[0].t)
    }

    @Test func phonesThatStayTogetherFireOnceAndNotAgainEveryCooldown() {
        #expect(Self.fires(Self.series((20, -64), (80, -44)), impulseAt: 2_050).count == 1)
        #expect(Self.fires(Self.series((20, -64), (80, -44))).count == 1)
    }

    @Test func aSlowApproachThatStopsShortOfContactDoesNotFire() {
        let ramp = (0..<30).map { -90 + $0 }
        for p in SongTapSensitivity.allCases { #expect(Self.fires(ramp + Self.series((40, -61)), profile: p).isEmpty) }
    }

    @Test func aJumpThatHoldsForGoodIsTakenAsTheNewLevelAfterAWhile() {
        var state = SongTapDetectorState.initial
        for i in 0..<20 { state = SongTapDetector.step(state, SongTapRssiSample(tMs: Int64(i) * 100, rssi: -90), impulseMs: -1, profile: .normal).state }
        for i in 20..<60 { state = SongTapDetector.step(state, SongTapRssiSample(tMs: Int64(i) * 100, rssi: -70), impulseMs: -1, profile: .normal).state }
        #expect(state.heldSinceMs < 0)
        #expect(state.baselineQ > -75 * songTapRssiScale)
    }

    @Test func aSpikeThatDoesNotHoldDoesNotFire() {
        for p in SongTapSensitivity.allCases {
            #expect(Self.fires(Self.series((20, -62), (1, -40), (20, -62)), impulseAt: 2_000, profile: p).isEmpty)
        }
    }

    @Test func aJerkLongBeforeTheJumpDoesNotCount() {
        let dwell = Self.fires(Self.series((20, -75), (15, -56)), impulseAt: 100)
        #expect(dwell[0].reason == .dwell)
    }

    @Test func theAbsoluteFloorKeepsAFarJumpFromFiring() {
        #expect(Self.fires(Self.series((20, -95), (10, -80)), impulseAt: 2_000).isEmpty)
    }

    @Test func theSameJumpFiresTheSameWayOnPhonesThatHearItAFewDbLouderOrQuieter() {
        let quiet = Self.fires(Self.series((20, -72), (10, -54)), impulseAt: 2_050)
        let loud = Self.fires(Self.series((20, -69), (10, -51)), impulseAt: 2_050)
        #expect(quiet.count == 1 && quiet[0].reason == .impulse)
        #expect(loud.count == 1 && loud[0].reason == .impulse)
        #expect((-200...200).contains(quiet[0].t - loud[0].t))
    }

    @Test func aSecondTapInsideTheCooldownDoesNotFire() {
        let f = Self.fires(Self.series((20, -64), (8, -46), (10, -64), (8, -46)), impulseAt: 2_050)
        #expect(f.filter { $0.t < 4_000 }.count == 1)
        let g = Self.fires(Self.series((20, -64), (8, -46), (20, -64), (20, -46)), impulseAt: 2_050)
        #expect(g.count == 2)
        #expect(g[1].t - g[0].t >= SongTapSensitivity.normal.cooldownMs)
    }

    @Test func highReactsToASmallerShorterJumpThanNormal() {
        // A 12 dB step held for 800 ms: not a tap for normal (15 dB), a tap for high (9 dB held 200 ms).
        let step = Self.series((20, -64), (8, -52), (10, -64))
        #expect(Self.fires(step, profile: .normal).isEmpty)
        let high = Self.fires(step, profile: .high)
        #expect(high.count == 1 && high[0].reason == .dwell)
        // With a 900 milli g bump the jump needs to hold only 60 ms.
        let bump = Self.fires(Self.series((20, -64), (6, -52), (10, -64)), impulseAt: 2_000, profile: .high)
        #expect(bump[0].reason == .impulse)
        #expect(bump[0].t < high[0].t)
        // And it may fire again after 1.2 s instead of 2 s.
        let twice = Self.fires(Self.series((20, -64), (6, -48), (10, -64), (8, -48)), profile: .high)
        #expect(twice.count == 2)
        #expect(Self.fires(Self.series((20, -64), (6, -48), (10, -64), (8, -48)), profile: .normal).count == 1)
        #expect((SongTapSensitivity.high.cooldownMs..<SongTapSensitivity.normal.cooldownMs).contains(twice[1].t - twice[0].t))
    }

    @Test func aLongGapForgetsThePeer() {
        var state = SongTapDetectorState.initial
        for i in 0..<5 { state = SongTapDetector.step(state, SongTapRssiSample(tMs: Int64(i) * 100, rssi: -62), impulseMs: -1).state }
        let after = SongTapDetector.step(state, SongTapRssiSample(tMs: 10_000, rssi: -42), impulseMs: -1)
        #expect(after.state.baselineQ == -42 * songTapRssiScale)
        #expect(after.fire == .none)
    }

    @Test func nearHasHysteresis() {
        var state = SongTapDetectorState.initial
        var near: [Bool] = []
        for (i, r) in [-90, -80, -73, -71, -69, -69, -69, -75, -75, -75, -75, -82, -82, -82, -82].enumerated() {
            state = SongTapDetector.step(state, SongTapRssiSample(tMs: Int64(i) * 100, rssi: r), impulseMs: -1).state
            near.append(state.near)
        }
        #expect(!near[0])
        #expect(!near[3], "-71 is outside the near gate (-70)")
        #expect(near[6])
        #expect(near[10], "-75 is inside the exit level, so it stays near")
        #expect(!near.last!)
    }

    @Test func glowGrowsWithTheSignalAndFloorDivisionRoundsDown() {
        #expect(SongTapDetector.glowPermille(-90 * songTapRssiScale) == 0)
        #expect(SongTapDetector.glowPermille(-40 * songTapRssiScale) == 500)
        #expect((100...400).contains(SongTapDetector.glowPermille(-62 * songTapRssiScale)))
        #expect(SongTapDetector.floorDiv(-1, 256) == -1)
        #expect(SongTapDetector.floorDiv(-257, 256) == -2)
        #expect(SongTapDetector.floorDiv(255, 256) == 0)
        #expect(SongTapDetector.floorDiv(-70 * 256, 256) == -70)
    }

    @Test func aJerkNeedsABigChangeAndIsDebouncedAndTheThresholdIsTheProfilesOwn() {
        var state = SongTapImpulseState.initial
        func feed(_ t: Int64, _ x: Int, _ y: Int, _ z: Int) -> Bool {
            let s = SongTapImpulse.step(state, SongTapAccelSample(tMs: t, xMg: x, yMg: y, zMg: z), profile: .normal)
            state = s.state
            return s.impulse
        }
        #expect(!feed(0, 0, 0, 1000))
        #expect(!feed(20, 10, 0, 1020))
        #expect(feed(40, 0, 0, 4000))
        #expect(!feed(60, 0, 0, 1000), "inside the debounce")
        #expect(!feed(80, 0, 0, 4000), "inside the debounce")
        #expect(feed(400, 0, 0, 1000))
        func hits(_ profile: SongTapSensitivity, _ step: Int) -> Bool {
            let first = SongTapImpulse.step(.initial, SongTapAccelSample(tMs: 0, xMg: 0, yMg: 0, zMg: 1000), profile: profile).state
            return SongTapImpulse.step(first, SongTapAccelSample(tMs: 20, xMg: 0, yMg: 0, zMg: 1000 + step), profile: profile).impulse
        }
        #expect(hits(.high, 1_000))
        #expect(!hits(.normal, 1_000))
        #expect(hits(.normal, 1_800))
        #expect(!hits(.high, 899))
    }

    // MARK: The one-sided tap

    static func judge(dbm: Int = -40, followed: Bool = true, yes: Bool = true, now: Int64 = 10_000, last: Int64 = -1) -> SongTapPeerTapVerdict {
        SongTapPeerTap.judge(ownFastDbm: dbm, followed: followed, saidYes: yes, nowMs: now, lastTapMs: last)
    }

    @Test func aPeerTapIsAcceptedWhenThisPhoneIsNearFollowsThatPhoneTheSenderSaidYesAndNothingWasTakenLately() {
        #expect(Self.judge() == .accept)
        #expect(Self.judge(dbm: SongTapTuning.nearEnterDbm) == .accept)
        #expect(Self.judge(dbm: -33) == .accept)
        #expect(Self.judge(dbm: -60) == .accept, "resting 20 to 30 cm apart is inside the gate")
    }

    @Test func aPeerTapIsIgnoredWhenTheSignalIsBelowTheNearGateTheMessageIsNotFromTheFollowedPhoneOrThereIsNoYes() {
        #expect(Self.judge(dbm: SongTapTuning.nearEnterDbm - 1) == .tooWeak)
        #expect(Self.judge(dbm: -90) == .tooWeak)
        #expect(Self.judge(followed: false) == .notFollowed)
        #expect(Self.judge(dbm: -95, followed: false, yes: false, last: 9_999) == .notFollowed, "not followed wins over everything else")
        #expect(Self.judge(yes: false) == .noYes)
        #expect(Self.judge(dbm: -95, yes: false) == .noYes)
    }

    @Test func aPeerTapIsRateLimitedToOnePer1200MsCountedFromThisPhonesOwnLastFireToo() {
        #expect(Self.judge(now: 10_000, last: 9_999) == .tooSoon)
        #expect(Self.judge(now: 10_000, last: 8_801) == .tooSoon)
        #expect(Self.judge(now: 10_000, last: 8_800) == .accept)
        #expect(Self.judge(now: 10_000, last: -1) == .accept)
        #expect(SongTapPeerTap.minGapMs == 1_200)
        #expect(SongTapPeerTapVerdict.allCases.map(\.code) == ["accept", "too_weak", "not_followed", "no_yes", "too_soon"])
    }

    @Test func theTapEventIsTheSingleByte04OnEventAndTheControlTapKeepsItsFiveBytes() {
        #expect(SongTapWire.eventTap == 4)
        #expect(SongTapWire.encodeTapEvent() == [0x04])
        #expect(SongTapWire.isTapEvent([4]))
        #expect(!SongTapWire.isTapEvent([3]))
        #expect(!SongTapWire.isTapEvent([4, 0]))
        #expect(!SongTapWire.isTapEvent([]))
        #expect(SongTapWire.encodeTap(ageMs: 100).count == 5 && SongTapWire.encodeTap(ageMs: 100)[0] == 0x04)
        #expect(!SongTapWire.isTapEvent(SongTapWire.encodeOfferReady()))
        #expect(!SongTapWire.isTapEvent(SongTapWire.encodeOfferWithdrawn()))
        #expect(!SongTapWire.isOfferReady(SongTapWire.encodeTapEvent()))
        #expect(!SongTapWire.isOfferWithdrawn(SongTapWire.encodeTapEvent()))
    }

    // MARK: Names and the nearby list

    @Test func aNameIsTrimmedCollapsedAndAtMost20Characters() {
        #expect(SongTapNames.clean("   Hoa's    iPhone  ") == "Hoa's iPhone")
        #expect(SongTapNames.clean(String(repeating: "A", count: 40)) == String(repeating: "A", count: 20))
        #expect(SongTapNames.clean("   ") == "")
        #expect(SongTapNames.orFallback("") == SongTapNames.fallback)
        // The cut can fall on a space: it is not left trailing.
        #expect(SongTapNames.clean(String(repeating: "x", count: 19) + " y") == String(repeating: "x", count: 19))
    }

    @Test func controlZeroWidthAndBidirectionalCharactersAreStripped() {
        #expect(SongTapNames.clean("\u{202E}evil\u{202C}") == "evil")
        #expect(SongTapNames.clean("zero\u{200B}width") == "zerowidth")
        #expect(SongTapNames.clean("bell\u{07}x") == "bellx")
        #expect(SongTapNames.clean("tab\there") == "tab here")
        #expect(SongTapNames.clean("\u{FEFF}bom") == "bom")
    }

    @Test func charactersAreScalarsNotSwiftCharacters() {
        // A family emoji is one Swift Character but seven scalars: the name counts scalars.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        #expect(family.count == 1)
        #expect(SongTapNames.clean(family) == "\u{1F468}\u{1F469}\u{1F467}", "the zero width joiners are stripped")
        let party = "\u{1F38A}"
        #expect(SongTapNames.clean(String(repeating: party, count: 40)) == String(repeating: party, count: 20))
        #expect(SongTapNames.isValid(String(repeating: party, count: 20)))
        #expect(!SongTapNames.isValid(String(repeating: party, count: 21)))
    }

    @Test func cleanIsIdempotentAndValidNamesAreFixedPoints() {
        for raw in ["Pixel 10 Pro", "  a  b  ", String(repeating: "\u{E9}", count: 25), String(repeating: "\u{1F38A} x", count: 8), "line\nbreak"] {
            let once = SongTapNames.clean(raw)
            #expect(SongTapNames.clean(once) == once)
            if !once.isEmpty { #expect(SongTapNames.isValid(once)) }
        }
        #expect(!SongTapNames.isValid(""))
        #expect(!SongTapNames.isValid(" x"))
    }

    @Test func theAdvertisedNameIsCutAtAScalarBoundaryTo24Bytes() {
        #expect(SongTapNames.advertName("Pixel 10 Pro") == "Pixel 10 Pro")
        #expect(SongTapNames.advertName(String(repeating: "\u{E9}", count: 20)) == String(repeating: "\u{E9}", count: 12))
        let emoji = String(repeating: "\u{1F38A}", count: 10)
        #expect(SongTapNames.advertName(emoji) == String(repeating: "\u{1F38A}", count: 6))
        #expect(SongTapText.utf8Length(SongTapText.toCodePoints(SongTapNames.advertName(emoji))) == 24)
        #expect(SongTapNames.fromAdvert("  ") == nil)
        #expect(SongTapNames.fromAdvert(" Bo ") == "Bo")
    }

    static func q(_ dbm: Int) -> Int { dbm * songTapRssiScale }

    @Test func aPhoneIsListedInsideTheListGateAndNotOutsideIt() {
        var book = SongTapNearbyBook()
        book.update(id: 1, name: "Ann", role: .receive, fastQ: Self.q(-70), near: false, nowMs: 1_000)
        book.update(id: 2, name: "Bo", role: .receive, fastQ: Self.q(-90), near: false, nowMs: 1_000)
        #expect(book.visible(role: .receive, nowMs: 1_000).map(\.id) == [1])
        #expect(SongTapTuning.listEnterDbm < SongTapTuning.nearEnterDbm)
        #expect(!book.visible(role: .receive, nowMs: 1_000)[0].near)
    }

    @Test func aListedPhoneLeavesTheListOnlyBelowTheExitLevel() {
        var book = SongTapNearbyBook()
        book.update(id: 1, name: "Ann", role: .receive, fastQ: Self.q(-84), near: false, nowMs: 1_000)
        book.update(id: 1, name: "Ann", role: .receive, fastQ: Self.q(-91), near: false, nowMs: 1_100)
        #expect(book.visible(role: .receive, nowMs: 1_100).count == 1)
        book.update(id: 1, name: "Ann", role: .receive, fastQ: Self.q(-93), near: false, nowMs: 1_200)
        #expect(book.visible(role: .receive, nowMs: 1_200).isEmpty)
        // And needs the enter level again to come back.
        book.update(id: 1, name: "Ann", role: .receive, fastQ: Self.q(-88), near: false, nowMs: 1_300)
        #expect(book.visible(role: .receive, nowMs: 1_300).isEmpty)
    }

    @Test func theListIsStrongestFirstTiesByNumberAndOnlyTheAskedRole() {
        var book = SongTapNearbyBook()
        book.update(id: 3, name: "Cy", role: .receive, fastQ: Self.q(-60), near: false, nowMs: 1_000)
        book.update(id: 1, name: "Ann", role: .receive, fastQ: Self.q(-70), near: false, nowMs: 1_000)
        book.update(id: 2, name: "Bo", role: .receive, fastQ: Self.q(-60), near: false, nowMs: 1_000)
        book.update(id: 4, name: "Di", role: .send, fastQ: Self.q(-40), near: false, nowMs: 1_000)
        #expect(book.visible(role: .receive, nowMs: 1_000).map(\.id) == [2, 3, 1])
        #expect(book.visible(role: .send, nowMs: 1_000).map(\.id) == [4])
    }

    @Test func staleEntriesExpireAndOnePhoneIsOneRowAlsoWhenItChangesAddress() {
        var book = SongTapNearbyBook()
        book.update(id: 1, name: "Ann", role: .receive, fastQ: Self.q(-60), near: false, nowMs: 1_000)
        #expect(book.visible(role: .receive, nowMs: 1_000 + SongTapNearbyBook.staleMs).count == 1)
        #expect(book.visible(role: .receive, nowMs: 1_001 + SongTapNearbyBook.staleMs).isEmpty)
        book.remove(1)
        #expect(book.visible(role: .receive, nowMs: 1_000).isEmpty)

        book.update(id: 1, name: "Ann", role: .receive, fastQ: Self.q(-70), near: false, nowMs: 1_000)
        book.update(id: 1, name: "Ann", role: .receive, fastQ: Self.q(-60), near: false, nowMs: 1_500)
        #expect(book.visible(role: .receive, nowMs: 1_500).count == 1)
        // The same name under a new number while the old one has gone quiet: only the newer shows.
        book.update(id: 2, name: "Ann", role: .receive, fastQ: Self.q(-60), near: false, nowMs: 3_100)
        #expect(book.visible(role: .receive, nowMs: 3_100).map(\.id) == [2])
        // Both heard at the same time: two phones that happen to share a name.
        book.update(id: 1, name: "Ann", role: .receive, fastQ: Self.q(-60), near: false, nowMs: 3_200)
        #expect(book.visible(role: .receive, nowMs: 3_200).count == 2)
    }

    @Test func thePromptIsForTheStrongestPhoneInsideTheNearGateThatWasNotToldNoAndNoSilencesItForAMinute() {
        var book = SongTapNearbyBook()
        book.update(id: 1, name: "Ann", role: .receive, fastQ: Self.q(-60), near: false, nowMs: 1_000)
        #expect(book.promptFor(role: .receive, nowMs: 1_000) == nil)
        book.update(id: 1, name: "Ann", role: .receive, fastQ: Self.q(-52), near: true, nowMs: 1_100)
        book.update(id: 2, name: "Bo", role: .receive, fastQ: Self.q(-50), near: true, nowMs: 1_100)
        #expect(book.promptFor(role: .receive, nowMs: 1_100)?.id == 2)
        book.ignore(2, nowMs: 1_100)
        #expect(book.promptFor(role: .receive, nowMs: 1_100)?.id == 1)
        book.ignore(1, nowMs: 1_100)
        #expect(book.promptFor(role: .receive, nowMs: 1_100) == nil)
        let later = 1_100 + SongTapNearbyBook.ignoreMs
        book.update(id: 1, name: "Ann", role: .receive, fastQ: Self.q(-52), near: true, nowMs: later - 1)
        #expect(book.promptFor(role: .receive, nowMs: later - 1) == nil)
        book.update(id: 1, name: "Ann", role: .receive, fastQ: Self.q(-52), near: true, nowMs: later)
        #expect(book.promptFor(role: .receive, nowMs: later)?.id == 1)
    }

    // MARK: The wire

    @Test func anOfferReadyEventIsItsOwnOneByteEventAndGoIsNoLongerSent() {
        #expect(SongTapWire.isOfferReady(SongTapWire.encodeOfferReady()))
        #expect(!SongTapWire.isOfferReady(SongTapWire.encodeGo()))
        #expect(!SongTapWire.isGo(SongTapWire.encodeOfferReady()))
        #expect(SongTapWire.eventOfferReady == 2 && SongTapWire.eventOfferWithdrawn == 3)
        #expect(SongTapWire.isOfferWithdrawn(SongTapWire.encodeOfferWithdrawn()))
        #expect(!SongTapWire.isOfferWithdrawn(SongTapWire.encodeOfferReady()))
        #expect(SongTapHandshake.goDelayMs == 0)
    }

    @Test func aNameTravelsInTheNameCharacteristicAndInTheAdvertisement() {
        #expect(SongTapWire.decodeName(SongTapWire.encodeName("Pixel 10 Pro")) == "Pixel 10 Pro")
        #expect(SongTapWire.decodeAdvertName(SongTapWire.encodeAdvertName("Pixel 10 Pro")) == "Pixel 10 Pro")
        let long = String(repeating: "\u{E9}", count: 20)
        #expect(SongTapWire.decodeName(SongTapWire.encodeName(long)) == long)
        #expect(SongTapWire.decodeAdvertName(SongTapWire.encodeAdvertName(long)) == String(repeating: "\u{E9}", count: 12))
        #expect(SongTapWire.encodeAdvertName(long).count <= 1 + SongTapNames.advertNameMaxBytes)
        #expect(Int(SongTapWire.encodeAdvertName("x")[0]) == SongTapWire.advertVersion)
        #expect(Int(SongTapWire.encodeName("x")[0]) == SongTapWire.version)
        #expect(SongTapWire.charName == "b7f3a1c0-5d2e-4c9a-8e61-3f4d7a2b9c15")
        #expect(SongTapWire.advertCompanyId == 0xFFFF)
    }

    @Test func aNameValueThatIsNotExactlyANameIsRefused() {
        #expect(SongTapWire.decodeName([]) == nil)
        #expect(SongTapWire.decodeName([1]) == nil)
        #expect(SongTapWire.decodeName([2, 65]) == nil)
        #expect(SongTapWire.decodeName([1, 0xFF]) == nil)
        #expect(SongTapWire.decodeName([1, 0x20]) == nil)
        #expect(SongTapWire.decodeName([UInt8](repeating: 65, count: 2 + SongTapNames.maxNameBytes)) == nil)
        #expect(SongTapWire.decodeAdvertName([1]) == nil)
        #expect(SongTapWire.decodeAdvertName([2, 65]) == nil)
        #expect(SongTapWire.decodeAdvertName([UInt8](repeating: 65, count: 2 + SongTapNames.advertNameMaxBytes)) == nil)
    }

    @Test func everyUuidIsALowerCase128BitUuidAndTheyAreAllDifferent() {
        let all = [SongTapWire.serviceSend, SongTapWire.serviceReceive, SongTapWire.charInfo, SongTapWire.charOffer, SongTapWire.charControl,
                   SongTapWire.charEvent, SongTapWire.charName]
        for u in all {
            #expect(u.split(separator: "-").map(\.count) == [8, 4, 4, 4, 12], "\(u)")
            #expect(u.allSatisfy { $0 == "-" || ("0"..."9").contains($0) || ("a"..."f").contains($0) }, "\(u)")
        }
        #expect(Set(all).count == all.count)
    }
}
