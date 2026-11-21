import PixlLibrary
import XCTest
@testable import PixlAudio

/// The spoken host's duck (Endless Listening): the ramp down and up through the tap's shared gain, an abort that gives the level back at once,
/// and a duck that cannot be held twice. The numbers are `HostVoice`'s (tested against Android's golden file in PixlLibrary); here only that
/// the engine side follows them. Waits are generous: a CI runner is slow.
@MainActor
final class HostDuckTests: XCTestCase {
    private func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    func testItRampsDownToTheDuckLevelAndBackUp() async {
        let effects = AudioEffectsParameters()
        let duck = HostDuck(effects: effects)
        XCTAssertEqual(effects.duckGain.load(), 1)
        XCTAssertTrue(duck.begin())
        XCTAssertTrue(duck.isActive)
        await settle(700)
        XCTAssertEqual(duck.permille, HostVoice.duckPermille)
        XCTAssertEqual(effects.duckGain.load(), 0.35, accuracy: 0.0001)
        duck.end()
        await settle(900)
        XCTAssertEqual(duck.permille, HostVoice.permilleFull)
        XCTAssertEqual(effects.duckGain.load(), 1)
        XCTAssertFalse(duck.isActive, "the duck is over once the music is back")
    }

    func testTheQuickWayBackIsQuick() async {
        let effects = AudioEffectsParameters()
        let duck = HostDuck(effects: effects)
        duck.begin()
        await settle(700)
        duck.end(quick: true)
        await settle(500)
        XCTAssertEqual(effects.duckGain.load(), 1)
        XCTAssertFalse(duck.isActive)
    }

    func testAnAbortGivesTheLevelBackAtOnceAndSaysWhy() async {
        let effects = AudioEffectsParameters()
        let duck = HostDuck(effects: effects)
        var reasons: [String] = []
        duck.onEnded = { reasons.append($0) }
        duck.begin()
        await settle(100)
        XCTAssertLessThan(effects.duckGain.load(), 1)
        duck.abort(reason: "transition")
        XCTAssertEqual(effects.duckGain.load(), 1, "no ramp: a crossfade must never read a ducked level")
        XCTAssertFalse(duck.isActive)
        XCTAssertEqual(reasons, ["transition"])
        // Nothing held: an abort says nothing and a ramp that was cut stays cut.
        duck.abort(reason: "again")
        await settle(300)
        XCTAssertEqual(reasons, ["transition"])
        XCTAssertEqual(effects.duckGain.load(), 1)
    }

    func testItIsNeverHeldTwice() async {
        let duck = HostDuck(effects: AudioEffectsParameters())
        XCTAssertTrue(duck.begin())
        XCTAssertFalse(duck.begin())
        duck.abort(reason: "test")
        XCTAssertTrue(duck.begin(), "after an abort it can be held again")
        duck.abort(reason: "test")
    }
}
