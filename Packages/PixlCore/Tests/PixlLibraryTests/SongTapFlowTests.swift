import Foundation
import PixlModel
import Testing
@testable import PixlLibrary

/// The receiver's and the sender's rules over fakes (Android `SongTapReceiverTest` and `SongTapSenderTest`), and the
/// engine that drives the state machine (the decisions of Android's `SongTapStateHolder`) over a fake port.
@Suite("Song Tap flow")
struct SongTapFlowTests {
    // MARK: Receiver

    final class FakeLibrary: SongTapLibrary, @unchecked Sendable {
        var videos: Set<String> = []
        var spotify: Set<String> = []
        var found: String?
        var failImport = false
        var calls: [String] = []

        func hasVideo(_ videoId: String) async -> Bool { calls.append("hasVideo"); return videos.contains(videoId) }
        func hasSpotifyId(_ spotifyId: String) async -> Bool { calls.append("hasSpotifyId"); return spotify.contains(spotifyId) }
        func findVideo(title: String, artist: String, durationMs: Int64, isrc: String?, spotifyId: String?) async throws -> String? {
            calls.append("findVideo:\(title)|\(artist)|\(durationMs)")
            return found
        }
        func importSong(videoId: String, title: String, artist: String, durationMs: Int64, artUrl: String?) async throws -> Bool {
            calls.append("import:\(videoId)|\(title)|\(artist)|\(durationMs)|\(artUrl ?? "-")")
            if failImport { throw CocoaError(.fileWriteOutOfSpace) }
            return videos.insert(videoId).inserted
        }
        func remove(videoId: String) async throws -> Bool { calls.append("remove:\(videoId)"); return videos.remove(videoId) != nil }
        func songId(videoId: String) async -> String { "id-\(videoId)" }
        func songId(spotifyId: String) async -> String { "sp-\(spotifyId)" }
    }

    static let payload = SongTapPayload(
        v: 1, ts: 1, ytVideoId: "dQw4w9WgXcQ", spotifyId: "4uLU6hMCjMI75M1A2tKUQC", isrc: nil,
        title: "Never Gonna Give You Up", artist: "Rick Astley", durationMs: 213_000, artUrl: "https://i.ytimg.com/vi/x/y.jpg")

    @Test func aNewSongIsImportedWithTheBeamsOwnTextAndCanBeUndone() async throws {
        let lib = FakeLibrary()
        let receiver = SongTapReceiver(library: lib)
        guard case .saved(let card) = await receiver.save(Self.payload) else { Issue.record("expected saved"); return }
        #expect(card.title == "Never Gonna Give You Up")
        #expect(card.songId == "id-dQw4w9WgXcQ")
        #expect(lib.calls.contains("import:dQw4w9WgXcQ|Never Gonna Give You Up|Rick Astley|213000|https://i.ytimg.com/vi/x/y.jpg"))
        #expect(await receiver.undo(videoId: "dQw4w9WgXcQ"))
        #expect(lib.videos.isEmpty)
    }

    @Test func aSongAlreadyInTheLibraryIsNotImportedAgain() async {
        let lib = FakeLibrary(); lib.videos = ["dQw4w9WgXcQ"]
        guard case .alreadyHad = await SongTapReceiver(library: lib).save(Self.payload) else { Issue.record("expected alreadyHad"); return }
        #expect(!lib.calls.contains { $0.hasPrefix("import") })
    }

    @Test func theListenersOwnSpotifyRowCountsAsAlreadyThere() async {
        let lib = FakeLibrary(); lib.spotify = ["4uLU6hMCjMI75M1A2tKUQC"]
        guard case .alreadyHad = await SongTapReceiver(library: lib).save(Self.payload) else { Issue.record("expected alreadyHad"); return }
        #expect(!lib.calls.contains { $0.hasPrefix("import") })
    }

    @Test func aSpotifyOnlySongIsLookedUpAndThenSavedUnderTheVideoThatWasFound() async {
        let lib = FakeLibrary(); lib.found = "abcdefghijk"
        var p = Self.payload; p.ytVideoId = nil
        guard case .saved = await SongTapReceiver(library: lib).save(p) else { Issue.record("expected saved"); return }
        #expect(lib.calls.contains("findVideo:Never Gonna Give You Up|Rick Astley|213000"))
        #expect(lib.calls.contains { $0.hasPrefix("import:abcdefghijk|") })
    }

    @Test func aSpotifyOnlySongTheListenerAlreadyHasIsNotSearchedFor() async {
        let lib = FakeLibrary(); lib.spotify = ["4uLU6hMCjMI75M1A2tKUQC"]
        var p = Self.payload; p.ytVideoId = nil
        guard case .alreadyHad(let card) = await SongTapReceiver(library: lib).save(p) else { Issue.record("expected alreadyHad"); return }
        #expect(card.songId == "sp-4uLU6hMCjMI75M1A2tKUQC")
        #expect(!lib.calls.contains { $0.hasPrefix("findVideo") })
    }

    @Test func nothingFoundMeansNothingSaved() async {
        let lib = FakeLibrary()
        var p = Self.payload; p.ytVideoId = nil
        #expect(await SongTapReceiver(library: lib).save(p) == .notFound)
        #expect(!lib.calls.contains { $0.hasPrefix("import") })
    }

    @Test func aFoundVideoThatIsNotAVideoIdIsNotSaved() async {
        let lib = FakeLibrary(); lib.found = "../../etc"
        var p = Self.payload; p.ytVideoId = nil
        #expect(await SongTapReceiver(library: lib).save(p) == .notFound)
    }

    @Test func aFailingLibraryIsAFailedResultAndNotACrash() async {
        let lib = FakeLibrary(); lib.failImport = true
        #expect(await SongTapReceiver(library: lib).save(Self.payload) == .failed)
    }

    @Test func receivingTouchesTheLibraryAndNothingElse() async {
        // The receiver's only collaborator is the library port: no brain, no listening history and no "saved while playing"
        // flag can be reached from here, so a private session has nothing to switch off.
        let lib = FakeLibrary()
        _ = await SongTapReceiver(library: lib).save(Self.payload)
        #expect(Set(lib.calls.map { String($0.prefix { $0 != ":" }) }) == ["hasVideo", "hasSpotifyId", "import"])
    }

    @Test func anUndoThatCannotBeDoneSaysSo() async {
        #expect(await SongTapReceiver(library: FakeLibrary()).undo(videoId: "zzzzzzzzzzz") == false)
    }

    // MARK: Sender

    struct FakeIds: SongTapSongIds {
        var video: String?
        var isrc: String?
        var synthetic = false
        func videoId(for song: Song) async -> String? { video }
        func isrc(forSpotifyId spotifyId: String) async -> String? { isrc }
        func isSyntheticId(_ spotifyId: String, forVideo videoId: String) -> Bool { synthetic }
    }

    static func song(spotifyId: String?) -> Song {
        var s = Song.emptySong()
        s.id = "x"; s.title = "Never Gonna Give You Up"; s.artist = "Rick Astley"; s.duration = 213_000
        s.albumArtUriString = "https://i.scdn.co/image/abc"; s.spotifyId = spotifyId
        return s
    }

    @Test func theSenderNamesTheSongByItsVideoAndItsRealSpotifyId() async throws {
        let p = try #require(await SongTapSender(ids: FakeIds(video: "dQw4w9WgXcQ", isrc: "GBARL9300135"))
            .payload(for: Self.song(spotifyId: "4uLU6hMCjMI75M1A2tKUQC"), nowMs: 1000))
        #expect(p.ytVideoId == "dQw4w9WgXcQ" && p.spotifyId == "4uLU6hMCjMI75M1A2tKUQC" && p.isrc == "GBARL9300135")
        #expect(p.title == "Never Gonna Give You Up" && p.durationMs == 213_000 && p.artUrl == "https://i.scdn.co/image/abc")
        #expect(p.ts == 1000)
    }

    @Test func aMadeUpSpotifyIdNeverGoesAlong() async throws {
        let p = try #require(await SongTapSender(ids: FakeIds(video: "dQw4w9WgXcQ", isrc: "GBARL9300135", synthetic: true))
            .payload(for: Self.song(spotifyId: "4uLU6hMCjMI75M1A2tKUQC"), nowMs: 1))
        #expect(p.spotifyId == nil && p.isrc == nil && p.ytVideoId == "dQw4w9WgXcQ")
    }

    @Test func aSpotifySongNeverMatchedIsSentBySpotifyIdAlone() async throws {
        let p = try #require(await SongTapSender(ids: FakeIds(video: nil, isrc: nil))
            .payload(for: Self.song(spotifyId: "4uLU6hMCjMI75M1A2tKUQC"), nowMs: 1))
        #expect(p.ytVideoId == nil && p.spotifyId == "4uLU6hMCjMI75M1A2tKUQC")
    }

    @Test func aYouTubeSongWithoutASpotifyIdIsSentByItsVideo() async throws {
        let p = try #require(await SongTapSender(ids: FakeIds(video: "dQw4w9WgXcQ")).payload(for: Self.song(spotifyId: nil), nowMs: 1))
        #expect(p.ytVideoId == "dQw4w9WgXcQ" && p.spotifyId == nil)
    }

    @Test func aSongThatCannotBeNamedIsNotSent() async {
        #expect(await SongTapSender(ids: FakeIds()).payload(for: Self.song(spotifyId: nil), nowMs: 1) == nil)
    }

    // MARK: Engine

    @MainActor
    final class FakePort: SongTapPort {
        var now: Int64 = 1_763_600_000_000
        var log: [String] = []
        var uis: [SongTapUiState] = []
        var saved: [SongTapPayload] = []
        var offers: [[UInt8]] = []
        var firstBeamAccepted = false

        func nowMs() -> Int64 { now }
        func startTransport(_ role: SongTapRole) { log.append("start:\(role.code)") }
        func stopTransport() { log.append("stop") }
        func publishOffer(peer: Int, payload: [UInt8]) { log.append("publish:\(peer)"); offers.append(payload) }
        func withdrawOffer(keepBluetooth: Bool) { log.append(keepBluetooth ? "withdraw:keep" : "withdraw") }
        func readOffer(peer: Int) { log.append("read:\(peer)") }
        func sendAck(peer: Int) { log.append("ack:\(peer)") }
        func sendDecline(peer: Int) { log.append("decline:\(peer)") }
        func abortTransfer(peer: Int) { log.append("abort:\(peer)") }
        func save(_ payload: SongTapPayload) { log.append("save:\(payload.songKey)"); saved.append(payload) }
        func cancelSave() { log.append("cancelSave") }
        func undoSave(videoId: String) { log.append("undo:\(videoId)") }
        func haptic(_ cue: SongTapHapticCue) { log.append("haptic:\(cue.code)") }
        func schedule(_ tag: SongTapTimeoutTag, afterMs: Int64) { log.append("schedule:\(tag.code):\(afterMs)") }
        func scheduleDismiss(afterMs: Int64) { log.append("dismissIn:\(afterMs)") }
        func cancelDismiss() { log.append("cancelDismiss") }
        func scheduleInvalidNoticeClear(afterMs: Int64) { log.append("clearNoticeIn:\(afterMs)") }
        func cancelTimers() { log.append("cancelTimers") }
        func markFirstBeamAccepted() { firstBeamAccepted = true }
        func uiChanged(_ ui: SongTapUiState) { uis.append(ui) }
        func reducedMotion() -> Bool { false }
        func scheduleBeamEnd(afterMs: Int64?) { log.append("beamEnd:\(afterMs.map(String.init) ?? "cancel")") }
        func resync() { log.append("resync") }
    }

    @MainActor
    static func engine(_ port: FakePort, allowed: Bool = true) -> SongTapEngine {
        let engine = SongTapEngine()
        engine.port = port
        engine.setAllowed(allowed)
        return engine
    }

    static func offerPayload(at ms: Int64) -> SongTapPayload {
        SongTapPayloads.make(nowMs: ms, ytVideoId: "dQw4w9WgXcQ", spotifyId: nil, isrc: nil, title: "Never Gonna Give You Up",
                             artist: "Rick Astley", durationMs: 213_000, artUrl: "https://i.ytimg.com/vi/x/y.jpg")!
    }

    static func link(for p: SongTapPayload) -> String { SongTapLink.encode(SongTapPayloads.encode(p)!) }

    @MainActor @Test func nothingStartsUnlessSongTapIsAllowed() {
        let port = FakePort()
        let engine = Self.engine(port, allowed: false)
        engine.arm(.receive, askFirst: true)
        #expect(engine.session.phase == .idle)
        #expect(!port.log.contains("start:receive"))
    }

    @MainActor @Test func aFirstBeamAsksThenSavesAndOffersUndoForSixSeconds() throws {
        let port = FakePort()
        let engine = Self.engine(port)
        engine.arm(.receive, askFirst: true)
        engine.scanned(Self.link(for: Self.offerPayload(at: port.now)))
        #expect(engine.session.phase == .offered)
        #expect(engine.ui.card?.title == "Never Gonna Give You Up")
        #expect(port.saved.isEmpty, "nothing is saved before the listener says yes")
        engine.accept()
        #expect(port.firstBeamAccepted)
        #expect(port.saved.count == 1)
        #expect(engine.session.phase == .transferring)
        engine.saveFinished(.saved(SongTapCard(videoId: "dQw4w9WgXcQ", songId: "id", title: "t", artist: "a", artUrl: nil)), for: port.saved[0])
        #expect(engine.session.phase == .saved)
        // The card came with a beam (a code plays the receiver beam too): the beam's own end puts it away, 6 s of Undo inside it.
        #expect(engine.ui.beamRole == .receive)
        #expect(port.log.contains { $0.hasPrefix("beamEnd:") })
        #expect(!port.log.contains("dismissIn:6000"))
        engine.undo()
        #expect(port.log.contains("undo:dQw4w9WgXcQ"))
        #expect(engine.session.phase == .armed)
        #expect(engine.ui.card == nil)
    }

    @MainActor @Test func laterBeamsSaveAtOnceAndAnAlreadyHadBeamHasNothingToUndo() {
        let port = FakePort()
        let engine = Self.engine(port)
        engine.arm(.receive, askFirst: false)
        engine.scanned(Self.link(for: Self.offerPayload(at: port.now)))
        #expect(port.saved.count == 1)
        engine.saveFinished(.alreadyHad(SongTapCard(videoId: "dQw4w9WgXcQ", songId: "id", title: "t", artist: "a", artUrl: nil)), for: port.saved[0])
        #expect(engine.session.alreadyHad)
        engine.undo()
        #expect(!port.log.contains { $0.hasPrefix("undo:") })
    }

    @MainActor @Test func theSameCodeSeenAgainWithinTenSecondsIsTheSameBeam() {
        let port = FakePort()
        let engine = Self.engine(port)
        engine.arm(.receive, askFirst: false)
        let link = Self.link(for: Self.offerPayload(at: port.now))
        engine.scanned(link)
        let before = port.log.count
        engine.scanned(link)
        port.now += 9_000
        engine.scanned(link)
        #expect(port.log.count == before)
    }

    @MainActor @Test func aStrangersCodeAndAnOldCodeAreANoticeThatGoesByItself() {
        let port = FakePort()
        let engine = Self.engine(port)
        engine.arm(.receive, askFirst: false)
        engine.scanned("https://example.com/not-a-song")
        #expect(engine.ui.notice == .invalidCode)
        #expect(port.log.contains("clearNoticeIn:2500"))
        engine.clearInvalidCodeNotice()
        #expect(engine.ui.notice == nil)
        engine.scanned(Self.link(for: Self.offerPayload(at: port.now - SongTapSigning.qrWindowMs - 1)))
        #expect(engine.ui.notice == .invalidCode, "a code older than five minutes is not accepted")
        #expect(port.saved.isEmpty)
    }

    @MainActor @Test func aSongThatCouldNotBeFoundIsAResultWithAnExplanationAndNothingSaved() {
        let port = FakePort()
        let engine = Self.engine(port)
        engine.arm(.receive, askFirst: false)
        engine.scanned(Self.link(for: Self.offerPayload(at: port.now)))
        engine.saveFinished(.notFound, for: port.saved[0])
        #expect(engine.session.phase == .failed)
        #expect(engine.ui.notice == .notFound)
        #expect(port.log.contains("dismissIn:4000"))
        engine.dismissTimerFired()
        #expect(engine.session.phase == .armed)
        #expect(engine.ui.notice == nil)
    }

    @MainActor @Test func aSaveThatFinishesAfterACancelIsTakenBack() {
        let port = FakePort()
        let engine = Self.engine(port)
        engine.arm(.receive, askFirst: false)
        engine.scanned(Self.link(for: Self.offerPayload(at: port.now)))
        engine.cancel()
        engine.saveFinished(.saved(SongTapCard(videoId: "dQw4w9WgXcQ", songId: "id", title: "t", artist: "a", artUrl: nil)), for: port.saved[0])
        #expect(port.log.filter { $0 == "undo:dQw4w9WgXcQ" }.count >= 1)
        #expect(engine.session.phase == .cancelled)
    }

    @MainActor @Test func aCodeScannedWhileACardWaitsForAddDoesNotReplaceTheCardOrWhatUndoRemoves() {
        let port = FakePort()
        let engine = Self.engine(port)
        engine.arm(.receive, askFirst: true)
        engine.scanned(Self.link(for: Self.offerPayload(at: port.now)))
        #expect(engine.session.phase == .offered)
        let other = SongTapPayloads.make(nowMs: port.now, ytVideoId: "aaaaaaaaaaa", spotifyId: nil, isrc: nil, title: "Another song",
                                         artist: "Someone", durationMs: 200_000, artUrl: nil)!
        engine.scanned(Self.link(for: other))
        #expect(engine.ui.card?.title == "Never Gonna Give You Up", "the card still shows the song that waits for Add")
        engine.accept()
        #expect(port.saved.count == 1 && port.saved[0].songKey == "dQw4w9WgXcQ", "Add saves the song the card showed")
        engine.saveFinished(.saved(SongTapCard(videoId: "dQw4w9WgXcQ", songId: "id", title: "t", artist: "a", artUrl: nil)), for: port.saved[0])
        engine.undo()
        #expect(port.log.filter { $0.hasPrefix("undo:") } == ["undo:dQw4w9WgXcQ"])
    }

    @MainActor @Test func overBluetoothTheBeamStartsWithTheSaveAndTheSenderIsToldWhenItIsDone() {
        let port = FakePort()
        let engine = Self.engine(port)
        engine.arm(.receive, askFirst: false)
        engine.handle(.peerFound(1))
        engine.handle(.peerNear(1))
        engine.handle(.tap(peer: 1))
        engine.handle(.offer(peer: 1, payload: SongTapPayloads.encode(Self.offerPayload(at: port.now))!, senderKey: 7, name: "Hoa's Pixel"))
        #expect(engine.session.phase == .transferring)
        #expect(engine.ui.peerName == "Hoa's Pixel")
        #expect(engine.ui.beamRole == .receive, "the beam starts with the save, nothing waits for the sender")
        #expect(!port.log.contains("ack:1"), "not before the save is done")
        engine.saveFinished(.saved(SongTapCard(videoId: "dQw4w9WgXcQ", songId: "id", title: "t", artist: "a", artUrl: nil)), for: port.saved[0])
        #expect(port.log.contains("ack:1"))
        #expect(!port.log.contains { $0.hasPrefix("dismissIn:") }, "the beam owns the end of the card")
    }

    @MainActor @Test func theSenderShowsACodeAndTakesItDownWhenDone() throws {
        let port = FakePort()
        let engine = Self.engine(port)
        engine.arm(.send, askFirst: true)
        engine.showCode(Self.offerPayload(at: port.now))
        #expect(engine.session.phase == .offered)
        let code = try #require(engine.ui.code)
        #expect(code.hasPrefix(SongTapLink.prefix))
        #expect(SongTapLink.decode(code) == port.offers.last)
        engine.refreshCode(Self.offerPayload(at: port.now + 240_000))
        #expect(engine.ui.code != code, "a fresh code is made while one is up")
        engine.hideCode()
        #expect(engine.ui.code == nil)
        #expect(engine.session.phase == .armed)
    }

    @MainActor @Test func aSenderWithNothingToSendGetsANoticeAndNoCode() {
        let port = FakePort()
        let engine = Self.engine(port)
        engine.arm(.send, askFirst: true)
        engine.showCode(nil)
        #expect(engine.ui.notice == .nothingToSend)
        #expect(engine.ui.code == nil)
        engine.refreshCode(Self.offerPayload(at: port.now))
        #expect(engine.ui.code == nil, "a refresh does nothing when no code is up")
    }

    @MainActor @Test func switchingRolePutsAwayWhatWasOnTheTable() {
        let port = FakePort()
        let engine = Self.engine(port)
        engine.arm(.send, askFirst: true)
        engine.showCode(Self.offerPayload(at: port.now))
        engine.switchRole(.receive)
        #expect(engine.session.role == .receive)
        #expect(engine.session.phase == .armed)
        #expect(engine.ui.code == nil)
    }

    @MainActor @Test func turningSongTapOffStopsEverything() {
        let port = FakePort()
        let engine = Self.engine(port)
        engine.arm(.receive, askFirst: true)
        engine.setAllowed(false)
        #expect(engine.session.phase == .idle)
        #expect(port.log.contains("stop") && port.log.contains("cancelTimers"))
    }

    @MainActor @Test func everyNoticeHasWordsAndEveryFailureReasonHasANotice() {
        for reason in SongTapFailReason.allCases { _ = SongTapNotice.of(reason) }
        #expect(SongTapNotice.allCases.count == 12)
    }
}
