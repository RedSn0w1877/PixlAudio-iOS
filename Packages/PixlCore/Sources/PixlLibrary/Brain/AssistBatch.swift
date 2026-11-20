// The checks on what the optional batch jobs bring back (docs/brain-spec.md, 9.4 "Batch jobs", stage 4 milestone 2). A transliteration of
// the Android `:brain` module's `AssistBatch.kt`; both reproduce `assistbatch.jsonl` bit for bit.

/// The jobs run only with the switch "Let Taizo help the engine", which is off by default, inside the monthly budget, and their answers
/// are cached forever by (model id, prompt version, input hash). Whatever the model writes is data: a plain function here decides what of
/// it may be used, and an invalid id, an unknown word or a name the island does not hold is dropped, never shown and never repaired.
public enum AssistBatch {
    /// Bump when a prompt or a rule here changes: the caches are keyed by it.
    public static let promptVersion = 1

    /// The cache key of one job: the model, the prompt version, the kind of job and the exact input text.
    public static func cacheKey(modelId: String, kind: String, input: String) -> Int64 {
        BrainHash.id(BrainHash.fnv1a64("assist|\(modelId)|\(promptVersion)|\(kind)|\(input)"))
    }

    // MARK: Island names

    public static let minName = 3
    public static let maxName = 28
    public static let maxNameWords = 4
    public static let maxLine = 90

    /// What an island holds: its id, the names of its genres in the atlas, and its top artists. Only these words may name it.
    public struct IslandIn: Sendable, Equatable {
        public let id: Int
        public let genres: [String]
        public let artists: [String]

        public init(id: Int, genres: [String], artists: [String]) {
            self.id = id
            self.genres = genres
            self.artists = artists
        }
    }

    public struct IslandName: Sendable, Equatable {
        public let id: Int
        public let name: String
        public let line: String

        public init(id: Int, name: String, line: String) {
            self.id = id
            self.name = name
            self.line = line
        }
    }

    /// The names of `outs` that may be shown. An answer is kept when its id is one of `ins`; its name is 3 to 28 characters, at most four
    /// words, made of letters, digits, spaces and `& ' -`; it shares a whole word (three letters or more) with the names of that island's
    /// own genres, so it cannot be about something else; it is not an artist's name; and neither it nor the one-line description holds a
    /// word the app never says. The description is at most 90 characters with no digit, quote or bracket. A description that fails is
    /// dropped alone: the name is kept with an empty line. Each island is named once (the first valid answer wins).
    public static func validateIslandNames(_ ins: [IslandIn], _ outs: [IslandName]) -> [IslandName] {
        var byId: [Int: IslandIn] = [:]
        for i in ins { byId[i.id] = i }
        var done = Set<Int>()
        var kept: [IslandName] = []
        for o in outs {
            guard let island = byId[o.id] else { continue }
            if done.contains(o.id) { continue }
            let name = WeeklyNote.oneLine(o.name)
            if !nameOk(name, island) { continue }
            done.insert(o.id)
            let line = WeeklyNote.oneLine(o.line)
            kept.append(IslandName(id: o.id, name: name, line: lineOk(line) ? line : ""))
        }
        return kept
    }

    private static func isLetterUnit(_ c: UInt16) -> Bool {
        (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c > 0x7F
    }

    private static func nameOk(_ name: String, _ island: IslandIn) -> Bool {
        let units = Array(name.utf16)
        if units.count < minName || units.count > maxName { return false }
        var words = 0
        var inWord = false
        for c in units {
            let letter = isLetterUnit(c)
            if !(letter || c == 0x20 || c == 0x26 || c == 0x27 || c == 0x2D) { return false }
            if c == 0x20 {
                inWord = false
            } else if !inWord {
                inWord = true
                words += 1
            }
        }
        if words == 0 || words > maxNameWords { return false }
        let folded = BrainText.fold(name)
        for w in WeeklyNote.forbidden where KotlinText.contains(folded, w, ignoreCase: false) { return false }
        let foldedTrim = BrainText.trim(folded)
        for a in island.artists where KotlinText.equals(BrainText.trim(BrainText.fold(a)), foldedTrim) { return false }
        // One whole word in common with the island's own genres (a word of three letters or more).
        var own = Set<KotlinKey>()
        for g in island.genres {
            for w in wordsOf(BrainText.fold(g)) where w.utf16.count >= 3 { own.insert(KotlinKey(w)) }
        }
        for w in wordsOf(folded) where w.utf16.count >= 3 && own.contains(KotlinKey(w)) { return true }
        return false
    }

    private static func lineOk(_ line: String) -> Bool {
        let units = Array(line.utf16)
        if units.isEmpty || units.count > maxLine { return false }
        for c in units where (c >= 0x30 && c <= 0x39) || c == 0x22 || c == 0x5B || c == 0x5D || c == 0x7B || c == 0x7D { return false }
        let folded = BrainText.fold(line)
        for w in WeeklyNote.forbidden where KotlinText.contains(folded, w, ignoreCase: false) { return false }
        return true
    }

    /// The words of `folded`: runs of letters and digits.
    public static func wordsOf(_ folded: String) -> [String] {
        var out: [String] = []
        var cur: [UInt16] = []
        for c in folded.utf16 {
            if (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c > 0x7F {
                cur.append(c)
            } else if !cur.isEmpty {
                out.append(String(decoding: cur, as: UTF16.self))
                cur.removeAll(keepingCapacity: true)
            }
        }
        if !cur.isEmpty { out.append(String(decoding: cur, as: UTF16.self)) }
        return out
    }

    // MARK: Constrained genre tags (tag source 10)

    /// Tracks a tagging call holds, and atlas ids it may choose among for each.
    public static let tagBatch = 50
    public static let shortlist = 30
    public static let maxTagsPerTrack = 3

    /// A claim must be at least this sure to be kept (the source's own trust is 0.25 in `Tags`; this is its own confidence).
    public static let minConfidence = 0.5

    public struct TagOut: Sendable, Equatable {
        public let index: Int
        public let atlasId: Int
        public let confidence: Double

        public init(index: Int, atlasId: Int, confidence: Double) {
            self.index = index
            self.atlasId = atlasId
            self.confidence = confidence
        }
    }

    /// The claims of `outs` that may be used. `shortlists` holds, for each track of the call, the atlas ids it was allowed to answer with.
    /// A claim is kept when its track index exists, its id is on THAT track's shortlist, and its confidence is within 0.5 to 1; a track
    /// keeps at most three, the most confident first (ties to the lower id), each id once. The rest are dropped.
    public static func validateTags(_ shortlists: [[Int]], _ outs: [TagOut]) -> [TagOut] {
        var perTrack: [Int: [TagOut]] = [:]
        for o in outs {
            if o.index < 0 || o.index >= shortlists.count { continue }
            if !(o.confidence >= minConfidence && o.confidence <= 1.0) { continue }
            if !shortlists[o.index].contains(o.atlasId) { continue }
            var list = perTrack[o.index] ?? []
            if !list.contains(where: { $0.atlasId == o.atlasId }) { list.append(o) }
            perTrack[o.index] = list
        }
        var kept: [TagOut] = []
        for index in perTrack.keys.sorted() {
            let list = perTrack[index]!.sorted {
                if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                return $0.atlasId < $1.atlasId
            }
            for k in 0..<min(list.count, maxTagsPerTrack) { kept.append(list[k]) }
        }
        return kept
    }

    // MARK: "Artists this listener likely does not know" (ASK arm)

    public static let askPerIsland = 20

    /// The names of `raw` worth looking up: trimmed, 2 to 60 characters, no digits-only, not already one of `knownFolded` (the listener's
    /// own artists, folded), each once, at most `askPerIsland`. A name is still only a name: it becomes a suggestion only if a search finds
    /// a real track by it, so nothing here is ever shown by itself.
    public static func validateArtistNames(_ raw: [String], knownFolded: Set<String>) -> [String] {
        var known = Set<KotlinKey>()
        for k in knownFolded { known.insert(KotlinKey(k)) }
        var out: [String] = []
        var seen = Set<KotlinKey>()
        for r in raw {
            let t = WeeklyNote.oneLine(r)
            let n = t.utf16.count
            if n < 2 || n > 60 { continue }
            let f = BrainText.trim(BrainText.fold(t))
            if f.isEmpty || known.contains(KotlinKey(f)) || !seen.insert(KotlinKey(f)).inserted { continue }
            var allDigits = true
            for c in f.utf16 where c < 0x30 || c > 0x39 { allDigits = false; break }
            if allDigits { continue }
            out.append(t)
            if out.count >= askPerIsland { break }
        }
        return out
    }
}
