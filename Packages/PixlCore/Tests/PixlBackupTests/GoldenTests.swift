import Foundation
import PixlFoundation
import PixlLibrary
import PixlModel
import Testing
@testable import PixlBackup

/// Every vector of `backup-android-golden.jsonl`: the Android app's compiled backup classes, Gson 2.14 and the
/// JDK zip streams run on the JVM by `tools/android-reference/BackupGen.java`.
@Suite struct BackupGoldenTests {
    static let lines: [JSONValue] = (try? goldenLines("backup-android-golden.jsonl")) ?? []

    func lines(_ fn: String) -> [(input: JSONValue, output: JSONValue)] {
        Self.lines.filter { $0["fn"]?.str == fn }.map { ($0["in"]!, $0["out"]!) }
    }

    @Test func fixtureIsComplete() {
        #expect(Self.lines.count == 764)
    }

    @Test func formatDetectionMatchesAndroid() {
        let cases = lines("detect")
        #expect(cases.count == 26)
        for (input, output) in cases {
            #expect(BackupFormatDetector.detect(hexBytes(input.str)).rawValue == output.str, "header \(input.str)")
        }
    }

    @Test func sanitizerMatchesAndroid() {
        var count = 0
        for (input, output) in lines("sanitizeString") {
            count += 1
            #expect(ContentSanitizer.sanitizeString(input["s"]!.str, maxLength: Int(input["max"]!.i64)) == output.str,
                    "sanitizeString \(input)")
        }
        for (input, output) in lines("sanitizeUrl") {
            count += 1
            #expect(ContentSanitizer.sanitizeUrl(input["s"]!.str, maxLength: Int(input["max"]!.i64)) == output.str,
                    "sanitizeUrl \(input)")
        }
        for (input, output) in lines("isValidModuleKey") {
            count += 1
            #expect(ContentSanitizer.isValidModuleKey(input.str) == output.bool, "isValidModuleKey \(input.str)")
        }
        #expect(count == 87 + 28 + 21)
    }

    @Test func moduleSchemaValidationMatchesAndroid() {
        let cases = lines("schema")
        #expect(cases.count == 147)
        for (input, output) in cases {
            let section = BackupSection.fromKey(input["section"]!.str)!
            let payload = input["payload"]!.str
            let label = "\(section.key) \(payload.prefix(80))"
            do {
                let result = try ModuleSchemaValidator.validate(section, payload: payload)
                #expect(output["throw"] == nil, "expected \(output["throw"]?.str ?? "") for \(label)")
                #expect((result == .valid) == output["valid"]!.bool, "valid flag \(label)")
                let expected = output["errors"]!.arr.map {
                    ValidationError(code: $0["code"]!.str, message: $0["message"]!.str, module: $0["module"]!.optStr,
                                    severity: Severity(rawValue: $0["severity"]!.str)!)
                }
                #expect(result.errors == expected, "errors \(label)")
            } catch {
                #expect(output["throw"]?.str == error.kind, "threw \(error) for \(label)")
            }
        }
    }

    @Test func manifestValidationMatchesAndroid() throws {
        let cases = lines("manifestValidate")
        #expect(cases.count == 9 * 7 * 4)
        for (input, output) in cases {
            let now = input["now"]!.i64
            var modules = GsonMap<BackupModuleInfo>()
            for key in input["modules"]!.arr { modules.put(key.str, BackupModuleInfo(checksum: "sha256:abc", entryCount: 1, sizeBytes: 10)) }
            let manifest = BackupManifest(schemaVersion: Int32(input["schemaVersion"]!.i64), appVersion: "1.0", appVersionCode: 1,
                                          createdAt: input["createdAt"]!.i64, deviceInfo: DeviceInfo(), modules: modules)
            let result = try ManifestValidator(now: { now }).validate(manifest)
            let expected = output["errors"]!.arr.map {
                ValidationError(code: $0["code"]!.str, message: $0["message"]!.str, module: $0["module"]!.optStr,
                                severity: Severity(rawValue: $0["severity"]!.str)!)
            }
            #expect(result.errors == expected, "\(input)")
            #expect((result == .valid) == output["valid"]!.bool)
        }
    }

    @Test func checksumVerificationMatchesAndroid() {
        let cases = lines("verifyChecksum")
        #expect(cases.count == 9)
        for (input, output) in cases {
            var modules = GsonMap<BackupModuleInfo>()
            if let checksum = input["checksum"]!.optStr { modules.put("favorites", BackupModuleInfo(checksum: checksum, entryCount: 1, sizeBytes: 1)) }
            let manifest = BackupManifest(schemaVersion: 3, appVersion: "", createdAt: 0, modules: modules)
            #expect(ManifestValidator().verifyChecksum(moduleKey: "favorites", payload: input["payload"]!.str, manifest: manifest)
                    == output.bool, "\(input)")
        }
    }

    /// `createdAt` defaults to the clock when the file has none; the generator's clock is not reproducible.
    static func maskCreatedAt(_ json: String) -> String {
        guard let range = json.range(of: "\"createdAt\": ") else { return json }
        var end = range.upperBound
        while end < json.endIndex, json[end].isNumber || json[end] == "-" { end = json.index(after: end) }
        return json.replacingCharacters(in: range.upperBound..<end, with: "<now>")
    }

    @Test func manifestDecodingMatchesGson() {
        let cases = lines("manifestDecode")
        #expect(cases.count == 26)
        for (input, output) in cases {
            let json = input.str
            do {
                let manifest = try BackupManifest.decode(json: json, now: 0)
                #expect(output["throw"] == nil, "expected a failure for \(json)")
                let encoded = manifest.map { $0.json } ?? "null"
                let hasCreatedAt = json.contains("\"createdAt\"")
                let expected = hasCreatedAt ? output.str : Self.maskCreatedAt(output.str)
                #expect((hasCreatedAt ? encoded : Self.maskCreatedAt(encoded)) == expected, "\(json)")
            } catch {
                #expect(output["throw"]?.str == "JsonSyntaxException", "threw \(error) for \(json)")
            }
        }
    }

    @Test func legacyAdapterMatchesAndroid() {
        let cases = lines("legacyAdapt")
        #expect(cases.count == 20)
        for (input, output) in cases {
            do {
                let result = try LegacyPayloadAdapter.adapt(input.str)
                #expect(output["throw"] == nil, "expected \(output["throw"]?.str ?? "") for \(input.str)")
                #expect(result.manifest.json == output["manifest"]?.str, "manifest for \(input.str)")
                let expected = output["modules"]!.objectValue!.members.map { ($0.key, $0.value.str) }
                #expect(result.modules.entries.map(\.key) == expected.map(\.0), "module keys for \(input.str)")
                for (key, payload) in expected { #expect(result.modules[key] == .some(payload), "\(key) for \(input.str)") }
            } catch {
                #expect(output["throw"]?.str == error.kind, "threw \(error) for \(input.str)")
            }
        }
    }

    static func decodeAndEncode(type: String, payload: String) throws(GsonError) -> String {
        switch type {
        case "favorites": return try encode(AndroidBackup.FavoritesEntity.decodeList(payload))
        case "lyrics": return try encode(AndroidBackup.LyricsEntity.decodeList(payload))
        case "search_history": return try encode(AndroidBackup.SearchHistoryEntity.decodeList(payload))
        case "transitions": return try encode(AndroidBackup.TransitionRuleEntity.decodeList(payload))
        case "playback_history": return try encode(AndroidBackup.PlaybackHistoryBackupEntry.decodeList(payload))
        case "ai_usage_logs": return try encode(AndroidBackup.AiUsageEntity.decodeList(payload))
        case "artist_images": return try encode(AndroidBackup.ArtistImageBackupEntry.decodeList(payload))
        case "preferences": return try encode(AndroidBackup.PreferenceBackupEntry.decodeList(payload))
        case "playlist_list": return try encode(AndroidBackup.PlaylistRecord.decodeList(payload))
        case "playlists_payload":
            return try AndroidBackup.PlaylistsBackupPayload.decode(payload).map { GsonWriter.backup($0.gsonTree) } ?? "null"
        case "order_modes":
            guard let value = try Gson.parse(payload), let map = try GsonRead.map(value, GsonRead.string) else { return "null" }
            return GsonWriter.backup(GsonValue.map(map) { .string($0) })
        default: return "?"
        }
    }

    static func encode<T: GsonRecord>(_ list: [T?]?) -> String {
        guard let list else { return "null" }
        return T.encodeList(list)
    }

    @Test func gsonEntityBindingMatchesAndroid() {
        let cases = lines("entities")
        #expect(cases.count == 92)
        for (input, output) in cases {
            let type = input["type"]!.str, payload = input["payload"]!.str
            do {
                let encoded = try Self.decodeAndEncode(type: type, payload: payload)
                #expect(output["throw"] == nil, "expected a failure for \(type) \(payload)")
                #expect(encoded == output.str, "\(type) \(payload)")
            } catch {
                #expect(output["throw"]?.str == "JsonSyntaxException", "threw \(error) for \(type) \(payload)")
            }
        }
    }

    @Test func gsonWriterMatchesAndroid() {
        let expected = lines("gsonPretty").map(\.output.str)
        #expect(expected.count == 11)
        let values: [String] = [
            AndroidBackup.FavoritesEntity.encodeList([
                .init(songId: 123, isFavorite: true, timestamp: 1_700_000_000_000), .init(songId: -4, isFavorite: false, timestamp: 0),
            ]),
            AndroidBackup.LyricsEntity.encodeList([
                .init(songId: 5, content: "[00:01.00]<b>Tom & Jerry's</b> = \"x\" \\ \u{2028} \u{1} café 🎵", isSynced: true, source: nil),
            ]),
            AndroidBackup.SearchHistoryEntity.encodeList([.init(id: 0, query: "q", timestamp: 5)]),
            AndroidBackup.TransitionRuleEntity.encodeList([
                .init(id: 7, playlistId: "p", fromTrackId: nil, toTrackId: "b",
                      settings: .init(mode: "FADE_IN_OUT", durationMs: 1500, curveIn: "LOG", curveOut: "LINEAR")),
            ]),
            AndroidBackup.PlaybackHistoryBackupEntry.encodeList([.init(songId: "s", timestamp: 10, durationMs: 5, startTimestamp: nil, endTimestamp: 10)]),
            AndroidBackup.ArtistImageBackupEntry.encodeList([.init(artistName: "A", imageUrl: "", customImageBase64: nil)]),
            AndroidBackup.PreferenceBackupEntry.encodeList([
                .float("f", 0.1), .float("g", 1.0e10), .float("h", 1.0e-5), .double("d", 1_234_567.0), .double("e", 12_345_678.9),
                .double("z", -0.0), .stringSet("t", ["b", "a"]),
            ]),
            AndroidBackup.FavoritesEntity.encodeList([]),
            AndroidBackup.PlaylistRecord.encodeList([
                .init(id: "p1", name: "Mix", songIds: ["1", "2"], createdAt: 5, lastModified: 6, isAiGenerated: true,
                      coverColorArgb: -16_777_216, coverShapeType: "Star", coverShapeDetail1: 0.5, coverShapeDetail4: 6.0,
                      source: "AI", sortOrder: 2),
            ]),
            GsonWriter.backup(AndroidBackup.PlaylistsBackupPayload(
                playlists: [.init(id: "p1", name: "Mix", songIds: ["1"], createdAt: 5, lastModified: 6, source: "LOCAL")],
                playlistSongOrderModes: GsonMap([("p1", "manual")]), playlistsSortOption: "playlist_name_az",
                songMetadata: GsonMap([("1", .init(title: "T", artist: "A", album: "B", duration: 1000))]), coverImages: nil).gsonTree),
            GsonWriter.backup(AndroidBackup.PlaylistsBackupPayload(
                playlists: [], playlistSongOrderModes: GsonMap(), playlistsSortOption: "", songMetadata: nil,
                coverImages: GsonMap()).gsonTree),
        ]
        for (i, value) in values.enumerated() { #expect(value == expected[i], "value \(i)") }
        // The AI usage handler uses the app's default compact Gson.
        let ai = AiUsageModule.export([AiUsageRecord(id: 1, timestamp: 1_700_000_000_000, provider: "GEMINI",
                                                      model: "gemini-2.5-flash", promptType: "playlist", promptTokens: 10,
                                                      outputTokens: 20, thoughtTokens: 3)])
        #expect(ai == lines("aiUsageExport").first?.output.str)
        let engagement = EngagementStatsModule.export([EngagementBackupEntry(songId: "song-1", stats: EngagementStats(
            playCount: 3, totalPlayDurationMs: 1200, lastPlayedTimestamp: 100))])
        #expect(engagement == lines("engagementExport").first?.output.str)
    }

    @Test func engagementRestoreMatchesAndroid() throws {
        let cases = lines("engagementRestore")
        #expect(cases.count == 15)
        for (input, output) in cases {
            do {
                let entries = try EngagementStatsModule.restore(payload: input.str)
                #expect(output["throw"] == nil, "expected a failure for \(input.str)")
                let expected = try JSONParser().parse(output.str).arr
                #expect(entries.count == expected.count, "\(input.str)")
                for (entry, e) in zip(entries, expected) {
                    #expect(entry.songId == e["songId"]!.str)
                    #expect(Int64(entry.stats.playCount) == e["playCount"]!.i64)
                    #expect(entry.stats.totalPlayDurationMs == e["totalPlayDurationMs"]!.i64)
                    #expect(entry.stats.lastPlayedTimestamp == e["lastPlayedTimestamp"]!.i64)
                }
            } catch {
                #expect(output["throw"]?.str == "IllegalArgumentException", "threw \(error) for \(input.str)")
            }
        }
    }

    @Test func playlistSongResolutionMatchesAndroid() {
        let libraryRows = lines("resolverLibrary").first!.input.arr
        let library = libraryRows.map {
            BackupSongSummary(id: String($0.arr[0].i64), title: $0.arr[1].str, artistName: $0.arr[2].str,
                              albumName: $0.arr[3].str, duration: $0.arr[4].i64)
        }
        let resolver = BackupSongResolver(library: library)
        let cases = lines("resolveSongId")
        #expect(cases.count == 22)
        for (input, output) in cases {
            let meta = input["title"].map { _ in
                AndroidBackup.SongMetadataEntry(title: input["title"]!.str, artist: input["artist"]!.str,
                                                album: input["album"]!.str, duration: input["duration"]!.i64)
            }
            #expect(resolver.resolve(input["id"]!.str, metadata: meta) == output.optStr, "\(input)")
        }
    }

    @Test func androidArchivesReadLikeAndroid() throws {
        let cases = lines("readV3") + lines("readLegacy")
        #expect(cases.count == 5)
        for (input, output) in cases {
            let reader = BackupReader(bytes: try fixtureBytes(input.str))
            let manifest = try reader.readManifest()
            #expect(manifest.json == output["manifest"]!.str, "manifest of \(input.str)")
            let modules = try reader.readAllModulePayloads()
            let expected = output["modules"]!.objectValue!.members
            #expect(modules.keys == expected.map(\.key), "modules of \(input.str)")
            for member in expected {
                #expect(modules[member.key] == .some(member.value.str), "\(member.key) of \(input.str)")
                #expect(try reader.readModulePayload(member.key) == member.value.str)
            }
        }
    }
}
