import Foundation
import PixlLibrary
import PixlModel
import PixlTags
import XCTest
@testable import PixlAudio

/// Stage 6: the library import against real files generated at test time (MP3 / FLAC / WAV / M4A).
final class LibraryImportTests: XCTestCase {
    private var workDirectory: URL!
    private var music: URL!
    private var persistence: PersistenceActor!

    override func setUp() async throws {
        workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryImportTests-\(UUID().uuidString)")
        music = workDirectory.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        persistence = PersistenceActor(modelContainer: try PersistenceActor.makeContainer(inMemory: true))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    private var root: FolderRoot { FolderRoot(id: "t", displayName: "Root", url: music) }

    private func makeImporter(options: LibraryScanOptions = .default) -> LocalLibraryImporter {
        var configuration = LocalLibraryImporter.Configuration()
        configuration.includeDocumentsFolder = false
        configuration.allowsMediaLibrary = false
        configuration.stateURL = workDirectory.appendingPathComponent("scan-state.plist")
        configuration.fixedRoots = [root]
        return LocalLibraryImporter(persistence: persistence, configuration: configuration, options: { options })
    }

    private func scan(_ importer: LocalLibraryImporter,
                      _ mode: LibraryImportMode = .incremental) async throws -> LibraryImportSummary {
        try await importer.importLibrary(mode: mode) { _ in }
    }

    private func snapshot() async throws -> LibrarySnapshot { try await persistence.loadLibrarySnapshot() }

    private func song(_ title: String, in snapshot: LibrarySnapshot) throws -> Song {
        try XCTUnwrap(snapshot.songs.first { $0.title == title }, "no song titled \(title)")
    }

    /// The standard fixture: two tagged songs in one album folder, an untagged WAV, and files the scanner must skip.
    @discardableResult
    private func writeFixture() throws -> (mp3: URL, flac: URL, wav: URL) {
        let mp3 = try TestAudioFiles.put(
            TestAudioFiles.mp3(seconds: 12, tags: [
                "TITLE": ["Song One"], "ARTIST": ["Alice; Bob"], "ALBUM": ["Album X"], "TRACKNUMBER": ["1"],
                "GENRE": ["Pop"], "REPLAYGAIN_TRACK_GAIN": ["-6.50 dB"],
            ], pictures: [TagPicture(data: TestAudioFiles.tinyPNG, mimeType: "image/png")]),
            at: "Album X/01 Song One.mp3", in: music)
        let flac = try TestAudioFiles.put(
            TestAudioFiles.flac(seconds: 12, tags: [
                "TITLE": ["Song Two"], "ARTIST": ["Alice"], "ALBUM": ["Album X"], "TRACKNUMBER": ["2"],
                "DATE": ["2021-04-01"], "GENRE": ["<unknown>"],
            ]),
            at: "Album X/02 Song Two.flac", in: music)
        let wav = try TestAudioFiles.put(TestAudioFiles.wav(seconds: 12), at: "Loose/tone.wav", in: music)
        // Too short (Android's 10 s minimum), hidden, in a .nomedia folder, not audio.
        try TestAudioFiles.put(TestAudioFiles.mp3(seconds: 3, tags: ["TITLE": ["Jingle"]]), at: "short.mp3", in: music)
        try TestAudioFiles.put(TestAudioFiles.mp3(seconds: 12, tags: ["TITLE": ["Hidden"]]), at: ".cache/h.mp3", in: music)
        try TestAudioFiles.put(TestAudioFiles.mp3(seconds: 12, tags: ["TITLE": ["Muted"]]), at: "Ringtones/r.mp3", in: music)
        try TestAudioFiles.put(Data(), at: "Ringtones/.nomedia", in: music)
        try TestAudioFiles.put(Data("notes".utf8), at: "Album X/notes.txt", in: music)
        return (mp3, flac, wav)
    }

    // MARK: Import

    func testImportReadsTagsSplitsArtistsAndGroupsAlbums() async throws {
        let files = try writeFixture()
        let summary = try await scan(makeImporter())
        XCTAssertEqual(summary.added, 3)
        let library = try await snapshot()
        XCTAssertEqual(Set(library.songs.map(\.title)), ["Song One", "Song Two", "tone"])

        let one = try song("Song One", in: library)
        XCTAssertEqual(one.id, "f:t/Album X/01 Song One.mp3")
        XCTAssertEqual(one.path, "/Root/Album X/01 Song One.mp3")
        XCTAssertEqual(URL(string: one.contentUriString)?.standardizedFileURL, files.mp3.standardizedFileURL)
        XCTAssertEqual(one.artist, "Alice; Bob")
        XCTAssertEqual(one.artists.map(\.name), ["Alice", "Bob"])
        XCTAssertEqual(one.artists.first?.isPrimary, true)
        XCTAssertEqual(one.trackNumber, 1)
        XCTAssertEqual(one.genre, "Pop")
        XCTAssertEqual(one.mimeType, "audio/mpeg")
        XCTAssertEqual(Double(one.duration), 12_000, accuracy: 1_500)
        XCTAssertTrue(one.albumArtUriString?.hasPrefix("embedded://file://") == true)
        XCTAssertTrue(one.albumArtUriString?.hasSuffix("01%20Song%20One.mp3") == true)

        let two = try song("Song Two", in: library)
        XCTAssertEqual(two.duration, 12_000, "FLAC duration comes from STREAMINFO")
        XCTAssertEqual(two.year, 2021)
        XCTAssertNil(two.genre, "placeholder genres are dropped")
        XCTAssertEqual(two.sampleRate, 44_100)
        XCTAssertEqual(two.albumId, one.albumId, "same album name in the same folder groups together")

        let tone = try song("tone", in: library)
        XCTAssertEqual(tone.artist, "Unknown Artist")
        XCTAssertEqual(tone.album, "Loose", "untagged files take the folder name as album, like MediaStore")
        XCTAssertNotEqual(tone.albumId, one.albumId)

        XCTAssertEqual(library.albums.count, 2)
        let albumX = try XCTUnwrap(library.albums.first { $0.id == one.albumId })
        XCTAssertEqual(albumX.title, "Album X")
        XCTAssertEqual(albumX.songCount, 2)
        XCTAssertEqual(albumX.artist, "Alice")
        let alice = try XCTUnwrap(library.artists.first { $0.name == "Alice" })
        XCTAssertEqual(alice.songCount, 2)
        XCTAssertEqual(library.artists.first { $0.name == "Bob" }?.songCount, 1)
        XCTAssertEqual(one.artistId, alice.id)
    }

    func testMetadataReaderReturnsReplayGainAndEmbeddedArtwork() async throws {
        let files = try writeFixture()
        let metadata = await AudioMetadataReader.read(url: files.mp3)
        XCTAssertEqual(try XCTUnwrap(metadata.replayGainTrackDb), -6.5, accuracy: 0.001)
        XCTAssertTrue(metadata.hasEmbeddedArtwork)
        let artwork = await EmbeddedArtworkReader.data(for: files.mp3)
        XCTAssertEqual(artwork, TestAudioFiles.tinyPNG)
    }

    func testSyncedLyricsAreReadFromSYLT() async throws {
        let frames = TestAudioFiles.mpegFrames(seconds: 12)
        let sylt = ID3v2SyncedLyrics(syncedLines: [SyncedLine(time: 1_000, line: "Hello"),
                                                   SyncedLine(time: 2_500, line: "World")])
        let data = try AudioTagWriter.write(TagChanges(properties: ["TITLE": ["Lyric"]], syncedLyrics: .some(sylt)),
                                            to: frames).data
        let url = try TestAudioFiles.put(data, at: "lyric.mp3", in: music)
        let metadata = await AudioMetadataReader.read(url: url)
        let lrc = try XCTUnwrap(metadata.syncedLyricsLRC)
        XCTAssertTrue(lrc.contains("Hello"))
        XCTAssertTrue(lrc.contains("World"))
    }

    // MARK: Rescans

    func testIncrementalRescanPicksUpChangedAndNewFiles() async throws {
        let files = try writeFixture()
        let importer = makeImporter()
        _ = try await scan(importer)
        let before = try song("Song Two", in: try await snapshot())

        let nothing = try await scan(importer)
        XCTAssertEqual(nothing, LibraryImportSummary(added: 0, updated: 0, removed: 0))

        try TestAudioFiles.put(TestAudioFiles.flac(seconds: 12, tags: [
            "TITLE": ["Song Two (Edit)"], "ARTIST": ["Alice"], "ALBUM": ["Album X"], "TRACKNUMBER": ["2"],
        ]), at: "Album X/02 Song Two.flac", in: music)
        try TestAudioFiles.touch(files.flac)
        try TestAudioFiles.put(TestAudioFiles.mp3(seconds: 15, tags: ["TITLE": ["Song Three"], "ARTIST": ["Carol"],
                                                                      "ALBUM": ["Album X"]]),
                               at: "Album X/03.mp3", in: music)
        let summary = try await scan(importer)
        XCTAssertEqual(summary.added, 1)
        XCTAssertEqual(summary.updated, 1)
        XCTAssertEqual(summary.removed, 0)
        let library = try await snapshot()
        let edited = try song("Song Two (Edit)", in: library)
        XCTAssertEqual(edited.id, before.id)
        XCTAssertEqual(edited.dateAdded, before.dateAdded, "date added survives a rescan")
        XCTAssertEqual(try song("Song Three", in: library).albumId, edited.albumId)
        XCTAssertEqual(library.albums.first { $0.id == edited.albumId }?.songCount, 3)
    }

    func testDeletedFilesLeaveTheLibraryWithTheirArtists() async throws {
        let files = try writeFixture()
        let importer = makeImporter()
        _ = try await scan(importer)
        try FileManager.default.removeItem(at: files.mp3)
        let summary = try await scan(importer)
        XCTAssertEqual(summary.removed, 1)
        let library = try await snapshot()
        XCTAssertNil(library.songs.first { $0.title == "Song One" })
        XCTAssertNil(library.artists.first { $0.name == "Bob" }, "an artist without songs is removed")
        XCTAssertEqual(library.artists.first { $0.name == "Alice" }?.songCount, 1)
    }

    func testFavouritesSurviveRescans() async throws {
        try writeFixture()
        let importer = makeImporter()
        _ = try await scan(importer)
        let id = try song("Song One", in: try await snapshot()).id
        var favourite = try song("Song One", in: try await snapshot())
        favourite.isFavorite = true
        let library = try await snapshot()
        var songs = library.songs
        songs[songs.firstIndex { $0.id == id }!] = favourite
        try await persistence.replaceLibrary(with: LibrarySnapshot(songs: songs, albums: library.albums,
                                                                   artists: library.artists, playlists: []))
        _ = try await scan(importer, .full)
        let afterScan = try await snapshot()
        XCTAssertEqual(try song("Song One", in: afterScan).isFavorite, true)
    }

    func testMinimumDurationAndBlockedFoldersFollowSettings() async throws {
        try writeFixture()
        var options = LibraryScanOptions.default
        options.minSongDurationMs = 1_000
        options.blockedDirectories = ["/Root/Loose"]
        _ = try await scan(makeImporter(options: options))
        let scanned = try await snapshot()
        let titles = Set(scanned.songs.map(\.title))
        XCTAssertTrue(titles.contains("Jingle"), "3 s file passes a 1 s minimum")
        XCTAssertFalse(titles.contains("tone"), "blocked folder is skipped")
        XCTAssertFalse(titles.contains("Muted"), ".nomedia folder is skipped")
        XCTAssertFalse(titles.contains("Hidden"), "hidden folder is skipped")
    }

    func testChangedFiltersTriggerAFullReadOfRejectedFiles() async throws {
        try writeFixture()
        let stateURL = workDirectory.appendingPathComponent("scan-state.plist")
        _ = try await scan(makeImporter())
        let first = try await snapshot()
        XCTAssertFalse(first.songs.contains { $0.title == "Jingle" })
        XCTAssertNotNil(ScanState.load(from: stateURL).rejected["f:t/short.mp3"])
        var options = LibraryScanOptions.default
        options.minSongDurationMs = 1_000
        _ = try await scan(makeImporter(options: options))
        let second = try await snapshot()
        XCTAssertTrue(second.songs.contains { $0.title == "Jingle" })
    }

    // MARK: Artists

    func testArtistDelimitersComeFromSettings() async throws {
        try TestAudioFiles.put(TestAudioFiles.mp3(seconds: 12, tags: ["TITLE": ["Duet"], "ARTIST": ["Xavier/Yara"],
                                                                      "ALBUM": ["Pairs"]]),
                               at: "duet.mp3", in: music)
        _ = try await scan(makeImporter())
        let byDefault = try await snapshot()
        XCTAssertEqual(try song("Duet", in: byDefault).artists.map(\.name), ["Xavier/Yara"],
                       "the default delimiter is ';' only")

        var options = LibraryScanOptions.default
        options.artistDelimiters = ["/"]
        _ = try await scan(makeImporter(options: options), .full)
        let library = try await snapshot()
        XCTAssertEqual(try song("Duet", in: library).artists.map(\.name), ["Xavier", "Yara"])
        XCTAssertNil(library.artists.first { $0.name == "Xavier/Yara" })
    }

    func testArtistIdsStayStableAcrossScans() async throws {
        try writeFixture()
        let importer = makeImporter()
        _ = try await scan(importer)
        let first = try await snapshot().artists.reduce(into: [String: Int64]()) { $0[$1.name] = $1.id }
        _ = try await scan(importer, .full)
        let second = try await snapshot().artists.reduce(into: [String: Int64]()) { $0[$1.name] = $1.id }
        XCTAssertEqual(first, second)
    }

    // MARK: Tag edits

    func testTagOverrideAppliesAndClears() async throws {
        try writeFixture()
        let importer = makeImporter()
        _ = try await scan(importer)
        let id = try song("Song One", in: try await snapshot()).id

        try await importer.editTags(songId: id, fields: TagOverrideFields(title: "Renamed", artist: "Carol; Dave",
                                                                          year: 1999))
        _ = try await scan(importer)
        var library = try await snapshot()
        let renamed = try song("Renamed", in: library)
        XCTAssertEqual(renamed.id, id)
        XCTAssertEqual(renamed.artists.map(\.name), ["Carol", "Dave"])
        XCTAssertEqual(renamed.year, 1999)
        XCTAssertNil(library.artists.first { $0.name == "Bob" })

        try await importer.editTags(songId: id, fields: nil)
        _ = try await scan(importer)
        library = try await snapshot()
        XCTAssertEqual(try song("Song One", in: library).artists.map(\.name), ["Alice", "Bob"])
        XCTAssertNil(library.artists.first { $0.name == "Carol" })
    }

    func testWriteBackRewritesMP3AndFLAC() async throws {
        let files = try writeFixture()
        let importer = makeImporter()
        _ = try await scan(importer)
        for (title, url) in [("Song One", files.mp3), ("Song Two", files.flac)] {
            let id = try song(title, in: try await snapshot()).id
            try await importer.editTags(songId: id, fields: TagOverrideFields(title: title + " (Written)", genre: "Jazz"),
                                        writeToFile: true)
            let metadata = await AudioMetadataReader.read(url: url)
            XCTAssertEqual(metadata.title, title + " (Written)")
            XCTAssertEqual(metadata.genre, "Jazz")
            let overrides = try await persistence.tagOverrides()
            XCTAssertNil(overrides[id], "everything was written, so no override is kept")
        }
        let artwork = await EmbeddedArtworkReader.data(for: files.mp3)
        XCTAssertEqual(artwork, TestAudioFiles.tinyPNG, "write-back keeps the picture")
        _ = try await scan(importer)
        let library = try await snapshot()
        XCTAssertNotNil(library.songs.first { $0.title == "Song One (Written)" })
        XCTAssertEqual(try song("Song Two (Written)", in: library).genre, "Jazz")
    }

    func testWriteBackRewritesM4AWithPassthroughExport() async throws {
        let url = music.appendingPathComponent("aac.m4a")
        do {
            try TestAudioFiles.writeM4A(to: url, seconds: 12)
        } catch {
            throw XCTSkip("AAC encoding unavailable here: \(error)")
        }
        let importer = makeImporter()
        _ = try await scan(importer)
        let importedLibrary = try await snapshot()
        let imported = try XCTUnwrap(importedLibrary.songs.first)
        XCTAssertEqual(imported.title, "aac")
        XCTAssertEqual(imported.mimeType, "audio/mp4")
        try await importer.editTags(songId: imported.id,
                                    fields: TagOverrideFields(title: "Exported", artist: "Mia", trackNumber: 4),
                                    writeToFile: true)
        let metadata = await AudioMetadataReader.read(url: url)
        XCTAssertEqual(metadata.title, "Exported")
        XCTAssertEqual(metadata.artist, "Mia")
        let overrides = try await persistence.tagOverrides()
        XCTAssertEqual(overrides[imported.id], TagOverrideFields(trackNumber: 4), "MP4 track numbers stay an override")
        _ = try await scan(importer)
        let rescanned = try await snapshot()
        let song = try XCTUnwrap(rescanned.songs.first)
        XCTAssertEqual(song.title, "Exported")
        XCTAssertEqual(song.trackNumber, 4)
    }

    // MARK: Store integration

    @MainActor
    func testLibraryStoreRefreshShowsTheImportedLibrary() async throws {
        try writeFixture()
        let loader = SnapshotLoader(persistence: persistence, cacheURL: workDirectory.appendingPathComponent("cache.plist"))
        let store = LibraryStore(loader: loader, importer: makeImporter())
        try await store.refresh()
        XCTAssertEqual(store.songs.count, 3)
        XCTAssertNotNil(store.song(id: "f:t/Loose/tone.wav"))
        XCTAssertEqual(loader.loadCached()?.songs.count, 3, "the snapshot cache is rewritten")
    }
}

/// The pure parts: diff planning, enumeration rules, ids.
final class LibraryScanLogicTests: XCTestCase {
    private func entry(_ path: String, modified: Int64 = 1, size: Int64 = 10, placeholder: Bool = false) -> ScannedFileEntry {
        ScannedFileEntry(relativePath: path, url: URL(fileURLWithPath: "/tmp/\(path)"), modifiedMs: modified, size: size,
                         isPlaceholder: placeholder)
    }

    func testScanPlanDiffsByRelativePathAndStamp() {
        var state = ScanState()
        state.stamps["f:r/a.mp3"] = FileStamp(modifiedMs: 1, size: 10)
        state.stamps["f:r/b.mp3"] = FileStamp(modifiedMs: 1, size: 10)
        state.rejected["f:r/short.mp3"] = FileStamp(modifiedMs: 1, size: 10)
        let files = [entry("a.mp3"), entry("b.mp3", modified: 2), entry("c.mp3"), entry("short.mp3"),
                     entry("cloud.mp3", placeholder: true)]
        let plan = FolderScanPlan.make(rootID: "r", files: files, state: state,
                                       storedSongIDs: ["f:r/a.mp3", "f:r/b.mp3"], fullRescan: false)
        XCTAssertEqual(plan.unchanged.map(\.relativePath), ["a.mp3"])
        XCTAssertEqual(plan.toRead.map(\.relativePath), ["b.mp3", "c.mp3"])
        XCTAssertEqual(plan.stillRejected.map(\.relativePath), ["short.mp3"])
        XCTAssertEqual(plan.placeholders.map(\.relativePath), ["cloud.mp3"])

        let full = FolderScanPlan.make(rootID: "r", files: files, state: state,
                                       storedSongIDs: ["f:r/a.mp3", "f:r/b.mp3"], fullRescan: true)
        XCTAssertEqual(full.toRead.count, 4)
    }

    func testUnchangedStampWithoutAStoredSongIsReadAgain() {
        var state = ScanState()
        state.stamps["f:r/a.mp3"] = FileStamp(modifiedMs: 1, size: 10)
        let plan = FolderScanPlan.make(rootID: "r", files: [entry("a.mp3")], state: state, storedSongIDs: [],
                                       fullRescan: false)
        XCTAssertEqual(plan.toRead.count, 1)
    }

    func testIdentityHelpers() {
        let root = FolderRoot(id: "abc", displayName: "Music", url: URL(fileURLWithPath: "/x"))
        XCTAssertEqual(LibraryIdentity.fileSongID(rootID: "abc", relativePath: "A/b.mp3"), "f:abc/A/b.mp3")
        XCTAssertEqual(LibraryIdentity.rootID(ofFileSongID: "f:abc/A/b.mp3"), "abc")
        XCTAssertEqual(LibraryIdentity.libraryPath(root: root, relativePath: "A/b.mp3"), "/Music/A/b.mp3")
        XCTAssertEqual(LibraryIdentity.parentDirectory(ofLibraryPath: "/Music/A/b.mp3"), "/Music/A")
        XCTAssertTrue(LibraryIdentity.isManaged("mp:42"))
        XCTAssertFalse(LibraryIdentity.isManaged("yt:abc"))
        XCTAssertEqual(LibraryIdentity.stableID("album|dir:/a"), LibraryIdentity.stableID("album|dir:/a"))
        XCTAssertGreaterThan(LibraryIdentity.stableID("x"), 0)
    }

    func testGenreNormalisationMatchesAndroid() {
        XCTAssertNil(ScannedTrack.normalizeGenre(" <unknown> "))
        XCTAssertNil(ScannedTrack.normalizeGenre("Unknown Genre"))
        XCTAssertNil(ScannedTrack.normalizeGenre("null"))
        XCTAssertEqual(ScannedTrack.normalizeGenre(" Rock "), "Rock")
    }

    func testScanOptionsReadAndroidKeys() throws {
        let name = "LibraryScanLogicTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(#"["/", ";", ",", "+", "&"]"#, forKey: PreferenceKeys.artistDelimiters)
        defaults.set(["/storage/Music/Podcasts"], forKey: PreferenceKeys.blockedDirectories)
        defaults.set(30_000, forKey: PreferenceKeys.minSongDurationMs)
        let options = LibraryScanOptions.current(defaults: defaults)
        XCTAssertEqual(options.artistDelimiters, [";"], "Android's legacy default list is normalised")
        XCTAssertEqual(options.blockedDirectories, ["/storage/Music/Podcasts"])
        XCTAssertEqual(options.minSongDurationMs, 30_000)
        XCTAssertTrue(options.includeMediaLibrary)
        defaults.set(#"["&"]"#, forKey: PreferenceKeys.artistDelimiters)
        XCTAssertEqual(LibraryScanOptions.current(defaults: defaults).artistDelimiters, ["&"])
    }

    func testTagOverrideRoundTripsAsJSON() throws {
        let fields = TagOverrideFields(title: "T", artist: "A", trackNumber: 3)
        XCTAssertEqual(TagOverrideFields.decode(try fields.encoded()), fields)
        XCTAssertTrue(TagOverrideFields().isEmpty)
    }
}
