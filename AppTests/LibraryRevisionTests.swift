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

    func testPatchedDetailIndexEqualsAFreshOne() {
        var songs = DemoLibrary.songs
        let base = LibraryDetailIndex.build(songs, revision: 1)
        var changed: [String: Song] = [:]
        for index in songs.indices where index % 2 == 0 {
            songs[index].isFavorite.toggle()
            changed[songs[index].id] = songs[index]
        }
        let patched = base.patched(changed, revision: 2)
        let fresh = LibraryDetailIndex.build(songs, revision: 2)
        XCTAssertEqual(patched.songsByAlbum, fresh.songsByAlbum)
        XCTAssertEqual(patched.songsByArtist, fresh.songsByArtist)
        XCTAssertEqual(patched.songsByGenre, fresh.songsByGenre)
        XCTAssertEqual(patched.firstArtworkByArtist, fresh.firstArtworkByArtist)
        XCTAssertEqual(patched.folderTree, fresh.folderTree)
    }

    func testAHeartTapPatchesTheDetailIndexForTheNewRevision() async throws {
        let library = LibraryStore(snapshot: DemoLibrary.snapshot)
        await waitForIndex(library)
        var snapshot = library.snapshot
        snapshot.songs[0].isFavorite.toggle()
        library.applyEdit(snapshot, changedSongs: [snapshot.songs[0]])
        await waitForIndex(library)
        let index = try XCTUnwrap(library.detailIndexIfCurrent)
        XCTAssertEqual(index.songsByAlbum[snapshot.songs[0].albumId]?.first { $0.id == snapshot.songs[0].id }?.isFavorite,
                       snapshot.songs[0].isFavorite)
    }

    func testEditsBumpTheSongsRevision() {
        let library = LibraryStore(snapshot: DemoLibrary.snapshot)
        let before = library.songsRevision
        library.applyEdit(library.snapshot)
        XCTAssertEqual(library.songsRevision, before &+ 1)
    }
}

/// The Library lists after a heart tap, a playlist edit or an artist picture are patched or reused from the previous
/// computation; they must equal a computation from scratch.
@MainActor
final class LibraryModelPatchTests: XCTestCase {
    private func inputs(_ snapshot: LibrarySnapshot, revision: Int, filter: StorageFilter) -> LibraryModel.Inputs {
        LibraryModel.Inputs(snapshot: snapshot, songSort: .songTitleZA, albumSort: .albumTitleAZ,
                            artistSort: .artistNumSongsDesc, playlistSort: .playlistNameAZ,
                            folderSort: .folderNameAZ, likedSort: .likedSongTitleAZ,
                            storageFilter: filter, likedAt: [:], revision: revision)
    }

    private func assertEqual(_ a: LibraryModel.Lists, _ b: LibraryModel.Lists, file: StaticString = #filePath,
                             line: UInt = #line) {
        XCTAssertEqual(a.songs, b.songs, file: file, line: line)
        XCTAssertEqual(a.albums, b.albums, file: file, line: line)
        XCTAssertEqual(a.artists, b.artists, file: file, line: line)
        XCTAssertEqual(a.playlists, b.playlists, file: file, line: line)
        XCTAssertEqual(a.liked, b.liked, file: file, line: line)
        XCTAssertEqual(a.folders, b.folders, file: file, line: line)
        XCTAssertEqual(a.folderPlaylists, b.folderPlaylists, file: file, line: line)
        XCTAssertEqual(a.folderRoots, b.folderRoots, file: file, line: line)
        XCTAssertEqual(a.songIds, b.songIds, file: file, line: line)
        XCTAssertEqual(a.likedIds, b.likedIds, file: file, line: line)
        XCTAssertEqual(Set(a.folderContents.keys), Set(b.folderContents.keys), file: file, line: line)
        for (path, contents) in a.folderContents {
            XCTAssertEqual(contents.songs, b.folderContents[path]?.songs, file: file, line: line)
            XCTAssertEqual(contents.subFolders, b.folderContents[path]?.subFolders, file: file, line: line)
        }
    }

    func testPatchedListsEqualFreshOnesAfterHeartsPlaylistsAndPictures() {
        for filter in [StorageFilter.all, .offline] {
            var snapshot = DemoLibrary.snapshot
            var revision = 1
            var previous = LibraryModel.compute(inputs(snapshot, revision: revision, filter: filter), previous: nil)
            // Hearts on and off.
            for step in 0..<6 {
                for index in snapshot.songs.indices where (index + step) % 3 == 0 { snapshot.songs[index].isFavorite.toggle() }
                revision += 1
                let model = inputs(snapshot, revision: revision, filter: filter)
                let patched = LibraryModel.compute(model, previous: previous)
                assertEqual(patched.lists, LibraryModel.compute(model, previous: nil).lists)
                previous = patched
            }
            // A playlist edit.
            if !snapshot.playlists.isEmpty {
                snapshot.playlists[0].name = "Zzz renamed"
                revision += 1
                let model = inputs(snapshot, revision: revision, filter: filter)
                let patched = LibraryModel.compute(model, previous: previous)
                assertEqual(patched.lists, LibraryModel.compute(model, previous: nil).lists)
                previous = patched
            }
            // An artist picture.
            if !snapshot.artists.isEmpty {
                snapshot.artists[0].imageUrl = "https://example.com/x.jpg"
                revision += 1
                let model = inputs(snapshot, revision: revision, filter: filter)
                let patched = LibraryModel.compute(model, previous: previous)
                assertEqual(patched.lists, LibraryModel.compute(model, previous: nil).lists)
                previous = patched
            }
            // A song that is not a favourites-only change falls back to a full computation.
            snapshot.songs[0].title = "Renamed song"
            revision += 1
            let model = inputs(snapshot, revision: revision, filter: filter)
            assertEqual(LibraryModel.compute(model, previous: previous).lists, LibraryModel.compute(model, previous: nil).lists)
        }
    }
}
