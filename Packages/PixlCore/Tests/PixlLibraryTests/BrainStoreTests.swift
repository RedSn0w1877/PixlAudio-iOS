import Foundation
import PixlFoundation
import PixlModel
import Testing
@testable import PixlLibrary

private func temporaryDirectory(_ label: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("brain-\(label)-\(UUID().uuidString)", isDirectory: true)
}

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

@Suite("Brain record files")
struct KeyedLogStoreTests {
    @Test func recordsSurviveAReopenAndTheNewestLineWins() throws {
        let url = temporaryDirectory("log").appendingPathComponent("table.pbl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = KeyedLogStore(url: url)
        #expect(store.count == 0)
        #expect(store.payload(for: "missing") == nil)
        #expect(store.put([(key: "a", payload: bytes("1")), (key: "b", payload: bytes("{\"x\":2}"))]))
        #expect(store.put("a", bytes("3")))
        #expect(store.remove(["b", "never-stored"]))
        #expect(store.payload(for: "a") == bytes("3"))
        #expect(store.payload(for: "b") == nil)
        #expect(store.count == 1)

        let reopened = KeyedLogStore(url: url)
        var seen: [String: [UInt8]] = [:]
        reopened.open { key, payload in seen[key] = Array(payload) }
        #expect(seen == ["a": bytes("3")])
        #expect(reopened.payload(for: "a") == bytes("3"))
        #expect(reopened.sizes.file == store.sizes.file)
    }

    @Test func keysWithTabsNewlinesAndPercentSignsAreKeptAndAPayloadWithALineFeedIsRefused() throws {
        let url = temporaryDirectory("keys").appendingPathComponent("table.pbl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = KeyedLogStore(url: url)
        let odd = "n:a\tb|100%\nc\r|0"
        #expect(store.put(odd, bytes("7")))
        #expect(store.put("n:s\u{01A1}n|ch\u{1EA1}y|0", bytes("8")))
        #expect(!store.put("bad", bytes("line\nfeed")))
        #expect(store.count == 2)
        let reopened = KeyedLogStore(url: url)
        reopened.open()
        #expect(reopened.payload(for: odd) == bytes("7"))
        #expect(reopened.payload(for: "n:s\u{01A1}n|ch\u{1EA1}y|0") == bytes("8"))
        #expect(reopened.contains(odd) && !reopened.contains("bad"))
        // Keys are compared by their bytes: canonically equal text is still two keys.
        #expect(reopened.put("\u{AC00}", bytes("1")) && reopened.put("\u{1100}\u{1161}", bytes("2")))
        #expect(reopened.count == 4)
    }

    @Test func aLineCutOffByACrashIsDroppedAndTheNextAppendStartsClean() throws {
        let url = temporaryDirectory("torn").appendingPathComponent("table.pbl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = KeyedLogStore(url: url)
        #expect(store.put("a", bytes("1")))
        #expect(store.put("b", bytes("2")))
        // A crash in the middle of a write: half a line, no line feed.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(bytes("c\t{\"half\":")))
        try handle.close()

        let reopened = KeyedLogStore(url: url)
        reopened.open()
        #expect(reopened.count == 2 && !reopened.contains("c"))
        #expect(reopened.put("d", bytes("4")))
        let again = KeyedLogStore(url: url)
        again.open()
        #expect(Set(again.keys) == ["a", "b", "d"])
        #expect(again.payload(for: "d") == bytes("4") && again.payload(for: "b") == bytes("2"))
    }

    @Test func theFileIsRewrittenWhenItPassesTwiceItsLiveSize() throws {
        let url = temporaryDirectory("compact").appendingPathComponent("table.pbl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = KeyedLogStore(url: url, compactionFloorBytes: 256)
        let payload = [UInt8](repeating: 0x78, count: 60)
        for i in 0..<5 { #expect(store.put("key\(i)", payload)) }
        #expect(store.compactions == 0)
        // Rewriting one key over and over: the dead lines outgrow the live ones.
        for round in 0..<40 { #expect(store.put("key0", bytes("round \(round)"))) }
        #expect(store.compactions >= 1)
        #expect(store.sizes.file <= 2 * store.sizes.live + 256)
        #expect(store.payload(for: "key0") == bytes("round 39"))
        #expect(store.payload(for: "key4") == payload)

        let reopened = KeyedLogStore(url: url)
        reopened.open()
        #expect(reopened.count == 5)
        #expect(reopened.payload(for: "key0") == bytes("round 39"))
        #expect(reopened.payload(for: "key3") == payload)
    }
}

@Suite("Brain tables")
struct BrainTablesTests {
    private func row(_ i: Int, _ artist: String, title: String? = nil, seconds: Int = 200) -> RadioRow {
        RadioRow(videoId: "vid\(i)", title: title ?? "Song \(i)", artists: [RadioArtistRef(name: artist, channelId: "UC\(artist)")],
                 durationSec: seconds, kind: .atv)
    }

    @Test func identitySurvivesARestartAndMergesStayFlat() throws {
        let directory = temporaryDirectory("identity")
        defer { try? FileManager.default.removeItem(at: directory) }
        let dreams = Ids.nameKey(primaryArtist: "Fleetwood Mac", rawTitle: "Dreams")
        let tables = BrainTables(directory: directory)
        let library = tables.resolveTrack(Ids.TrackKeys(spotifyId: "SP1", nameKey: dreams), durationMs: 257_000)
        let radio = tables.resolveTrack(Ids.TrackKeys(videoId: "VID1", nameKey: dreams), durationMs: 258_500)
        #expect(library != 0 && library == radio)
        let other = tables.resolveTrack(Ids.TrackKeys(videoId: "VID2"), durationMs: 0)
        let isrc = tables.resolveTrack(Ids.TrackKeys(isrc: "USX", videoId: "VID3"), durationMs: 0)
        #expect(Set([library, other, isrc]).count == 3)
        // An ISRC arrives for the library track and for VID2: three recordings become one, flat.
        #expect(tables.resolveTrack(Ids.TrackKeys(isrc: "USX", videoId: "VID2"), durationMs: 0) == isrc)
        #expect(tables.resolveTrack(Ids.TrackKeys(spotifyId: "SP1", isrc: "USX"), durationMs: 0) == library)
        #expect(tables.resolveTrack(Ids.TrackKeys(videoId: "VID2"), durationMs: 0) == library)
        #expect(tables.otherVideoIds(rid: library, exceptVideoId: "VID1").isEmpty)
        #expect(tables.resolveTracks([TrackRequest(keys: Ids.TrackKeys(), durationMs: 0)]) == [0])

        let restarted = BrainTables(directory: directory)
        #expect(restarted.resolveTrack(Ids.TrackKeys(videoId: "VID1"), durationMs: 0) == library)
        #expect(restarted.resolveTrack(Ids.TrackKeys(videoId: "VID2"), durationMs: 0) == library)
        #expect(restarted.resolveTrack(Ids.TrackKeys(videoId: "VID3"), durationMs: 0) == library)
        #expect(restarted.resolveTrack(Ids.TrackKeys(nameKey: dreams), durationMs: 0) == library)
        #expect(restarted.trackAliasCount == tables.trackAliasCount)
        // The length stored with the name key still tells another recording apart after the restart.
        #expect(restarted.resolveTrack(Ids.TrackKeys(videoId: "EDIT", nameKey: dreams), durationMs: 200_000) != library)
        // A second audio id of the same recording is found for the junk fallback.
        _ = restarted.resolveTrack(Ids.TrackKeys(videoId: "VID9", nameKey: dreams), durationMs: 257_500)
        #expect(restarted.otherVideoIds(rid: library, exceptVideoId: "VID1") == ["VID9"])
    }

    @Test func radioListsAreStoredTouchedCountedAndTrimmedByLastUse() throws {
        let directory = temporaryDirectory("radio")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tables = BrainTables(directory: directory)
        let rows = [StoredRadioRow(row: row(1, "S\u{01A1}n T\u{00F9}ng M-TP", title: "Ch\u{00FA}ng Ta"), rid: -42),
                    StoredRadioRow(row: row(2, "B"), rid: 7)]
        let chips = [RadioChip(label: "V-pop", playlistId: "RDATxyz", params: "abc"), RadioChip(label: "Popular", playlistId: "RDATq")]
        for seed in Int64(1)...4 {
            tables.upsertRadio(RadioList(seedRid: seed, kind: RadioList.kindSong, chip: "", fetchedAt: 100 * seed,
                                         lastUsedAt: 100 * seed, healthy: true, rows: rows, chips: chips))
        }
        tables.upsertRadio(RadioList(seedRid: 1, kind: RadioList.kindSong, chip: "+pages", fetchedAt: 500, lastUsedAt: 500,
                                     healthy: true, rows: Array(rows.prefix(1)), chips: []))
        #expect(tables.radioCount == 5)
        #expect(tables.radiosFetchedSince(300) == 3)
        #expect(tables.radioRows(seedRid: 2, kind: RadioList.kindSong, chip: "") == rows)
        #expect(tables.radioRows(seedRid: 1, kind: RadioList.kindSong, chip: "+pages").count == 1)
        #expect(tables.radioFacts(seedRid: 2, kind: RadioList.kindSong, chip: "")?.chips == chips)
        #expect(tables.radioFacts(seedRid: 9, kind: RadioList.kindSong, chip: "") == nil)
        #expect(tables.radioRows(seedRid: 9, kind: RadioList.kindSong, chip: "").isEmpty)

        tables.touchRadio(seedRid: 1, kind: RadioList.kindSong, chip: "", nowMs: 900)
        tables.trimRadios(to: 3)
        #expect(tables.radioCount == 3)
        // The least recently used went: seeds 2 and 3. Seed 1 was touched and stays.
        #expect(tables.radioFacts(seedRid: 2, kind: RadioList.kindSong, chip: "") == nil)
        #expect(tables.radioFacts(seedRid: 3, kind: RadioList.kindSong, chip: "") == nil)
        #expect(tables.radioRows(seedRid: 2, kind: RadioList.kindSong, chip: "").isEmpty)

        let restarted = BrainTables(directory: directory)
        #expect(restarted.radioCount == 3)
        #expect(restarted.radioFacts(seedRid: 1, kind: RadioList.kindSong, chip: "")?.lastUsedAt == 900)
        #expect(restarted.radioRows(seedRid: 4, kind: RadioList.kindSong, chip: "") == rows)
    }

    @Test func playableRowsSurviveARestartAndAreDeletedAfterSixtyDaysUnlessSomethingStillNamesThem() throws {
        let directory = temporaryDirectory("playable")
        defer { try? FileManager.default.removeItem(at: directory) }
        let day: Int64 = 24 * 60 * 60 * 1000
        let tables = BrainTables(directory: directory)
        let old = EngineTrack(row: row(1, "Old"), rid: 11).record(nowMs: 0)
        let queued = EngineTrack(row: row(2, "Queued"), rid: 12).record(nowMs: 0)
        let fresh = EngineTrack(row: row(3, "Fresh"), rid: 13).record(nowMs: 59 * day)
        tables.registerPlayable([old, queued, fresh])
        #expect(tables.playableCount == 3)
        #expect(tables.playable(songId: "yt:vid1")?.videoId == "vid1")
        #expect(tables.playable(songId: "yt:nope") == nil)

        // Registering the same pool again the same day writes nothing.
        let before = try Data(contentsOf: directory.appendingPathComponent("playable.pbl")).count
        var again = old
        again.lastUsedAt = 1_000
        tables.registerPlayable([again])
        let after = try Data(contentsOf: directory.appendingPathComponent("playable.pbl")).count
        #expect(before > 0 && before == after)

        let restarted = BrainTables(directory: directory)
        #expect(restarted.playable(songId: "yt:vid2")?.title == "Song 2")
        #expect(restarted.prunePlayable(keepSongIds: ["yt:vid2"], nowMs: 61 * day) == 1)
        #expect(restarted.playable(songId: "yt:vid1") == nil)
        #expect(restarted.playable(songId: "yt:vid2") != nil, "the saved queue still names it")
        #expect(restarted.playable(songId: "yt:vid3") != nil, "used a day ago")
        #expect(BrainTables(directory: directory).playableCount == 2)
    }

    @Test func anEngineTrackIsTheSongTheImporterWouldMake() {
        let track = EngineTrack(row: RadioRow(videoId: "J7p4bzqLvCw", title: "Blinding Lights",
                                              artists: [RadioArtistRef(name: "The Weeknd", channelId: "UCw"),
                                                        RadioArtistRef(name: "Guest", channelId: nil)],
                                              album: "After Hours", durationSec: 202, thumbnailUrl: "https://example.invalid/a.jpg",
                                              kind: .atv), rid: 99)
        #expect(track.songId == "yt:J7p4bzqLvCw")
        #expect(track.contentUri == "pixlstream://J7p4bzqLvCw")
        #expect(track.artistDisplay == "The Weeknd, Guest")
        let song = track.song(artistId: { $0 == "The Weeknd" ? 5 : 6 }, albumId: { _, _ in 7 }, nowMs: 123)
        #expect(song.id == "yt:J7p4bzqLvCw" && song.contentUriString == "pixlstream://J7p4bzqLvCw")
        #expect(song.artist == "The Weeknd, Guest" && song.artistId == 5 && song.albumId == 7)
        #expect(song.artists == [ArtistRef(id: 5, name: "The Weeknd", isPrimary: true), ArtistRef(id: 6, name: "Guest")])
        #expect(song.duration == 202_000 && song.albumArtUriString == "https://example.invalid/a.jpg")
        #expect(song.primaryArtist.name == "The Weeknd")
        #expect(EngineTrack(record: track.record(nowMs: 5)) == track)
        // A row that names nobody and no album still makes a song the queue can show.
        let bare = EngineTrack(row: RadioRow(videoId: "v", title: "t"), rid: 1).song()
        #expect(bare.artist == "Unknown Artist" && bare.album == "Unknown Album" && bare.artistId == -1)
    }
}

@Suite("Brain library index")
struct BrainLibraryIndexTests {
    private func song(_ id: String, _ title: String, _ artist: String, durationMs: Int64 = 200_000, artists: [String] = []) -> Song {
        Song(id: id, title: title, artist: artist, artistId: 1,
             artists: artists.enumerated().map { ArtistRef(id: Int64($0), name: $1, isPrimary: $0 == 0) },
             album: "Album", albumId: 1, path: "", contentUriString: "spotify://x", albumArtUriString: nil,
             duration: durationMs, mimeType: nil, bitrate: nil, sampleRate: nil)
    }

    private func row(_ title: String, _ artist: String, seconds: Int = 200) -> RadioRow {
        RadioRow(videoId: "v", title: title, artists: [RadioArtistRef(name: artist, channelId: "UCx")], durationSec: seconds,
                 kind: .atv)
    }

    @Test func aRadioRowMatchesTheLibraryRecordingAcrossSpellingCaseAndARemasterTag() {
        let dreams = song("1", "Dreams (2004 Remaster)", "Fleetwood Mac", durationMs: 257_000)
        let index = BrainLibraryIndex(songs: [dreams, song("2", "Ch\u{1EA1}y Ngay \u{0110}i", "S\u{01A1}n T\u{00F9}ng M-TP", durationMs: 248_000)])
        #expect(index.match(row("Dreams", "FLEETWOOD MAC", seconds: 258)) == dreams)
        #expect(index.match(row("CH\u{1EA0}Y NGAY \u{0110}I", "Son Tung M-TP", seconds: 249))?.id == "2")
        #expect(index.match(row("Dreams", "Someone Else", seconds: 258)) == nil)
        #expect(index.match(row("Rhiannon", "Fleetwood Mac", seconds: 258)) == nil)
        #expect(index.size == 2)
    }

    @Test func aDifferentLengthUnderTheSameNameIsAnotherRecording() {
        let index = BrainLibraryIndex(songs: [song("1", "Hello", "Adele", durationMs: 295_000)])
        #expect(index.match(row("Hello", "Adele", seconds: 180)) == nil)
        #expect(index.match(row("Hello", "Adele", seconds: 297))?.id == "1")
        #expect(index.match(row("Hello", "Adele", seconds: 0))?.id == "1")
        // A live version is not the studio recording.
        #expect(index.match(row("Hello (Live)", "Adele", seconds: 295)) == nil)
    }

    @Test func thePrimaryArtistIsTheFirstOfTheSplitList() {
        let joined = song("1", "EARFQUAKE", "Tyler, The Creator, Playboi Carti", artists: ["Tyler, The Creator", "Playboi Carti"])
        #expect(BrainLibraryIndex.primaryArtistName(joined) == "Tyler, The Creator")
        #expect(BrainLibraryIndex.artistKey(of: joined) == "tyler the creator")
        let index = BrainLibraryIndex(songs: [joined])
        #expect(index.match(row("EARFQUAKE", "Tyler, The Creator"))?.id == "1")
        #expect(index.byPrimaryArtist("tyler the creator") == [joined])
        #expect(index.byPrimaryArtist("playboi carti").isEmpty)
        // No split list: the legacy field is the fallback, as one name.
        #expect(BrainLibraryIndex.primaryArtistName(song("2", "Hello", "Adele")) == "Adele")
        #expect(BrainLibraryIndex.albumKey(of: "Unknown Album") == nil && BrainLibraryIndex.albumKey(of: "25") == "25")
    }

    @Test func theJunkDetectorFallsBackToTheFoldedNameOfASeedWithoutAChannelId() {
        func row(_ i: Int, _ name: String) -> RadioRow {
            RadioRow(videoId: "v\(i)", title: "t\(i)", artists: [RadioArtistRef(name: name, channelId: nil)], kind: .atv)
        }
        let seed = row(0, "S\u{01A1}n T\u{00F9}ng M-TP")
        let rows = [seed] + (0..<44).map { row($0 + 1, $0 == 5 ? "SON TUNG M-TP" : "Other \($0)") }
        #expect(!RadioRules.isJunkRadio(rows: rows, seedVideoId: "v0", seedArtistIds: [], fold: BrainText.fold))
        let none = [seed] + (0..<44).map { row($0 + 1, "Other \($0)") }
        #expect(RadioRules.isJunkRadio(rows: none, seedVideoId: "v0", seedArtistIds: [], fold: BrainText.fold))
    }
}

/// The five brain fields of the saved queue (docs/brain-spec.md, 4.2): an engine item must come back from a restart
/// as an engine item, and a queue saved by an earlier version must still load. Port of Android's
/// `PlaybackQueueSnapshotBrainFieldsTest`; the JSON field names are the same on both platforms.
@Suite("Queue snapshot brain fields")
struct QueueSnapshotBrainFieldsTests {
    private let engineTag = BrainItemTag(surface: Surface.nameOf(Surface.autoplay), surfaceId: "yt:J7p4bzqLvCw",
                                         recId: 446_464_000_001, slot: 3, arm: Arm.nameOf(Arm.radio))

    private func item(_ id: String) -> PlaybackQueueItemSnapshot {
        PlaybackQueueItemSnapshot(mediaId: id, uri: "pixlstream://J7p4bzqLvCw", title: "Title \(id)", artist: "Artist",
                                  albumTitle: "Album", artworkUri: "https://example.invalid/a.jpg", durationMs: 200_000)
    }

    @Test func saveAndRestoreKeepsTheFiveBrainFieldsOfAnEngineItem() throws {
        let saved = PlaybackQueueSnapshot(items: [item("user"), item("engine").withBrainTag(engineTag)],
                                          currentMediaId: "user", currentIndex: 0, savedAtEpochMs: 1)
        let restored = try JSONDecoder().decode(PlaybackQueueSnapshot.self, from: JSONEncoder().encode(saved))
        #expect(saved == restored)
        let engine = restored.items[1]
        #expect(engine.brainSurface == "autoplay")
        #expect(engine.brainSurfaceId == "yt:J7p4bzqLvCw")
        #expect(engine.brainRecId == 446_464_000_001)
        #expect(engine.brainSlot == 3)
        #expect(engine.brainArm == "RADIO")
        #expect(engine.brainTag() == engineTag)
        #expect(engine.brainTag()?.isEngineOwned == true)
        // The listener's own track has no tag and is not engine-owned after the restore either.
        #expect(restored.items[0].brainTag() == nil)
    }

    @Test func aQueueSavedByAnEarlierVersionDecodesUnchanged() throws {
        let old = #"""
        {"items":[{"mediaId":"sp:4uLU6hMCjMI75M1A2tKUQC","uri":"spotify://4uLU6hMCjMI75M1A2tKUQC","title":"Song",
        "artist":"Artist","albumTitle":"Album","artworkUri":null,"durationMs":201000}],
        "currentMediaId":"sp:4uLU6hMCjMI75M1A2tKUQC","currentIndex":0,"currentPositionMs":42000,"playWhenReady":true,
        "repeatMode":0,"shuffleEnabled":false,"savedAtEpochMs":1700000000000}
        """#
        let snapshot = try JSONDecoder().decode(PlaybackQueueSnapshot.self, from: Data(old.utf8))
        let item = try #require(snapshot.items.first)
        #expect(snapshot.items.count == 1 && item.durationMs == 201_000)
        #expect(item.brainSurface == nil && item.brainSurfaceId == nil && item.brainRecId == nil)
        #expect(item.brainSlot == nil && item.brainArm == nil && item.brainTag() == nil)
        #expect(snapshot.currentPositionMs == 42_000)
        // A queue Android saved with engine items decodes too: the field names are shared.
        let android = #"{"items":[{"mediaId":"-3000123","uri":"spotify://0123456789abcdef012345","brainSurface":"autoplay","brainRecId":7,"brainSlot":0,"brainArm":"RADIO"}]}"#
        let shared = try JSONDecoder().decode(PlaybackQueueSnapshot.self, from: Data(android.utf8))
        #expect(shared.items.first?.brainTag()?.isEngineOwned == true)
    }

    @Test func aQueueWithoutEngineItemsIsWrittenExactlyAsBefore() throws {
        let encoded = String(decoding: try JSONEncoder().encode(item("user")), as: UTF8.self)
        #expect(!encoded.contains("brain"), "\(encoded)")
        // An untagged item stays untagged.
        #expect(item("user").withBrainTag(nil) == item("user"))
        #expect(item("user").withBrainTag(BrainItemTag()) == item("user"))
    }

    @Test func aPlayTheListenerStartedKeepsItsSurfaceWithoutBecomingEngineOwned() throws {
        // Stage 1b tags plays the UI starts ("playlist", "album", ...) with a surface and no arm.
        let tag = BrainItemTag(surface: Surface.nameOf(Surface.playlist), surfaceId: "pl_abc")
        let restored = try JSONDecoder().decode(PlaybackQueueItemSnapshot.self,
                                                from: JSONEncoder().encode(item("user").withBrainTag(tag)))
        #expect(restored.brainTag() == tag)
        #expect(restored.brainTag()?.isEngineOwned == false)
        #expect(restored.brainRecId == nil, "0 is not written")
        #expect(restored.brainSlot == nil, "-1 is not written")
        #expect(restored.brainArm == nil)
        #expect(BrainItemTag().isEmpty)
        // The surface id is cut at 40 characters, as on Android.
        #expect(BrainItemTag(surfaceId: String(repeating: "x", count: 50)).surfaceId?.count == 40)
    }
}
