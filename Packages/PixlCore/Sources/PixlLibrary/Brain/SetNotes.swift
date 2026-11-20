// Set notes (docs/brain-spec.md, 9.3 "What the listener gets", stage 4 milestone 2): one line in the queue, and under the player title,
// that says what the next few tracks are: "Three from your V-pop side, then something new from HIEUTHUHAI." A transliteration of the
// Android `:brain` module's `SetNotes.kt`; both reproduce `setnotes.jsonl` bit for bit.

/// No voice and no model call: the line is a template filled from the queue itself, so it is true of the queue it describes, and it is
/// gone the moment the queue changes (the caller recomputes it from the queue it has).
///
/// A note describes a group: a run of two to five tracks the listener already has, then, when the next track is one they do not have,
/// that track. At most one note per five tracks.
public enum SetNotes {
    /// The least distance between the starts of two notes: at most one note per five tracks.
    public static let minGap = 5

    /// The longest run of known tracks a note describes.
    public static let maxGroup = 5

    public static let minGroup = 2

    /// One upcoming track, as the queue shows it. `known` is true for a track in the listener's own library; `genre` is the name of its
    /// first genre, "" when unknown; `artist` is its primary artist, "" when unknown.
    public struct Slot: Sendable, Equatable {
        public let artist: String
        public let genre: String
        public let known: Bool

        public init(artist: String, genre: String, known: Bool) {
            self.artist = artist
            self.genre = genre
            self.known = known
        }
    }

    public static let kindGenreThenNew = 0
    public static let kindArtistThenNew = 1
    public static let kindKnownThenNew = 2
    public static let kindGenreOnly = 3

    /// `index` is the slot the note sits on (its first track); `count` the tracks it counts; `genre` and `artist` what the group shares
    /// (kind 0 and 3: the genre; kind 1: the artist); `newArtist` the artist of the new track that follows (kinds 0 to 2).
    public struct Note: Sendable, Equatable {
        public let index: Int
        public let kind: Int
        public let count: Int
        public let genre: String
        public let artist: String
        public let newArtist: String

        public init(index: Int, kind: Int, count: Int, genre: String, artist: String, newArtist: String) {
            self.index = index
            self.kind = kind
            self.count = count
            self.genre = genre
            self.artist = artist
            self.newArtist = newArtist
        }
    }

    /// The notes of `slots`, in order, each at least `minGap` slots after the one before. Never traps.
    public static func notes(_ slots: [Slot]) -> [Note] {
        var out: [Note] = []
        var i = 0
        let n = slots.count
        while i < n {
            var k = 0
            while i + k < n && k < maxGroup && slots[i + k].known { k += 1 }
            if k < minGroup {
                i += 1
                continue
            }
            let next: Slot? = i + k < n ? slots[i + k] : nil
            let newNext = next != nil && !next!.known && !BrainText.isBlank(next!.artist)
            let genre = sharedGenre(slots, i, k)
            let artist = sharedArtist(slots, i, k)
            var made: Note?
            var span = k
            if newNext, let next {
                span = k + 1
                let newArtist = BrainText.trim(next.artist)
                if !genre.isEmpty {
                    made = Note(index: i, kind: kindGenreThenNew, count: k, genre: genre, artist: "", newArtist: newArtist)
                } else if !artist.isEmpty {
                    made = Note(index: i, kind: kindArtistThenNew, count: k, genre: "", artist: artist, newArtist: newArtist)
                } else {
                    made = Note(index: i, kind: kindKnownThenNew, count: k, genre: "", artist: "", newArtist: newArtist)
                }
            } else if k >= 3 && !genre.isEmpty {
                made = Note(index: i, kind: kindGenreOnly, count: k, genre: genre, artist: "", newArtist: "")
            }
            guard let made else {
                i += 1
                continue
            }
            out.append(made)
            i += span > minGap ? span : minGap
        }
        return out
    }

    /// The genre all `k` slots from `from` share (compared folded), or "" when any has none or they differ. The first slot's spelling is kept.
    private static func sharedGenre(_ slots: [Slot], _ from: Int, _ k: Int) -> String {
        let first = BrainText.trim(slots[from].genre)
        if first.isEmpty { return "" }
        let key = BrainText.fold(first)
        for j in stride(from: 1, to: k, by: 1) {
            let g = BrainText.trim(slots[from + j].genre)
            if g.isEmpty || !KotlinText.equals(BrainText.fold(g), key) { return "" }
        }
        return first
    }

    private static func sharedArtist(_ slots: [Slot], _ from: Int, _ k: Int) -> String {
        let first = BrainText.trim(slots[from].artist)
        if first.isEmpty { return "" }
        let key = BrainText.fold(first)
        for j in stride(from: 1, to: k, by: 1) {
            let a = BrainText.trim(slots[from + j].artist)
            if a.isEmpty || !KotlinText.equals(BrainText.fold(a), key) { return "" }
        }
        return first
    }

    /// "Two", "Three", "Four", "Five".
    public static func countWord(_ count: Int) -> String {
        switch count {
        case 2: return "Two"
        case 3: return "Three"
        case 4: return "Four"
        case 5: return "Five"
        default: return String(count)
        }
    }

    /// The first genre of a genre field: Spotify joins several with a comma, a semicolon or a slash. "" for none.
    public static func firstGenre(_ raw: String?) -> String {
        guard let raw else { return "" }
        let u = Array(raw.utf16)
        var end = u.count
        for sep: UInt16 in [0x2C, 0x3B, 0x2F, 0x7C] {
            if let at = u.firstIndex(of: sep), at < end { end = at }
        }
        return BrainText.trim(String(decoding: u[0..<end], as: UTF16.self))
    }

    /// The sentence of `note`.
    public static func text(_ note: Note) -> String {
        let c = countWord(note.count)
        switch note.kind {
        case kindGenreThenNew: return "\(c) from your \(note.genre) side, then something new from \(note.newArtist)."
        case kindArtistThenNew: return "\(c) from \(note.artist), then something new from \(note.newArtist)."
        case kindKnownThenNew: return "\(c) you know, then something new from \(note.newArtist)."
        case kindGenreOnly: return "\(c) from your \(note.genre) side."
        default: return ""
        }
    }
}
