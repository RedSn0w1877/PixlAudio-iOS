import Foundation
import PixlLibrary
import PixlModel
import XCTest
@testable import PixlAudio

/// Ask Taizo's taste changes in the app: the store (apply, undo, persist, expire), the turn state the injection guard
/// reads, and Home's mixes honouring a mute. The rules themselves are PixlCore's (`TasteAdjustmentTests`).
@MainActor
final class TasteAdjustmentStoreTests: XCTestCase {
    private let now: Int64 = 1_789_065_000_000
    private let utc = TimeZone(identifier: "UTC")!

    private func change(_ action: TasteAction, _ type: TasteTargetType, _ label: String) -> TasteChange {
        TasteChange(action: action, targetType: type, key: TasteKey.of(label), label: label, reason: "test")
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("taste-\(UUID().uuidString).json")
    }

    func testApplyRemoveAndClearBumpTheRevision() async {
        let store = TasteAdjustmentStore(file: nil)
        XCTAssertEqual(store.count, 0)
        let outcomes = await store.apply([change(.boost, .artist, "Luma Vale"), change(.mute, .genre, "Folk")])
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.revision, 1, "one bump for the whole call")
        let id = store.items[0].id
        XCTAssertTrue(store.remove(id: id))
        XCTAssertFalse(store.remove(id: id))
        XCTAssertEqual(store.count, 1)
        // Undoing something that was never set changes nothing and does not bump.
        let revision = store.revision
        let none = await store.apply([change(.unblock, .artist, "Nobody")])
        XCTAssertEqual(none, [.nothingToRemove])
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(store.removeAll(), 1)
        XCTAssertEqual(store.removeAll(), 0)
        XCTAssertEqual(store.count, 0)
    }

    func testChangesSurviveARelaunch() async {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let first = TasteAdjustmentStore(file: file)
        _ = await first.apply([change(.block, .artist, "Hollow Pines")])
        // The write is off the main thread: wait for it.
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: file.path) { try? await Task.sleep(for: .milliseconds(40)) }
        let second = TasteAdjustmentStore(file: file)
        await second.ensureLoaded()
        XCTAssertEqual(second.items.map(\.label), ["Hollow Pines"])
        XCTAssertEqual(second.items.first?.kind, .block)
        XCTAssertTrue(second.activeSet(nowMs: currentTimeMillis()).isBlocked(DemoLibrary.songs.first { $0.artist == "Hollow Pines" }!))
    }

    func testAnUnreadableFileIsAnEmptyList() async {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try? Data("not json".utf8).write(to: file)
        let store = TasteAdjustmentStore(file: file)
        await store.ensureLoaded()
        XCTAssertEqual(store.count, 0)
    }

    func testTheTurnStateCarriesOnlyTheUsersMessage() {
        let turn = TaizoTurnState()
        XCTAssertNil(turn.userMessage)
        turn.begin(userMessage: "play more luma vale")
        XCTAssertEqual(turn.userMessage, "play more luma vale")
        turn.end()
        XCTAssertNil(turn.userMessage)
    }

    func testAMuteLeavesAnArtistOutOfTheMixes() {
        let events = DemoListeningHistory.events(songs: DemoLibrary.songs, nowMs: now)
        let plain = HomeStore.compute(snapshot: DemoLibrary.snapshot, events: events, nowMs: now, timeZone: utc, savedDaily: [],
                                      savedYourMix: [])
        guard let artist = plain.content.dailyMix.first?.artist else { return XCTFail("the demo library has a daily mix") }
        var list = TasteAdjustmentList()
        list.apply(change(.mute, .artist, artist), nowMs: now)
        let muted = HomeStore.compute(snapshot: DemoLibrary.snapshot, events: events, nowMs: now, timeZone: utc, savedDaily: [],
                                      savedYourMix: [], adjustments: list.set(nowMs: now))
        XCTAssertTrue(plain.content.dailyMix.contains { $0.artist == artist }, "the demo mix has songs by \(artist) without the mute")
        XCTAssertFalse(muted.content.dailyMix.isEmpty)
        XCTAssertFalse(muted.content.dailyMix.contains { $0.artist == artist })
        XCTAssertFalse(muted.content.curatedYourMix.contains { $0.artist == artist })
        let shelved = (muted.content.mixes + muted.content.shelves).flatMap(\.songs)
        XCTAssertFalse(shelved.contains { $0.artist == artist })
        // Saved picks that now contain a muted song are filtered when they are shown.
        let saved = HomeStore.compute(snapshot: DemoLibrary.snapshot, events: events, nowMs: now, timeZone: utc,
                                      savedDaily: plain.content.dailyMix.map(\.id), savedYourMix: plain.content.curatedYourMix.map(\.id),
                                      adjustments: list.set(nowMs: now))
        XCTAssertFalse(saved.content.dailyMix.contains { $0.artist == artist })
    }

    func testAnEmptySetLeavesHomeUntouched() {
        let events = DemoListeningHistory.events(songs: DemoLibrary.songs, nowMs: now)
        let plain = HomeStore.compute(snapshot: DemoLibrary.snapshot, events: events, nowMs: now, timeZone: utc, savedDaily: [],
                                      savedYourMix: [])
        let empty = HomeStore.compute(snapshot: DemoLibrary.snapshot, events: events, nowMs: now, timeZone: utc, savedDaily: [],
                                      savedYourMix: [], adjustments: .empty)
        XCTAssertEqual(plain.content, empty.content)
    }

    func testTheDemoScreenListsFourChanges() {
        let store = TasteAdjustmentStore(file: nil, seed: DemoTasteChanges.list(nowMs: now))
        XCTAssertEqual(store.items.map(\.kind), [.block, .mute, .reduce, .boost], "newest first")
        XCTAssertEqual(TasteChangeText.title(store.items[3]), "Much more of Luma Fields")
        XCTAssertEqual(TasteChangeText.summary(count: 0), "Nothing changed yet. Ask Taizo to boost, reduce or mute music.")
    }
}
