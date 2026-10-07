import Foundation
import PixlFoundation
import PixlLibrary
import PixlModel
import Testing
@testable import PixlBackup

@Suite struct JavaNumberTextTests {
    @Test func doublesPrintLikeJava() {
        let cases: [(Double, String)] = [
            (100.0, "100.0"), (1e7, "1.0E7"), (9_999_999.0, "9999999.0"), (0.001, "0.001"), (0.0001, "1.0E-4"),
            (123_456_789.125, "1.23456789125E8"), (12_345_678.9, "1.23456789E7"), (1_234_567.0, "1234567.0"), (2.5, "2.5"),
            (-0.0, "-0.0"), (0.0, "0.0"), (.nan, "NaN"), (.infinity, "Infinity"), (-.infinity, "-Infinity"),
            (.greatestFiniteMagnitude, "1.7976931348623157E308"), (1e23, "1.0E23"), (0.1, "0.1"), (-1.5e-7, "-1.5E-7"),
            (1.2345678901234568e20, "1.2345678901234568E20"), (1.0, "1.0"), (10.0, "10.0"), (0.5, "0.5"),
        ]
        for (value, expected) in cases { #expect(JavaNumberText.double(value) == expected, "\(value)") }
    }

    @Test func floatsPrintLikeJava() {
        let cases: [(Float, String)] = [
            (0.1, "0.1"), (1e10, "1.0E10"), (1e-5, "1.0E-5"), (3.4028235e38, "3.4028235E38"), (0.3, "0.3"), (2.5, "2.5"),
            (6.0, "6.0"), (0.25, "0.25"), (-0.0, "-0.0"), (1e7, "1.0E7"), (9_999_999, "9999999.0"),
        ]
        for (value, expected) in cases { #expect(JavaNumberText.float(value) == expected, "\(value)") }
    }

    @Test func javaParsingRules() {
        #expect(JavaNumbers.parseLong("+5") == 5)
        #expect(JavaNumbers.parseLong("-0") == 0)
        #expect(JavaNumbers.parseLong(" 5") == nil)
        #expect(JavaNumbers.parseLong("9223372036854775808") == nil)
        #expect(JavaNumbers.parseLong("-9223372036854775808") == .min)
        #expect(JavaNumbers.parseLong("١٢") == 12) // Arabic-Indic digits (Character.digit)
        #expect(JavaNumbers.parseInt("2147483648") == nil)
        #expect(JavaNumbers.parseDouble(" 5 ") == 5)
        #expect(JavaNumbers.parseDouble("5f") == 5)
        #expect(JavaNumbers.parseDouble("0x10p0") == 16)
        #expect(JavaNumbers.parseDouble("1.") == 1)
        #expect(JavaNumbers.parseDouble(".5") == 0.5)
        #expect(JavaNumbers.parseDouble("") == nil)
        #expect(JavaNumbers.parseDouble("1e") == nil)
        #expect(JavaNumbers.parseDouble("NaN")?.isNaN == true)
        #expect(JavaNumbers.bigDecimalLongValue("12.9") == 12)
        #expect(JavaNumbers.bigDecimalLongValue("-1.5") == -1)
        #expect(JavaNumbers.bigDecimalLongValue("1e3") == 1000)
        #expect(JavaNumbers.bigDecimalLongValue("9223372036854775808") == .min)
    }
}

@Suite struct GsonSemanticsTests {
    @Test func lenientTokensAndEmptyDocuments() throws {
        #expect(try Gson.parse("") == nil)
        #expect(try Gson.parse(" \n\t") == nil)
        #expect(try Gson.parseTree("") == .null)
        #expect(try Gson.parse("[TRUE, False, NULL, abc, 01, 1e2]") == .array([.bool(true), .bool(false), .null, .string("abc"),
                                                                              .string("01"), .number("1e2")]))
        #expect(throws: GsonError.self) { try Gson.parse("[1] x") }
        #expect(throws: GsonError.self) { try Gson.parse("{'a': 1}") }
    }

    @Test func readerConversions() throws {
        #expect(try GsonRead.long(.string("5.0")) == 5)
        #expect(try GsonRead.long(.number("1e3")) == 1000)
        #expect(throws: GsonError.self) { try GsonRead.long(.number("1.5")) }
        #expect(throws: GsonError.self) { try GsonRead.long(.bool(true)) }
        #expect(try GsonRead.long(.number("9223372036854775808")) == .max)
        #expect(throws: GsonError.self) { try GsonRead.int(.number("2147483648")) }
        #expect(try GsonRead.int(.string("2.0")) == 2)
        #expect(try GsonRead.bool(.string("TrUe")) == true)
        #expect(try GsonRead.bool(.string("yes")) == false)
        #expect(throws: GsonError.self) { try GsonRead.bool(.number("1")) }
        #expect(try GsonRead.string(.bool(false)) == "false")
        #expect(try GsonRead.float(.number("0.30000001192092896")) == 0.3)
        #expect(try GsonRead.enumName(.string("BOGUS"), allowed: ["A"]) == nil)
        #expect(throws: GsonError.self) { try GsonRead.enumName(.bool(true), allowed: ["A"]) }
        // Maps: duplicate keys fail unless the earlier value was null; arrays of pairs are accepted.
        #expect(throws: GsonError.self) { try GsonRead.map(Gson.parseTree("{\"a\": \"x\", \"a\": \"y\"}"), GsonRead.string) }
        let replaced = try GsonRead.map(Gson.parseTree("{\"a\": null, \"a\": \"y\"}"), GsonRead.string)
        #expect(replaced?["a"] == .some("y"))
        let pairs = try GsonRead.map(Gson.parseTree("[[\"k\", \"v\"], [1, 2]]"), GsonRead.string)
        #expect(pairs?.entries.map(\.key) == ["k", "1"])
        #expect(try GsonRead.stringSet(Gson.parseTree("[\"b\", \"a\", \"b\", null, null]")) == ["b", "a", nil])
    }

    @Test func elementAccessors() throws {
        #expect(try GsonElement.asString(.array([.number("5")])) == "5")
        #expect(throws: GsonError("IllegalStateException", "Array must have size 1, but has size 2")) {
            try GsonElement.asString(.array([.number("1"), .number("2")]))
        }
        #expect(throws: GsonError("UnsupportedOperationException", "JsonNull")) { try GsonElement.asLong(.null) }
        #expect(try GsonElement.asLong(.number("99999999999999999999")) == 7_766_279_631_452_241_919)
        #expect(try GsonElement.asInt(.number("3000000000")) == -1_294_967_296)
        #expect(throws: GsonError.self) { try GsonElement.memberArray(JSONObject([("a", .null)]), "a") }
        #expect(try GsonElement.memberArray(JSONObject([("a", .array([]))]), "b") == nil)
        // JsonObject keeps the last duplicate.
        #expect(Gson.member(JSONObject([("a", .number("1")), ("a", .number("2"))]), "a") == .number("2"))
    }

    @Test func writerEscapesLikeGson() {
        var out = ""
        GsonWriter.writeString("<a href='x'>&=\u{2028}\u{7F}é\u{1}", into: &out)
        #expect(out == "\"\\u003ca href\\u003d\\u0027x\\u0027\\u003e\\u0026\\u003d\\u2028\u{7F}é\\u0001\"")
        #expect(GsonWriter.plain(.object(JSONObject([("a", .null), ("b", .number("1"))]))) == "{\"b\":1}")
        #expect(GsonWriter.backup(.object(JSONObject([("a", .null), ("b", .array([]))]))) == "{\n  \"a\": null,\n  \"b\": []\n}")
    }
}

@Suite struct PreferenceTests {
    @Test func valueCoercionsFollowImportPreferencesFromBackup() {
        typealias E = AndroidBackup.PreferenceBackupEntry
        #expect(E(key: "k", type: "int", doubleValue: 2.9).resolvedValue == .int(2))
        #expect(E(key: "k", type: "int", longValue: 4_294_967_297).resolvedValue == .int(1))
        #expect(E(key: "k", type: "long", intValue: 5).resolvedValue == .long(5))
        #expect(E(key: "k", type: "long", doubleValue: 1e19).resolvedValue == .long(.max))
        #expect(E(key: "k", type: "float", doubleValue: 0.5).resolvedValue == .float(0.5))
        #expect(E(key: "k", type: "double", floatValue: 0.1).resolvedValue == .double(Double(Float(0.1))))
        #expect(E(key: "k", type: "string").resolvedValue == nil)
        #expect(E(key: "k", type: "STRING", stringValue: "x").resolvedValue == nil)
        #expect(E(key: "k", type: "string_set", stringSetValue: ["a", nil]).resolvedValue == .stringSet(["a"]))
    }

    @Test func catalogueKinds() {
        #expect(AndroidPreferenceCatalog.kind(of: "app_theme_mode") == .portable)
        #expect(AndroidPreferenceCatalog.kind(of: "gemini_api_key") == .portable)
        #expect(AndroidPreferenceCatalog.kind(of: "openrouter_base_url") == .portable)
        #expect(AndroidPreferenceCatalog.kind(of: "nav_bar_corner_radius") == .androidOnly)
        #expect(AndroidPreferenceCatalog.kind(of: "album_art_palette_style_v1") == .androidOnly)
        #expect(AndroidPreferenceCatalog.kind(of: "playback_queue_snapshot_v1") == .deviceState)
        #expect(AndroidPreferenceCatalog.kind(of: "lyrics_sync_offsets_json") == .deviceIds)
        #expect(AndroidPreferenceCatalog.kind(of: "something_new") == nil)
        // iOS-only settings (owner requests) restore by name like the portable keys.
        #expect(AndroidPreferenceCatalog.kind(of: "accent_color_v1") == .portable)
        // Retired on iOS: the lyrics screen always keeps the screen on.
        #expect(AndroidPreferenceCatalog.kind(of: "keep_screen_on_lyrics") == .androidOnly)
        // The catalogue lists every key once.
        let all = AndroidPreferenceCatalog.portable + AndroidPreferenceCatalog.androidOnly + AndroidPreferenceCatalog.deviceState
            + AndroidPreferenceCatalog.deviceIds + AndroidPreferenceCatalog.iosOnly
        #expect(Set(all).count == all.count)
    }

    /// The accent colour (iOS-only) round-trips through a global-settings export and restore; a backup without it
    /// (older iOS backups, Android backups) restores cleanly and clears it like every portable key.
    @Test func iosOnlyAccentColorRoundTripsAndOldBackupsClearIt() throws {
        let payload = PreferencesModule.export(.globalSettings, values: [
            ("app_theme_mode", .string("dark")), ("accent_color_v1", .string("#FF453A")),
        ])
        let restored = try PreferencesModule.restore(.globalSettings, payload: payload)
        #expect(restored.values.map(\.key) == ["app_theme_mode", "accent_color_v1"])
        #expect(restored.values.last?.value == .string("#FF453A"))
        #expect(restored.skippedKeys.isEmpty)

        let old = AndroidBackup.PreferenceBackupEntry.encodeList([.string("app_theme_mode", "light")])
        let oldRestore = try PreferencesModule.restore(.globalSettings, payload: old)
        #expect(oldRestore.values.map(\.key) == ["app_theme_mode"])
        #expect(oldRestore.skippedKeys.isEmpty)
        guard case .allExcept(let kept) = oldRestore.clear else {
            Issue.record("a global-settings restore clears every portable key but the dedicated modules'")
            return
        }
        #expect(!kept.contains("accent_color_v1"))
    }

    /// "Keep screen on" left the lyrics More sheet (2026-10-07: always on). A backup that still carries it (Android,
    /// or iOS from before) restores cleanly: the key is reported under skipped settings and never written.
    @Test func retiredKeepScreenOnIsSkippedAndReported() throws {
        let old = AndroidBackup.PreferenceBackupEntry.encodeList([
            .boolean("keep_screen_on_lyrics", true), .string("app_theme_mode", "dark"),
        ])
        let restored = try PreferencesModule.restore(.globalSettings, payload: old)
        #expect(restored.values.map(\.key) == ["app_theme_mode"])
        #expect(restored.skippedAndroidOnly == ["keep_screen_on_lyrics"])
        #expect(restored.skippedKeys.contains("keep_screen_on_lyrics"))
        #expect(restored.unknownKeys.isEmpty)
        #expect(restored.ignored.isEmpty)
    }

    @Test func restoreScopesAndReport() throws {
        let payload = AndroidBackup.PreferenceBackupEntry.encodeList([
            .string("app_theme_mode", "dark"), .boolean("initial_setup_done", true), .int("nav_bar_corner_radius", 28),
            .string("app_theme_mode", "light"), .string("brand_new_key", "x"), AndroidBackup.PreferenceBackupEntry(key: "k", type: "bogus"),
            .long("last_daily_mix_update", 5), .stringSet("daily_mix_song_ids", ["1"]),
        ])
        let global = try PreferencesModule.restore(.globalSettings, payload: payload)
        #expect(global.clear == .allExcept(PreferencesModule.globalExcludedKeys))
        #expect(global.values.map(\.key) == ["app_theme_mode"])
        #expect(global.values.first?.value == .string("light"))
        #expect(global.skippedAndroidOnly == ["nav_bar_corner_radius"])
        #expect(global.skippedDeviceState == ["last_daily_mix_update"])
        #expect(global.skippedDeviceIds == ["daily_mix_song_ids"])
        #expect(global.unknownKeys == ["brand_new_key"])
        #expect(global.ignored == ["initial_setup_done", "k"])
        #expect(try PreferencesModule.restore(.quickFill, payload: "[]").clear == .only(["custom_genres", "custom_genre_icons"]))
        #expect(try PreferencesModule.restore(.equalizer, payload: "[]").clear == .only(["custom_presets_json", "pinned_presets_json"]))
        #expect(throws: BackupError.self) { try PreferencesModule.restore(.globalSettings, payload: "") }
        #expect(throws: BackupError.self) { try PreferencesModule.restore(.globalSettings, payload: "[null]") }
    }

    @Test func exportFiltersOwnedKeys() throws {
        let values: [(key: String, value: PreferenceValue)] = [
            ("app_theme_mode", .string("dark")), ("custom_presets_json", .string("[]")), ("custom_genres", .stringSet(["a"])),
            ("user_playlists_json_v1", .string("[]")), ("initial_setup_done", .bool(true)), ("ai_temperature", .float(0.7)),
        ]
        let global = try PreferencesModule.decode(payload: PreferencesModule.export(.globalSettings, values: values))
        #expect(global.map(\.key) == ["app_theme_mode", "ai_temperature"])
        let eq = try PreferencesModule.decode(payload: PreferencesModule.export(.equalizer, values: values))
        #expect(eq.map(\.key) == ["custom_presets_json"])
        let quick = try PreferencesModule.decode(payload: PreferencesModule.export(.quickFill, values: values))
        #expect(quick.map(\.key) == ["custom_genres"])
        #expect(quick.first?.stringSetValue == ["a"])
    }

    @Test func unreadablePinnedPresetsFallBackToBuiltIns() {
        let restore = PreferencesModule.plan([.string("pinned_presets_json", "not json")], clear: .only([]))
        #expect(PreferencesModule.pinnedPresets(from: restore) == EqualizerPreset.allPresets.map(\.name))
        #expect(PreferencesModule.customPresets(from: restore) == [])
    }
}

@Suite struct PlaylistsModuleTests {
    let library = [
        BackupSongSummary(id: "a", title: "One", artistName: "X", albumName: "L", duration: 1000),
        BackupSongSummary(id: "b", title: "Two", artistName: "X", albumName: "L", duration: 2000),
    ]

    @Test func malformedJsonThrowsButAnUnbindableObjectRestoresEmpty() throws {
        #expect(throws: BackupError.self) { try PlaylistsModule.restore(payload: "{", library: library) }
        let empty = try PlaylistsModule.restore(payload: "{\"playlists\": 5}", library: library)
        #expect(empty.playlists.isEmpty)
        #expect(empty.playlistsSortOption == SortOption.playlistNameAZ.storageKey)
        #expect(try PlaylistsModule.restore(payload: "null", library: library).playlists.isEmpty)
    }

    @Test func unresolvedSongsKeepAPendingPayloadThatResolvesLater() throws {
        let payload = AndroidBackup.PlaylistsBackupPayload(
            playlists: [.init(id: "p", name: "P", songIds: ["7", "8"])],
            songMetadata: GsonMap([("7", .init(title: "One", artist: "X", album: "L", duration: 1000)),
                                   ("8", .init(title: "Three", artist: "X", album: "L", duration: 3000))]))
        let json = GsonWriter.backup(payload.gsonTree)
        let restore = try PlaylistsModule.restore(payload: json, library: library)
        #expect(restore.playlists.first?.songIds == ["a"])
        #expect(restore.unresolvedCount == 1)
        #expect(restore.pendingPayload == json)
        // Before the scan nothing changes; after "Three" is imported the playlist grows and the payload is done.
        let before = PlaylistsModule.resolvePending(payload: json, current: restore.playlists, library: library)
        #expect(before.updated == nil && !before.done)
        let scanned = library + [BackupSongSummary(id: "c", title: "Three", artistName: "X", albumName: "L", duration: 3000)]
        let after = PlaylistsModule.resolvePending(payload: json, current: restore.playlists, library: scanned)
        #expect(after.updated?.first?.songIds == ["a", "c"])
        #expect(after.done)
    }

    @Test func legacyArrayRestore() throws {
        let playlistsJson = AndroidBackup.PlaylistRecord.encodeList([.init(id: "old", name: "Old", songIds: ["1", nil])])
        let payload = AndroidBackup.PreferenceBackupEntry.encodeList([
            .string("user_playlists_json_v1", playlistsJson), .string("playlist_song_order_modes", "{\"old\":\"manual\"}"),
        ])
        let restore = try PlaylistsModule.restore(payload: payload, library: library)
        #expect(restore.playlists.map(\.songIds) == [["1"]])
        #expect(restore.playlistSongOrderModes == ["old": "manual"])
        #expect(restore.playlistsSortOption == "playlist_name_az")
        // An unreadable playlists string restores no playlists (Android's runCatching default).
        let broken = AndroidBackup.PreferenceBackupEntry.encodeList([.string("user_playlists_json_v1", "{oops")])
        #expect(try PlaylistsModule.restore(payload: broken, library: library).playlists.isEmpty)
    }

    @Test func exportKeepsLocalPlaylistsAndWritesMetadata() throws {
        let playlists = [
            Playlist(id: "l", name: "Local", songIds: ["a", "sp:1", "yt:2", "missing"], createdAt: 1, lastModified: 2),
            Playlist(id: "s", name: "Cloud", songIds: ["a"], createdAt: 1, lastModified: 2, source: "SPOTIFY"),
        ]
        let json = PlaylistsModule.export(playlists: playlists, library: library, playlistSongOrderModes: [],
                                          playlistsSortOption: "playlist_name_az", extraSongIds: ["b", "yt:9"])
        let decoded = try #require(try AndroidBackup.PlaylistsBackupPayload.decode(json))
        #expect(decoded.playlists?.compactMap { $0?.id } == ["l"])
        #expect(decoded.playlists?.first??.songIds == ["a", "missing"])
        #expect(decoded.songMetadata?.keys == ["a", "b"])
        #expect(decoded.coverImages == nil)
        #expect(decoded.playlistSongOrderModes == GsonMap())
        let snapshot = PlaylistsModule.snapshot(playlists: playlists, playlistSongOrderModes: [("l", "manual")], playlistsSortOption: "x")
        let snap = try #require(try AndroidBackup.PlaylistsBackupPayload.decode(snapshot))
        #expect(snap.playlists?.count == 2 && snap.songMetadata == nil)
    }

    @Test func base64LikeAndroid() {
        #expect(BackupBase64.encode([]) == "")
        #expect(BackupBase64.encode(Array("f".utf8)) == "Zg==")
        #expect(BackupBase64.encode(Array("fo".utf8)) == "Zm8=")
        #expect(BackupBase64.encode(Array("foo".utf8)) == "Zm9v")
        #expect(BackupBase64.decode("Zm9vYg==") == Array("foob".utf8))
        #expect(BackupBase64.decode("Zm9vYg") == Array("foob".utf8))
        #expect(BackupBase64.decode("Zm9v\nYmFy") == Array("foobar".utf8))
        #expect(BackupBase64.decode("Zm9v!") == nil)
        #expect(BackupBase64.decode("Z") == nil)
        #expect(BackupBase64.decode("Zg=a") == nil)
        let bytes = (0..<300).map { UInt8($0 % 256) }
        #expect(BackupBase64.decode(BackupBase64.encode(bytes)) == bytes)
    }
}

@Suite struct DataModuleTests {
    @Test func lyricsRowsUseGsonsTreeReader() throws {
        let (rows, files) = try LyricsModule.restore(payload: """
            [{"songId": 1.9, "content": "x"}, {"song_id": "12", "content": "y", "isSynced": "true"},
             {"jsonFile": "yt_1.json", "json": "{}"}, {"jsonFile": "42.json", "json": "{}"}, {"jsonFile": ".hidden.json", "json": "{}"},
             {"jsonFile": "a/b.json", "json": "{}"}, {"jsonFile": "x.txt", "json": "{}"}, {"jsonFile": "ok.json"}, 5]
            """)
        #expect(rows.map(\.backupSongId) == ["1", "12"])
        #expect(rows[1].isSynced)
        #expect(files.map(\.fileName) == ["yt_1.json"])
        #expect(files.first?.songId == "yt_1")
        #expect(throws: BackupError.self) { try LyricsModule.restore(payload: "[{\"songId\": \"5.0\", \"content\": \"x\"}]") }
        #expect(throws: BackupError.self) { try LyricsModule.restore(payload: "[{\"songId\": 5}]") }
        #expect(throws: BackupError.self) { try LyricsModule.restore(payload: "{}") }
    }

    @Test func lyricsExportRoundTripsWithPixlIds() throws {
        let json = LyricsModule.export(rows: [LyricsBackupRow(backupSongId: "f:x/y.flac", content: "[00:01.00]a", isSynced: true, source: nil)],
                                       files: [LyricsBackupFile(fileName: "yt_9.json", json: "{\"plainLyrics\":\"p\"}"),
                                               LyricsBackupFile(fileName: "../x.json", json: "{}")])
        #expect(json.contains("\"pixlSongId\": \"f:x/y.flac\""))
        let (rows, files) = try LyricsModule.restore(payload: json)
        #expect(rows == [LyricsBackupRow(backupSongId: "f:x/y.flac", content: "[00:01.00]a", isSynced: true, source: nil)])
        #expect(files.map(\.fileName) == ["yt_9.json"])
        #expect(files.first?.cacheData?.plainLyrics == "p")
        #expect(try ModuleSchemaValidator.validate(.lyrics, payload: json) == .valid)
    }

    @Test func numericIdsForPixlSongs() {
        #expect(BackupSongIds.numericId(for: "123") == 123)
        let id = BackupSongIds.numericId(for: "f:Music/a.flac")
        #expect(id >= 1 << 52 && id < 1 << 53)
        #expect(BackupSongIds.numericId(for: "f:Music/a.flac") == id)
        #expect(BackupSongIds.numericId(for: "f:Music/b.flac") != id)
        #expect(BackupSongIds.isCloudSong("sp:1") && BackupSongIds.isCloudSong("yt:1") && !BackupSongIds.isCloudSong("mp:1"))
    }

    @Test func requiredListsFailLikeKotlinNonNullAssignments() {
        #expect(throws: BackupError("Favorites payload is empty.")) { try FavoritesModule.restore(payload: "") }
        #expect(throws: BackupError("Favorites payload is empty.")) { try FavoritesModule.restore(payload: "null") }
        #expect(throws: BackupError("Favorites payload contains a null entry.")) { try FavoritesModule.restore(payload: "[null]") }
        #expect(throws: BackupError.self) { try FavoritesModule.restore(payload: "[{\"songId\": \"x\"}]") }
        #expect(throws: BackupError.self) { try SearchHistoryModule.restore(payload: "[{\"id\": 1}]") }
        #expect(throws: BackupError.self) { try TransitionsModule.restore(payload: "[{\"playlistId\": \"p\", \"settings\": {\"mode\": \"BOGUS\"}}]") }
        #expect(throws: BackupError.self) { try TransitionsModule.restore(payload: "[{\"settings\": {}}]") }
        #expect(throws: BackupError.self) { try PlaybackHistoryModule.restore(payload: "[{\"timestamp\": 5}]") }
        #expect(throws: BackupError.self) { try AiUsageModule.restore(payload: "[{\"timestamp\": 1}]") }
        #expect(throws: BackupError("Engagement stats payload must be a JSON array.")) {
            try EngagementStatsModule.restore(payload: "{}")
        }
    }

    @Test func playbackHistoryIsSanitisedAndDeduplicated() throws {
        let events = try PlaybackHistoryModule.restore(payload: """
            [{"songId": "b", "timestamp": 20, "durationMs": 5}, {"songId": "a", "timestamp": 10, "durationMs": -5},
             {"songId": "b", "timestamp": 20, "durationMs": 5}]
            """)
        #expect(events == [PlaybackEvent(songId: "a", timestamp: 10, durationMs: 0, startTimestamp: 10, endTimestamp: 10),
                           PlaybackEvent(songId: "b", timestamp: 20, durationMs: 5, startTimestamp: 15, endTimestamp: 20)])
    }

    @Test func artistImagesSkipNamelessEntriesAndBadBase64() throws {
        let images = try ArtistImagesModule.restore(payload: """
            [{"artistName": "A", "imageUrl": "  ", "customImageBase64": "!!"}, {"imageUrl": "https://x"}]
            """)
        #expect(images == [ArtistImageRestore(artistName: "A", imageUrl: nil, customImage: nil)])
    }
}

@Suite struct ContainerValidationTests {
    /// A ZIP holding one DEFLATE entry (Java level-9 zeros: 300,000 bytes from about 400).
    func bombArchive(name: String) throws -> [UInt8] {
        let cases = try goldenLines("inflate-cases.jsonl")
        let zeros = try #require(cases.first { $0["size"]!.i64 == 300_000 && $0["level"]!.i64 == 9 })
        let data = Array(Data(base64Encoded: zeros["deflate"]!.str)!)
        let crc = CRC32.checksum([UInt8](repeating: 0, count: 300_000))
        var out: [UInt8] = []
        func u16(_ v: Int) { out += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func u32(_ v: UInt32) { out += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
        let nameBytes = Array(name.utf8)
        u32(0x0403_4B50); u16(20); u16(0); u16(8); u16(0); u16(0); u32(crc); u32(UInt32(data.count)); u32(300_000)
        u16(nameBytes.count); u16(0); out += nameBytes; out += data
        let central = out.count
        u32(0x0201_4B50); u16(20); u16(20); u16(0); u16(8); u16(0); u16(0); u32(crc); u32(UInt32(data.count)); u32(300_000)
        u16(nameBytes.count); u16(0); u16(0); u16(0); u16(0); u32(0); u32(0); out += nameBytes
        let end = out.count
        u32(0x0605_4B50); u16(0); u16(0); u16(1); u16(1); u32(UInt32(end - central)); u32(UInt32(central)); u16(0)
        return BackupFormatDetector.pxplMagic + out
    }

    func archive(_ entries: [(String, [UInt8])]) -> [UInt8] {
        var zip = ZipWriter()
        for (name, data) in entries { zip.addStored(name: name, data: data) }
        return BackupFormatDetector.pxplMagic + zip.finish()
    }

    func codes(_ result: BackupValidationResult) -> [String] { result.errors.map(\.code) }

    @Test func fileLevelChecks() throws {
        #expect(codes(BackupFileValidator.validate(bytes: [], fileName: "a.pxpl", fileSize: 0)) == ["FILE_EMPTY"])
        #expect(codes(BackupFileValidator.validate(bytes: [0x7B], fileName: "a.pxpl", fileSize: 60 * 1024 * 1024)) == ["FILE_TOO_LARGE"])
        #expect(codes(BackupFileValidator.validate(bytes: [1, 2, 3, 4, 5, 6, 7, 8], fileName: "a.bin", fileSize: 8))
                == ["FILE_EXTENSION", "FORMAT_UNKNOWN"])
        let json = Array("{\"a\": 1}".utf8)
        #expect(BackupFileValidator.validate(bytes: json, fileName: "A.PXPL", fileSize: 8) == .valid)
        #expect(BackupFileValidator.validate(bytes: json, fileName: "a.GZ", fileSize: 8) == .valid)
        #expect(BackupFileValidator.validate(bytes: json, fileName: nil, fileSize: nil) == .valid)
        // Fewer than four bytes can never be recognised (Android's detector needs the magic's length).
        #expect(codes(BackupFileValidator.validate(bytes: Array("{}".utf8), fileName: "a.pxpl", fileSize: 2)) == ["FORMAT_UNKNOWN"])
        #expect(codes(BackupFileValidator.validate(bytes: Array("PXPLPK\u{3}\u{4}garbage".utf8), fileName: "a.pxpl", fileSize: 15))
                == ["ZIP_CORRUPT"])
    }

    @Test func zipEntryChecks() throws {
        let traversal = archive([("manifest.json", Array("{}".utf8)), ("../evil.json", [])])
        #expect(BackupFileValidator.validate(bytes: traversal, fileName: "a.pxpl", fileSize: nil).errors
                == [ValidationError(code: "ZIP_PATH_TRAVERSAL", message: "Suspicious zip entry path: ../evil.json")])
        let unexpected = archive([("manifest.json", Array("{}".utf8)), ("cover.jpg", [1, 2, 3])])
        let result = BackupFileValidator.validate(bytes: unexpected, fileName: "a.pxpl", fileSize: Int64(unexpected.count))
        #expect(codes(result) == ["ZIP_UNEXPECTED_ENTRY"])
        #expect(result.isValid)
        let bigManifest = archive([("manifest.json", [UInt8](repeating: 0x20, count: BackupReader.maxManifestBytes + 1))])
        #expect(BackupFileValidator.validate(bytes: bigManifest, fileName: "a.pxpl", fileSize: nil).errors
                == [ValidationError(code: "ZIP_ENTRY_TOO_LARGE",
                                    message: "Backup entry 'manifest.json' exceeds the 0MB in-memory safety limit.")])
    }

    @Test func compressionBombsAreCaught() throws {
        let bomb = try bombArchive(name: "favorites.json")
        #expect(BackupFileValidator.validate(bytes: bomb, fileName: "a.pxpl", fileSize: Int64(bomb.count)).errors
                == [ValidationError(code: "ZIP_BOMB", message: "Backup file has suspicious compression ratio.")])
        // Without a known file size the ratio cannot be checked; the 300 kB entry is within the limits.
        #expect(BackupFileValidator.validate(bytes: bomb, fileName: "a.pxpl", fileSize: nil) == .valid)
    }

    @Test func readerMessages() throws {
        #expect(throws: BackupError("Unrecognized backup file format")) { try BackupReader(bytes: [0, 1, 2, 3]).readManifest() }
        #expect(throws: BackupError("Manifest not found in backup archive")) {
            try BackupReader(bytes: archive([("favorites.json", Array("[]".utf8))])).readManifest()
        }
        #expect(throws: BackupError("Backup entry 'manifest.json' exceeds the 0MB in-memory safety limit.")) {
            try BackupReader(bytes: archive([("manifest.json", [UInt8](repeating: 0x20, count: BackupReader.maxManifestBytes + 1))])).readManifest()
        }
        let legacy = Array("{\"formatVersion\": 2, \"availableSections\": []}".utf8)
        #expect(throws: BackupError("Module 'favorites' not found in legacy backup")) { try BackupReader(bytes: legacy).readModulePayload("favorites") }
        #expect(throws: BackupError.self) { try BackupReader(bytes: Array("PXPL\u{1F}\u{8B}\u{8}\u{0}xx".utf8)).readManifest() }
        // Non-.json entries and the manifest are not module payloads.
        let mixed = archive([("manifest.json", Array("{}".utf8)), ("a.json", Array("[1]".utf8)), ("b.txt", [1]), ("a.json", Array("[2]".utf8))])
        let all = try BackupReader(bytes: mixed).readAllModulePayloads()
        #expect(all.keys == ["a"])
        #expect(all["a"] == .some("[2]"))
        #expect(try BackupReader(bytes: mixed).readModulePayload("a") == "[1]")
    }

    @Test func historyListRules() {
        func entry(_ uri: String) -> BackupHistoryEntry {
            BackupHistoryEntry(uri: uri, displayName: uri, createdAt: 0, schemaVersion: 3, modules: [], sizeBytes: 0)
        }
        var history: [BackupHistoryEntry] = []
        for i in 0..<12 { history = BackupHistory.adding(entry("u\(i)"), to: history) }
        #expect(history.count == 10)
        #expect(history.first?.uri == "u11")
        history = BackupHistory.adding(entry("u5"), to: history)
        #expect(history.first?.uri == "u5" && history.filter { $0.uri == "u5" }.count == 1)
        #expect(BackupHistory.removing(uri: "u5", from: history).count == 9)
    }

    @Test func progressFraction() {
        #expect(BackupTransferProgressUpdate(operation: .export, step: 1, totalSteps: 4, title: "", detail: "").progress == 0.25)
        #expect(BackupTransferProgressUpdate(operation: .export, step: 9, totalSteps: 4, title: "", detail: "").progress == 1)
        #expect(BackupTransferProgressUpdate(operation: .export, step: 1, totalSteps: 0, title: "", detail: "").progress == 0)
    }
}
