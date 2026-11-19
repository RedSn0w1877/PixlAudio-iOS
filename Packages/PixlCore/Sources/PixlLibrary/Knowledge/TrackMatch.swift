// Whether a track a source returned is the track the brain asked about (docs/brain-spec.md, 3.3 B: "accept the first
// hit whose folded title and primary artist match and whose duration is within 3 s"). Pure, so every source client and
// its tests share it. A port of Android's `TrackMatch.kt`.
//
// Titles are compared after `BrainText.cleanTitle` (so "Blinding Lights - Radio Edit" is "Blinding Lights") and only as
// folded text; a version the listener's track does not have ("live", "remix", "instrumental") is a different recording
// and is refused.

public enum TrackMatch {
    public static let durationToleranceMs = 3_000

    /// What the listener's track is.
    public struct Want: Sendable {
        public let title: String
        public let artist: String
        public let durationMs: Int
        public let clean: BrainText.CleanTitle
        public let artistFolded: String

        public init(title: String, artist: String, durationMs: Int) {
            self.title = title
            self.artist = artist
            self.durationMs = durationMs
            clean = BrainText.cleanTitle(title)
            artistFolded = BrainText.trim(BrainText.fold(artist))
        }
    }

    public static func titleMatches(_ want: Want, _ gotTitle: String) -> Bool {
        let got = BrainText.cleanTitle(gotTitle)
        if !BrainKey.sameBytes(got.title, want.clean.title) { return false }
        // A remix, a live take or a karaoke version is another recording unless the listener's own track is one too.
        let extra = got.identityFlags & ~want.clean.identityFlags
        return extra == 0
    }

    /// True when `gotNames` holds the artist: the same folded name, or one whole-word run inside the other ("A" in "A & B").
    public static func artistMatches(_ want: Want, _ gotNames: [String]) -> Bool {
        let w = want.artistFolded
        if w.isEmpty { return false }
        for g in gotNames {
            let f = BrainText.trim(BrainText.fold(g))
            if f.isEmpty { continue }
            if BrainKey.sameBytes(f, w) { return true }
            let (short, long) = f.utf16.count <= w.utf16.count ? (f, w) : (w, f)
            if short.utf16.count >= 3 && containsBytes(" " + long + " ", " " + short + " ") { return true }
        }
        return false
    }

    private static func containsBytes(_ haystack: String, _ needle: String) -> Bool {
        let h = Array(haystack.utf8), n = Array(needle.utf8)
        if n.isEmpty { return true }
        if n.count > h.count { return false }
        var i = 0
        while i + n.count <= h.count {
            var j = 0
            while j < n.count && h[i + j] == n[j] { j += 1 }
            if j == n.count { return true }
            i += 1
        }
        return false
    }

    /// Unknown on either side is close enough; otherwise within `durationToleranceMs`.
    public static func durationClose(wantMs: Int, gotMs: Int) -> Bool {
        if wantMs <= 0 || gotMs <= 0 { return true }
        let d = wantMs > gotMs ? wantMs - gotMs : gotMs - wantMs
        return d <= durationToleranceMs
    }

    /// A MusicBrainz recording's disambiguation ("live, 2024-09-07: Sao Paulo") that names a version the listener's
    /// track lacks.
    public static func disambiguationRefuses(_ want: Want, _ disambiguation: String) -> Bool {
        if BrainText.isBlank(disambiguation) { return false }
        let flags = BrainText.cleanTitle("x (\(disambiguation))").versionFlags & ~BrainText.flagRemaster
        // "live, 2024-09-07: ..." starts with the word; cleanTitle also reads "live" inside the group.
        let folded = BrainText.trim(BrainText.fold(disambiguation))
        let firstWord = folded.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? folded
        var named = flags
        switch firstWord {
        case "live": named |= BrainText.flagLive
        case "remix": named |= BrainText.flagRemix
        case "instrumental": named |= BrainText.flagInstrumental
        case "karaoke": named |= BrainText.flagKaraoke
        case "acoustic": named |= BrainText.flagAcoustic
        default: break
        }
        return (named & ~want.clean.identityFlags) != 0
    }
}
