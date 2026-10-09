import PixlModel
import XCTest
@testable import PixlAudio

/// Performance round 2: which library changes bump which revision, and that an artist-picture update keeps the
/// (song-only) detail index instead of rebuilding it.
@MainActor
final class LibraryRevisionTests: XCTestCase {
    private func waitForIndex(_ library: LibraryStore) async {
        for _ in 0..<200 where library.detailIndexIfCurrent == nil { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testArtistPicturesKeepTheSongsRevisionAndTheDetailIndex() async throws {
        let library = LibraryStore(snapshot: DemoLibrary.snapshot)
        await waitForIndex(library)
        let index = try XCTUnwrap(library.detailIndexIfCurrent)
        let songsRevision = library.songsRevision, revision = library.revision
        var artist = try XCTUnwrap(library.artists.first)
        artist.imageUrl = "https://example.com/a.jpg"
        library.updateArtists([artist])
        XCTAssertEqual(library.songsRevision, songsRevision)
        XCTAssertEqual(library.revision, revision &+ 1)
        // Current at once: no rebuild, the same lists under the new revision.
        let carried = try XCTUnwrap(library.detailIndexIfCurrent)
        XCTAssertEqual(carried.songsByAlbum.count, index.songsByAlbum.count)
        XCTAssertEqual(carried.revision, library.revision)
        XCTAssertEqual(library.artist(id: artist.id)?.imageUrl, "https://example.com/a.jpg")
    }

    func testEditsBumpTheSongsRevision() {
        let library = LibraryStore(snapshot: DemoLibrary.snapshot)
        let before = library.songsRevision
        library.applyEdit(library.snapshot)
        XCTAssertEqual(library.songsRevision, before &+ 1)
    }
}
