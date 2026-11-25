import Foundation
import PixlModel
import Testing
@testable import PixlLibrary

/// Two phones, whole (Android `TwoPhonesTest`): the real session state machine, the real engine and the real Bluetooth
/// route on each, with the radios wired to each other. A "touch" is both phones' signal jumping. What is not real is the
/// platform's Bluetooth, the clock, and the song library.
@MainActor
@Suite("Song Tap two phones")
struct SongTapTwoPhonesTests {
    /// A radio whose other end is another `LinkedRadio`: what one writes, the other's server receives.
    final class LinkedRadio: SongTapBleRadio {
        let name: String
        weak var peer: LinkedRadio?
        var listener: (any SongTapBleRadioListener)?
        var linkUp = true
        var calls: [String] = []

        init(name: String) { self.name = name }

        func start(role: SongTapRole, listener: any SongTapBleRadioListener, name: String) -> SongTapBleStatus {
            self.listener = listener
            calls.append("start")
            return .active
        }

        func stop() { calls.append("stop"); listener = nil }
        func connect(address: String) { calls.append("connect"); listener?.onConnected(address: address, ok: linkUp) }
        func disconnect(address: String) { calls.append("disconnect") }
        func readInfo(address: String) { listener?.onInfoRead(address: address, value: peer?.listener?.serverInfo()) }
        func readName(address: String) { listener?.onNameRead(address: address, value: linkUp ? peer?.listener?.serverName() : nil) }
        func readOffer(address: String) {
            let value = linkUp ? peer?.listener?.serverOffer(client: name) : nil
            listener?.onOfferRead(address: address, value: value)
        }
        func writeControl(address: String, value: [UInt8]) {
            let ok = linkUp && (peer?.listener?.serverControl(client: name, value: value) ?? false)
            listener?.onControlWritten(address: address, ok: ok)
        }
        func notify(client: String, value: [UInt8]) { if linkUp { peer?.listener?.onNotified(address: name, value: value) } }
        func dropClient(client: String) { calls.append("drop") }

        /// The link breaks: the other side's server loses its client, and ours loses the sender.
        func drop() {
            linkUp = false
            peer?.listener?.onDisconnected(address: name)
            listener?.serverClientGone(client: peer?.name ?? "")
        }
    }

    final class Library: SongTapLibrary, @unchecked Sendable {
        var videos: Set<String> = []
        var removed: [String] = []
        func hasVideo(_ videoId: String) async -> Bool { videos.contains(videoId) }
        func hasSpotifyId(_ spotifyId: String) async -> Bool { false }
        func findVideo(title: String, artist: String, durationMs: Int64, isrc: String?, spotifyId: String?) async throws -> String? { nil }
        func importSong(videoId: String, title: String, artist: String, durationMs: Int64, artUrl: String?) async throws -> Bool {
            videos.insert(videoId).inserted
        }
        func remove(videoId: String) async throws -> Bool { removed.append(videoId); return videos.remove(videoId) != nil }
        func songId(videoId: String) async -> String { "id-\(videoId)" }
        func songId(spotifyId: String) async -> String { "sp-\(spotifyId)" }
    }

    /// What the app's controller does for the engine, over the test's own timers.
    @MainActor
    final class Phone: SongTapPort {
        let name: String
        /// The name this phone shows the other one (Settings > Song Tap > Your name).
        let ownName: String
        let radio: LinkedRadio
        let clock: SongTapTestClock
        let scheduler: FakeScheduler
        let library = Library()
        let impulses = FakeImpulses()
        let engine = SongTapEngine()
        let receiver: SongTapReceiver
        let route: SongTapBleRoute
        var playing: SongTapPayload?
        var haptics: [SongTapHapticCue] = []
        var firstBeamAccepted = false
        var reduced = false
        var saveTask: Task<Void, Never>?
        private let counter = TestByteSource()

        init(name: String, clock: SongTapTestClock, playing: SongTapPayload?, firstBeamAsks: Bool = false) {
            self.name = name
            ownName = name == "A" ? "Ann" : "Bea"
            self.clock = clock
            self.playing = playing
            radio = LinkedRadio(name: name)
            scheduler = FakeScheduler(clock: clock)
            receiver = SongTapReceiver(library: library)
            let counter = counter
            route = SongTapBleRoute(radio: radio, impulses: impulses, clock: clock, diag: SongTapDiagnostics(), scheduler: scheduler,
                                    newSigner: { FakeSigner() }, verifier: FakeVerifier(), random: { counter.bytes($0) })
            route.setOwnName(ownName)
            engine.port = self
            engine.setAllowed(true)
            route.onEvent = { [unowned self] in engine.handle($0) }
            route.onStatusChange = { [unowned self] in engine.setBluetooth($0) }
            route.onNearbyChange = { [unowned self] list, ask in engine.setNearby(list, prompt: ask) }
            self.firstBeamAsks = firstBeamAsks
        }

        var firstBeamAsks = false
        var phase: SongTapPhase { engine.session.phase }
        var ui: SongTapUiState { engine.ui }

        func arm(_ role: SongTapRole) { engine.arm(role, askFirst: firstBeamAsks) }
        func see(_ other: String, _ role: SongTapRole, _ rssi: Int, name: String? = nil) {
            radio.listener!.onSeen(address: other, role: role, rssi: rssi, name: name)
        }

        /// Lets a save in flight finish, as the app's task would.
        func finishSave() async { await saveTask?.value; await undoTask?.value }

        // MARK: SongTapPort

        func nowMs() -> Int64 { clock.wall }
        func startTransport(_ role: SongTapRole) { route.start(role: role) }
        func stopTransport() { route.stop() }
        func publishOffer(peer: Int, payload: [UInt8]) { if peer != 0 { route.publishOffer(peer: peer, payload: payload) } }
        func withdrawOffer(keepBluetooth: Bool) { if !keepBluetooth { route.withdrawOffer() } }
        func readOffer(peer: Int) { route.readOffer(peer: peer) }
        func sendAck(peer: Int) { route.sendAck(peer: peer) }
        func sendDecline(peer: Int) { route.sendDecline(peer: peer) }
        func abortTransfer(peer: Int) { route.abort(peer: peer) }
        func save(_ payload: SongTapPayload) {
            saveTask = Task { @MainActor [receiver, engine] in
                let result = await receiver.save(payload)
                engine.saveFinished(result, for: payload)
            }
        }
        func cancelSave() {}
        var undoTask: Task<Void, Never>?
        func undoSave(videoId: String) { undoTask = Task { @MainActor [receiver] in _ = await receiver.undo(videoId: videoId) } }
        func haptic(_ cue: SongTapHapticCue) { haptics.append(cue) }
        func schedule(_ tag: SongTapTimeoutTag, afterMs: Int64) { scheduler.set("timeout.\(tag.code)", ms: afterMs) { [unowned self] in engine.timeout(tag) } }
        func scheduleDismiss(afterMs: Int64) { scheduler.set("dismiss", ms: afterMs) { [unowned self] in engine.dismissTimerFired() } }
        func cancelDismiss() { scheduler.cancel("dismiss") }
        func scheduleInvalidNoticeClear(afterMs: Int64) { scheduler.set("notice", ms: afterMs) { [unowned self] in engine.clearInvalidCodeNotice() } }
        func cancelTimers() { for key in ["dismiss", "notice"] + SongTapTimeoutTag.allCases.map({ "timeout.\($0.code)" }) { scheduler.cancel(key) } }
        func markFirstBeamAccepted() { firstBeamAccepted = true }
        func uiChanged(_ ui: SongTapUiState) {}
        func reducedMotion() -> Bool { reduced }
        func scheduleBeamEnd(afterMs: Int64?) {
            if let afterMs { scheduler.set("beam", ms: afterMs) { [unowned self] in engine.beamTimerFired() } } else { scheduler.cancel("beam") }
        }
        func resync() { route.resync() }
    }

    static func payload() -> SongTapPayload {
        SongTapPayloads.make(nowMs: 1_763_600_000_000, ytVideoId: "dQw4w9WgXcQ", spotifyId: "4uLU6hMCjMI75M1A2tKUQC", isrc: nil,
                             title: "Never Gonna Give You Up", artist: "Rick Astley", durationMs: 213_000, artUrl: "https://i.scdn.co/image/abc")!
    }

    /// Both phones on one clock (so the timing is exact); each has its own timers on it.
    @MainActor
    final class Duo {
        let a: Phone, b: Phone, clock: SongTapTestClock

        init(sender: Phone, receiver: Phone, clock: SongTapTestClock) { a = sender; b = receiver; self.clock = clock }

        func step(_ rssi: Int) {
            clock.advance(100)
            a.see("B", .receive, rssi, name: "Bea")
            b.see("A", .send, rssi, name: "Ann")
        }

        /// Resting 20 to 30 cm apart: about -60, inside the near gate and well below the hold level.
        func settle(_ rssi: Int = BleRig.nearDbm, samples: Int = 8) { for _ in 0..<samples { step(rssi) } }
        /// Touching: about -33.
        func touch(_ rssi: Int = BleRig.touchDbm, samples: Int = 8) { for _ in 0..<samples { step(rssi) } }

        /// The listener of the sender says yes to "Song drop to Bea?": the offer is published for that phone only (the receiver fetches it).
        func yes(name: String = "Bea") {
            a.engine.approve(peer: a.engine.session.peer, name: name, payload: a.playing)
        }

        /// Time passes on both phones, with saves finishing as they would.
        func pass(_ ms: Int64) async {
            var left = ms
            while left > 0 {
                let chunk = min(50, left)
                clock.advance(chunk)
                a.scheduler.pump()
                b.scheduler.pump()
                await a.finishSave()
                await b.finishSave()
                a.scheduler.pump()
                b.scheduler.pump()
                left -= chunk
            }
        }
    }

    static func pair(firstBeamAsks: Bool = false, playing: SongTapPayload? = payload()) -> Duo {
        let clock = SongTapTestClock()
        let a = Phone(name: "A", clock: clock, playing: playing)
        let b = Phone(name: "B", clock: clock, playing: nil, firstBeamAsks: firstBeamAsks)
        a.radio.peer = b.radio
        b.radio.peer = a.radio
        a.arm(.send)
        b.arm(.receive)
        return Duo(sender: a, receiver: b, clock: clock)
    }

    /// Both phones near each other, the sender's listener said yes, the receiver holds the checked offer: the state a touch happens in.
    static func ready(firstBeamAsks: Bool = false) -> Duo {
        let p = pair(firstBeamAsks: firstBeamAsks)
        p.settle()
        p.yes()
        return p
    }

    @Test func touchingTwoPhonesSendsTheSongSavesItAndPlaysBothAnimationsToTheEnd() async {
        let p = Self.pair()
        #expect(p.a.phase == .armed)
        #expect(p.b.ui.bluetooth == .active)

        p.settle()
        #expect(p.a.phase == .found || p.a.phase == .near)
        #expect(p.b.phase == .found || p.b.phase == .near)
        #expect(p.a.route.glow > 0)

        // Nothing is offered until the sender's listener says yes (Song drop to Bea?), then the receiver holds the offer before any touch.
        #expect(p.b.engine.session.pre == false)
        p.yes()
        #expect(p.a.phase == .offered && p.a.engine.session.target == p.a.engine.session.peer)
        #expect(p.b.engine.session.pre, "the offer was fetched ahead of the tap")
        #expect(p.b.ui.peerName == "Ann", "the receiver's card will say who it is from")

        p.touch()
        await p.pass(400)

        // Both sides are in the beam, the song is in the receiver's library, and nothing was asked.
        #expect(p.b.library.videos == ["dQw4w9WgXcQ"])
        #expect(p.a.ui.beamRole == .send)
        #expect(p.b.ui.beamRole == .receive)
        #expect(p.b.phase == .saved)
        #expect(p.b.ui.card?.title == "Never Gonna Give You Up")
        // One haptic tick each at the moment of the touch, and both beams start together (the commit is one reduction on each phone).
        #expect(p.a.haptics.first == .tick && p.b.haptics.first == .tick)
        let skew = p.b.ui.beamStartMs - p.a.ui.beamStartMs
        #expect(abs(skew) <= 150, "skew \(skew) ms")

        await p.pass(SongTapTimeline.receiveTotalMs + 500)
        #expect(p.a.ui.beamRole == nil)
        #expect(p.b.ui.beamRole == nil)
        #expect([.armed, .found, .near].contains(p.b.phase))
        #expect(p.b.library.videos == ["dQw4w9WgXcQ"])
    }

    @Test func theFirstHapticAndTheBeamComeAtTheTapBeforeTheSaveIsDoneAndBeforeTheSenderHasHeardAnything() async {
        let p = Self.ready()
        p.touch(samples: 3)
        // No time has passed for the library or the network: the save has not finished, yet both phones are already beaming.
        #expect(p.a.ui.beamRole == .send)
        #expect(p.b.ui.beamRole == .receive)
        #expect(p.b.phase == .transferring)
        #expect(p.b.haptics == [.tick])
        #expect(p.a.phase == .transferring)
        await p.pass(500)
        #expect(p.b.phase == .saved)
    }

    @Test func theFirstBeamAReceiverEverGetsAsksAtTheTapTheSenderAlreadyBeamingAndAYesSavesIt() async {
        let p = Self.ready(firstBeamAsks: true)
        p.touch()
        await p.pass(400)
        #expect(p.b.phase == .offered)
        #expect(p.b.library.videos.isEmpty)
        #expect(p.a.ui.beamRole == .send, "the sender's beam has already played")

        p.b.engine.accept()
        await p.pass(1_000)
        #expect(p.b.firstBeamAccepted)
        #expect(p.b.library.videos == ["dQw4w9WgXcQ"])
        #expect(p.b.ui.beamRole == .receive)
    }

    @Test func notNowTellsTheSenderAndNothingIsSaved() async {
        let p = Self.ready(firstBeamAsks: true)
        p.touch()
        await p.pass(1_000)
        p.b.engine.decline()
        await p.pass(500)
        #expect(p.b.library.videos.isEmpty)
        #expect(p.a.phase == .declined)
        #expect(p.a.ui.beamRole == nil)
    }

    @Test func undoInsideTheCardsWindowTakesTheSongOutAgain() async {
        let p = Self.ready()
        p.touch()
        await p.pass(2_000)
        #expect(p.b.library.videos.count == 1)
        p.b.engine.undo()
        await p.pass(100)
        #expect(p.b.library.removed == ["dQw4w9WgXcQ"])
        #expect(p.b.library.videos.isEmpty)
        #expect(p.b.ui.beamRole == nil)
    }

    @Test func theLinkDroppingAfterTheOfferWasFetchedStillSavesTheSongAndTheSenderGivesUpAfterItsOwnTimeout() async {
        let p = Self.ready()
        p.b.radio.linkUp = false // reads and writes fail from here, the offer is already in hand
        p.touch()
        await p.pass(2_000)
        #expect(p.b.library.videos == ["dQw4w9WgXcQ"], "the receiver needs nothing more from the sender")
        // The sender beamed on its own tap and never hears the acknowledgement: it gives up after 45 seconds.
        await p.pass(SongTapSession.ackTimeoutMs + 1_000)
        #expect(p.a.ui.beamRole == nil)
        #expect(p.a.phase != .transferring)
    }

    @Test func whenNoOfferIsInHandAtTheTapNothingIsBeamedOnEitherPhoneAndTheSenderGivesUpAfterAMinute() async {
        let p = Self.pair()
        p.settle()
        // The sender never said yes: a touch beams nothing.
        p.touch()
        await p.pass(15_000)
        #expect(p.b.library.videos.isEmpty)
        #expect(p.b.phase != .saved)
        #expect(p.a.ui.beamRole == nil)
        #expect(p.b.ui.beamRole == nil)

        // The sender said yes but the receiver never got the offer (the link fails): the tap reads it the slow way and fails.
        let q = Self.pair()
        q.settle()
        q.b.radio.linkUp = false
        q.yes()
        q.touch()
        await q.pass(15_000)
        #expect(q.b.library.videos.isEmpty)
        #expect(q.b.ui.beamRole == nil)
        await q.pass(SongTapSession.targetTimeoutMs)
        #expect(q.a.phase != .offered, "the sender lets go of the phone after its minute")
    }

    @Test func theOtherPhoneVanishingMidBeamIsALostPeerWithANotice() async {
        let p = Self.ready(firstBeamAsks: true)
        p.touch()
        await p.pass(1_000)
        #expect(p.b.phase == .offered)
        p.a.radio.drop()
        await p.pass(100)
        // The sender's receiver left in the middle of its beam, before answering: lost peer on the sender.
        #expect(p.a.phase == .failed)
        #expect(p.a.ui.notice == .peerLost)
    }

    @Test func aSlowFirstBeamConsentDoesNotTimeTheSenderOut() async {
        // The listener reads the card for 18 seconds: the sender waits for the answer for 45.
        let p = Self.ready(firstBeamAsks: true)
        p.touch()
        await p.pass(1_000)
        for _ in 0..<170 { // the phones stay together, so both keep hearing each other
            p.step(-33)
            p.a.scheduler.pump()
            p.b.scheduler.pump()
        }
        #expect(p.b.phase == .offered)
        #expect(p.a.phase == .transferring)
        p.b.engine.accept()
        await p.pass(600)
        #expect(p.b.library.videos == ["dQw4w9WgXcQ"])
        #expect(p.a.phase == .saved, "the sender hears back after the save")
    }

    @Test func theFirstBeamsAddStillSavesTheSongAfterThePhonesCameApart() async {
        let p = Self.ready(firstBeamAsks: true)
        p.touch()
        await p.pass(1_000)
        #expect(p.b.phase == .offered)
        p.a.radio.drop() // pulling the phones apart after a tap is normal
        await p.pass(100)
        #expect(p.b.phase == .offered, "the card is still there")
        p.b.engine.accept()
        await p.pass(1_000)
        #expect(p.b.library.videos == ["dQw4w9WgXcQ"])
        #expect(p.b.phase == .saved)
        #expect(p.b.library.removed.isEmpty)
    }

    @Test func aSongTheListenerAlreadyHadIsNeverTakenBackWhenTheBeamIsCancelledMidSave() async {
        let p = Self.ready()
        p.b.library.videos = ["dQw4w9WgXcQ"] // already in the library
        p.touch()
        await p.pass(100)
        p.b.engine.cancel()
        await p.pass(2_000)
        #expect(p.b.library.removed.isEmpty)
        #expect(p.b.library.videos == ["dQw4w9WgXcQ"])
    }

    @Test func cancellingOnTheSenderAfterTheBeamStartedClosesItAndTheReceiverKeepsItsOwnCard() async {
        let p = Self.ready(firstBeamAsks: true)
        p.touch()
        await p.pass(1_000)
        p.a.engine.cancel()
        #expect(p.a.phase == .cancelled)
        await p.pass(60_000)
        #expect(p.a.ui.beamRole == nil)
        #expect(p.b.library.videos.isEmpty, "nothing is saved without the listener's yes")
    }

    @Test func bothPhonesSendingIsToldToTheListenerNotTried() async {
        let clock = SongTapTestClock()
        let a = Phone(name: "A", clock: clock, playing: Self.payload())
        let b = Phone(name: "B", clock: clock, playing: Self.payload())
        a.radio.peer = b.radio
        b.radio.peer = a.radio
        a.arm(.send)
        b.arm(.send)
        for _ in 0..<8 { clock.advance(100); a.see("B", .send, -60); b.see("A", .send, -60) }
        for _ in 0..<8 { clock.advance(100); a.see("B", .send, -33); b.see("A", .send, -33) }
        #expect(a.phase == .failed)
        #expect(a.ui.notice == .bothSending)
        #expect(b.phase == .failed)
        #expect(a.ui.beamRole == nil)
    }

    @Test func aSenderWithNothingPlayingSaysSoAndTheReceiverIsNotLeftWaiting() async {
        let p = Self.pair(playing: nil)
        p.settle()
        p.yes()
        #expect(p.a.ui.notice == .nothingToSend)
        p.touch()
        await p.pass(2_000)
        #expect(p.b.library.videos.isEmpty)
        #expect(p.b.phase != .saved)
    }

    @Test func aSecondTouchOfTheSameSongWithinAMinuteIsNotSavedTwice() async {
        let p = Self.ready()
        p.touch()
        await p.pass(SongTapTimeline.receiveTotalMs + 2_000)
        #expect(p.b.library.videos.count == 1)
        // Apart, and together again: the sender says yes again.
        for _ in 0..<6 { p.step(-85) }
        await p.pass(3_000)
        p.settle()
        p.yes()
        p.touch()
        await p.pass(2_000)
        #expect(p.b.library.videos.count == 1)
        #expect(p.b.library.removed.isEmpty)
    }

    @Test func armingAgainAsTheSameRoleOrAPauseAndResumeNeverRestartsTheRadioMoreThanNeeded() {
        let a = Phone(name: "A", clock: SongTapTestClock(), playing: Self.payload())
        a.arm(.receive)
        a.arm(.receive) // a resume that followed no pause, or a second screen
        #expect(a.radio.calls.filter { $0 == "start" }.count == 1)
        #expect(!a.radio.calls.contains("stop"))
        // A real pause and resume stops and starts once each.
        a.engine.disarm()
        a.arm(.receive)
        #expect(a.radio.calls.filter { $0 == "start" }.count == 2)
        #expect(a.phase == .armed)
    }

    @Test func leavingTheScreenStopsTheRadioAndTheSensorOnBothPhones() async {
        let p = Self.pair()
        p.settle()
        p.a.engine.disarm()
        p.b.engine.disarm()
        await p.pass(100)
        #expect(p.a.radio.calls.last == "stop")
        #expect(p.b.radio.calls.last == "stop")
        #expect(!p.a.impulses.running)
        #expect(!p.b.impulses.running)
        #expect(p.a.phase == .idle)
    }

    @Test func theBeamsOwnHapticsReplaceTheSessionsSuccessBuzzWhileItPlays() async {
        let p = Self.ready()
        p.touch()
        await p.pass(2_000)
        // The tap's tick came from the session; no success from the session while the beam plays.
        #expect(!p.b.haptics.contains(.success))
    }

    @Test func withReduceMotionTheBeamIsTheShortCrossFadeOnBothPhones() async {
        let p = Self.ready()
        p.a.reduced = true
        p.b.reduced = true
        p.touch()
        await p.pass(1_000)
        #expect(p.a.ui.beamReduced && p.b.ui.beamReduced)
        #expect(p.b.library.videos.count == 1)
        await p.pass(SongTapTimeline.totalMs(role: .receive, reducedMotion: true) + 500)
        #expect(p.b.ui.beamRole == nil)
        #expect(p.a.ui.beamRole == nil)
    }

    // MARK: The one-sided tap

    @Test func theSenderFeelingTheTapFirstBeamsBothPhonesWhileTheReceiversOwnSignalNeverMoves() async {
        let p = Self.ready()
        // Only the sender's signal for the receiver jumps; the receiver keeps reading -60 (resting beside the sender).
        for _ in 0..<8 {
            p.clock.advance(100)
            p.a.see("B", .receive, BleRig.touchDbm, name: "Bea")
            p.b.see("A", .send, BleRig.nearDbm, name: "Ann")
        }
        await p.pass(400)
        #expect(p.a.ui.beamRole == .send)
        #expect(p.b.ui.beamRole == .receive, "the sender told it at once over the link that exists")
        #expect(p.b.library.videos == ["dQw4w9WgXcQ"])
        #expect(p.b.route.lastPeerTapNote.contains("accept"))
    }

    @Test func theReceiverFeelingTheTapFirstBeamsBothPhonesWhileTheSendersOwnSignalNeverMoves() async {
        let p = Self.ready()
        for _ in 0..<8 {
            p.clock.advance(100)
            p.a.see("B", .receive, BleRig.nearDbm, name: "Bea")
            p.b.see("A", .send, BleRig.touchDbm, name: "Ann")
        }
        await p.pass(400)
        #expect(p.b.ui.beamRole == .receive)
        #expect(p.a.ui.beamRole == .send)
        #expect(p.a.route.lastPeerTapNote.contains("accept"))
    }

    @Test func theSendersTapIsNotBelievedByAReceiverThatIsAFewMetresAwayAndTheSendersBeamTimesOut() async {
        let p = Self.ready()
        // The receiver reads the sender at -80 (inside the list gate only) while the sender's own detector fires.
        for _ in 0..<8 {
            p.clock.advance(100)
            p.a.see("B", .receive, BleRig.touchDbm, name: "Bea")
            p.b.see("A", .send, BleRig.listOnlyDbm, name: "Ann")
        }
        await p.pass(1_000)
        #expect(p.b.ui.beamRole == nil)
        #expect(p.b.library.videos.isEmpty)
        await p.pass(SongTapSession.ackTimeoutMs + 1_000)
        #expect(p.a.ui.beamRole == nil)
    }

    @Test func aTapWithNoYesFromTheSenderBeamsNothingOnEitherSide() async {
        let p = Self.pair()
        p.settle()
        p.touch()
        await p.pass(2_000)
        #expect(p.a.ui.beamRole == nil && p.b.ui.beamRole == nil)
        #expect(p.b.library.videos.isEmpty)
        #expect(p.a.haptics.isEmpty)
    }

    // MARK: Song Drop (names, the picker, the prompt)

    @Test func thePickerListsThePhoneWithItsNameAndThePromptAsksWhenItComesInsideTheNearGate() async {
        let p = Self.pair()
        for _ in 0..<8 { p.step(BleRig.listOnlyDbm) }
        await p.pass(300)
        #expect(p.a.ui.nearby.map(\.name) == ["Bea"])
        #expect(p.a.ui.prompt == nil)
        for _ in 0..<8 { p.step(BleRig.nearDbm) }
        await p.pass(300)
        #expect(p.a.ui.prompt?.name == "Bea")
    }

    @Test func noToThePromptIgnoresThatPhoneForAMinuteAndATouchThenBeamsNothing() async {
        let p = Self.pair()
        p.settle()
        await p.pass(300)
        let ask = p.a.ui.prompt
        #expect(ask != nil)
        p.a.route.ignorePrompt(ask!.id)
        #expect(p.a.route.prompt == nil)
        p.touch()
        await p.pass(1_500)
        #expect(p.a.ui.beamRole == nil && p.b.ui.beamRole == nil)
        #expect(p.b.library.videos.isEmpty)
    }

    @Test func yesArmsTheBeamToThatPhoneAndCancellingPutsTheOfferAway() async {
        let p = Self.pair()
        p.settle()
        p.yes()
        #expect(p.a.phase == .offered)
        #expect(p.a.route.prompt == nil && p.a.ui.peerName == "Bea")
        #expect(p.b.engine.session.pre)
        p.a.engine.cancelDrop()
        await p.pass(300)
        #expect([.armed, .found, .near].contains(p.a.phase))
        #expect(p.a.engine.session.target == 0)
        #expect(!p.b.engine.session.pre, "the receiver let the offer go when the sender withdrew it")
        p.touch()
        await p.pass(1_000)
        #expect(p.b.library.videos.isEmpty)
    }

    @Test func aSenderStaysArmedToItsPhoneForAMinuteAndThenLetsGo() async {
        let p = Self.ready()
        await p.pass(SongTapSession.targetTimeoutMs - 1_000)
        // The phones keep resting beside each other so the sender keeps hearing the receiver.
        #expect(p.a.phase == .offered)
        await p.pass(2_000)
        #expect(p.a.phase != .offered)
    }

    @Test func theReceiversCardsSayWhoTheSongIsFromWithTheFullName() async {
        let p = Self.ready()
        p.b.radio.listener?.onNameRead(address: "A", value: SongTapWire.encodeName("Ann's iPhone 17 Pro"))
        p.touch()
        await p.pass(500)
        #expect(p.b.ui.peerName == "Ann's iPhone 17 Pro")
    }

    @Test func thePhonesAdvertiseTheirOwnCleanNames() async {
        let p = Self.pair()
        #expect(p.a.radio.calls.contains("start"))
        // The route passes `ownName` to the radio when it starts (the radio's own name is tested in the route tests).
        let rig = BleRig()
        rig.route.setOwnName("Hoa's iPhone")
        rig.route.start(role: .receive)
        #expect(rig.radio.advertisedName == "Hoa's iPhone")
    }
}
