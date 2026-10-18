import Foundation
import Testing
@testable import PixlBackup

/// The 2026-10-18 iOS-only settings (blocked artists, gestures, Music Haptics) travel in the global-settings module.
@Suite struct IosFeatureKeysTests {
    private let blocked = "[{\"artistId\":4,\"name\":\"Someone\",\"blockedAt\":9}]"

    @Test func everyNewKeyIsPortableAndListedOnce() {
        let keys = ["blocked_artists_json", "gesture_player_artwork_swipe", "gesture_player_artwork_double_tap_like",
                    "gesture_player_artwork_long_press", "gesture_mini_swipe_skip", "gesture_mini_swipe_up_open",
                    "gesture_mini_long_press", "gesture_list_swipe_queue", "music_haptics_enabled",
                    "music_haptics_strength", "music_haptics_mode"]
        for key in keys {
            #expect(AndroidPreferenceCatalog.kind(of: key) == .portable, "\(key)")
            #expect(AndroidPreferenceCatalog.iosOnly.filter { $0 == key }.count == 1, "\(key)")
        }
    }

    @Test func theBlockedListAndTheSwitchesRoundTrip() throws {
        let payload = PreferencesModule.export(.globalSettings, values: [
            ("blocked_artists_json", .string(blocked)),
            ("gesture_mini_swipe_skip", .bool(false)),
            ("music_haptics_enabled", .bool(true)),
            ("music_haptics_strength", .int(140)),
            ("music_haptics_mode", .string("bass")),
        ])
        let restored = try PreferencesModule.restore(.globalSettings, payload: payload)
        #expect(restored.skippedKeys.isEmpty)
        #expect(restored.values.map(\.key) == ["blocked_artists_json", "gesture_mini_swipe_skip", "music_haptics_enabled",
                                               "music_haptics_strength", "music_haptics_mode"])
        #expect(restored.values.first?.value == .string(blocked))
        #expect(restored.values[3].value == .int(140))
    }
}
