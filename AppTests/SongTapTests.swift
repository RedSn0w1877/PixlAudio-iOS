import Foundation
import PixlLibrary
import XCTest
@testable import PixlAudio

/// Song Tap's app-side pieces: the CryptoKit signer and verifier (the Android `SongTapCryptoTest`), the settings and the
/// entry rows. The rules and the state machine are tested in PixlCore (`SongTapCoreTests`, `SongTapFlowTests`).
final class SongTapTests: XCTestCase {
    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "pixlaudio.tests.songtap.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: Crypto

    func testASignatureVerifiesAndATamperedMessageDoesNot() throws {
        let signer = SongTapSigner()
        let message = [UInt8]("payload challenge timestamp".utf8)
        let signature = try XCTUnwrap(signer.sign(message))
        XCTAssertEqual(signer.publicKey.count, SongTapSigning.publicKeyBytes)
        XCTAssertEqual(signer.publicKey.first, 4, "an uncompressed point")
        XCTAssertEqual(signature.count, SongTapSigning.signatureBytes)
        let verifier = SongTapVerifier()
        XCTAssertTrue(verifier.verify(publicKey: signer.publicKey, message: message, signature: signature))
        XCTAssertFalse(verifier.verify(publicKey: signer.publicKey, message: message + [0], signature: signature))
        var flipped = signature
        flipped[10] ^= 0x01
        XCTAssertFalse(verifier.verify(publicKey: signer.publicKey, message: message, signature: flipped))
    }

    func testAnotherPhonesKeyDoesNotVerify() throws {
        let message = [UInt8]("m".utf8)
        let signature = try XCTUnwrap(SongTapSigner().sign(message))
        XCTAssertFalse(SongTapVerifier().verify(publicKey: SongTapSigner().publicKey, message: message, signature: signature))
    }

    func testMalformedKeysAndSignaturesAreFalseNotACrash() {
        let verifier = SongTapVerifier()
        XCTAssertFalse(verifier.verify(publicKey: [], message: [1], signature: []))
        XCTAssertFalse(verifier.verify(publicKey: [UInt8](repeating: 4, count: 65), message: [1], signature: [UInt8](repeating: 1, count: 64)))
        XCTAssertFalse(verifier.verify(publicKey: [UInt8](repeating: 0, count: 65), message: [1], signature: [UInt8](repeating: 1, count: 64)))
        XCTAssertFalse(verifier.verify(publicKey: SongTapSigner().publicKey, message: [1], signature: [UInt8](repeating: 1, count: 63)))
    }

    func testASignedOfferRoundTripsThroughTheCore() throws {
        let payload = try XCTUnwrap(SongTapPayloads.make(nowMs: 1_000, ytVideoId: "dQw4w9WgXcQ", spotifyId: nil, isrc: nil, title: "Song",
                                                         artist: "Artist", durationMs: 1000, artUrl: nil))
        let bytes = try XCTUnwrap(SongTapPayloads.encode(payload))
        let challenge = [UInt8](repeating: 7, count: SongTapSigning.challengeBytes)
        let message = try XCTUnwrap(SongTapSigning.signingBytes(payload: bytes, challenge: challenge, timestampMs: 1_000))
        let signer = SongTapSigner()
        let offer = SongTapSignedOffer(payload: bytes, timestampMs: 1_000, publicKey: signer.publicKey,
                                       signature: try XCTUnwrap(signer.sign(message)))
        let frame = try XCTUnwrap(SongTapSigning.encodeFrame(offer))
        let back = try XCTUnwrap(SongTapSigning.decodeFrame(frame))
        XCTAssertEqual(SongTapSigning.check(back, challenge: challenge, nowMs: 1_500, verifier: SongTapVerifier()), .ok)
        XCTAssertEqual(SongTapSigning.check(back, challenge: [UInt8](repeating: 8, count: 16), nowMs: 1_500, verifier: SongTapVerifier()),
                       .badSignature, "an offer made for another challenge is not accepted (no replay)")
    }

    // MARK: Settings

    @MainActor
    func testSongTapIsOffAndTheFirstBeamAsksUntilTheListenerSaysYes() {
        let defaults = freshDefaults()
        let settings = SongTapSettings(defaults: defaults)
        XCTAssertFalse(settings.allowed, "off by default")
        XCTAssertTrue(settings.firstBeamAsks)
        settings.allowed = true
        settings.markFirstBeamAccepted()
        let again = SongTapSettings(defaults: defaults)
        XCTAssertTrue(again.allowed)
        XCTAssertFalse(again.firstBeamAsks)
    }

    // MARK: Entry points

    func testSongTapIsASettingsCategoryAfterSingAndACover() {
        XCTAssertEqual(SettingsCategory.songTap.rawValue, "song_tap")
        XCTAssertEqual(SettingsCategory.allCases.firstIndex(of: .songTap), (SettingsCategory.allCases.firstIndex(of: .sing) ?? 0) + 1)
        XCTAssertEqual(AppCover.songTap.id, "songTap")
    }

    func testTheStringsAreFilledAndTheNoticesAllHaveWords() {
        XCTAssertEqual(SongTapStrings.title, "Song Tap")
        for notice in SongTapNotice.allCases {
            XCTAssertFalse(SongTapStrings.notice(notice).isEmpty, "\(notice)")
        }
    }
}
