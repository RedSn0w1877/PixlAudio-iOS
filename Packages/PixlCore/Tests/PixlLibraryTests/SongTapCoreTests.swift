import Foundation
import Testing
@testable import PixlLibrary

/// Hand-written tests of Song Tap's pure core (the Android `:songtap` module's PayloadTest, SessionTest, DetectorTest and
/// MiscTest in Swift Testing). The golden files cover the same functions with Android's numbers; these state the rules.
@Suite("Song Tap core")
struct SongTapCoreTests {
    // MARK: Helpers

    /// A seeded stream (SplitMix64) for the fuzz tests.
    struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ bound: Int) -> Int { Int((next() >> 1) % UInt64(bound)) }
    }

    static let base = SongTapPayload(
        v: 1, ts: 1_763_600_000_000, ytVideoId: "dQw4w9WgXcQ", spotifyId: "4uLU6hMCjMI75M1A2tKUQC", isrc: "GBARL9300135",
        title: "Never Gonna Give You Up", artist: "Rick Astley", durationMs: 213_000,
        artUrl: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")

    static func text(_ bytes: [UInt8]) -> String { SongTapText.fromCodePoints(SongTapText.decodeUtf8(bytes)!) }

    static func bytes(_ text: String) -> [UInt8] { SongTapText.encodeUtf8(SongTapText.toCodePoints(text)) }

    static func reject(_ bytes: [UInt8]) -> SongTapPayloadReject? {
        if case .rejected(let reason) = SongTapPayloads.decode(bytes) { return reason }
        return nil
    }

    static func scalars(_ s: String) -> [UInt32] { s.unicodeScalars.map(\.value) }

    // MARK: Payload

    @Test func canonicalFormIsExactlyTheDocumentedJson() throws {
        let bytes = try #require(SongTapPayloads.encode(Self.base))
        #expect(Self.text(bytes) == "{\"v\":1,\"ts\":1763600000000,\"yt\":\"dQw4w9WgXcQ\",\"sp\":\"4uLU6hMCjMI75M1A2tKUQC\",\"isrc\":\"GBARL9300135\"," +
                "\"t\":\"Never Gonna Give You Up\",\"a\":\"Rick Astley\",\"d\":213000,\"art\":\"https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg\"}")
        #expect(bytes.count <= SongTapPayloads.maxBytes)
    }

    @Test func aPayloadRoundTrips() throws {
        var variants = [Self.base]
        var a = Self.base; a.spotifyId = nil; variants.append(a)
        var b = Self.base; b.isrc = nil; b.artUrl = nil; variants.append(b)
        var c = Self.base; c.title = "Say \"hi\" \\ bye"; variants.append(c)
        var d = Self.base; d.title = "\u{6771}\u{4EAC} \u{1F3B5}"; d.artist = "\u{5E73}\u{91CE}"; variants.append(d)
        var e = Self.base; e.ts = 0; e.durationMs = 0; variants.append(e)
        var f = Self.base; f.durationMs = SongTapPayloads.maxDurationMs; variants.append(f)
        var g = Self.base; g.ytVideoId = nil; variants.append(g)
        for p in variants {
            let encoded = try #require(SongTapPayloads.encode(p))
            let decoded = SongTapPayloads.decode(encoded)
            guard case .ok(let back) = decoded else { Issue.record("\(p.title) did not decode: \(decoded)"); continue }
            #expect(SongTapPayloads.encode(back) == encoded)
            #expect(Self.scalars(back.title) == Self.scalars(p.title))
            #expect(back.ytVideoId == p.ytVideoId && back.spotifyId == p.spotifyId && back.durationMs == p.durationMs)
        }
    }

    @Test func theSizeCapIsHard() {
        var big = Self.base
        big.title = String(repeating: "\u{6771}", count: 33)
        big.artist = String(repeating: "\u{6771}", count: 26)
        big.artUrl = "https://i.ytimg.com/" + String(repeating: "p", count: 90)
        #expect(SongTapPayloads.encode(big) == nil, "over 400 bytes is refused by encode")
        #expect(Self.reject([UInt8](repeating: 0x61, count: 401)) == .tooLarge)
        #expect(Self.reject([UInt8](repeating: 0x61, count: 400)) == .syntax)
    }

    @Test func makeDropsTheOptionalPartsUntilItFits() throws {
        let made = try #require(SongTapPayloads.make(
            nowMs: 1, ytVideoId: "dQw4w9WgXcQ", spotifyId: "4uLU6hMCjMI75M1A2tKUQC", isrc: "GBARL9300135",
            title: String(repeating: "\u{6771}", count: 60), artist: String(repeating: "\u{6771}", count: 60), durationMs: 1000,
            artUrl: "https://i.ytimg.com/" + String(repeating: "p", count: 90)))
        #expect(made.artUrl == nil)
        #expect(try #require(SongTapPayloads.encode(made)).count <= SongTapPayloads.maxBytes)
        #expect(SongTapText.utf8Length(SongTapText.toCodePoints(made.title)) <= SongTapPayloads.maxTitleBytes)
    }

    @Test func makeCleansTextAndIgnoresBadOptionalIds() throws {
        let made = try #require(SongTapPayloads.make(nowMs: 5, ytVideoId: "dQw4w9WgXcQ", spotifyId: "bad", isrc: "bad",
                                                     title: "  T\u{202E}e\u{200B}s\tt  ", artist: "  ", durationMs: -9,
                                                     artUrl: "http://i.scdn.co/x"))
        #expect(made.title == "Tes t")
        #expect(made.artist == SongTapPayloads.unknownArtist)
        #expect(made.spotifyId == nil && made.isrc == nil && made.artUrl == nil)
        #expect(made.durationMs == 0)
        #expect(SongTapPayloads.make(nowMs: 5, ytVideoId: "short", spotifyId: nil, isrc: nil, title: "t", artist: "a", durationMs: 0, artUrl: nil) == nil)
        #expect(SongTapPayloads.make(nowMs: 5, ytVideoId: "dQw4w9WgXcQ", spotifyId: nil, isrc: nil, title: "\u{7}\u{202E}", artist: "a",
                                     durationMs: 0, artUrl: nil) == nil)
    }

    @Test func artLinksAreHttpsOnTheFourHostsOnly() {
        for ok in ["https://i.scdn.co/image/x", "https://i.ytimg.com/vi/x/y.jpg", "https://lh3.googleusercontent.com/a=w1", "https://yt3.ggpht.com/a"] {
            #expect(SongTapPayloads.isAllowedArtUrl(ok), "\(ok)")
        }
        for bad in ["http://i.scdn.co/x", "https://evil.example/x", "https://i.scdn.co.evil.example/x", "https://i.scdn.co@evil.example/x",
                    "https://i.scdn.co:443/x", "https://I.SCDN.CO/x", "https://i.scdn.co", "https://i.scdn.co/", "https://i.scdn.co/a b",
                    "https://i.scdn.co/\"x", "https://i.scdn.co/\\x", "https://i.scdn.co/<x>", "https://i.scdn.co/\u{E9}",
                    "javascript:alert(1)", ""] {
            #expect(!SongTapPayloads.isAllowedArtUrl(bad), "\(bad)")
        }
    }

    @Test func idsFollowTheirAlphabets() {
        #expect(SongTapPayloads.isVideoId("a-b_c-d_e-f"))
        #expect(!SongTapPayloads.isVideoId("a.b_c-d_e-f"))
        #expect(!SongTapPayloads.isVideoId("short"))
        #expect(SongTapPayloads.isSpotifyId("4uLU6hMCjMI75M1A2tKUQC"))
        #expect(!SongTapPayloads.isSpotifyId("4uLU6hMCjMI75M1A2tKUQ_"))
        #expect(SongTapPayloads.isIsrc("GBARL9300135"))
        #expect(!SongTapPayloads.isIsrc("gbarl9300135"))
    }

    @Test func hostileTextIsRefused() throws {
        let good = Self.text(try #require(SongTapPayloads.encode(Self.base)))
        #expect(Self.reject(Self.bytes(good.replacingOccurrences(of: "Never Gonna Give You Up", with: "a\u{202E}b"))) == .badTitle)
        #expect(Self.reject(Self.bytes(good.replacingOccurrences(of: "Never Gonna Give You Up", with: "a\u{7}b"))) == .badTitle)
        #expect(Self.reject(Self.bytes(good.replacingOccurrences(of: "Never Gonna Give You Up", with: " lead"))) == .badTitle)
        #expect(Self.reject(Self.bytes(good.replacingOccurrences(of: "Rick Astley", with: ""))) == .badArtist)
        #expect(Self.reject(Self.bytes(good.replacingOccurrences(of: "i.ytimg.com", with: "evil.example"))) == .badArtUrl)
    }

    @Test func anythingThatIsNotExactlyTheCanonicalFormIsRefused() throws {
        var bare = Self.base; bare.spotifyId = nil; bare.isrc = nil; bare.artUrl = nil
        let good = Self.text(try #require(SongTapPayloads.encode(bare)))
        guard case .ok = SongTapPayloads.decode(Self.bytes(good)) else { Issue.record("the canonical form must decode"); return }
        let variants = [
            good.replacingOccurrences(of: "{\"v\":1,", with: "{ \"v\":1,"),
            good + "\n",
            good.replacingOccurrences(of: "\"ts\":", with: "\"ts\":0"),
            good.replacingOccurrences(of: "\"v\":1,\"ts\"", with: "\"ts\""),
            good.replacingOccurrences(of: "}", with: ",\"x\":1}"),
            good.replacingOccurrences(of: "\"t\":\"Never Gonna Give You Up\"", with: "\"t\":\"N\\u0065ver Gonna Give You Up\""),
            good.replacingOccurrences(of: "\"d\":213000", with: "\"d\":213000.0"),
            good.replacingOccurrences(of: "\"d\":213000", with: "\"d\":-1"),
            "", "{}",
        ]
        for v in variants {
            #expect(Self.reject(Self.bytes(v)) != nil, "\(v)")
        }
    }

    @Test func invalidUtf8IsRefused() throws {
        let good = try #require(SongTapPayloads.encode(Self.base))
        let at = try #require(good.firstIndex(of: UInt8(ascii: "N")))
        let bads: [[UInt8]] = [[0xC0, 0x80], [0x80], [0xE6, 0x9D], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80]]
        for bad in bads {
            let bytes = Array(good[0..<at]) + bad + Array(good[(at + 1)...])
            #expect(Self.reject(bytes) == .notUtf8, "\(bad)")
        }
    }

    @Test func randomBytesAndMutationsNeverCrashAndNeverGetThroughUnlessExact() throws {
        var rng = SplitMix64(state: 7)
        let source = try #require(SongTapPayloads.encode(Self.base))
        var accepted = 0
        for i in 0..<5000 {
            var bytes: [UInt8]
            switch i % 3 {
            case 0: bytes = (0..<rng.int(450)).map { _ in UInt8(rng.int(256)) }
            case 1: bytes = source; bytes[rng.int(bytes.count)] = UInt8(rng.int(256))
            default: bytes = Array(source[0..<rng.int(source.count + 1)])
            }
            if case .ok(let p) = SongTapPayloads.decode(bytes) {
                accepted += 1
                #expect(SongTapPayloads.encode(p) == bytes, "an accepted payload is exactly its canonical bytes")
            }
        }
        #expect(accepted < 2500)
    }

    @Test func textRules() {
        #expect(SongTapText.sanitize("  a \t\u{A0} b  ", maxBytes: 100) == "a b")
        #expect(SongTapText.sanitize("a\u{0}b", maxBytes: 100) == "ab")
        #expect(SongTapText.sanitize("abcdef", maxBytes: 3) == "abc")
        #expect(SongTapText.sanitize("\u{6771}\u{4EAC}", maxBytes: 5) == "\u{6771}")
        #expect(SongTapText.sanitize("a \u{6771}", maxBytes: 3) == "a")
        let s = SongTapText.sanitize("\u{1F3B5} x \u{200D} y", maxBytes: 100)
        #expect(SongTapText.sanitize(s, maxBytes: 100) == s, "idempotent")
        #expect(SongTapText.decodeUtf8([0xF0, 0x9F]) == nil)
    }

    @Test func linksRoundTripAndAreUnique() throws {
        let bytes = try #require(SongTapPayloads.encode(Self.base))
        let link = SongTapLink.encode(bytes)
        #expect(link.hasPrefix("pixlsong1:"))
        #expect(SongTapLink.decode(link) == bytes)
        #expect(SongTapLink.decode(link + "=") == nil)
        #expect(SongTapLink.decode(link.replacingOccurrences(of: "pixlsong1:", with: "pixlsong2:")) == nil)
        #expect(SongTapLink.decode(link + "A") == nil)
        #expect(SongTapLink.decode("pixlsong1:") == nil)
        for n in 1...40 {
            let b = (0..<n).map { UInt8(truncatingIfNeeded: $0 * 31 + n) }
            #expect(SongTapLink.decode(SongTapLink.encode(b)) == b, "n=\(n)")
        }
    }

    // MARK: Signing

    struct FakeVerifier: SongTapSignatureVerifier {
        let accepts: Bool
        func verify(publicKey: [UInt8], message: [UInt8], signature: [UInt8]) -> Bool { accepts }
    }

    static func pattern(_ n: Int, _ seed: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: $0 * 7 + seed) } }

    @Test func signingBytesArePayloadChallengeTimestamp() throws {
        let payload: [UInt8] = [1, 2, 3]
        let challenge = Self.pattern(16, 1)
        let out = try #require(SongTapSigning.signingBytes(payload: payload, challenge: challenge, timestampMs: 0x0102_0304_0506_0708))
        #expect(out == payload + challenge + [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(SongTapSigning.signingBytes(payload: payload, challenge: Self.pattern(15, 1), timestampMs: 0) == nil)
    }

    @Test func framesRoundTripAndRefuseTheWrongShape() throws {
        let payload = try #require(SongTapPayloads.encode(Self.base))
        let offer = SongTapSignedOffer(payload: payload, timestampMs: 42, publicKey: Self.pattern(65, 3), signature: Self.pattern(64, 5))
        let frame = try #require(SongTapSigning.encodeFrame(offer))
        #expect(SongTapSigning.decodeFrame(frame) == offer)
        #expect(SongTapSigning.decodeFrame(Array(frame.dropLast())) == nil)
        #expect(SongTapSigning.decodeFrame(frame + [0]) == nil)
        #expect(SongTapSigning.decodeFrame([2] + frame.dropFirst()) == nil)
        #expect(SongTapSigning.decodeFrame([]) == nil)
        #expect(SongTapSigning.encodeFrame(SongTapSignedOffer(payload: payload, timestampMs: 0, publicKey: Self.pattern(64, 3), signature: Self.pattern(64, 5))) == nil)
    }

    @Test func anOfferIsCheckedForPayloadFreshnessAndSignature() throws {
        let payload = try #require(SongTapPayloads.encode(Self.base))
        let now: Int64 = 1_763_600_010_000
        let offer = SongTapSignedOffer(payload: payload, timestampMs: now - 1000, publicKey: Self.pattern(65, 3), signature: Self.pattern(64, 5))
        let challenge = Self.pattern(16, 9)
        #expect(SongTapSigning.check(offer, challenge: challenge, nowMs: now, verifier: FakeVerifier(accepts: true)) == .ok)
        #expect(SongTapSigning.check(offer, challenge: challenge, nowMs: now, verifier: FakeVerifier(accepts: false)) == .badSignature)
        #expect(SongTapSigning.check(offer, challenge: challenge, nowMs: now + 40_000, verifier: FakeVerifier(accepts: true)) == .stale)
        #expect(SongTapSigning.check(offer, challenge: Self.pattern(3, 9), nowMs: now, verifier: FakeVerifier(accepts: true)) == .badFrame)
        var junk = offer; junk.payload = [1, 2, 3]
        #expect(SongTapSigning.check(junk, challenge: challenge, nowMs: now, verifier: FakeVerifier(accepts: true)) == .badPayload)
    }

    @Test func theSenderKeyIsASignedThirtyTwoBitNumber() {
        #expect(SongTapSigning.senderKey([0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFE]) == -2)
        #expect(SongTapSigning.senderKey([1, 2, 3]) == 0)
        #expect(SongTapSigning.senderKey([9, 0, 0, 1, 2]) == 0x0000_0102)
    }

    // MARK: Session

    static let v1 = "dQw4w9WgXcQ"
    static let v2 = "aaaaaaaaaaa"

    static func run(_ ask: Bool, _ events: [SongTapSessionEvent]) -> [SongTapReduction] {
        SongTapSession.run(start: .initial(askFirst: ask), events: events)
    }

    @Test func aSenderOffersAndBeamsAfterTheAcknowledgement() {
        let steps = Self.run(true, [.arm(role: .send, askFirst: true), .peerFound(1), .peerNear(1), .tapDetected(peer: 1, videoId: Self.v1),
                                    .ackReceived(nowMs: 1000, rttMs: 80), .beamFinished])
        #expect(steps[3].state.phase == .offered)
        #expect(steps[3].effects.contains(.publishOffer(peer: 1, videoId: Self.v1)))
        #expect(steps[3].effects.contains(.scheduleTimeout(.ack, afterMs: SongTapSession.ackTimeoutMs)))
        #expect(steps[4].effects == [.sendGo(peer: 1, startMs: 1150), .startBeam(role: .send, startMs: 1150)])
        #expect(steps[5].state.phase == .saved)
    }

    @Test func nothingPlayingMeansNothingToSend() {
        let steps = Self.run(true, [.arm(role: .send, askFirst: true), .peerFound(1), .peerNear(1), .tapDetected(peer: 1, videoId: "")])
        #expect(steps[3].state.phase == .failed && steps[3].state.fail == .nothingToSend)
    }

    @Test func twoSendersFailWithBothSending() {
        let steps = Self.run(true, [.arm(role: .send, askFirst: true), .peerFound(1), .peerNear(1), .peerRole(peer: 1, role: .send)])
        #expect(steps[3].state.fail == .bothSending)
        #expect(steps[3].effects.contains(.notice(.bothSending)))
    }

    @Test func aLateAcknowledgementAfterACancelChangesNothing() {
        let steps = Self.run(true, [.arm(role: .send, askFirst: true), .peerFound(1), .peerNear(1), .tapDetected(peer: 1, videoId: Self.v1),
                                    .cancel, .ackReceived(nowMs: 900, rttMs: 50)])
        #expect(steps[4].state.phase == .cancelled)
        #expect(steps[5].state == steps[4].state)
        #expect(steps[5].effects.isEmpty)
    }

    @Test func aDuplicateAcknowledgementStartsOneBeam() {
        let steps = Self.run(true, [.arm(role: .send, askFirst: true), .peerFound(1), .peerNear(1), .tapDetected(peer: 1, videoId: Self.v1),
                                    .ackReceived(nowMs: 900, rttMs: 50), .ackReceived(nowMs: 950, rttMs: 50)])
        #expect(steps[5].effects.isEmpty)
    }

    @Test func theFirstBeamAsksAndLaterBeamsSaveAtOnce() {
        let ask = Self.run(true, [.arm(role: .receive, askFirst: true), .offerReceived(peer: 0, videoId: Self.v1, senderKey: 0, nowMs: 5000)])
        #expect(ask[1].state.phase == .offered)
        #expect(ask[1].effects == [.scheduleTimeout(.consent, afterMs: SongTapSession.consentTimeoutMs)])
        let direct = Self.run(false, [.arm(role: .receive, askFirst: false), .offerReceived(peer: 0, videoId: Self.v1, senderKey: 0, nowMs: 5000)])
        #expect(direct[1].state.phase == .transferring)
        #expect(direct[1].effects.first == .saveSong(videoId: Self.v1))
        #expect(direct[1].effects.contains(.startBeam(role: .receive, startMs: 5000)))
    }

    @Test func aSaveThenUndoRemovesTheSongAndLeavesTheSessionArmed() {
        let steps = Self.run(false, [.arm(role: .receive, askFirst: false), .offerReceived(peer: 0, videoId: Self.v1, senderKey: 0, nowMs: 5000),
                                     .saveResult(.saved, nowMs: 5100), .undo(nowMs: 6000), .undo(nowMs: 6100)])
        #expect(steps[2].state.phase == .saved)
        #expect(steps[3].state.phase == .armed)
        #expect(steps[3].effects == [.undoSave(videoId: Self.v1)])
        #expect(steps[4].effects.isEmpty, "a second undo does nothing")
    }

    @Test func aSongThatWasAlreadyThereHasNothingToUndo() {
        let steps = Self.run(false, [.arm(role: .receive, askFirst: false), .offerReceived(peer: 0, videoId: Self.v1, senderKey: 0, nowMs: 5000),
                                     .saveResult(.alreadyHad, nowMs: 5100), .undo(nowMs: 5200)])
        #expect(steps[2].state.alreadyHad)
        #expect(steps[3].state == steps[2].state)
    }

    @Test func cancelWhileSavingOnlyStopsTheTransferAndNeverUndoesASong() {
        let steps = Self.run(false, [.arm(role: .receive, askFirst: false), .peerFound(1), .peerNear(1), .tapDetected(peer: 1, videoId: ""),
                                     .offerReceived(peer: 1, videoId: Self.v1, senderKey: 7, nowMs: 1000), .cancel, .saveResult(.saved, nowMs: 1100)])
        #expect(steps[5].effects == [.abortTransfer(peer: 1)])
        #expect(steps[6].state.phase == .cancelled, "a result after a cancel changes nothing")
        #expect(steps[6].effects.isEmpty)
    }

    @Test func aTeardownNeverEmitsAnUndoOfASongTheListenerMayHave() {
        let disarm = Self.run(false, [.arm(role: .receive, askFirst: false), .peerFound(1), .peerNear(1), .tapDetected(peer: 1, videoId: ""),
                                      .offerReceived(peer: 1, videoId: Self.v1, senderKey: 7, nowMs: 1000), .disarm])
        #expect(disarm.last?.effects == [.abortTransfer(peer: 1), .stopTransport])
        let timeout = Self.run(false, [.arm(role: .receive, askFirst: false), .offerReceived(peer: 0, videoId: Self.v1, senderKey: 0, nowMs: 1000),
                                       .timeout(.save)])
        #expect(!timeout.last!.effects.contains(.undoSave(videoId: Self.v1)))
    }

    @Test func aReceiverThatHoldsACheckedOfferKeepsSavingWhenThePhonesComeApart() {
        let steps = Self.run(false, [.arm(role: .receive, askFirst: false), .peerFound(1), .peerNear(1), .tapDetected(peer: 1, videoId: ""),
                                     .offerReceived(peer: 1, videoId: Self.v1, senderKey: 7, nowMs: 1000), .peerLost(1),
                                     .saveResult(.saved, nowMs: 1500)])
        #expect(steps[5].state.phase == .transferring && steps[5].state.peer == 0)
        #expect(steps[5].effects.isEmpty)
        #expect(steps[6].state.phase == .saved)
        #expect(steps[6].effects == [.haptic(.success)], "no one to answer, so nobody is acknowledged")
    }

    @Test func theFirstBeamsAddStillWorksAfterThePhonesComeApart() {
        let steps = Self.run(true, [.arm(role: .receive, askFirst: true), .peerFound(1), .peerNear(1), .tapDetected(peer: 1, videoId: ""),
                                    .offerReceived(peer: 1, videoId: Self.v1, senderKey: 7, nowMs: 1000), .peerLost(1),
                                    .accept(nowMs: 9_000), .saveResult(.saved, nowMs: 9_200)])
        #expect(steps[5].state.phase == .offered && steps[5].state.videoId == Self.v1)
        #expect(steps[5].effects.isEmpty)
        #expect(steps[6].effects == [.saveSong(videoId: Self.v1), .scheduleTimeout(.save, afterMs: SongTapSession.saveTimeoutMs),
                                     .startBeam(role: .receive, startMs: 9_000)])
        #expect(steps[7].state.phase == .saved)
    }

    @Test func aBeamStillBeingReadIsLostWhenThePhonesComeApart() {
        let steps = Self.run(false, [.arm(role: .receive, askFirst: false), .peerFound(1), .peerNear(1), .tapDetected(peer: 1, videoId: ""),
                                     .peerLost(1)])
        #expect(steps[4].state.fail == .peerLost)
        #expect(steps[4].effects == [.abortTransfer(peer: 1), .haptic(.warn)])
    }

    @Test func theSenderIsToldOnlyOnceTheSaveIsDone() {
        let steps = Self.run(false, [.arm(role: .receive, askFirst: false), .peerFound(1), .peerNear(1), .tapDetected(peer: 1, videoId: ""),
                                     .offerReceived(peer: 1, videoId: Self.v1, senderKey: 7, nowMs: 10_000),
                                     .saveResult(.notFound, nowMs: 10_100), .dismiss, .tapDetected(peer: 1, videoId: ""),
                                     .offerReceived(peer: 1, videoId: Self.v2, senderKey: 7, nowMs: 11_000)])
        #expect(steps[4].effects == [.saveSong(videoId: Self.v1), .scheduleTimeout(.save, afterMs: 20_000)])
        #expect(steps[5].effects == [.sendDecline(peer: 1), .notice(.notFound), .haptic(.warn)])
        #expect(steps[8].state.fail == .tooSoon, "a failed offer counts towards the gap")
    }

    @Test func everyFifthBeamSavedWithoutAskingMakesTheNextOneAsk() {
        var events: [SongTapSessionEvent] = [.arm(role: .receive, askFirst: false)]
        var at: Int64 = 10_000
        for v in [Self.v1, Self.v2, "bbbbbbbbbbb", "ccccccccccc", "ddddddddddd"] {
            events += [.offerReceived(peer: 0, videoId: v, senderKey: 0, nowMs: at), .saveResult(.saved, nowMs: at + 100), .dismiss]
            at += 10_000
        }
        let steps = Self.run(false, events)
        #expect(steps[3 * 4].state.askFirst == false)
        #expect(steps.last?.state.askFirst == true)
        let next = SongTapSession.reduce(steps.last!.state, .offerReceived(peer: 0, videoId: "zzzzzzzzzzz", senderKey: 0, nowMs: at))
        #expect(next.state.phase == .offered)
    }

    @Test func rateLimitsAreHonouredThroughTheSession() {
        let steps = Self.run(false, [
            .arm(role: .receive, askFirst: false),
            .offerReceived(peer: 0, videoId: Self.v1, senderKey: 3, nowMs: 10_000), .saveResult(.saved, nowMs: 10_100), .dismiss,
            .offerReceived(peer: 0, videoId: Self.v2, senderKey: 3, nowMs: 11_000), .dismiss,
            .offerReceived(peer: 0, videoId: Self.v1, senderKey: 3, nowMs: 20_000), .dismiss,
        ])
        #expect(steps[4].state.fail == .tooSoon)
        #expect(steps[6].state.fail == .duplicate)
    }

    @Test func twoUndosMuteASenderButNeverAQrCode() {
        let muted = Self.run(false, [
            .arm(role: .receive, askFirst: false),
            .offerReceived(peer: 0, videoId: Self.v1, senderKey: 9, nowMs: 10_000), .saveResult(.saved, nowMs: 10_100), .undo(nowMs: 11_000),
            .offerReceived(peer: 0, videoId: Self.v2, senderKey: 9, nowMs: 20_000), .saveResult(.saved, nowMs: 20_100), .undo(nowMs: 21_000),
            .offerReceived(peer: 0, videoId: "bbbbbbbbbbb", senderKey: 9, nowMs: 30_000),
        ])
        #expect(muted[7].state.fail == .muted)
        let qr = Self.run(false, [
            .arm(role: .receive, askFirst: false),
            .offerReceived(peer: 0, videoId: Self.v1, senderKey: 0, nowMs: 10_000), .saveResult(.saved, nowMs: 10_100), .undo(nowMs: 11_000),
            .offerReceived(peer: 0, videoId: Self.v2, senderKey: 0, nowMs: 20_000), .saveResult(.saved, nowMs: 20_100), .undo(nowMs: 21_000),
            .offerReceived(peer: 0, videoId: "bbbbbbbbbbb", senderKey: 0, nowMs: 30_000),
        ])
        #expect(qr[7].state.phase == .transferring)
    }

    @Test func aStrangersCodeIsANoticeNotAFailure() {
        let steps = Self.run(true, [.arm(role: .receive, askFirst: true), .offerRejected])
        #expect(steps[1].state.phase == .armed)
        #expect(steps[1].effects == [.noticeInvalidCode])
    }

    @Test func idleIgnoresEverything() {
        let steps = Self.run(true, [.peerFound(1), .tapDetected(peer: 1, videoId: Self.v1), .offerReceived(peer: 0, videoId: Self.v1, senderKey: 1, nowMs: 0),
                                    .accept(nowMs: 0), .undo(nowMs: 0), .dismiss, .cancel, .disarm, .timeout(.ack)])
        for step in steps {
            #expect(step.state.phase == .idle)
            #expect(step.effects.isEmpty)
        }
    }

    @Test func switchingRoleRestartsTheTransportOnlyWhileSearching() {
        let steps = Self.run(true, [.arm(role: .send, askFirst: true), .setRole(.receive), .setRole(.receive)])
        #expect(steps[1].effects == [.stopTransport, .startTransport(.receive)])
        #expect(steps[2].effects.isEmpty)
    }

    // MARK: Rate limits

    @Test func theLimitsAreThreeSecondsTenAMinuteThirtyAnHourAndSameSongSixtySeconds() {
        var l = SongTapRateLimits()
        #expect(l.admit(nowMs: 0, videoId: "a", senderKey: 1) == .allowed)
        l = l.accepted(nowMs: 0, videoId: "a")
        #expect(l.admit(nowMs: 2999, videoId: "b", senderKey: 1) == .tooSoon)
        #expect(l.admit(nowMs: 3000, videoId: "b", senderKey: 1) == .allowed)
        #expect(l.admit(nowMs: 10_000, videoId: "a", senderKey: 1) == .duplicate)
        #expect(l.admit(nowMs: 60_000, videoId: "a", senderKey: 1) == .allowed)
        var m = SongTapRateLimits()
        for i in 0..<10 { m = m.accepted(nowMs: Int64(i) * 5000, videoId: "v\(i)") }
        #expect(m.admit(nowMs: 56_000, videoId: "x", senderKey: 1) == .minuteLimit)
        #expect(m.admit(nowMs: 61_000, videoId: "x", senderKey: 1) == .allowed)
        var h = SongTapRateLimits()
        for i in 0..<30 { h = h.accepted(nowMs: Int64(i) * 100_000, videoId: "h\(i)") }
        #expect(h.admit(nowMs: 3_100_001, videoId: "x", senderKey: 1) == .hourLimit)
    }

    @Test func twoUndosMuteAKnownSenderForAnHourAndAnUnknownOneNever() {
        var l = SongTapRateLimits().undone(nowMs: 0, senderKey: 5)
        #expect(l.admit(nowMs: 100, videoId: "a", senderKey: 5) == .allowed)
        l = l.undone(nowMs: 1000, senderKey: 5)
        #expect(l.admit(nowMs: 1001, videoId: "a", senderKey: 5) == .muted)
        #expect(l.admit(nowMs: 1001, videoId: "a", senderKey: 6) == .allowed)
        #expect(l.admit(nowMs: 3_601_001, videoId: "a", senderKey: 5) == .allowed)
        var u = SongTapRateLimits()
        for t in 0..<5 { u = u.undone(nowMs: Int64(t), senderKey: 0) }
        #expect(u.admit(nowMs: 10_000, videoId: "a", senderKey: 0) == .allowed)
    }

    // MARK: Detector

    static func series(_ segments: [(count: Int, rssi: Int)], step: Int64 = 100, impulseAt: Int64 = -1,
                       start: SongTapDetectorState = .initial) -> [(t: Int64, fire: SongTapFireReason, step: SongTapDetectorStep)] {
        var state = start
        var t: Int64 = 0
        var out: [(Int64, SongTapFireReason, SongTapDetectorStep)] = []
        for segment in segments {
            for _ in 0..<segment.count {
                let impulse = impulseAt >= 0 && impulseAt <= t ? impulseAt : -1
                let s = SongTapDetector.step(state, SongTapRssiSample(tMs: t, rssi: segment.rssi), impulseMs: impulse)
                state = s.state
                out.append((t, s.fire, s))
                t += step
            }
        }
        return out
    }

    @Test func aSteadySignalNeverFires() {
        #expect(Self.series([(40, -60)]).allSatisfy { $0.fire == .none })
    }

    @Test func aJumpWithAJerkFiresAfterTheHoldTime() {
        let fires = Self.series([(20, -62), (10, -42)], impulseAt: 2_050).filter { $0.fire != .none }
        #expect(fires.count == 1)
        #expect(fires.first?.fire == .impulse)
        #expect(fires.first.map { $0.t >= 2_000 + SongTapTuning.holdMs } == true)
    }

    @Test func aJumpWithoutAJerkNeedsTheDwellTime() {
        let fires = Self.series([(20, -62), (10, -42)]).filter { $0.fire != .none }
        #expect(fires.count == 1)
        #expect(fires.first?.fire == .dwell)
        #expect(fires.first.map { $0.t >= 2_000 + SongTapTuning.dwellMs } == true)
    }

    @Test func phonesThatStayTogetherFireOnceAndNotAgainEveryCooldown() {
        #expect(Self.series([(20, -62), (80, -42)], impulseAt: 2_050).filter { $0.fire != .none }.count == 1)
        #expect(Self.series([(20, -62), (80, -42)]).filter { $0.fire != .none }.count == 1)
    }

    @Test func aSlowApproachThatStopsShortOfContactDoesNotFire() {
        let ramp = (0..<30).map { (count: 1, rssi: -90 + $0) }
        #expect(Self.series(ramp + [(40, -61)]).filter { $0.fire != .none }.isEmpty)
    }

    @Test func aJumpThatHoldsForGoodIsTakenAsTheNewLevelAfterAWhile() {
        var state = SongTapDetectorState.initial
        for i in 0..<20 { state = SongTapDetector.step(state, SongTapRssiSample(tMs: Int64(i) * 100, rssi: -90), impulseMs: -1).state }
        for i in 20..<60 { state = SongTapDetector.step(state, SongTapRssiSample(tMs: Int64(i) * 100, rssi: -70), impulseMs: -1).state }
        #expect(state.heldSinceMs < 0)
        #expect(state.baselineQ > -75 * songTapRssiScale)
    }

    @Test func anOfferThatEndedInNoSongStillCountsTowardsTheGapAndTheMinute() {
        var l = SongTapRateLimits()
        for i in 0..<10 { l = l.attempted(nowMs: Int64(i) * 5_000) }
        #expect(SongTapRateLimits().attempted(nowMs: 0).admit(nowMs: 2_999, videoId: "x", senderKey: 1) == .tooSoon)
        #expect(l.admit(nowMs: 55_000, videoId: "x", senderKey: 1) == .minuteLimit)
        #expect(SongTapRateLimits().attempted(nowMs: 0).admit(nowMs: 3_000, videoId: "a", senderKey: 1) == .allowed)
    }

    @Test func aShortSpikeDoesNotFire() {
        #expect(Self.series([(20, -62), (1, -40), (20, -62)]).allSatisfy { $0.fire == .none })
        #expect(Self.series([(20, -62), (2, -40), (20, -62)]).allSatisfy { $0.fire == .none })
    }

    @Test func theTapIsRelativeNotAFixedLevel() {
        let a = Self.series([(20, -62), (10, -42)], impulseAt: 2_050).firstIndex { $0.fire != .none }
        let b = Self.series([(20, -72), (10, -52)], impulseAt: 2_050).firstIndex { $0.fire != .none }
        #expect(a != nil && a == b, "the same jump fires at the same moment whatever the starting level")
    }

    @Test func aJumpFromOutOfReachDoesNotFire() {
        #expect(Self.series([(20, -95), (10, -78)], impulseAt: 2_000).allSatisfy { $0.fire == .none })
    }

    @Test func aFireIsFollowedByACooldownAndAGapResetsThePeer() {
        let fires = Self.series([(20, -62), (10, -42), (5, -62), (10, -42), (20, -62), (30, -42)], impulseAt: 2_050).filter { $0.fire != .none }
        #expect(!fires.isEmpty)
        for pair in zip(fires, fires.dropFirst()) {
            #expect(pair.1.t - pair.0.t >= SongTapTuning.cooldownMs, "no new fire inside the cooldown")
        }
        var state = SongTapDetectorState.initial
        for (t, rssi) in [(0, -62), (100, -62), (200, -62), (300, -42), (400, -42)] as [(Int64, Int)] {
            state = SongTapDetector.step(state, SongTapRssiSample(tMs: t, rssi: rssi), impulseMs: -1).state
        }
        let after = SongTapDetector.step(state, SongTapRssiSample(tMs: 5_000, rssi: -42), impulseMs: -1)
        #expect(after.state.baselineQ == -42 * songTapRssiScale, "after a long gap the baseline starts again at the new signal")
        #expect(after.fire == .none)
    }

    @Test func theGlowGrowsWithTheSmoothedSignalAndStopsAtHalf() {
        #expect(SongTapDetector.glowPermille(-100 * songTapRssiScale) == 0)
        #expect(SongTapDetector.glowPermille(SongTapTuning.glowMaxDbm * songTapRssiScale) == 500)
        #expect(SongTapDetector.glowPermille(0) == 500)
        let mid = SongTapDetector.glowPermille(-62 * songTapRssiScale)
        #expect(mid > 0 && mid < 500)
    }

    @Test func aSharpJerkIsDetectedOnceAndASlowTiltIsNot() {
        var state = SongTapImpulseState.initial
        var hits = 0
        let rows: [(Int, Int, Int)] = [(0, 0, 1000), (0, 0, 1000), (300, -200, 4200), (100, 0, 700), (0, 0, 1000)]
        for (i, r) in rows.enumerated() {
            let s = SongTapImpulse.step(state, SongTapAccelSample(tMs: Int64(i) * 20, xMg: r.0, yMg: r.1, zMg: r.2))
            state = s.state
            if s.impulse { hits += 1 }
        }
        #expect(hits == 1, "the debounce keeps one knock one jerk")
        var tilt = SongTapImpulseState.initial
        for (i, r) in [(0, 0, 1000), (300, 0, 950), (600, 0, 800), (900, 0, 450), (1000, 0, 0)].enumerated() {
            let s = SongTapImpulse.step(tilt, SongTapAccelSample(tMs: Int64(i) * 20, xMg: r.0, yMg: r.1, zMg: r.2))
            tilt = s.state
            #expect(!s.impulse)
        }
    }

    // MARK: Timeline, haptics, handshake

    @Test func everyFrameStaysInRange() {
        for role in SongTapRole.allCases {
            for reduced in [false, true] {
                var t: Int64 = -200
                while t <= SongTapTimeline.totalMs(role: role, reducedMotion: reduced) + 200 {
                    let f = SongTapTimeline.frame(role: role, tMs: t, reducedMotion: reduced)
                    #expect(f.glow >= 0 && f.glow <= 500)
                    #expect(f.alpha >= 0 && f.alpha <= 1000)
                    #expect(f.scale >= 300 && f.scale <= 1100)
                    #expect(f.translateY >= SongTapTimeline.offTop && f.translateY <= 0)
                    #expect(f.shadow >= 0 && f.shadow <= 1000)
                    #expect(f.cardAlpha >= 0 && f.cardAlpha <= 1000 && f.textAlpha >= 0 && f.textAlpha <= 1000 && f.undoAlpha >= 0 && f.undoAlpha <= 1000)
                    if reduced { #expect(f.translateY == 0 && f.scale == 1000, "reduced motion has no flight") }
                    t += 25
                }
            }
        }
    }

    @Test func theSenderLiftsFliesOffTheTopAndComesBack() {
        let start = SongTapTimeline.frame(role: .send, tMs: 0, reducedMotion: false)
        #expect(start.scale == 1000 && start.translateY == 0 && start.alpha == 1000)
        let lifted = SongTapTimeline.frame(role: .send, tMs: SongTapTimeline.liftMs, reducedMotion: false)
        #expect(lifted.scale <= 925 && lifted.shadow >= 900)
        let gone = SongTapTimeline.frame(role: .send, tMs: SongTapTimeline.liftMs + SongTapTimeline.flyMs, reducedMotion: false)
        #expect(gone.alpha == 0 && gone.translateY == SongTapTimeline.offTop && gone.scale == 400)
        let back = SongTapTimeline.frame(role: .send, tMs: SongTapTimeline.sendTotalMs, reducedMotion: false)
        #expect(back.scale == 1000 && back.translateY == 0 && back.alpha == 1000)
    }

    @Test func theReceiverEntersFromTheTopSettlesRestsAndSlidesAway() {
        let enter = SongTapTimeline.frame(role: .receive, tMs: 0, reducedMotion: false)
        #expect(enter.scale == 400 && enter.translateY == SongTapTimeline.offTop && enter.alpha == 0)
        let rest = SongTapTimeline.frame(role: .receive, tMs: 3000, reducedMotion: false)
        #expect(rest.scale == 1000 && rest.translateY == 0 && rest.alpha == 1000 && rest.undoAlpha == 1000)
        let end = SongTapTimeline.frame(role: .receive, tMs: SongTapTimeline.receiveTotalMs, reducedMotion: false)
        #expect(end.alpha == 0)
        #expect(SongTapTimeline.cardRestMs == 6000, "the card rests six seconds with Undo")
    }

    @Test func hapticsKeepAPulseEvenWithReducedMotion() {
        #expect(SongTapHaptics.cues(role: .send, reducedMotion: true) == [SongTapTimedCue(tMs: 0, cue: .success)])
        #expect(SongTapHaptics.cues(role: .receive, reducedMotion: false).last?.cue == .success)
        #expect(SongTapHaptics.cues(role: .send, reducedMotion: false).count == 2)
    }

    @Test func theHandshakeAlignsBothClocks() {
        #expect(SongTapHandshake.senderStartMs(1000) == 1150)
        #expect(SongTapHandshake.receiverStartMs(receiptMs: 10_000, rttMs: 80) == 10_110)
        #expect(SongTapHandshake.receiverStartMs(receiptMs: 10_000, rttMs: 50_000) == 10_000 + 150 - 500, "a long round trip is capped")
        #expect(SongTapHandshake.receiverStartMs(receiptMs: 10_000, rttMs: -5) == 10_150)
        #expect(SongTapHandshake.impulseAgeMs(nowMs: 1000, impulseMs: 900) == 100)
        #expect(SongTapHandshake.impulseAgeMs(nowMs: 1000, impulseMs: 1001) == -1)
        #expect(SongTapHandshake.peerImpulseLocalMs(receiptMs: 10_000, ageMs: -1, rttMs: 40) == -1)
    }
}
