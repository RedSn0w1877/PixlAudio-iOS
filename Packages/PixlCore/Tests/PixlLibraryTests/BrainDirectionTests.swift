import Testing
@testable import PixlLibrary

/// The change of direction after three skipped picks (docs/brain-spec.md, 7.3): what turns the engine, what it
/// follows meanwhile, and what ends the turn. The iOS twin of Android's `DirectionTest`.
/// A `Direction` behind a reference, so a step can be asked inside `#expect`.
private final class Turning {
    var direction = Direction()
    var turn: Int { direction.turn }
    func follow(_ anchors: [Int64]) -> [Int64] { direction.follow(anchors) }
}

@Suite("Brain direction")
struct BrainDirectionTests {
    private let a: Int64 = 11
    private let b: Int64 = 22
    private let c: Int64 = 33
    /// Newest first.
    private var anchors: [Int64] { [a, b, c] }

    @discardableResult
    private func engineSkip(_ turning: Turning, _ anchors: [Int64]? = nil) -> Bool {
        turning.direction.onEvent(enginePick: true, station: false, hardSkip: true, positive: false, anchors: anchors ?? self.anchors)
    }

    @discardableResult
    private func engineDone(_ turning: Turning, _ anchors: [Int64]? = nil) -> Bool {
        turning.direction.onEvent(enginePick: true, station: false, hardSkip: false, positive: true, anchors: anchors ?? self.anchors)
    }

    @discardableResult
    private func ownTrack(_ turning: Turning, hardSkip: Bool) -> Bool {
        turning.direction.onEvent(enginePick: false, station: false, hardSkip: hardSkip, positive: !hardSkip, anchors: anchors)
    }

    @Test func threeEnginePicksSkippedInARowTurnTheEngineToTheNextAnchor() {
        let direction = Turning()
        #expect(!engineSkip(direction))
        #expect(!engineSkip(direction))
        #expect(direction.turn == 0)
        #expect(direction.follow(anchors) == anchors)
        #expect(engineSkip(direction))
        #expect(direction.turn == 1)
        #expect(direction.follow(anchors) == [b])
    }

    @Test func skippingThroughOnesOwnPlaylistNeverTurnsTheEngine() {
        let direction = Turning()
        for _ in 0..<6 { #expect(!ownTrack(direction, hardSkip: true)) }
        #expect(direction.turn == 0)
        // And the listener's skips do not count towards the engine's three.
        #expect(!engineSkip(direction))
        #expect(!engineSkip(direction))
        #expect(!ownTrack(direction, hardSkip: true))
        #expect(!engineSkip(direction))
        #expect(!engineSkip(direction))
        #expect(direction.turn == 0)
    }

    @Test func aPickThatIsHeardOutBreaksTheRunOfSkips() {
        let direction = Turning()
        engineSkip(direction)
        engineSkip(direction)
        engineDone(direction)
        #expect(!engineSkip(direction))
        #expect(!engineSkip(direction))
        #expect(engineSkip(direction))
    }

    @Test func theTurnLastsWhileTheEnginesPicksPlayAndEndsWithTheListenersNextOwnTrack() {
        let direction = Turning()
        for _ in 0..<3 { engineSkip(direction) }
        // Picks of the new direction play through: still turned, still the one anchor.
        engineDone(direction)
        engineDone(direction)
        #expect(direction.turn == 1)
        #expect(direction.follow(anchors) == [b])
        // The listener plays a song of their own (even one they then skip): the detour is over.
        ownTrack(direction, hardSkip: true)
        #expect(direction.turn == 0)
        #expect(direction.follow(anchors) == anchors)
        // A later turn starts from scratch.
        for _ in 0..<2 { #expect(!engineSkip(direction)) }
        #expect(engineSkip(direction))
        #expect(direction.turn == 2)
        #expect(direction.follow(anchors) == [b])
    }

    @Test func turningAgainGoesToTheNextAnchorAndThenToTheLibraryWhenNoneIsLeft() {
        let direction = Turning()
        for _ in 0..<3 { engineSkip(direction) }
        #expect(direction.follow(anchors) == [b])
        for _ in 0..<3 { engineSkip(direction) }
        #expect(direction.turn == 2)
        #expect(direction.follow(anchors) == [c])
        for _ in 0..<3 { engineSkip(direction) }
        #expect(direction.turn == 3)
        // Every anchor was tried: nothing of the session is left to follow.
        #expect(direction.follow(anchors).isEmpty)
    }

    @Test func withOneAnchorOrNoneThereIsNothingToTurnTo() {
        let one = Turning()
        for _ in 0..<3 { engineSkip(one, [a]) }
        #expect(one.turn == 1)
        #expect(one.follow([a]).isEmpty)

        let none = Turning()
        for _ in 0..<3 { engineSkip(none, []) }
        #expect(none.turn == 1)
        #expect(none.follow([]).isEmpty)
    }

    @Test func aPickLikedAfterTheTurnLeadsTheNewDirection() {
        let direction = Turning()
        for _ in 0..<3 { engineSkip(direction) }
        // The liked pick became an anchor (newest first); the oldest anchor fell off the list.
        let liked: Int64 = 44
        let after = [liked, a, b]
        engineDone(direction, after)
        #expect(direction.follow(after) == [liked, b])
    }

    @Test func aStationStaysOnItsSeed() {
        let direction = Turning()
        for _ in 0..<5 {
            let turned = direction.direction.onEvent(enginePick: true, station: true, hardSkip: true, positive: false,
                                                     anchors: anchors)
            #expect(!turned)
        }
        #expect(direction.turn == 0)
    }
}
