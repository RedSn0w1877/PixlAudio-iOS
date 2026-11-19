// What a radio's tuning chip says about the music inside it (docs/brain-spec.md, 3.4 tag source 4, stage 2a: "chips
// mapped to tags and stored for stage 2b"). A transliteration of the Android `:brain` module's `ChipLabels.kt`.

/// A YouTube Music radio offers chips such as "Popular", "Deep cuts", "V-pop", "2010s", "Workout". Only some of them
/// describe the music: a genre, a decade, a mood. The rest ("Popular", "Discover", "All") only steer the radio. Stage
/// 2b's genre atlas turns a `genre` label into an atlas id; until then the folded label is what is stored, and an
/// unknown label is `unknown`, never a guessed genre (principle 7: unknown stays unknown).
public enum ChipLabels {
    public enum Kind: String, Sendable { case genre = "GENRE", decade = "DECADE", mood = "MOOD", steer = "STEER", unknown = "UNKNOWN" }

    /// A classified chip: `key` is the folded label; for a decade, `"2010s"`.
    public struct Chip: Sendable, Equatable {
        public let kind: Kind
        public let key: String
    }

    private static let steer: Set<String> = folded(
        "all", "popular", "deep cuts", "discover", "familiar", "new releases", "recent", "trending", "hits", "unplayed")
    private static let moods: Set<String> = folded(
        "party", "romance", "workout", "chill", "sad", "happy", "focus", "sleep", "energize", "feel good", "relax",
        "commute", "gaming", "love", "dance", "study")
    // Labels that name a genre in the words YouTube Music uses. The atlas of stage 2b maps them to ids.
    private static let genres: Set<String> = folded(
        "pop", "adult pop", "alternative", "electronic", "rock", "hip hop", "hip-hop", "rap", "r&b", "r&b & soul", "soul",
        "country", "jazz", "blues", "classical", "metal", "folk", "indie", "latin", "reggae", "k-pop", "j-pop", "v-pop",
        "c-pop", "dance & electronic", "indie & alternative", "punk", "disco", "funk", "house", "techno", "ambient",
        "soundtrack", "gospel", "afrobeats", "bollywood", "opm", "mandopop", "cantopop")

    // The tables are written in the labels' own words and folded the way a label is before the lookup.
    private static func folded(_ labels: String...) -> Set<String> {
        var out: Set<String> = []
        for l in labels { out.insert(BrainText.trim(BrainText.fold(l))) }
        return out
    }

    /// Classifies one chip label. Case, accents and spacing do not matter.
    public static func classify(_ label: String) -> Chip {
        let key = BrainText.trim(BrainText.fold(label))
        if key.isEmpty { return Chip(kind: .unknown, key: "") }
        if steer.contains(key) { return Chip(kind: .steer, key: key) }
        if let decade = decadeOf(key) { return Chip(kind: .decade, key: decade) }
        if moods.contains(key) { return Chip(kind: .mood, key: key) }
        if genres.contains(key) { return Chip(kind: .genre, key: key) }
        return Chip(kind: .unknown, key: key)
    }

    /// "2010s", "1990s", "80s", "'90s": the decade as `"2010s"`; nil for anything else.
    public static func decadeOf(_ key: String) -> String? {
        var scalars = Array(BrainText.trim(key).unicodeScalars)
        if let first = scalars.first, first.value == 0x27 { scalars.removeFirst() }
        if scalars.count < 3 { return nil }
        guard let last = scalars.last, last.value == 0x73 else { return nil }
        let digits = scalars.dropLast()
        if digits.isEmpty { return nil }
        var n = 0
        for d in digits {
            if d.value < 0x30 || d.value > 0x39 { return nil }
            n = n * 10 + Int(d.value - 0x30)
        }
        let year: Int
        if digits.count == 4 {
            year = n
        } else if digits.count == 2 {
            year = n >= 30 ? 1900 + n : 2000 + n
        } else {
            return nil
        }
        if year < 1900 || year > 2090 || year % 10 != 0 { return nil }
        return "\(year)s"
    }
}
