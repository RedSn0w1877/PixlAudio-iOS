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

        func start(role: SongTapRole, listener: any SongTapBleRadioListener) -> SongTapBleStatus {
            self.listener = listener
            calls.append("start")
            return .active
        }

        func stop() { calls.append("stop"); listener = nil }
        func connect(address: String) { calls.append("connect"); listener?.onConnected(address: address, ok: linkUp) }
        func disconnect(address: String) { calls.append("disconnect") }
        func readInfo(address: String) { listener?.onInfoRead(address: address, value: peer?.listener?.serverInfo()) }
        func readOffer(address: String) {
            let value = linkUp ? peer?.listener?.serverOffer(client: name) : nil
            listener?.onOfferRead(address: address, value: value)
        }
        func writeControl(address: String, value: [UInt8]) {
            let ok = linkUp && (peer?.listener?.serverControl(client: name, value: value) ?? false)
            listener?.onControlWritten(address: address, ok: ok)
        }
        func notifyGo(client: String) { if linkUp { peer?.listener?.onNotified(address: name, value: SongTapWire.encodeGo()) } }
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
            self.clock = clock
            self.playing = playing
            radio = LinkedRadio(name: name)
            scheduler = FakeScheduler(clock: clock)
            receiver = SongTapReceiver(library: library)
            let counter = counter
            route = SongTapBleRoute(radio: radio, impulses: impulses, clock: clock, diag: SongTapDiagnostics(), scheduler: scheduler,
                                    newSigner: { FakeSigner() }, verifier: FakeVerifier(), random: { counter.bytes($0) })
            engine.port = self
            engine.setAllowed(true)
            route.onEvent = { [unowned self] in engine.handle($0) }
            route.onStatusChange = { [unowned self] in engine.setBluetooth($0) }
            self.firstBeamAsks = firstBeamAsks
        }

        var firstBeamAsks = false
        var phase: SongTapPhase { engine.session.phase }
        var ui: SongTapUiState { engine.ui }

        func arm(_ role: SongTapRole) { engine.arm(role, askFirst: firstBeamAsks) }
        func see(_ other: String, _ role: SongTapRole, _ rssi: Int) { radio.listener!.onSeen(address: other, role: role, rssi: rssi) }

        /// Lets a save in flight finish, as the app's task would.
        func finishSave() async { await saveTask?.value; await undoTask?.value }

        // MARK: SongTapPort

        func nowMs() -> Int64 { clock.wall }
        func startTransport(_ role: SongTapRole) { route.start(role: role) }
        func stopTransport() { route.stop() }
        func publishOffer(peer: Int, payload: [UInt8]) { if peer != 0 { route.publishOffer(peer: peer, payload: payload) } }
        func withdrawOffer() { route.withdrawOffer() }
        func readOffer(peer: Int) { route.readOffer(peer: peer) }
        func sendAck(peer: Int) { route.sendAck(peer: peer) }
        func sendGo(peer: Int, startMs: Int64) { route.sendGo(peer: peer, startMs: startMs) }
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
        func requestTapPayload(peer: Int) { engine.tap(peer: peer, payload: playing) }
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

    /// Both phones on one clock (so the handshake's arithmetic is exact); each has its own timers on it.
    @MainActor
    final class Duo {
        let a: Phone, b: Phone, clock: SongTapTestClock

        init(sender: Phone, receiver: Phone, clock: SongTapTestClock) { a = sender; b = receiver; self.clock = clock }

        func step(_ rssi: Int) {
            clock.advance(100)
            a.see("B", .receive, rssi)
            b.see("A", .send, rssi)
        }

        func settle(_ rssi: Int = -62, samples: Int = 8) { for _ in 0..<samples { step(rssi) } }
        func touch(_ rssi: Int = -40, samples: Int = 8) { for _ in 0..<samples { step(rssi) } }

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

    static func pair(firstBeamAsks: Bool = false) -> Duo {
        let clock = SongTapTestClock()
        let a = Phone(name: "A", clock: clock, playing: payload())
        let b = Phone(name: "B", clock: clock, playing: nil, firstBeamAsks: firstBeamAsks)
        a.radio.peer = b.radio
        b.radio.peer = a.radio
        a.arm(.send)
        b.arm(.receive)
        return Duo(sender: a, receiver: b, clock: clock)
    }

    @Test func touchingTwoPhonesSendsTheSongSavesItAndPlaysBothAnimationsToTheEnd() async {
        let p = Self.pair()
        #expect(p.a.phase == .armed)
        #expect(p.b.ui.bluetooth == .active)

        p.settle()
        #expect(p.a.phase == .found || p.a.phase == .near)
        #expect(p.b.phase == .found || p.b.phase == .near)
        #expect(p.a.route.glow > 0)

        p.touch()
        await p.pass(1_000)

        // Both sides are in the beam, the song is in the receiver's library, and nothing was asked.
        #expect(p.b.library.videos == ["dQw4w9WgXcQ"])
        #expect(p.a.ui.beamRole == .send)
        #expect(p.b.ui.beamRole == .receive)
        #expect(p.b.phase == .saved)
        #expect(p.b.ui.card?.title == "Never Gonna Give You Up")
        // The two start within a few tens of ms of each other (here exactly the handshake's rule).
        let skew = p.b.ui.beamStartMs - p.a.ui.beamStartMs
        #expect(skew <= 60 && skew >= -200)

        await p.pass(SongTapTimeline.receiveTotalMs + 500)
        #expect(p.a.ui.beamRole == nil)
        #expect(p.b.ui.beamRole == nil)
        #expect([.armed, .found, .near].contains(p.b.phase))
        #expect(p.b.library.videos == ["dQw4w9WgXcQ"])
    }

    @Test func theFirstBeamAReceiverEverGetsAsksAndAYesSavesIt() async {
        let p = Self.pair(firstBeamAsks: true)
        p.settle()
        p.touch()
        await p.pass(1_000)
        #expect(p.b.phase == .offered)
        #expect(p.b.library.videos.isEmpty)
        #expect(p.a.phase == .offered)

        p.b.engine.accept()
        await p.pass(1_000)
        #expect(p.b.firstBeamAccepted)
        #expect(p.b.library.videos == ["dQw4w9WgXcQ"])
        #expect(p.b.ui.beamRole == .receive)
    }

    @Test func notNowTellsTheSenderAndNothingIsSaved() async {
        let p = Self.pair(firstBeamAsks: true)
        p.settle()
        p.touch()
        await p.pass(1_000)
        p.b.engine.decline()
        await p.pass(500)
        #expect(p.b.library.videos.isEmpty)
        #expect(p.a.phase == .declined)
        #expect(p.a.ui.beamRole == nil)
    }

    @Test func undoInsideTheCardsWindowTakesTheSongOutAgain() async {
        let p = Self.pair()
        p.settle()
        p.touch()
        await p.pass(2_000)
        #expect(p.b.library.videos.count == 1)
        p.b.engine.undo()
        await p.pass(100)
        #expect(p.b.library.removed == ["dQw4w9WgXcQ"])
        #expect(p.b.library.videos.isEmpty)
        #expect(p.b.ui.beamRole == nil)
    }

    @Test func theLinkDroppingBeforeTheOfferIsReadFailsTheBeamOnBothPhonesAndTheSessionRecovers() async {
        let p = Self.pair()
        p.settle()
        p.b.radio.linkUp = false // reads and writes fail from here
        p.touch()
        await p.pass(15_000)
        #expect(p.b.library.videos.isEmpty)
        #expect(p.b.phase != .saved)
        #expect(p.a.ui.beamRole == nil)
        #expect(p.b.ui.beamRole == nil)
    }

    @Test func theOtherPhoneVanishingMidOfferIsALostPeerWithANotice() async {
        let p = Self.pair(firstBeamAsks: true)
        p.settle()
        p.touch()
        await p.pass(1_000)
        #expect(p.b.phase == .offered)
        p.a.radio.drop()
        await p.pass(100)
        // The sender's receiver left while an offer stood: lost peer on the sender.
        #expect(p.a.phase == .failed)
        #expect(p.a.ui.notice == .peerLost)
    }

    @Test func cancellingOnTheSenderAfterTheOfferIsUpClosesItAndTheReceiverGivesUp() async {
        let p = Self.pair(firstBeamAsks: true)
        p.settle()
        p.touch()
        await p.pass(1_000)
        p.a.engine.cancel()
        #expect(p.a.phase == .cancelled)
        await p.pass(60_000)
        #expect(p.b.library.videos.isEmpty)
        #expect(p.a.ui.beamRole == nil)
    }

    @Test func bothPhonesSendingIsToldToTheListenerNotTried() async {
        let clock = SongTapTestClock()
        let a = Phone(name: "A", clock: clock, playing: Self.payload())
        let b = Phone(name: "B", clock: clock, playing: Self.payload())
        a.radio.peer = b.radio
        b.radio.peer = a.radio
        a.arm(.send)
        b.arm(.send)
        for _ in 0..<8 { clock.advance(100); a.see("B", .send, -62); b.see("A", .send, -62) }
        for _ in 0..<8 { clock.advance(100); a.see("B", .send, -40); b.see("A", .send, -40) }
        #expect(a.phase == .failed)
        #expect(a.ui.notice == .bothSending)
        #expect(b.phase == .failed)
        #expect(a.ui.beamRole == nil)
    }

    @Test func aSenderWithNothingPlayingSaysSoAndTheReceiverIsNotLeftWaiting() async {
        let clock = SongTapTestClock()
        let a = Phone(name: "A", clock: clock, playing: nil)
        let b = Phone(name: "B", clock: clock, playing: nil)
        a.radio.peer = b.radio
        b.radio.peer = a.radio
        a.arm(.send)
        b.arm(.receive)
        let p = Duo(sender: a, receiver: b, clock: clock)
        p.settle()
        p.touch()
        await p.pass(2_000)
        #expect(a.ui.notice == .nothingToSend)
        #expect(b.library.videos.isEmpty)
        #expect(b.phase != .saved)
    }

    @Test func aSecondTouchOfTheSameSongWithinAMinuteIsNotSavedTwice() async {
        let p = Self.pair()
        p.settle()
        p.touch()
        await p.pass(SongTapTimeline.receiveTotalMs + 2_000)
        #expect(p.b.library.videos.count == 1)
        // Apart, and together again.
        for _ in 0..<6 { p.step(-85) }
        await p.pass(3_000)
        p.settle()
        p.touch()
        await p.pass(2_000)
        #expect(p.b.library.videos.count == 1)
        #expect(p.b.library.removed.isEmpty)
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
        let p = Self.pair()
        p.settle()
        p.touch()
        await p.pass(2_000)
        // The tap's tick came from the session; no success from the session while the beam plays.
        #expect(!p.b.haptics.contains(.success))
    }

    @Test func withReduceMotionTheBeamIsTheShortCrossFadeOnBothPhones() async {
        let p = Self.pair()
        p.a.reduced = true
        p.b.reduced = true
        p.settle()
        p.touch()
        await p.pass(1_000)
        #expect(p.a.ui.beamReduced && p.b.ui.beamReduced)
        #expect(p.b.library.videos.count == 1)
        await p.pass(SongTapTimeline.totalMs(role: .receive, reducedMotion: true) + 500)
        #expect(p.b.ui.beamRole == nil)
        #expect(p.a.ui.beamRole == nil)
    }
}
