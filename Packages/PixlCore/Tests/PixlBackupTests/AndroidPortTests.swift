import Foundation
import PixlFoundation
import PixlLibrary
import PixlModel
import Testing
@testable import PixlBackup

// Ports of the Android unit tests under app/src/test/java/com/theveloper/pixelplay/data/backup/ — same inputs and
// expectations, one Swift test per Kotlin test.

@Suite struct BackupSectionTests {
    @Test func allSectionsHaveUniqueKeys() {
        let keys = BackupSection.allCases.map(\.key)
        #expect(Set(keys).count == keys.count)
    }

    @Test func allSectionsHaveUniqueLabels() {
        let labels = BackupSection.allCases.map(\.label)
        #expect(Set(labels).count == labels.count)
    }

    @Test func fromKeyReturnsCorrectSectionForKnownKeys() {
        #expect(BackupSection.fromKey("playlists") == .playlists)
        #expect(BackupSection.fromKey("global_settings") == .globalSettings)
        #expect(BackupSection.fromKey("favorites") == .favorites)
        #expect(BackupSection.fromKey("lyrics") == .lyrics)
        #expect(BackupSection.fromKey("search_history") == .searchHistory)
        #expect(BackupSection.fromKey("transitions") == .transitions)
        #expect(BackupSection.fromKey("engagement_stats") == .engagementStats)
        #expect(BackupSection.fromKey("playback_history") == .playbackHistory)
        #expect(BackupSection.fromKey("quick_fill") == .quickFill)
        #expect(BackupSection.fromKey("artist_images") == .artistImages)
        #expect(BackupSection.fromKey("equalizer") == .equalizer)
    }

    @Test func fromKeyReturnsNullForUnknownKey() {
        #expect(BackupSection.fromKey("nonexistent") == nil)
        #expect(BackupSection.fromKey("") == nil)
    }

    @Test func defaultSelectionContainsAllSections() {
        #expect(BackupSection.defaultSelection == Set(BackupSection.allCases))
    }

    @Test func allTwelveSupportedBackupSectionsArePresent() {
        #expect(BackupSection.allCases.count == 12)
        #expect(BackupSection.fromKey("ai_usage_logs") == .aiUsageLogs)
        #expect(BackupSection.aiUsageLogs.sinceVersion == 4)
    }

    @Test func newSectionsHaveSinceVersion3() {
        #expect(BackupSection.quickFill.sinceVersion == 3)
        #expect(BackupSection.artistImages.sinceVersion == 3)
        #expect(BackupSection.equalizer.sinceVersion == 3)
    }

    @Test func originalSectionsHaveSinceVersion1() {
        let original: [BackupSection] = [.playlists, .globalSettings, .favorites, .lyrics, .searchHistory, .transitions,
                                         .engagementStats, .playbackHistory]
        for section in original { #expect(section.sinceVersion == 1, "\(section.label) should have sinceVersion 1") }
    }

    @Test func allSectionsHaveNonEmptyLabelsAndDescriptions() {
        for section in BackupSection.allCases {
            #expect(!section.label.isKotlinBlank, "\(section.key) should have a non-empty label")
            #expect(!section.description.isKotlinBlank, "\(section.key) should have a non-empty description")
        }
    }
}

@Suite struct BackupFormatDetectorTests {
    @Test func detectsV3PxplZipFormat() {
        #expect(BackupFormatDetector.detect(Array("PXPL".utf8) + [0x50, 0x4B, 0x03, 0x04]) == .pxplV3Zip)
    }

    @Test func detectsV2PxplGzipFormat() {
        #expect(BackupFormatDetector.detect(Array("PXPL".utf8) + [0x1F, 0x8B, 0x08, 0x00]) == .pxplV2Gzip)
    }

    @Test func detectsLegacyGzipFormat() {
        #expect(BackupFormatDetector.detect([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00]) == .legacyGzip)
    }

    @Test func detectsLegacyRawJsonFormat() {
        #expect(BackupFormatDetector.detect(Array("{ \"formatVersion\": 1".utf8)) == .legacyRaw)
    }

    @Test func returnsUnknownForUnrecognizedFormat() {
        #expect(BackupFormatDetector.detect([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]) == .unknown)
    }

    @Test func returnsUnknownForEmptyInput() {
        #expect(BackupFormatDetector.detect([UInt8]()) == .unknown)
    }

    @Test func returnsUnknownForTooShortInput() {
        #expect(BackupFormatDetector.detect(Array("PX".utf8)) == .unknown)
    }
}

@Suite struct LegacyPayloadAdapterTests {
    @Test func adaptsV2BackupWithSeparatePlaylistsAndGlobalSettings() throws {
        let json = """
        {
            "formatVersion": 2,
            "exportedAtEpochMs": 1700000000000,
            "availableSections": ["playlists", "global_settings", "favorites"],
            "playlists": [
                {"key": "user_playlists_json_v1", "type": "string", "stringValue": "[]"}
            ],
            "globalSettings": [
                {"key": "app_theme", "type": "string", "stringValue": "dark"}
            ],
            "favorites": [
                {"songId": 123, "addedAt": 1700000000000}
            ]
        }
        """
        let result = try LegacyPayloadAdapter.adapt(json)
        #expect(result.manifest.schemaVersion == 2)
        #expect(result.manifest.createdAt == 1_700_000_000_000)
        #expect(result.modules.count == 3)
        #expect(result.modules.contains("playlists"))
        #expect(result.modules.contains("global_settings"))
        #expect(result.modules.contains("favorites"))
    }

    @Test func adaptsV1BackupWithCombinedPreferencesField() throws {
        let json = """
        {
            "formatVersion": 1,
            "exportedAtEpochMs": 1600000000000,
            "availableSections": ["playlists", "global_settings"],
            "preferences": [
                {"key": "user_playlists_json_v1", "type": "string", "stringValue": "[]"},
                {"key": "app_theme", "type": "string", "stringValue": "dark"},
                {"key": "crossfade_duration", "type": "int", "intValue": 6000}
            ]
        }
        """
        let result = try LegacyPayloadAdapter.adapt(json)
        #expect(result.manifest.schemaVersion == 1)
        #expect(result.modules.count == 2)
        #expect(result.modules.contains("playlists"))
        #expect(result.modules.contains("global_settings"))
    }

    @Test func skipsModulesNotInAvailableSections() throws {
        let json = """
        {
            "formatVersion": 2,
            "exportedAtEpochMs": 1700000000000,
            "availableSections": ["favorites"],
            "playlists": [
                {"key": "user_playlists_json_v1", "type": "string", "stringValue": "[]"}
            ],
            "favorites": [
                {"songId": 123}
            ]
        }
        """
        let result = try LegacyPayloadAdapter.adapt(json)
        #expect(result.modules.count == 1)
        #expect(result.modules.contains("favorites"))
    }

    @Test func generatesChecksumsInManifestModuleInfo() throws {
        let json = """
        {
            "formatVersion": 2,
            "exportedAtEpochMs": 1700000000000,
            "availableSections": ["favorites"],
            "favorites": [
                {"songId": 123}
            ]
        }
        """
        let result = try LegacyPayloadAdapter.adapt(json)
        let info = try #require(result.manifest.module("favorites"))
        #expect(info.checksum?.hasPrefix("sha256:") == true)
        #expect(info.entryCount > 0)
        #expect(info.sizeBytes > 0)
    }

    @Test func handlesEmptyBackupGracefully() throws {
        let json = """
        {
            "formatVersion": 2,
            "exportedAtEpochMs": 1700000000000,
            "availableSections": []
        }
        """
        let result = try LegacyPayloadAdapter.adapt(json)
        #expect(result.manifest.schemaVersion == 2)
        #expect(result.modules.isEmpty)
    }
}

@Suite struct ContentSanitizerTests {
    @Test func sanitizeStringTrimsWhitespace() {
        #expect(ContentSanitizer.sanitizeString("  hello  ") == "hello")
    }

    @Test func sanitizeStringTruncatesToMaxLength() {
        #expect(ContentSanitizer.sanitizeString(String(repeating: "a", count: 2000), maxLength: 100).utf16.count == 100)
    }

    @Test func sanitizeStringStripsControlCharactersButKeepsNewlinesAndTabs() {
        let result = ContentSanitizer.sanitizeString("Hello\tWorld\n\u{0}\u{1}\u{2}Test")
        #expect(result.contains("\t"))
        #expect(result.contains("\n"))
        #expect(!result.unicodeScalars.contains("\u{0}"))
        #expect(!result.unicodeScalars.contains("\u{1}"))
    }

    @Test func sanitizeUrlAcceptsValidHttpsUrl() {
        #expect(ContentSanitizer.sanitizeUrl("https://cdn.example.com/image.jpg") == "https://cdn.example.com/image.jpg")
    }

    @Test func sanitizeUrlAcceptsValidHttpUrl() {
        #expect(ContentSanitizer.sanitizeUrl("http://example.com/image.jpg") == "http://example.com/image.jpg")
    }

    @Test func sanitizeUrlReturnsEmptyForNonHttpProtocol() {
        #expect(ContentSanitizer.sanitizeUrl("ftp://files.example.com/image.jpg") == "")
    }

    @Test func sanitizeUrlTruncatesOverlyLongUrlToMaxLength() {
        let result = ContentSanitizer.sanitizeUrl("https://example.com/" + String(repeating: "a", count: 3000))
        #expect(result.utf16.count == 2000)
        #expect(result.hasPrefix("https://"))
    }

    @Test func isValidModuleKeyAcceptsKnownKeys() {
        for key in ["playlists", "global_settings", "favorites", "quick_fill", "artist_images", "equalizer"] {
            #expect(ContentSanitizer.isValidModuleKey(key))
        }
    }

    @Test func isValidModuleKeyRejectsInvalidKeys() {
        for key in ["", "../path_traversal", "UPPERCASE", "has spaces", "has-dashes"] {
            #expect(!ContentSanitizer.isValidModuleKey(key))
        }
    }
}

@Suite struct ManifestValidatorTests {
    let validator = ManifestValidator(now: { testNow })

    @Test func validManifestPassesValidation() throws {
        let manifest = BackupManifest(schemaVersion: 3, appVersion: "1.0.0", appVersionCode: 100, createdAt: testNow,
                                      modules: GsonMap([("playlists", BackupModuleInfo(checksum: "sha256:abc", entryCount: 5, sizeBytes: 1024))]))
        #expect(try validator.validate(manifest).isValid)
    }

    @Test func schemaVersion0FailsWithError() throws {
        let result = try validator.validate(BackupManifest(schemaVersion: 0, createdAt: testNow))
        #expect(result.fatalErrors.contains { $0.code == "SCHEMA_TOO_OLD" })
    }

    @Test func futureSchemaVersionEmitsWarning() throws {
        let result = try validator.validate(BackupManifest(schemaVersion: 99, createdAt: testNow))
        #expect(result != .valid)
        #expect(result.warnings.contains { $0.code == "SCHEMA_TOO_NEW" })
    }

    @Test func timestampFarInTheFutureEmitsWarning() throws {
        let result = try validator.validate(BackupManifest(schemaVersion: 3, createdAt: testNow + 86_400_000 * 2))
        #expect(result != .valid)
        #expect(result.warnings.contains { $0.code == "TIMESTAMP_FUTURE" })
    }

    @Test func oldTimestampEmitsWarning() throws {
        let result = try validator.validate(BackupManifest(schemaVersion: 3, createdAt: 1_000_000_000_000))
        #expect(result != .valid)
        #expect(result.warnings.contains { $0.code == "TIMESTAMP_OLD" })
    }

    @Test func unknownModuleKeyEmitsWarning() throws {
        let manifest = BackupManifest(schemaVersion: 3, createdAt: testNow,
                                      modules: GsonMap([("unknown_module_xyz", BackupModuleInfo(checksum: "", entryCount: 0, sizeBytes: 0))]))
        let result = try validator.validate(manifest)
        #expect(result != .valid)
        #expect(result.warnings.contains { $0.code == "UNKNOWN_MODULE" })
    }

    @Test func verifyChecksumReturnsTrueForMatchingPayload() {
        let payload = "[{\"songId\": 123}]"
        let manifest = BackupManifest(modules: GsonMap([("favorites", BackupModuleInfo(
            checksum: "sha256:" + SHA256.hex(Array(payload.utf8)), entryCount: 1, sizeBytes: Int64(payload.utf8.count)))]))
        #expect(validator.verifyChecksum(moduleKey: "favorites", payload: payload, manifest: manifest))
    }

    @Test func verifyChecksumReturnsFalseForMismatchedPayload() {
        let manifest = BackupManifest(modules: GsonMap([("favorites", BackupModuleInfo(
            checksum: "sha256:" + String(repeating: "0", count: 64), entryCount: 1, sizeBytes: 10))]))
        #expect(!validator.verifyChecksum(moduleKey: "favorites", payload: "[{\"songId\": 999}]", manifest: manifest))
    }

    @Test func verifyChecksumReturnsTrueWhenNoChecksumInManifest() {
        #expect(validator.verifyChecksum(moduleKey: "favorites", payload: "any payload", manifest: BackupManifest(modules: GsonMap())))
    }
}

@Suite struct ModuleSchemaValidatorTests {
    func validate(_ section: BackupSection, _ payload: String) throws -> BackupValidationResult {
        try ModuleSchemaValidator.validate(section, payload: payload)
    }

    @Test func validFavoritesArrayPassesValidation() throws {
        #expect(try validate(.favorites, "[{\"songId\": 123, \"addedAt\": 1700000000000}]").isValid)
    }

    @Test func invalidJsonFailsValidation() throws {
        #expect(try validate(.favorites, "not valid json{").fatalErrors.contains { $0.code == "INVALID_JSON" })
    }

    @Test func nonArrayModuleFailsValidation() throws {
        #expect(try validate(.favorites, "{\"key\": \"value\"}").fatalErrors.contains { $0.code == "NOT_ARRAY" })
    }

    @Test func favoritesWithInvalidSongIdEmitsWarning() throws {
        #expect(try validate(.favorites, "[{\"songId\": 0, \"addedAt\": 1700000000000}]").warnings.contains { $0.code == "INVALID_SONG_ID" })
    }

    @Test func favoritesWithSnakeCaseSongIdPassValidation() throws {
        #expect(try validate(.favorites, "[{\"song_id\": \"123\", \"added_at\": 1700000000000}]").isValid)
    }

    @Test func artistImagesWithNonHttpsUrlEmitsWarning() throws {
        let result = try validate(.artistImages, "[{\"artistName\": \"Test\", \"imageUrl\": \"http://insecure.com/img.jpg\"}]")
        #expect(result.warnings.contains { $0.code == "INSECURE_URL" })
    }

    @Test func artistImagesWithValidHttpsUrlPasses() throws {
        #expect(try validate(.artistImages, "[{\"artistName\": \"Test\", \"imageUrl\": \"https://cdn.example.com/img.jpg\"}]").isValid)
    }

    @Test func playbackHistoryWithNegativeDurationEmitsWarning() throws {
        let result = try validate(.playbackHistory, "[{\"songId\": \"123\", \"timestamp\": 1700000000000, \"durationMs\": -500}]")
        #expect(result.warnings.contains { $0.code == "NEGATIVE_DURATION" })
    }

    @Test func preferenceEntriesWithValidTypesPass() throws {
        let payload = """
        [
            {"key": "theme", "type": "string", "stringValue": "dark"},
            {"key": "count", "type": "int", "intValue": 5},
            {"key": "enabled", "type": "boolean", "booleanValue": true}
        ]
        """
        #expect(try validate(.globalSettings, payload).isValid)
    }

    @Test func preferenceEntriesWithInvalidTypeEmitWarning() throws {
        let result = try validate(.globalSettings, "[{\"key\": \"theme\", \"type\": \"invalid_type\", \"stringValue\": \"dark\"}]")
        #expect(result.warnings.contains { $0.code == "INVALID_PREF_TYPE" })
    }

    @Test func transitionsWithOutOfRangeDurationEmitWarning() throws {
        let result = try validate(.transitions, "[{\"fromSongId\": \"1\", \"toSongId\": \"2\", \"settings\": {\"durationMs\": 50000}}]")
        #expect(result.warnings.contains { $0.code == "INVALID_TRANSITION_DURATION" })
    }

    @Test func engagementStatsWithNegativePlayCountEmitWarning() throws {
        let result = try validate(.engagementStats, "[{\"songId\": \"123\", \"playCount\": -1, \"totalDuration\": 0}]")
        #expect(result.warnings.contains { $0.code == "NEGATIVE_PLAY_COUNT" })
    }

    @Test func engagementStatsWithMissingSongIdAndInvalidNumbersEmitWarnings() throws {
        let result = try validate(.engagementStats, "[{\"playCount\": \"oops\", \"totalDuration\": -5, \"lastPlayedTimestamp\": \"bad\"}]")
        let codes = result.warnings.map(\.code)
        #expect(codes.contains("MISSING_SONG_ID"))
        #expect(codes.contains("INVALID_PLAY_COUNT"))
        #expect(codes.contains("NEGATIVE_TOTAL_DURATION"))
        #expect(codes.contains("INVALID_LAST_PLAYED_TIMESTAMP"))
    }

    @Test func engagementStatsWithDuplicateSongIdsEmitWarning() throws {
        let payload = """
        [
            {"songId": "123", "playCount": 1},
            {"songId": "123", "playCount": 2}
        ]
        """
        #expect(try validate(.engagementStats, payload).warnings.contains { $0.code == "DUPLICATE_SONG_ID" })
    }

    @Test func emptyArrayPassesValidation() throws {
        #expect(try validate(.favorites, "[]").isValid)
    }

    @Test func tooManyEntriesIsFatal() throws {
        let payload = "[" + Array(repeating: "0", count: ModuleSchemaValidator.maxEntriesPerModule + 1).joined(separator: ",") + "]"
        let result = try validate(.favorites, payload)
        #expect(result.fatalErrors.map(\.message) == ["Module 'favorites' has 100001 entries (max 100000)."])
        #expect(try validate(.favorites, "[" + Array(repeating: "0", count: 100_000).joined(separator: ",") + "]").isValid)
    }
}

@Suite struct EngagementStatsModuleHandlerTests {
    @Test func exportUsesStableCanonicalFieldNames() {
        let payload = EngagementStatsModule.export([EngagementBackupEntry(songId: "song-1", stats: EngagementStats(
            playCount: 3, totalPlayDurationMs: 1200, lastPlayedTimestamp: 100))])
        #expect(payload.contains("\"songId\""))
        #expect(payload.contains("\"playCount\""))
        #expect(payload.contains("\"totalPlayDurationMs\""))
        #expect(payload.contains("\"lastPlayedTimestamp\""))
        #expect(!payload.contains("\"song_id\""))
        #expect(!payload.contains("\"play_count\""))
    }

    @Test func restoreSanitizesLegacyFieldsSkipsMalformedRowsAndMergesDuplicates() throws {
        let payload = """
            [
              {"songId":"song-1","playCount":3,"totalDuration":1200,"lastPlayedAt":100},
              {"song_id":"song-2","play_count":"-4","duration_ms":"500","last_played_timestamp":"250"},
              {"songId":"song-1","playCount":2,"totalPlayDurationMs":4000,"lastPlayedTimestamp":300},
              {"songId":"   ","playCount":8},
              "bad-row"
            ]
        """
        #expect(try EngagementStatsModule.restore(payload: payload) == [
            EngagementBackupEntry(songId: "song-1", stats: EngagementStats(playCount: 3, totalPlayDurationMs: 4000, lastPlayedTimestamp: 300)),
            EngagementBackupEntry(songId: "song-2", stats: EngagementStats(playCount: 0, totalPlayDurationMs: 500, lastPlayedTimestamp: 250)),
        ])
    }

    @Test func restoreRejectsPayloadsThatContainNoUsableEntries() {
        #expect(throws: BackupError("Engagement stats backup does not contain any valid entries.")) {
            try EngagementStatsModule.restore(payload: "[{\"playCount\": 3}, null, \"bad-row\"]")
        }
    }
}

@Suite struct FavoritesModuleHandlerTests {
    @Test func exportUsesStableCanonicalFieldNames() {
        let payload = FavoritesModule.export([FavoriteBackupEntry(backupSongId: "123", isFavorite: true, timestamp: 1_700_000_000_000)])
        #expect(payload.contains("\"songId\""))
        #expect(payload.contains("\"isFavorite\""))
        #expect(payload.contains("\"timestamp\""))
        #expect(!payload.contains("\"song_id\""))
        // A numeric id stays Android's number.
        #expect(payload.contains("\"songId\": 123,"))
    }

    @Test func restoreAcceptsLegacySnakeCasePayload() throws {
        let payload = """
            [
              {"song_id": 123, "is_favorite": true, "added_at": 1700000000000}
            ]
        """
        #expect(try FavoritesModule.restore(payload: payload) == [
            FavoriteBackupEntry(backupSongId: "123", isFavorite: true, timestamp: 1_700_000_000_000),
        ])
    }
}

@Suite struct RestoreExecutorTests {
    func makePlan(_ modules: [BackupSection], moduleSize: Int64 = 32) -> RestorePlan {
        var map = GsonMap<BackupModuleInfo>()
        for m in modules { map.put(m.key, BackupModuleInfo(checksum: "sha256:test", entryCount: 1, sizeBytes: moduleSize)) }
        let manifest = BackupManifest(schemaVersion: BackupManifest.currentSchemaVersion, appVersion: "test", appVersionCode: 1,
                                      createdAt: 1_700_000_000_000, deviceInfo: DeviceInfo(), modules: map)
        return RestorePlan(manifest: manifest, backupUri: "test-backup", availableModules: modules, selectedModules: modules,
                           moduleDetails: Dictionary(uniqueKeysWithValues: modules.map { ($0, ModuleRestoreDetail(entryCount: 1, sizeBytes: moduleSize)) }))
    }

    @Test func executeRollsBackTheModuleThatFailsDuringRestore() async throws {
        let favorites = RecordingHandler(.favorites, snapshot: "favorites-snapshot")
        let history = RecordingHandler(.playbackHistory, snapshot: "history-snapshot")
        await history.failRestore("boom")
        let favoritesPayload = "[{\"songId\": 1, \"isFavorite\": true, \"timestamp\": 5}]"
        let historyPayload = "[{\"songId\": \"1\", \"timestamp\": 5, \"durationMs\": 1}]"
        let bytes = makeBackup([("favorites", favoritesPayload), ("playback_history", historyPayload)])
        // The plan's checksums are the archive's (the Android test mocks validation to Valid).
        let reader = BackupReader(bytes: bytes)
        var plan = makePlan([.favorites, .playbackHistory])
        plan.manifest = try reader.readManifest()
        let result = await RestoreExecutor.execute(reader: reader, plan: plan,
                                                   handlers: [.favorites: favorites, .playbackHistory: history])
        guard case .totalFailure(let message) = result else {
            Issue.record("expected a total failure, got \(result)")
            return
        }
        #expect(message.contains("Playback History"))
        #expect(await favorites.restored == [favoritesPayload])
        #expect(await favorites.rolledBack == ["favorites-snapshot"])
        #expect(await history.rolledBack == ["history-snapshot"])
    }

    @Test func executeFailsWhenASelectedModulePayloadIsMissing() async {
        let favorites = RecordingHandler(.favorites, snapshot: "favorites-snapshot")
        let bytes = makeBackup([("search_history", "[]")])
        let result = await RestoreExecutor.execute(reader: BackupReader(bytes: bytes), plan: makePlan([.favorites]),
                                                   handlers: [.favorites: favorites])
        #expect(result == .totalFailure(
            "Restore failed at Favorites: Module 'favorites' not found in backup. All applied changes were rolled back."))
        #expect(await favorites.restored.isEmpty)
    }

    @Test func executeFailsBeforeLoadingOversizedModulePayload() async {
        let history = RecordingHandler(.playbackHistory, snapshot: "history-snapshot")
        // The archive has no payload at all: reading it would fail differently.
        let bytes = makeBackup([])
        let result = await RestoreExecutor.execute(reader: BackupReader(bytes: bytes),
                                                   plan: makePlan([.playbackHistory], moduleSize: Int64(BackupReader.maxModulePayloadBytes) + 1),
                                                   handlers: [.playbackHistory: history])
        guard case .totalFailure(let message) = result else {
            Issue.record("expected a total failure, got \(result)")
            return
        }
        #expect(message.contains("restore safety limit"))
        #expect(await history.restored.isEmpty)
    }
}

@Suite struct BackupManagerTests {
    let manager = BackupManager(pipeline: ValidationPipeline(manifestValidator: ManifestValidator(now: { testNow })),
                                now: { testNow })

    @Test func inspectBackupSurfacesFileAndModuleWarningsInTheRestorePlan() throws {
        let bytes = makeBackup([("engagement_stats", "[{\"playCount\": 1}]")])
        let plan = try manager.inspectBackup(bytes: bytes, fileName: "backup.zip")
        #expect(plan.warnings == [
            "File extension is not .pxpl. The file may not be a valid backup.",
            "Engagement Stats: EngagementStats[0]: missing songId",
        ])
    }

    @Test func inspectBackupFailsWhenTheManifestListsAModuleWithoutPayload() {
        let bytes = makeBackup([("search_history", "[]")]) { manifest in
            manifest.modules?.put("favorites", BackupModuleInfo(checksum: "sha256:test", entryCount: 1, sizeBytes: 32))
        }
        #expect(throws: BackupError("Module 'favorites' not found in backup")) {
            try manager.inspectBackup(bytes: bytes, fileName: "backup.pxpl")
        }
    }

    @Test func inspectBackupSkipsOversizedModulePreviewValidation() throws {
        let bytes = makeBackup([]) { manifest in
            manifest.modules?.put("playback_history", BackupModuleInfo(
                checksum: "sha256:test", entryCount: 1, sizeBytes: Int64(BackupReader.maxModulePayloadBytes) + 1))
        }
        let plan = try manager.inspectBackup(bytes: bytes, fileName: "backup.pxpl")
        #expect(plan.warnings.contains { $0.lowercased().contains("preview validation was skipped") })
    }
}
