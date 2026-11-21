// Host notes of Endless Listening: one short line about a track that is coming, built from facts the app really holds about it (an
// island's name, the atlas' one-line description of a genre, a release year, "new from an artist you play", "a step sideways"). The
// stage 4 set notes (`SetNotes`) stay what they were; these are the host-only kinds, and the two never share a track. A
// transliteration of the Android `:brain` module's `HostNotes.kt`; both reproduce `endless.jsonl` bit for bit.
//
// Rules, all pure:
//  - a note is a template with slots filled from real data; when a slot has nothing to fill it, that kind is not used for the track,
//    and a track nothing can be said about has no note (nothing is invented);
//  - at most one note per `minGap` tracks, counting the set notes already in the queue (`Taken`): a host note starts at least `minGap`
//    tracks away from the start of any other note, and never inside the tracks a set note describes;
//  - every sentence is short (at most `maxWords` words, two sentences at most) so a spoken line can say it as it stands, and a text
//    that holds a word the app never says (`WeeklyNote.forbidden`) is dropped.
//
// Word and sentence counting scan UTF-16 units, as the Kotlin does.

public enum HostNotes {
    public static let minGap = SetNotes.minGap

    public static let maxWords = 12
    public static let maxSentences = 2
    public static let maxFactWords = 9
    public static let maxFactChars = 80

    public static let kindNewFromArtist = 10
    public static let kindSideways = 11
    public static let kindIsland = 12
    public static let kindGenreFact = 13
    public static let kindYear = 14

    /// One upcoming track as the host sees it; "" and 0 are unknown. `genre` is the track's first genre; `genreFact` the atlas'
    /// description of that genre; `island` the name of the taste island the track sits in; `newFromPlayedArtist` says the track is a
    /// new release by an artist the listener plays; `sideways` says the engine picked it from a genre next to the listener's own.
    public struct Slot: Sendable, Equatable {
        public let artist: String
        public let genre: String
        public let genreFact: String
        public let year: Int
        public let island: String
        public let newFromPlayedArtist: Bool
        public let sideways: Bool

        public init(artist: String, genre: String, genreFact: String, year: Int, island: String,
                    newFromPlayedArtist: Bool, sideways: Bool) {
            self.artist = artist
            self.genre = genre
            self.genreFact = genreFact
            self.year = year
            self.island = island
            self.newFromPlayedArtist = newFromPlayedArtist
            self.sideways = sideways
        }
    }

    /// A note already in the queue: the set note that starts at `index` and describes `span` tracks.
    public struct Taken: Sendable, Equatable {
        public let index: Int
        public let span: Int

        public init(index: Int, span: Int) {
            self.index = index
            self.span = span
        }
    }

    /// `a` and `b` are what the template says: see `text`.
    public struct Note: Sendable, Equatable {
        public let index: Int
        public let kind: Int
        public let a: String
        public let b: String

        public init(index: Int, kind: Int, a: String, b: String) {
            self.index = index
            self.kind = kind
            self.a = a
            self.b = b
        }
    }

    /// The host notes of `slots` (the current track first), in order. Never traps. `sinceLast` is how many tracks ago the last note was shown
    /// or spoken before the current track (1 = the track just before it; `minGap` or more = none close enough): the window is made again at
    /// every track, so without it the current track would always be free for a note and one would land on almost every track (see
    /// `tracksSinceNote`).
    public static func notes(_ slots: [Slot], taken: [Taken] = [], sinceLast: Int = minGap) -> [Note] {
        var out: [Note] = []
        var last = -(sinceLast < 1 ? 1 : (sinceLast > minGap ? minGap : sinceLast))
        for i in slots.indices {
            if i - last < minGap { continue }
            if !free(i, taken) { continue }
            guard let note = candidate(slots, i) else { continue }
            out.append(note)
            last = i
        }
        return out
    }

    /// How many tracks before `index` (1 to `minGap` - 1) the nearest earlier queue position sits whose song is in `noted` (the songs whose
    /// note was shown or spoken); `minGap` when none of the `minGap` - 1 tracks before `index` is one. The queue is `ids` in order.
    public static func tracksSinceNote(_ ids: [String], index: Int, noted: Set<String>) -> Int {
        var d = 1
        while d < minGap {
            let j = index - d
            if j >= 0 && j < ids.count && noted.contains(ids[j]) { return d }
            d += 1
        }
        return minGap
    }

    /// True when a note at `index` is at least `minGap` tracks from every taken note and outside the tracks a taken note describes.
    private static func free(_ index: Int, _ taken: [Taken]) -> Bool {
        for t in taken {
            let after = t.index + (t.span > minGap ? t.span : minGap)
            if index >= after { continue }
            if index <= t.index - minGap { continue }
            return false
        }
        return true
    }

    private static func candidate(_ slots: [Slot], _ i: Int) -> Note? {
        let s = slots[i]
        let artist = BrainText.trim(s.artist)
        let genre = BrainText.trim(s.genre)
        var note: Note?
        if s.newFromPlayedArtist && !artist.isEmpty { note = checked(Note(index: i, kind: kindNewFromArtist, a: artist, b: "")) }
        // The engine only says this pick comes from a genre next to the listener's own: the note says that and nothing more.
        if note == nil && s.sideways && !genre.isEmpty { note = checked(Note(index: i, kind: kindSideways, a: genre, b: "")) }
        if note == nil && !BrainText.trim(s.island).isEmpty {
            note = checked(Note(index: i, kind: kindIsland, a: BrainText.trim(s.island), b: ""))
        }
        if note == nil && !genre.isEmpty {
            let fact = factOf(s.genreFact)
            if !fact.isEmpty { note = checked(Note(index: i, kind: kindGenreFact, a: genre, b: fact)) }
        }
        if note == nil && s.year >= 1900 && s.year <= 2100 { note = checked(Note(index: i, kind: kindYear, a: String(s.year), b: "")) }
        return note
    }

    /// The first sentence of an atlas description, cut to a short clause and ended with a full stop; "" when it is empty, too long, or
    /// holds a line break (a long sentence is not shortened, because a shortened one can say something else).
    public static func factOf(_ raw: String) -> String {
        let trimmed = BrainText.trim(raw)
        if trimmed.isEmpty { return "" }
        let u = Array(trimmed.utf16)
        var end = u.count
        var k = 0
        while k < u.count {
            let c = u[k]
            if (c == 0x2E || c == 0x21 || c == 0x3F) && (k + 1 >= u.count || u[k + 1] == 0x20) {
                end = k
                break
            }
            k += 1
        }
        let text = BrainText.trim(String(decoding: u[0..<end], as: UTF16.self))
        let units = Array(text.utf16)
        if text.isEmpty || units.count > maxFactChars || units.contains(0x0A) { return "" }
        if wordCount(text) > maxFactWords { return "" }
        return text
    }

    /// The sentence of `note`.
    public static func text(_ note: Note) -> String {
        switch note.kind {
        case kindNewFromArtist: return "New from \(note.a), an artist you play."
        case kindSideways: return "A step sideways: \(note.a)."
        case kindIsland: return "From your \(note.a) side."
        case kindGenreFact: return "\(note.a): \(note.b)."
        case kindYear: return "Released in \(note.a)."
        default: return ""
        }
    }

    /// `note` when its text is short and clean, else nil (the kind is then not used for the track). The words the app never says are looked
    /// for in what the app wrote (the template and the atlas' sentence), not in a name: an artist called Claude Debussy or a group called
    /// Atmosphere is real data, not copy.
    private static func checked(_ note: Note) -> Note? {
        let t = text(note)
        if t.isEmpty || !isShort(t) { return nil }
        let ours = text(Note(index: note.index, kind: note.kind, a: "", b: note.kind == kindGenreFact ? note.b : ""))
        return isClean(ours) ? note : nil
    }

    /// True when `text` is short (see `isShort`) and has none of the words the app never says (whole words, see `isClean`).
    public static func isSpeakable(_ text: String) -> Bool { isShort(text) && isClean(text) }

    /// True when no word or phrase of `WeeklyNote.forbidden` is in `text` as whole words: "Atmosphere" and "learner" are not "atmos" and
    /// "learn". Compared folded, so "Hi-Res" is "hi res" on both sides.
    public static func isClean(_ text: String) -> Bool {
        let padded = " " + BrainText.fold(text) + " "
        for w in WeeklyNote.forbidden where KotlinText.contains(padded, " " + BrainText.fold(w) + " ", ignoreCase: false) { return false }
        return true
    }

    /// True when `text` has at most `maxSentences` sentences of at most `maxWords` words.
    public static func isShort(_ text: String) -> Bool {
        var sentences = 0
        var words = 0
        var inWord = false
        var any = false
        for c in text.utf16 {
            if c == 0x20 {
                if inWord { words += 1 }
                inWord = false
            } else if c == 0x2E || c == 0x21 || c == 0x3F {
                if inWord { words += 1 }
                inWord = false
                if any {
                    sentences += 1
                    if words > maxWords { return false }
                }
                words = 0
                any = false
            } else {
                inWord = true
                any = true
            }
        }
        if inWord { words += 1 }
        if any {
            sentences += 1
            if words > maxWords { return false }
        }
        return sentences >= 1 && sentences <= maxSentences
    }

    /// The number of words of `text`: runs of non-space characters.
    public static func wordCount(_ text: String) -> Int {
        var words = 0
        var inWord = false
        for c in text.utf16 {
            if c == 0x20 {
                inWord = false
            } else if !inWord {
                inWord = true
                words += 1
            }
        }
        return words
    }
}
