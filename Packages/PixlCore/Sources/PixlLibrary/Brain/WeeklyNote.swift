// The weekly note on First Listen (docs/brain-spec.md, 9.3 and 9.4, stage 4 milestone 2): two or three sentences about this week's list.
// A transliteration of the Android `:brain` module's `WeeklyNote.kt`; both reproduce `weeklynote.jsonl` bit for bit.

/// The words come from one cloud call a week over a handful of evidence rows, with the template here as the fallback when the call is not
/// made (offline, over budget, switched off) or when its answer is not clearly true of the evidence (`check`). Nothing here ranks and
/// nothing invents: every name and every number in a note is in the evidence rows or the note is not shown. A plain function of its
/// inputs, no clock and no I/O.
public enum WeeklyNote {
    /// Bump when the instruction text or the evidence rows change: the cache is keyed by it.
    public static let promptVersion = 1

    public static let maxChars = 420
    public static let minSentences = 2
    public static let maxSentences = 3

    /// Words the app never says, in any user-visible text (the copy rule), and the one stage 3 allows only where it is true.
    public static let forbidden: [String] = [
        "lossless", "hi-res", "hires", "dolby", "atmos", "360 reality", "claude", "anthropic", "binilyrics", "enhanced", "learn",
    ]

    /// What is known about this week's list. -1 and "" are unknown, and an unknown row is left out of the note and the evidence.
    /// `artists` are the first artists of the list in order (at most three are used); `genre` is the name of the adjacent genre the list
    /// leans on; `island` the taste island that genre sits next to; `newSharePct` the share of the last 7 days' plays that were new.
    public struct Evidence: Sendable, Equatable {
        public let tracks: Int
        public let newSongs: Int
        public let artists: [String]
        public let genre: String
        public let island: String
        public let newSharePct: Int

        public init(tracks: Int, newSongs: Int, artists: [String], genre: String, island: String, newSharePct: Int) {
            self.tracks = tracks
            self.newSongs = newSongs
            self.artists = artists
            self.genre = genre
            self.island = island
            self.newSharePct = newSharePct
        }
    }

    private static func artistsOf(_ e: Evidence) -> [String] {
        var out: [String] = []
        for a in e.artists {
            let t = BrainText.trim(a)
            if !t.isEmpty && !out.contains(where: { KotlinText.equals($0, t) }) { out.append(t) }
            if out.count == 3 { break }
        }
        return out
    }

    /// "a", "a and b", "a, b and c".
    public static func joinNames(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return names[0] + " and " + names[1]
        default: return names[0] + ", " + names[1] + " and " + names[2]
        }
    }

    /// The note when no model wrote it: up to three sentences, each one true of the evidence. "" when there is nothing to say (no tracks).
    public static func template(_ e: Evidence) -> String {
        if e.tracks < 1 { return "" }
        var s = "This week's First Listen has " + (e.tracks == 1 ? "1 song" : "\(e.tracks) songs")
        if e.newSongs >= 1 && e.newSongs <= e.tracks {
            s += ", and \(e.newSongs)" + (e.newSongs == 1 ? " of them is not in your library yet." : " of them are not in your library yet.")
        } else {
            s += "."
        }
        let genre = BrainText.trim(e.genre)
        let island = BrainText.trim(e.island)
        let artists = artistsOf(e)
        if !genre.isEmpty && !island.isEmpty {
            s += " Some of it is \(genre), which sits next to \(island)."
        } else if !genre.isEmpty {
            s += " Some of it is \(genre), a genre next to what you play."
        } else if !artists.isEmpty {
            s += " It opens with songs by " + joinNames(artists) + "."
        }
        if e.newSharePct >= 0 && e.newSharePct <= 100 {
            s += " In the last 7 days, \(e.newSharePct)% of what you played was new to you."
        }
        return s
    }

    /// The evidence as the lines the model is given (and the text its answer is checked against). Unknown rows are left out.
    public static func evidenceLines(_ e: Evidence) -> String {
        var s = "songs in this week's list: \(e.tracks)\n"
        if e.newSongs >= 0 { s += "songs in the list that are not in the listener's library yet: \(e.newSongs)\n" }
        let artists = artistsOf(e)
        if !artists.isEmpty { s += "first artists in the list: " + joinNames(artists) + "\n" }
        if !BrainText.isBlank(e.genre) { s += "the genre the list leans on: " + BrainText.trim(e.genre) + "\n" }
        if !BrainText.isBlank(e.island) { s += "the taste it sits next to: " + BrainText.trim(e.island) + "\n" }
        if e.newSharePct >= 0 { s += "share of the listener's plays in the last 7 days that were new to them: \(e.newSharePct)%\n" }
        return s
    }

    /// Hash of the evidence and the prompt version: one cloud call per week, and none when nothing changed.
    public static func evidenceHash(_ e: Evidence) -> Int64 {
        BrainHash.id(BrainHash.fnv1a64("weekly|\(promptVersion)|" + evidenceLines(e)))
    }

    /// The registry a note is checked against: the names in the evidence, and its numbers.
    public static func registry(_ e: Evidence) -> Grounding.Registry {
        var r = Grounding.Registry()
        for a in artistsOf(e) { r.addName(a) }
        r.addName(e.genre)
        r.addName(e.island)
        r.addText(evidenceLines(e))
        r.addNumber(e.tracks)
        if e.newSongs >= 0 { r.addNumber(e.newSongs) }
        if e.newSharePct >= 0 { r.addNumber(e.newSharePct) }
        return r
    }

    /// `cloud` if it is a note we may show, else nil (the caller shows `template`). It must be two or three sentences of at most
    /// `maxChars`, with no word of `forbidden`, no line break or list, and every name and number in it must come from `e` (a name is
    /// marked `[[Name]]` by the model, as in the chat; the marks are taken off).
    public static func check(_ cloud: String, _ e: Evidence) -> String? {
        let text = oneLine(cloud)
        if text.isEmpty || text.utf16.count > maxChars { return nil }
        let folded = BrainText.fold(text)
        for w in forbidden where KotlinText.contains(folded, w, ignoreCase: false) { return nil }
        let sentences = sentenceCount(text)
        if sentences < minSentences || sentences > maxSentences { return nil }
        let verdict = Grounding.check(text, registry(e), userText: "", placeholder: "\u{0}", dropUngroundedNumbers: false)
        if !verdict.ok { return nil }
        for c in verdict.cleaned.utf16 where c == 0 || c == 0x5B || c == 0x5D { return nil }
        return BrainText.trim(verdict.cleaned)
    }

    /// `raw` with its line breaks and runs of spaces turned into single spaces.
    public static func oneLine(_ raw: String) -> String {
        var out: [UInt16] = []
        var lastSpace = true
        for c in raw.utf16 {
            let space = c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09
            if space {
                if !lastSpace { out.append(0x20) }
                lastSpace = true
            } else {
                out.append(c)
                lastSpace = false
            }
        }
        return BrainText.trim(String(decoding: out, as: UTF16.self))
    }

    /// Sentences are ended by `.`, `!` or `?` followed by a space or the end; a number's decimal point is not an end.
    public static func sentenceCount(_ text: String) -> Int {
        let t = Array(text.utf16)
        var n = 0
        var i = 0
        func isEnd(_ c: UInt16) -> Bool { c == 0x2E || c == 0x21 || c == 0x3F }
        while i < t.count {
            let c = t[i]
            if isEnd(c) {
                let next: UInt16 = i + 1 < t.count ? t[i + 1] : 0x20
                if next == 0x20 { n += 1 }
                while i + 1 < t.count && isEnd(t[i + 1]) { i += 1 }
            }
            i += 1
        }
        // A last sentence with no ending mark still counts.
        var last = t.count
        while last > 0 && BrainText.isWhitespace(UInt32(t[last - 1])) { last -= 1 }
        if last > 0 && !isEnd(t[last - 1]) { n += 1 }
        return n
    }
}
