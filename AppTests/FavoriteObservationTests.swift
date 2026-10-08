import Observation
import PixlModel
import XCTest
@testable import PixlAudio

/// The favourite heart fix (2026-10-07): `LibraryStore`'s song lookup is `@ObservationIgnored`, so a view that read the
/// favourite through `song(id:)` never redrew after a favourite edit (the full player's heart waited for shuffle or
/// repeat). `observedSong(id:)` also reads `revision`, so an edit invalidates its reader at once.
@MainActor
final class FavoriteObservationTests: XCTestCase {
    func testObservedSongInvalidatesItsReaderOnAFavoriteEdit() {
        let store = LibraryStore(snapshot: DemoLibrary.snapshot)
        let editor = LibraryEditor(store: store, persistence: nil, writesCache: false)
        let id = DemoLibrary.songs[0].id
        XCTAssertEqual(store.observedSong(id: id)?.isFavorite, true, "demo song 0 starts liked")
        let changed = expectation(description: "a reader of observedSong is invalidated by the edit")
        withObservationTracking {
            _ = store.observedSong(id: id)
        } onChange: {
            changed.fulfill()
        }
        editor.toggleFavorite(id)
        wait(for: [changed], timeout: 1)
        XCTAssertEqual(store.observedSong(id: id)?.isFavorite, false)
    }

    /// Tap after tap, as on the full player's heart: each toggle invalidates the reader that the previous redraw
    /// registered, and the flag alternates (liked → not → liked → not).
    func testEveryToggleInvalidatesTheNextRead() {
        let store = LibraryStore(snapshot: DemoLibrary.snapshot)
        let editor = LibraryEditor(store: store, persistence: nil, writesCache: false)
        let id = DemoLibrary.songs[0].id
        for expected in [false, true, false] {
            let changed = expectation(description: "toggle to \(expected) invalidates the reader")
            withObservationTracking {
                _ = store.observedSong(id: id)
            } onChange: {
                changed.fulfill()
            }
            editor.toggleFavorite(id)
            wait(for: [changed], timeout: 1)
            XCTAssertEqual(store.observedSong(id: id)?.isFavorite, expected)
        }
    }

    /// Why `observedSong` exists: the plain lookup registers nothing, so its reader is never invalidated.
    func testPlainLookupIsNotObserved() {
        let store = LibraryStore(snapshot: DemoLibrary.snapshot)
        let editor = LibraryEditor(store: store, persistence: nil, writesCache: false)
        let id = DemoLibrary.songs[0].id
        let changed = expectation(description: "a reader of song(id:) is not invalidated")
        changed.isInverted = true
        withObservationTracking {
            _ = store.song(id: id)
        } onChange: {
            changed.fulfill()
        }
        editor.toggleFavorite(id)
        wait(for: [changed], timeout: 0.2)
        XCTAssertEqual(store.song(id: id)?.isFavorite, false, "the lookup itself is patched in place")
    }
}
