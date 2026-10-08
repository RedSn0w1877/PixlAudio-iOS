import Foundation
import Observation
import PixlLyrics

/// The lyrics screen's own look preferences (Android DataStore keys read by `rememberLyricsAppearancePrefs` and the
/// More sheet): alignment, translation and romanisation visibility. The blur preferences live in `LyricsSettings`
/// (Settings › Appearance) and `disable_blur_all_over`. Android's `keep_screen_on_lyrics` is retired: the lyrics
/// screen always keeps the screen on (owner, 2026-10-07), so the stored value is dropped and never read.
@Observable
final class LyricsViewPreferences {
    private let defaults: UserDefaults

    /// Android's "Keep screen on" switch, retired on iOS (always on); removed from the defaults so it never lingers.
    static let retiredKeepScreenOnKey = "keep_screen_on_lyrics"

    /// "left", "center" or "right".
    var alignment: String { didSet { defaults.set(alignment, forKey: LyricsAppearancePrefs.Key.alignment) } }
    var showTranslation: Bool {
        didSet { defaults.set(showTranslation, forKey: LyricsAppearancePrefs.Key.showTranslation) }
    }
    var showRomanization: Bool {
        didSet { defaults.set(showRomanization, forKey: LyricsAppearancePrefs.Key.showRomanization) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        alignment = defaults.string(LyricsAppearancePrefs.Key.alignment, default: "left")
        showTranslation = defaults.bool(LyricsAppearancePrefs.Key.showTranslation, default: true)
        showRomanization = defaults.bool(LyricsAppearancePrefs.Key.showRomanization, default: true)
        defaults.removeObject(forKey: Self.retiredKeepScreenOnKey)
    }

    /// `disable_blur_all_over` (Settings › Appearance; global "no blur" switch).
    var disableBlurAllOver: Bool { defaults.bool(PreferenceKeys.disableBlurAllOver, default: false) }

    // MARK: Per-song sync offsets (Android `lyrics_sync_offsets_json`: a JSON object songId → ms)

    func offset(for songId: String) -> Int { offsets()[songId] ?? 0 }

    func setOffset(_ ms: Int, for songId: String) {
        var map = offsets()
        if ms == 0 { map[songId] = nil } else { map[songId] = ms }
        if let data = try? JSONEncoder().encode(map), let json = String(data: data, encoding: .utf8) {
            defaults.set(json, forKey: PreferenceKeys.lyricsSyncOffsets)
        }
    }

    private func offsets() -> [String: Int] {
        guard let json = defaults.string(forKey: PreferenceKeys.lyricsSyncOffsets), let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return map
    }

    /// The store for this launch: the UI-test suite under `-uiTest`, else the standard defaults.
    static func make(isUITest: Bool) -> LyricsViewPreferences {
        if isUITest, let suite = UserDefaults(suiteName: "pixlaudio.uitest") {
            return LyricsViewPreferences(defaults: suite)
        }
        return LyricsViewPreferences(defaults: .standard)
    }
}
