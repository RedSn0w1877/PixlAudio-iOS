import PixlLibrary
import PixlModel
import XCTest
@testable import PixlAudio

/// The words of stage 2a, milestone 2 (docs/brain-spec.md, section 8; the same sentences as Android's
/// `strings_brain.xml`): the controls, the reasons, the facts and the bar after a piece of feedback.
@MainActor
final class BrainControlsCopyTests: XCTestCase {
    func testTheControlsReadAsOnAndroid() {
        XCTAssertEqual(BrainStrings.moreLikeThis, "More like this")
        XCTAssertEqual(BrainStrings.dontCount, "Don't count this")
        XCTAssertEqual(BrainStrings.dontCountDone, "This won't shape your picks.")
        XCTAssertEqual(BrainStrings.dontCountHour, "Don't count the last hour")
        XCTAssertEqual(BrainStrings.muteArtist("Doja Cat"), "Mute Doja Cat")
        XCTAssertEqual(BrainStrings.privateSession, "Private session")
        XCTAssertEqual(BrainStrings.privatePill, "Private")
        XCTAssertEqual(BrainStrings.refreshPicks, "Refresh picks")
        XCTAssertEqual(BrainStrings.startArtistStation, "Start artist station")
        XCTAssertEqual(BrainStrings.startStationFromAlbum, "Start station from this album")
        XCTAssertEqual(BrainStrings.startStationFromPlaylist, "Start station from this playlist")
        XCTAssertEqual(BrainStrings.homeNewReleases, "New from artists you play")
        XCTAssertEqual(BrainStrings.spotifyShapesTitle, "Use my Spotify music to shape picks")
    }

    func testTheNewReasonLinesAndFactsReadAsOnAndroid() {
        XCTAssertEqual(BrainStrings.whyLine(.similarArtist("Zed")), "Close to Zed")
        XCTAssertEqual(BrainStrings.whyLine(.newRelease("Zed")), "New from Zed")
        XCTAssertEqual(BrainStrings.whyFact(WhyFacts.Fact(key: WhyFacts.keyArtistFinished, a: 9, b: 10)),
                       "You finished 9 of your last 10 plays by this artist")
        XCTAssertEqual(BrainStrings.whyFact(WhyFacts.Fact(key: WhyFacts.keyTrackFinished, a: 3, b: 0)),
                       "You've finished this 3 times")
        XCTAssertEqual(BrainStrings.whyFact(WhyFacts.Fact(key: WhyFacts.keyYear, a: 2024, b: 0)), "Out in 2024")
    }

    func testEveryKindOfBarHasWordsAndNoneSaysLearn() {
        let kinds: [BrainNotice.Kind] = [.notForMe, .notSaved, .lessFrom, .undone, .moreLike, .dontCount, .dontCountNothing,
                                         .alreadyReduced, .muted]
        for kind in kinds {
            let text = BrainStrings.notice(BrainNotice(serial: 1, kind: kind, adjustmentId: nil, artistName: "Zed"))
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.lowercased().contains("learn"), text)
        }
        XCTAssertEqual(BrainStrings.notice(BrainNotice(serial: 1, kind: .alreadyReduced, adjustmentId: nil, artistName: "Zed")),
                       "You already hear less from Zed. Mute them?")
        XCTAssertEqual(BrainStrings.notice(BrainNotice(serial: 1, kind: .moreLike, adjustmentId: "x", artistName: "Zed")),
                       "Got it. More like Zed for a while.")
    }
}
