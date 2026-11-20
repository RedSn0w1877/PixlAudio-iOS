// What the listener sees under an Ask Taizo answer (docs/brain-spec.md, 9.3 "What the listener gets", stage 4 milestone 2): the chips under a
// mix card, their words, and the one-tap "Less X" that ends an explanation. A transliteration of the Android `:brain` module's
// `AssistantCards.kt`; both reproduce `assistantcards.jsonl` bit for bit.

/// A plain function of its inputs: a chip is a delta on the stored request applied on the device with no model call. The chips themselves
/// (`AssistantRules.Chip`, `applyChip`, `chipsFor`) are milestone 1's and unchanged; this adds the chips beyond the first three and the
/// words every chip wears.
public enum AssistantCards {
    /// At most this many chips under one card.
    public static let maxChips = 6

    /// A name in a chip longer than this is cut (a chip is one line), in UTF-16 units as on Android.
    public static let maxName = 22

    /// The share of new music at which "More new" stops doing anything (the planner caps it at `MixPlanner.nuMax`).
    public static let shareTop = 60

    /// The chips under a mix card, in this order: `AssistantRules.chipsFor` (Less artist, More genre, Shorter or Longer), then one chip for
    /// the pace (Slower, or Calmer when tempo is not known for this listener's tracks, none when neither filter can be applied), then
    /// More new and More familiar, each only when it can change the request. `unsupported` is the list of filters the mix could not apply:
    /// a chip for a filter nobody can answer is not offered.
    public static func allChips(_ q: AssistantRules.Query, topArtistRef: String, topGenreId: Int, unsupported: [String]) -> [AssistantRules.Chip] {
        var out: [AssistantRules.Chip] = []
        out.append(contentsOf: AssistantRules.chipsFor(q, topArtistRef: topArtistRef, topGenreId: topGenreId))
        let tempoOk = !unsupported.contains { KotlinText.equals($0, AssistantRules.filterTempo) }
        let energyOk = !unsupported.contains { KotlinText.equals($0, AssistantRules.filterEnergy) }
        if tempoOk && q.tempo != AssistantRules.slow {
            out.append(AssistantRules.Chip(kind: AssistantRules.chipSlower))
        } else if energyOk && q.energy != AssistantRules.lower {
            out.append(AssistantRules.Chip(kind: AssistantRules.chipLowerEnergy))
        }
        let share = q.noveltySharePct >= 0 ? q.noveltySharePct : AssistantRules.shareBase
        if share < shareTop { out.append(AssistantRules.Chip(kind: AssistantRules.chipMoreNew)) }
        if share > 0 { out.append(AssistantRules.Chip(kind: AssistantRules.chipMoreFamiliar)) }
        return out.count > maxChips ? Array(out[0..<maxChips]) : out
    }

    /// The words of a chip. "Less Sabrina Carpenter", "More R&B", "Shorter". A chip that is about a name has no label without one ("" is
    /// "do not show it"): the label never guesses a name.
    public static func chipLabel(_ chip: AssistantRules.Chip, artistName: String, genreName: String) -> String {
        switch chip.kind {
        case AssistantRules.chipLessArtist: return withName("Less ", artistName)
        case AssistantRules.chipMoreGenre: return withName("More ", genreName)
        case AssistantRules.chipLessGenre: return withName("Less ", genreName)
        case AssistantRules.chipShorter: return "Shorter"
        case AssistantRules.chipLonger: return "Longer"
        case AssistantRules.chipMoreNew: return "More new"
        case AssistantRules.chipMoreFamiliar: return "More familiar"
        case AssistantRules.chipSlower: return "Slower"
        case AssistantRules.chipFaster: return "Faster"
        case AssistantRules.chipLowerEnergy: return "Calmer"
        case AssistantRules.chipHigherEnergy: return "Livelier"
        default: return ""
        }
    }

    private static func withName(_ prefix: String, _ rawName: String) -> String {
        let name = shortName(rawName)
        return name.isEmpty ? "" : prefix + name
    }

    /// `raw` on one line and at most `maxName` units; a longer name ends in an ellipsis.
    public static func shortName(_ raw: String) -> String {
        let t = AssistantRules.cleanTitle(raw)
        let u = Array(t.utf16)
        if u.count <= maxName { return t }
        let head = BrainText.trim(String(decoding: u[0..<(maxName - 1)], as: UTF16.self))
        return head + "\u{2026}"
    }

    // MARK: "Less X": the one tap that ends an explanation

    public static let namedGenre = 0
    public static let namedArtist = 1

    /// A genre or an artist that a tool result held (so it is real) and that a "Less X" could be about.
    public struct Named: Sendable, Equatable {
        public let kind: Int
        public let name: String

        public init(kind: Int, name: String) {
            self.kind = kind
            self.name = name
        }
    }

    /// Which of `named` the listener asked about in `userText` ("Why do I keep getting trap?" names trap): the longest of them that is a
    /// whole-word run of what they wrote, ties to the earlier one. nil when none is, and then no chip is offered: a "Less X" for a thing the
    /// listener did not ask about would be a guess. Names shorter than two characters never match (a one-letter name is in every sentence).
    public static func lessTarget(userText: String, named: [Named]) -> Named? {
        let text = Array((" " + BrainText.trim(BrainText.fold(userText)) + " ").utf16)
        var best: Named?
        var bestLen = 0
        for n in named {
            let f = Array(BrainText.trim(BrainText.fold(n.name)).utf16)
            if f.count < 2 { continue }
            if containsWords(text, f) && f.count > bestLen {
                best = n
                bestLen = f.count
            }
        }
        return best
    }

    /// True when `needle` occurs in `haystack` with no word character on either side.
    private static func containsWords(_ haystack: [UInt16], _ needle: [UInt16]) -> Bool {
        var from = 0
        while true {
            let at = Grounding.indexOf(haystack, needle, from)
            if at < 0 { return false }
            let before: UInt16 = at > 0 ? haystack[at - 1] : 0x20
            let afterIndex = at + needle.count
            let after: UInt16 = afterIndex < haystack.count ? haystack[afterIndex] : 0x20
            if !isWordChar(before) && !isWordChar(after) { return true }
            from = at + 1
        }
    }

    private static func isWordChar(_ c: UInt16) -> Bool { (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c > 0x7F }

    /// The words of the one-tap chip: "Less trap". An empty name has no chip.
    public static func lessLabel(_ name: String) -> String { withName("Less ", name) }
}
