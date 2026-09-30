import XCTest
@testable import PixlAudio

@MainActor
final class LaunchConfigurationTests: XCTestCase {
    func testParsesUITestArguments() {
        let launch = LaunchConfiguration(arguments: [
            "PixlAudio", "-uiTest", "-screen", "diagnostics", "-appearance", "dark",
        ])
        XCTAssertTrue(launch.isUITest)
        XCTAssertEqual(launch.screen, .diagnostics)
        XCTAssertEqual(launch.appearance, .dark)
        XCTAssertEqual(launch.colorScheme, .dark)
    }

    func testDefaultsWithoutArguments() {
        let launch = LaunchConfiguration(arguments: ["PixlAudio"])
        XCTAssertFalse(launch.isUITest)
        XCTAssertNil(launch.screen)
        XCTAssertEqual(launch.appearance, .system)
        XCTAssertNil(launch.colorScheme)
    }

    func testIgnoresUnknownValuesAndTrailingFlags() {
        let launch = LaunchConfiguration(arguments: ["PixlAudio", "-screen", "nope", "-appearance"])
        XCTAssertNil(launch.screen)
        XCTAssertEqual(launch.appearance, .system)
    }

    func testInitialStateRoutesEveryScreen() {
        func state(_ screen: DemoScreen) -> UITestLaunchRouter.InitialState {
            UITestLaunchRouter.initialState(for: LaunchConfiguration(arguments: ["-uiTest", "-screen", screen.rawValue]))
        }
        XCTAssertEqual(state(.home).tab, .home)
        XCTAssertEqual(state(.library).tab, .library)
        XCTAssertEqual(state(.miniPlayer).tab, .library)
        XCTAssertEqual(state(.search).tab, .search)
        XCTAssertEqual(state(.search).searchText, "")
        XCTAssertEqual(state(.searchResults).searchText, UITestLaunchRouter.defaultSearchQuery)
        XCTAssertEqual(state(.settings).homePath, [.settings])
        XCTAssertEqual(state(.diagnostics).homePath, [.settings, .diagnostics])
    }

    func testRouterActivatesSearchOnlyForSearchScreens() {
        XCTAssertTrue(Router(launch: LaunchConfiguration(arguments: ["-uiTest", "-screen", "search"])).isSearchPresented)
        XCTAssertTrue(Router(launch: LaunchConfiguration(arguments: ["-uiTest", "-screen", "searchResults"])).isSearchPresented)
        XCTAssertFalse(Router(launch: LaunchConfiguration(arguments: ["-uiTest", "-screen", "home"])).isSearchPresented)
    }

    func testDemoSearchMatchesTitleArtistAndAlbum() {
        let library = DemoLibrary()
        XCTAssertFalse(library.search(UITestLaunchRouter.defaultSearchQuery).isEmpty)
        XCTAssertFalse(library.search("glass").isEmpty)
        XCTAssertTrue(library.search("   ").isEmpty)
        XCTAssertEqual(library.songs.first?.durationText, "3:34")
    }

    func testPlaybackStoreSkipsAndWraps() {
        let library = DemoLibrary()
        let store = PlaybackStore(demoQueue: library.songs)
        XCTAssertEqual(store.current, library.songs.first)
        store.play(library.songs[library.songs.count - 1])
        store.skipToNext()
        XCTAssertEqual(store.current, library.songs.first)
        XCTAssertTrue(store.isPlaying)
        store.togglePlayPause()
        XCTAssertFalse(store.isPlaying)
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
