import PixlLibrary
import PixlModel
import XCTest
@testable import PixlAudio

@MainActor
final class LaunchConfigurationTests: XCTestCase {
    func testParsesUITestArguments() {
        let launch = LaunchConfiguration(arguments: [
            "PixlAudio", "-uiTest", "-screen", "diagnostics", "-appearance", "dark", "-paused",
        ])
        XCTAssertTrue(launch.isUITest)
        XCTAssertEqual(launch.screen, .diagnostics)
        XCTAssertEqual(launch.appearance, .dark)
        XCTAssertEqual(launch.colorScheme, .dark)
        XCTAssertFalse(launch.startsPlaying)
        XCTAssertTrue(launch.hasSong)
        XCTAssertEqual(launch.songIndex, 0)
    }

    func testDefaultsWithoutArguments() {
        let launch = LaunchConfiguration(arguments: ["PixlAudio"])
        XCTAssertFalse(launch.isUITest)
        XCTAssertNil(launch.screen)
        XCTAssertEqual(launch.appearance, .system)
        XCTAssertNil(launch.colorScheme)
        XCTAssertTrue(launch.startsPlaying)
    }

    func testIgnoresUnknownValuesAndTrailingFlags() {
        let launch = LaunchConfiguration(arguments: ["PixlAudio", "-screen", "nope", "-appearance"])
        XCTAssertNil(launch.screen)
        XCTAssertEqual(launch.appearance, .system)
    }

    /// `-accent RRGGBB` (accent screenshots) only counts in UI tests; AppEnvironment normalises it into the settings.
    func testAccentArgumentIsForUITestsOnly() {
        let launch = LaunchConfiguration(arguments: ["PixlAudio", "-uiTest", "-screen", "home", "-accent", "34c759"])
        XCTAssertEqual(launch.accentHex, "34c759")
        XCTAssertEqual(launch.accentHex.flatMap(AccentPalette.seed(hex:)).map(AccentPalette.hex(argb:)), "#34C759")
        XCTAssertNil(LaunchConfiguration(arguments: ["PixlAudio", "-accent", "34C759"]).accentHex)
        XCTAssertNil(LaunchConfiguration(arguments: ["PixlAudio", "-uiTest"]).accentHex)
        XCTAssertNil(LaunchConfiguration(arguments: ["PixlAudio", "-uiTest", "-accent"]).accentHex)
    }

    func testMiniPlayerScreensUseTheVividSong() {
        let launch = LaunchConfiguration(arguments: ["-uiTest", "-screen", "miniPlayer"])
        XCTAssertEqual(launch.songIndex, UITestLaunchRouter.vividSongIndex)
        XCTAssertEqual(LaunchConfiguration(arguments: ["-screen", "miniPlayer", "-song", "5"]).songIndex, 5)
    }

    /// `-demoScale` repeats the demo library for the transition performance tests (clamped to 1…400).
    func testParsesDemoScale() {
        XCTAssertEqual(LaunchConfiguration(arguments: ["-uiTest"]).demoScale, 1)
        XCTAssertEqual(LaunchConfiguration(arguments: ["-uiTest", "-demoScale", "100"]).demoScale, 100)
        XCTAssertEqual(LaunchConfiguration(arguments: ["-uiTest", "-demoScale", "0"]).demoScale, 1)
        XCTAssertEqual(LaunchConfiguration(arguments: ["-uiTest", "-demoScale", "9999"]).demoScale, 400)
        XCTAssertEqual(LaunchConfiguration(arguments: ["-uiTest", "-demoScale", "x"]).demoScale, 1)
    }

    /// Every DemoScreen resolves to at most one destination and has a ready identifier.
    func testEveryDemoScreenRoutes() {
        for screen in DemoScreen.allCases {
            let launch = LaunchConfiguration(arguments: ["-uiTest", "-screen", screen.rawValue])
            let state = UITestLaunchRouter.initialState(for: launch)
            XCTAssertEqual(state.tab, screen.tab, "\(screen)")
            let destinations = [screen.route != nil, screen.sheet != nil, screen.cover != nil].filter { $0 }.count
            XCTAssertLessThanOrEqual(destinations, 1, "\(screen) has more than one destination")
            if let route = screen.route {
                let path: [AppRoute]
                switch screen.tab {
                case .home: path = state.homePath
                case .search: path = state.searchPath
                case .library: path = state.libraryPath
                }
                XCTAssertEqual(path.last, route, "\(screen)")
                XCTAssertEqual(screen.readyIdentifier, "screen.\(route.screenID)", "\(screen)")
            }
            XCTAssertEqual(state.sheet, screen.sheet)
            XCTAssertEqual(state.cover, screen.cover)
            XCTAssertTrue(screen.readyIdentifier.hasPrefix("screen."))
        }
    }

    func testSettingsSubScreensSitOnSettings() {
        func path(_ screen: DemoScreen) -> [AppRoute] {
            UITestLaunchRouter.initialState(for: LaunchConfiguration(arguments: ["-screen", screen.rawValue])).homePath
        }
        XCTAssertEqual(path(.settings), [.settings])
        XCTAssertEqual(path(.settingsAppearance), [.settings, .settingsCategory(.appearance)])
        XCTAssertEqual(path(.diagnostics), [.settings, .diagnostics])
        XCTAssertEqual(path(.spotifyDashboard), [.settings, .accounts, .spotifyDashboard])
        let results = UITestLaunchRouter.initialState(for: LaunchConfiguration(arguments: ["-screen", "searchResults"]))
        XCTAssertEqual(results.searchText, UITestLaunchRouter.defaultSearchQuery)
    }

    func testRouterNavigationAndBarVisibility() {
        let router = Router(launch: LaunchConfiguration(arguments: ["PixlAudio"]))
        XCTAssertEqual(router.selection, .home)
        XCTAssertTrue(router.isNavigationBarVisible)
        router.push(.settings)
        XCTAssertEqual(router.homePath, [.settings])
        XCTAssertFalse(router.isNavigationBarVisible, "pushed screens hide the bar (Android routesWithHiddenNavigationBar)")
        router.select(.library)
        XCTAssertEqual(router.selection, .library)
        XCTAssertTrue(router.isNavigationBarVisible)
        router.select(.home)
        router.select(.home)
        XCTAssertTrue(router.homePath.isEmpty, "re-selecting a tab pops it to its root")
        router.present(AppSheet.queue)
        XCTAssertEqual(router.sheet, .queue)
        router.dismissSheet()
        XCTAssertNil(router.sheet)
    }
}

@MainActor
final class StoreTests: XCTestCase {
    func testDemoLibraryIsConsistent() {
        let demo = DemoLibrary.snapshot
        XCTAssertEqual(demo.songs.count, 24)
        XCTAssertEqual(Set(demo.songs.map(\.id)).count, demo.songs.count)
        for song in demo.songs {
            XCTAssertNotNil(demo.albums.first { $0.id == song.albumId })
            XCTAssertNotNil(ArtworkSource(song: song))
        }
        XCTAssertEqual(demo.albums.reduce(0) { $0 + $1.songCount }, demo.songs.count)
        XCTAssertFalse(demo.playlists.isEmpty)
    }

    func testLibraryStoreLookups() {
        let store = LibraryStore(snapshot: DemoLibrary.snapshot)
        let song = DemoLibrary.songs[3]
        XCTAssertEqual(store.song(id: song.id), song)
        XCTAssertEqual(store.album(id: song.albumId)?.title, song.album)
    }

    func testPlaybackStoreWithDemoEngine() async throws {
        let store = PlaybackStore(engine: DemoPlaybackEngine())
        let songs = DemoLibrary.songs
        store.play(songs, startIndex: songs.count - 1)
        XCTAssertEqual(store.current, songs.last)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(store.isPlaying)
        store.setRepeatMode(.all)
        store.skipToNext()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.current, songs.first)
        store.togglePlayPause()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(store.isPlaying)
        XCTAssertLessThanOrEqual(store.positionMs(), store.durationMs())
    }

    func testSettingsUseAndroidKeysAndDefaults() {
        let name = "pixlaudio.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.appearance.appThemeMode, .followSystem)
        XCTAssertEqual(settings.appearance.playerTheme, .albumArt)
        XCTAssertEqual(settings.appearance.paletteStyle, .tonalSpot)
        XCTAssertEqual(settings.playback.crossfadeDurationMs, 2000)
        XCTAssertEqual(settings.library.minSongDurationMs, 10_000)
        XCTAssertEqual(settings.lyrics.tapOffsetBluetoothMs, 180)
        XCTAssertEqual(settings.behavior.launchTab, .home)
        settings.appearance.paletteStyle = .vibrant
        settings.behavior.launchTab = .library
        XCTAssertEqual(defaults.string(forKey: "album_art_palette_style_v1"), "vibrant")
        XCTAssertEqual(defaults.string(forKey: "launch_tab"), "Library")
        XCTAssertEqual(SettingsStore(defaults: defaults).appearance.paletteStyle, .vibrant)
    }

    func testArtworkSourceParsing() {
        XCTAssertEqual(ArtworkSource(uriString: "demo-art://7"), .generated(seed: 7))
        XCTAssertEqual(ArtworkSource(uriString: "https://i.scdn.co/image/x"),
                       .remote(URL(string: "https://i.scdn.co/image/x")!))
        XCTAssertEqual(ArtworkSource(uriString: "file:///tmp/a.jpg"), .file(URL(string: "file:///tmp/a.jpg")!))
        XCTAssertNil(ArtworkSource(uriString: ""))
        XCTAssertNil(ArtworkSource(uriString: "content://media/1"))
    }

    /// Generated art → pixel read → PixlLibrary seed → a coloured scheme (the album-tint pipeline).
    func testGeneratedArtworkProducesAColouredScheme() throws {
        let image = try XCTUnwrap(GeneratedArtwork.render(seed: 9, pixelSize: 128))
        let pixels = try XCTUnwrap(ArtworkPipeline.argbPixels(of: image))
        XCTAssertEqual(pixels.count, 128 * 128)
        let seed = ArtworkTheme.seedColor(argbPixels: pixels)
        let pair = ArtworkTheme.schemePair(seed: seed)
        let primary = pair.light.primary
        let r = (primary >> 16) & 255, g = (primary >> 8) & 255, b = primary & 255
        XCTAssertFalse(r == g && g == b, "a colourful artwork must not give a grey scheme")
    }

    func testThemeColorsAndTypeScale() {
        let colors = ThemeColors.brandDark
        XCTAssertTrue(colors.isDark)
        XCTAssertEqual(colors.argb(\.primary), ArtworkTheme.brandPair.dark.primary)
        XCTAssertEqual(DynamicTypeScale.factor(.large), 1)
        XCTAssertEqual(DynamicTypeScale.factor(.accessibility5), 1.6)
        XCTAssertEqual(PixlTextStyle.bodyLarge.size, 16)
        XCTAssertEqual(PixlTextStyle.headlineSmall.weight(.bold).size, 24)
        XCTAssertGreaterThan(relativeLuminance(argb: 0xFFFF_FFFF), 0.99)
    }

    func testPersistenceRoundTripsTheLibrary() async throws {
        let container = try PersistenceActor.makeContainer(inMemory: true)
        let persistence = PersistenceActor(modelContainer: container)
        try await persistence.replaceLibrary(with: DemoLibrary.snapshot)
        let loaded = try await persistence.loadLibrarySnapshot()
        XCTAssertEqual(Set(loaded.songs.map(\.id)), Set(DemoLibrary.songs.map(\.id)))
        XCTAssertEqual(loaded.albums.count, DemoLibrary.snapshot.albums.count)
        XCTAssertEqual(loaded.playlists.first { $0.id == "demo-playlist-1" }?.songIds,
                       DemoLibrary.snapshot.playlists.first { $0.id == "demo-playlist-1" }?.songIds)
        let pair = ArtworkTheme.brandPair
        try await persistence.saveArtworkTheme(key: "k|tonal_spot", artworkKey: "k", paletteKey: "tonal_spot", pair: pair)
        let restored = try await persistence.artworkTheme(key: "k|tonal_spot")
        XCTAssertEqual(restored, pair)
        try await persistence.deleteArtworkThemes(artworkKey: "k")
        let gone = try await persistence.artworkTheme(key: "k|tonal_spot")
        XCTAssertNil(gone)
    }
}

final class TestToneWriterTests: XCTestCase {
    func testWritesValidPCMWaveHeader() {
        let data = TestToneWriter.makeWAV(seconds: 1)
        XCTAssertEqual(data.count, 44 + TestToneWriter.sampleRate * 2)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")
        // The tone must not clip and must not be silent.
        var peak = 0
        data.withUnsafeBytes { raw in
            var offset = 44
            while offset + 1 < raw.count {
                peak = max(peak, abs(Int(raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))))
                offset += 2
            }
        }
        XCTAssertGreaterThan(peak, 1_000)
        XCTAssertLessThan(peak, Int(Int16.max))
    }
}

final class KeychainStoreTests: XCTestCase {
    func testRoundTrip() throws {
        let account = "tests.\(UUID().uuidString)"
        let payload = Data("hello".utf8)
        do {
            try KeychainStore.set(payload, for: account)
        } catch KeychainStore.KeychainError.status(let status) where status == errSecMissingEntitlement {
            throw XCTSkip("Keychain unavailable in this unsigned simulator build (errSecMissingEntitlement)")
        }
        XCTAssertEqual(try KeychainStore.data(for: account), payload)
        try KeychainStore.delete(account: account)
        XCTAssertNil(try KeychainStore.data(for: account))
    }
}
