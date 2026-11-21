import Foundation
import PixlModel
import Testing
@testable import PixlLibrary

/// The ring code's flow on the receiver, with a fake scanner (results are handed in), a fake lookup and the real engine over its fake
/// port (the Android `RingCodeFlowTest`, receiver half) and what a lookup turns into (`RingCodeSongsTest`). Nothing here needs a camera.
private enum RingTestIds {
    static let video = "dQw4w9WgXcQ"
    static let t0: Int64 = 1_763_600_000_000
}

@Suite("Ring code receiver")
@MainActor
struct RingScanSessionTests {
    private static let video = RingTestIds.video

    /// A lookup the test controls: which video ids resolve to which song, how long it takes, and how many lookups were made.
    final class FakeLookup: RingCodeLookup, @unchecked Sendable {
        private let lock = NSLock()
        var known: [String: (String, String)] = [RingTestIds.video: ("Never Gonna Give You Up", "Rick Astley")]
        var offline = false
        var hangs = false
        private var made: [String] = []
        var lookups: [String] { lock.withLock { made } }

        func resolve(videoId: String, nowMs: Int64) async -> SongTapPayload? {
            lock.withLock { made.append(videoId) }
            if hangs { try? await Task.sleep(for: .seconds(30)) }
            if offline || Task.isCancelled { return nil }
            guard let (title, artist) = known[videoId] else { return nil }
            return SongTapPayloads.make(nowMs: nowMs, ytVideoId: videoId, spotifyId: nil, isrc: nil, title: title, artist: artist,
                                        durationMs: 213_000, artUrl: "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg")
        }
    }

    final class TestClock { var now = RingTestIds.t0 }

    @MainActor private struct Rig {
        let clock = TestClock()
        let lookup = FakeLookup()
        let session: RingScanSession
        let port = SongTapFlowTests.FakePort()
        let engine: SongTapEngine

        init(timeoutMs: Int64 = RingScanSession.resolveTimeoutMs) {
            let clock = clock
            session = RingScanSession(lookup: lookup, clock: { clock.now }, timeoutMs: timeoutMs)
            port.now = clock.now
            engine = SongTapFlowTests.engine(port)
        }
    }

    private func decoded(_ p: RingCodePayload) -> RingScanResult { .decoded(payload: p, corrected: 1, erasures: 0) }

    private func code(_ rig: Rig, random: Int = 17, ageMinutes: Int = 0) -> RingCodePayload {
        let bucket = (RingCodePayloads.bucketOf(nowMs: rig.clock.now) - ageMinutes + 64) % 64
        return RingCodePayload(videoId: Self.video, minuteBucket: bucket, random: random)
    }

    /// The camera hands in `times` equal results 150 ms apart (three of them are what a steady camera gives for a code).
    private func scan(_ rig: Rig, _ result: RingScanResult, times: Int = 3) {
        for _ in 0..<times {
            rig.clock.now += 150
            rig.session.offer(result)
        }
    }

    /// Lets the lookup's task finish (it runs on this actor, so awaiting gives it its turns).
    private func settle(_ until: () -> Bool) async {
        for _ in 0..<400 {
            if until() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func aSteadyFreshCodeIsLookedUpAndHandedOverAsASong() async {
        let rig = Rig()
        var delivered: [SongTapPayload] = []
        rig.session.onSong = { delivered.append($0) }
        rig.session.start(cameraAvailable: true)
        #expect(rig.session.view.stage == .scanning)
        scan(rig, decoded(code(rig)))
        #expect(rig.session.view.stage == .resolving)
        await settle { rig.session.view.stage != .resolving }
        #expect(rig.session.view.stage == .idle)
        #expect(delivered.count == 1)
        #expect(delivered.first?.title == "Never Gonna Give You Up")
        #expect(delivered.first?.songKey == Self.video)
        #expect(rig.lookup.lookups == [Self.video])
    }

    @Test func theSongGoesThroughTheSameConsentSaveAndUndoAsAnyOtherBeam() async {
        let rig = Rig()
        rig.engine.arm(.receive, askFirst: true)
        rig.session.onSong = { rig.engine.ringOffer($0) }
        rig.session.start(cameraAvailable: true)
        scan(rig, decoded(code(rig)))
        await settle { rig.engine.session.phase == .offered }
        #expect(rig.engine.session.phase == .offered)
        #expect(rig.engine.ui.card?.title == "Never Gonna Give You Up")
        #expect(rig.port.saved.isEmpty, "nothing is saved before the listener says yes")
        rig.engine.accept()
        #expect(rig.port.saved.count == 1)
        rig.engine.saveFinished(.saved(SongTapCard(videoId: Self.video, songId: "id", title: "t", artist: "a", artUrl: nil)), for: rig.port.saved[0])
        #expect(rig.engine.session.phase == .saved)
        rig.engine.undo()
        #expect(rig.port.log.contains("undo:\(Self.video)"))
    }

    @Test func aRingSongSavesAtOnceWhenFirstBeamsNoLongerAsk() async {
        let rig = Rig()
        rig.engine.arm(.receive, askFirst: false)
        rig.session.onSong = { rig.engine.ringOffer($0) }
        rig.session.start(cameraAvailable: true)
        scan(rig, decoded(code(rig)))
        await settle { !rig.port.saved.isEmpty }
        #expect(rig.port.saved.count == 1)
        #expect(rig.port.saved.first?.songKey == Self.video)
    }

    @Test func aSendingPhoneIgnoresASongFromTheRingCode() {
        let rig = Rig()
        rig.engine.arm(.send, askFirst: false)
        rig.engine.ringOffer(SongTapFlowTests.offerPayload(at: rig.port.now))
        #expect(rig.engine.ui.card == nil)
        #expect(rig.port.saved.isEmpty)
    }

    @Test func aLookupThatFailsOffline() async {
        let rig = Rig()
        rig.lookup.offline = true
        var delivered = 0
        rig.session.onSong = { _ in delivered += 1 }
        rig.session.start(cameraAvailable: true)
        let p = code(rig)
        scan(rig, decoded(p))
        await settle { rig.session.view.stage != .resolving }
        let v = rig.session.view
        #expect(v.stage == .scanning)
        #expect(v.message == .lookupFailed)
        #expect(v.qrOffered)
        #expect(delivered == 0)
        // The same code is left alone for three seconds, then may be tried again, and now the internet is back.
        rig.lookup.offline = false
        scan(rig, decoded(p))
        #expect(rig.session.view.stage == .scanning)
        rig.clock.now += 3_000
        scan(rig, decoded(p))
        await settle { rig.session.view.stage == .idle }
        #expect(delivered == 1)
    }

    @Test func aLookupThatNeverAnswersEndsAsAFailureAfterTheTimeout() async {
        let rig = Rig(timeoutMs: 40)
        rig.lookup.hangs = true
        var delivered = 0
        rig.session.onSong = { _ in delivered += 1 }
        rig.session.start(cameraAvailable: true)
        scan(rig, decoded(code(rig)))
        #expect(rig.session.view.stage == .resolving)
        await settle { rig.session.view.stage != .resolving }
        #expect(rig.session.view.message == .lookupFailed)
        #expect(delivered == 0)
    }

    @Test func leavingTheScreenWhileASongIsBeingLookedUpDropsTheSong() async {
        let rig = Rig()
        rig.lookup.hangs = true
        var delivered = 0
        rig.session.onSong = { _ in delivered += 1 }
        rig.session.start(cameraAvailable: true)
        scan(rig, decoded(code(rig)))
        rig.session.stop()
        #expect(rig.session.view == .idle)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(delivered == 0)
        #expect(rig.session.view == .idle)
    }

    @Test func theQrIsOfferedAfterSixSecondsOfAScanThatReadsNothingAndNeverBefore() {
        let rig = Rig()
        rig.session.start(cameraAvailable: true)
        rig.clock.now += 5_900
        rig.session.tick()
        #expect(!rig.session.view.qrOffered)
        rig.clock.now += 200
        rig.session.tick()
        #expect(rig.session.view.qrOffered)
        #expect(rig.session.view.stage == .scanning)
    }

    @Test func noCameraACameraThatFailsAndASlowScannerAllOfferTheQr() {
        let rig = Rig()
        rig.session.start(cameraAvailable: false)
        #expect(rig.session.view.stage == .unavailable)
        #expect(rig.session.view.qrOffered)
        rig.session.start(cameraAvailable: true)
        #expect(!rig.session.view.qrOffered)
        rig.session.scannerTooSlow()
        #expect(rig.session.view.qrOffered)
        rig.session.start(cameraAvailable: true)
        rig.session.cameraFailed()
        #expect(rig.session.view.stage == .unavailable)
        #expect(rig.session.view.qrOffered)
    }

    @Test func anOldTagIsRefusedWithAMessageAndTheQrAndNothingIsLookedUp() {
        let rig = Rig()
        rig.session.start(cameraAvailable: true)
        scan(rig, decoded(code(rig, ageMinutes: 5)))
        #expect(rig.session.view.message == .expired)
        #expect(rig.session.view.qrOffered)
        #expect(rig.lookup.lookups.isEmpty)
    }

    @Test func theSameCodeTakenTwiceIsARefusedReplay() async {
        let rig = Rig()
        rig.session.onSong = { _ in }
        rig.session.start(cameraAvailable: true)
        let p = code(rig)
        scan(rig, decoded(p))
        await settle { rig.session.view.stage == .idle }
        rig.session.start(cameraAvailable: true)
        scan(rig, decoded(p))
        #expect(rig.session.view.message == .replay)
        #expect(!rig.session.view.qrOffered)
        #expect(rig.lookup.lookups.count == 1)
    }

    // MARK: What a lookup becomes (the Android RingCodeSongsTest)

    private func row(title: String = "Never Gonna Give You Up", artists: [RadioArtistRef] = [RadioArtistRef(name: "Rick Astley")],
                     thumb: String? = "https://lh3.googleusercontent.com/abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz=w544-h544-l90-rj",
                     durationSec: Int = 213) -> RadioRow {
        RadioRow(videoId: "dQw4w9WgXcQ", title: title, artists: artists, durationSec: durationSec, thumbnailUrl: thumb)
    }

    @Test func aRowBecomesAPayloadWithTheVideoIdAndTheTextTheCardShows() throws {
        let p = try #require(RingCodeSongs.payload(from: row(), nowMs: 5_000))
        #expect(p.ytVideoId == "dQw4w9WgXcQ")
        #expect(p.spotifyId == nil)
        #expect(p.title == "Never Gonna Give You Up")
        #expect(p.artist == "Rick Astley")
        #expect(p.durationMs == 213_000)
        #expect(p.ts == 5_000)
        #expect(p.songKey == "dQw4w9WgXcQ")
    }

    @Test func theCoverIsKeptOnAnAllowedHostEvenWhenLongerThanABeamWouldCarry() throws {
        let art = try #require(RingCodeSongs.payload(from: row(), nowMs: 0)?.artUrl)
        #expect(art.hasPrefix("https://lh3.googleusercontent.com/"))
        #expect(art.utf8.count > 110)
    }

    @Test func aCoverOnAnyOtherHostOrNotHttpsBecomesTheVideosOwnThumbnail() throws {
        let bads: [String?] = ["https://evil.example.com/a.jpg", "http://i.ytimg.com/vi/x/a.jpg", "https://i.ytimg.com", "javascript:alert(1)",
                               "https://i.ytimg.com/a b.jpg", nil]
        for bad in bads {
            let art = try #require(RingCodeSongs.payload(from: row(thumb: bad), nowMs: 0)?.artUrl)
            #expect(art == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg", "\(bad ?? "nil")")
        }
    }

    @Test func textIsCleanedTheWayABeamsIs() throws {
        let p = try #require(RingCodeSongs.payload(from: row(title: "Song\u{202E}\u{07} name\u{200B}"), nowMs: 0))
        #expect(!p.title.contains("\u{202E}"))
        #expect(!p.title.contains("\u{07}"))
        #expect(!p.title.contains("\u{200B}"))
    }

    @Test func noTitleIsNoSongAndNoArtistIsAnUnknownArtist() throws {
        #expect(RingCodeSongs.payload(from: row(title: "  "), nowMs: 0) == nil)
        #expect(try #require(RingCodeSongs.payload(from: row(artists: []), nowMs: 0)).artist == "Unknown artist")
    }

    @Test func aVeryLongSongIsCappedAtADay() throws {
        let p = try #require(RingCodeSongs.payload(from: row(durationSec: 10_000_000), nowMs: 0))
        #expect(p.durationMs == SongTapPayloads.maxDurationMs)
    }
}
