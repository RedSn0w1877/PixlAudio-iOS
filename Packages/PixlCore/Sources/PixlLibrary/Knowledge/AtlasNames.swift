// Which atlas names the listener may read. The atlas is data (CC0, byte for byte as published), and a few real genres carry a
// word the app never says ("atmospheric ..." holds "atmos"). Such a node is treated as absent in everything the listener sees
// (cards, Search tiles, island names, "A step sideways"): never renamed, never guessed. A port of Android's `AtlasNames.kt`; the
// check is by substring, like the copy test.

import Foundation

public enum AtlasNames {
    static let forbidden = ["lossless", "hi-res", "hires", "dolby", "atmos", "360 reality", "claude", "anthropic", "binilyrics",
                            "enhanced", "learn"]

    /// True when `name` may be shown.
    public static func isShown(_ name: String?) -> Bool {
        guard let name, !BrainText.isBlank(name) else { return false }
        let lower = name.lowercased()
        for word in forbidden where lower.contains(word) { return false }
        return true
    }

    /// The genre's name when it may be shown, else nil.
    public static func genreName(_ atlas: GenreAtlas, _ id: Int) -> String? {
        guard let name = atlas.genre(id)?.name, isShown(name) else { return nil }
        return name
    }

    /// The mood's name when it may be shown, else nil.
    public static func moodName(_ atlas: GenreAtlas, _ id: Int) -> String? {
        guard id >= 0, id < atlas.moods.count, isShown(atlas.moods[id]) else { return nil }
        return atlas.moods[id]
    }
}
