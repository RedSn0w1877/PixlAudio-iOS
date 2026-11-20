// The grounding rule of Ask Taizo (docs/brain-spec.md, 1 principle 9, 9.4): the assistant's reply can never name a track, album or artist
// that a tool did not return in the same conversation, and a number about the listener comes only from a tool result. A transliteration
// of the Android `:brain` module's `Grounding.kt`.
//
// Code cannot tell a title from any other words in free text, so the prompt asks the model to mark every track, album and artist it names
// as `[[Name]]` (deviation 208). This enum finds those marks, and also double-quoted phrases (a title the model forgot to mark), and
// checks each against what the conversation really held: the names tools returned (`Registry.addName`), free text that tools returned
// (lyrics, a tool's JSON: `Registry.addText`), and the user's own words. Pure: no regular expressions, folded text only
// (`BrainText.fold`), UTF-16 code units everywhere (a Swift `String.contains` compares characters, not code units, and would differ),
// so the same text gives the same verdict on both platforms.

/// The grounding check.
public enum Grounding {

    /// The longest and shortest span that counts as a name.
    public static let maxSpan = 120
    public static let minQuoted = 2
    public static let maxQuoted = 80
    /// A marked name must be at least this long to be accepted as one the user typed (a one-letter word is in every sentence).
    public static let minUserName = 2

    typealias Units = [UInt16]

    private static func units(_ s: String) -> Units { Array(s.utf16) }
    private static func string(_ u: Units) -> String { String(decoding: u, as: UTF16.self) }
    private static func string(_ u: ArraySlice<UInt16>) -> String { String(decoding: u, as: UTF16.self) }

    /// Index of `needle` in `hay` at or after `from`, or -1 (Kotlin `String.indexOf`).
    static func indexOf(_ hay: Units, _ needle: Units, _ from: Int) -> Int {
        let n = needle.count
        var i = from < 0 ? 0 : from
        if n == 0 { return i <= hay.count ? i : hay.count }
        if hay.count < n { return -1 }
        while i + n <= hay.count {
            var k = 0
            while k < n && hay[i + k] == needle[k] { k += 1 }
            if k == n { return i }
            i += 1
        }
        return -1
    }

    static func contains(_ hay: Units, _ needle: Units) -> Bool { indexOf(hay, needle, 0) >= 0 }

    /// Everything the conversation really held.
    public struct Registry: Sendable {
        private var names = Set<KotlinKey>()
        private var corpus: [[UInt16]] = []
        private var numbers = Set<String>()

        public init() {}

        /// A name a tool returned (a title, an artist, an album). Its clean-title form counts too ("Song - Remastered" is "Song").
        public mutating func addName(_ raw: String?) {
            guard let raw else { return }
            let folded = BrainText.trim(BrainText.fold(raw))
            if folded.utf16.isEmpty { return }
            names.insert(KotlinKey(folded))
            let clean = BrainText.trim(BrainText.cleanTitle(raw).title)
            if !clean.utf16.isEmpty { names.insert(KotlinKey(clean)) }
        }

        /// Free text the model may quote from, or numbers it may read: a tool result as text, lyrics, what the user said.
        public mutating func addText(_ raw: String?) {
            guard let raw, !raw.utf16.isEmpty else { return }
            // Padded with a space on both sides, so a lookup is a whole-word match ("sia" is not inside "asia").
            corpus.append([0x20] + Grounding.units(BrainText.fold(raw)) + [0x20])
            for n in Grounding.numbersIn(raw) { numbers.insert(n) }
        }

        /// True when `folded` is a name a tool returned.
        public func hasName(_ folded: String) -> Bool { names.contains(KotlinKey(folded)) }

        /// True when `folded` is a run of whole words of some registered free text.
        public func inText(_ folded: String) -> Bool {
            let f = Grounding.units(folded)
            if f.isEmpty { return false }
            let needle: [UInt16] = [0x20] + f + [0x20]
            for t in corpus where Grounding.contains(t, needle) { return true }
            return false
        }

        /// True when `folded` is a run of whole words of some name a tool returned ("Good Luck" of "Good Luck, Babe!"). Only the unmarked scan uses it.
        public func inName(_ folded: String) -> Bool {
            let f = Grounding.units(folded)
            if f.isEmpty { return false }
            let needle: [UInt16] = [0x20] + f + [0x20]
            for n in names where Grounding.contains([0x20] + Grounding.units(n.value) + [0x20], needle) { return true }
            return false
        }

        /// A number the app itself vouches for (how many items a tool returned).
        public mutating func addNumber(_ n: Int) { numbers.insert(String(n)) }

        public func hasNumber(_ token: String) -> Bool { numbers.contains(token) }

        public var size: Int { names.count }
    }

    public struct Span: Sendable {
        public let start: Int
        public let end: Int
        public let inner: String
        public let marked: Bool
        /// Found by the unmarked scan and not grounded: it is replaced whatever the registry holds.
        public let bad: Bool

        public init(start: Int, end: Int, inner: String, marked: Bool, bad: Bool = false) {
            self.start = start
            self.end = end
            self.inner = inner
            self.marked = marked
            self.bad = bad
        }
    }

    /// The `[[...]]` marks of `text`, in order (an unclosed mark, an empty one and a long one are not spans).
    public static func markedSpans(_ text: String) -> [Span] {
        markedSpans(units(text))
    }

    static func markedSpans(_ t: Units) -> [Span] {
        var out: [Span] = []
        var i = 0
        while i + 1 < t.count {
            if t[i] == 0x5B && t[i + 1] == 0x5B {
                var j = i + 2
                var ok = false
                while j + 1 < t.count && j - i <= maxSpan + 2 {
                    if t[j] == 0x0A { break }
                    if t[j] == 0x5D && t[j + 1] == 0x5D { ok = true; break }
                    j += 1
                }
                if ok {
                    let inner = BrainText.trim(string(t[(i + 2)..<j]))
                    if !inner.utf16.isEmpty { out.append(Span(start: i, end: j + 2, inner: inner, marked: true)) }
                    i = j + 2
                    continue
                }
            }
            i += 1
        }
        return out
    }

    private static let noClose: UInt16 = 0

    /// True for a Unicode letter or digit among the UTF-16 units (Kotlin `Char.isLetterOrDigit`): a surrogate half is neither.
    static func isLetterOrDigit(_ c: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(UInt32(c)) else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: return true
        default: return false
        }
    }

    /// True for an upper-case unit (Kotlin `Char.isUpperCase`).
    static func isUpperCase(_ c: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(UInt32(c)) else { return false }
        return scalar.properties.isUppercase
    }

    /// The unit that closes a quote opened at `i` of `t`, or `noClose` when `i` does not open one. Double quotes (straight and curly),
    /// guillemets and curly single quotes always open one; a straight single quote opens one only at a word start followed by a letter or
    /// digit (an apostrophe in "don't" is not a quote).
    private static func closeFor(_ t: Units, _ i: Int) -> UInt16 {
        let c = t[i]
        switch c {
        case 0x22: return 0x22
        case 0x201C: return 0x201D
        case 0x00AB: return 0x00BB
        case 0x2018: return 0x2019
        case 0x27:
            let before: UInt16 = i == 0 ? 0x20 : t[i - 1]
            let startsWord = before == 0x20 || before == 0x28 || before == 0x5B || before == 0x0A || before == 0x09
            if startsWord && i + 1 < t.count && isLetterOrDigit(t[i + 1]) { return 0x27 }
            return noClose
        default: return noClose
        }
    }

    /// True when the unit at `j` closes a quote that `close` ends (a single quote only when no letter follows it: "Rock'n'roll" stays whole).
    private static func closesAt(_ t: Units, _ j: Int, _ close: UInt16) -> Bool {
        if t[j] != close { return false }
        if close == 0x27 || close == 0x2019 { return j + 1 >= t.count || !isLetterOrDigit(t[j + 1]) }
        return true
    }

    /// Quoted phrases of `text` that are not inside a `[[...]]` mark: a title the model quoted without marking it. Double quotes, curly single
    /// quotes, straight single quotes at a word start, and guillemets.
    public static func quotedSpans(_ text: String, _ marked: [Span]) -> [Span] {
        quotedSpans(units(text), marked)
    }

    static func quotedSpans(_ t: Units, _ marked: [Span]) -> [Span] {
        var out: [Span] = []
        var i = 0
        while i < t.count {
            var inMark = false
            for m in marked where i >= m.start && i < m.end { inMark = true; break }
            let close: UInt16 = inMark ? noClose : closeFor(t, i)
            if close != noClose {
                var j = i + 1
                var closed = -1
                while j < t.count && j - i <= maxQuoted + 1 {
                    if t[j] == 0x0A { break }
                    if closesAt(t, j, close) { closed = j; break }
                    j += 1
                }
                if closed > 0 {
                    let inner = BrainText.trim(string(t[(i + 1)..<closed]))
                    if inner.utf16.count >= minQuoted { out.append(Span(start: i, end: closed + 1, inner: inner, marked: false)) }
                    i = closed + 1
                    continue
                }
            }
            i += 1
        }
        return out
    }

    /// Punctuation that joins names in the raw text; fold turns punctuation into a space, so these are split before folding.
    private static let rawJoiners: [Units] = [
        ", ", " & ", " / ", " - ", " \u{2013} ", " \u{2014} ", " + ", " \u{00D7} ", " \u{00B7} ",
    ].map { units($0) }

    /// Words that join names once folded.
    private static let wordJoiners: [Units] = [" by ", " and ", " feat ", " ft ", " featuring ", " with ", " x "].map { units($0) }

    /// True when `inner` is grounded: a name a tool returned, or a list of such names joined the way a listener writes them
    /// ("Espresso by Sabrina Carpenter", "Daft Punk & Pharrell"). A quoted span (not marked) also passes when it is part of free text the
    /// conversation held (lyrics, a tool result, what the user said). A marked name the listener typed is theirs (whole words).
    public static func isGrounded(_ inner: String, _ registry: Registry, marked: Bool, userText: String = "") -> Bool {
        let folded = BrainText.trim(BrainText.fold(inner))
        if folded.utf16.isEmpty { return true }
        if registry.hasName(folded) { return true }
        let clean = BrainText.trim(BrainText.cleanTitle(inner).title)
        if !clean.utf16.isEmpty && registry.hasName(clean) { return true }
        let foldedUnits = units(folded)
        if !marked {
            if registry.inText(folded) { return true }
            if !userText.utf16.isEmpty {
                let hay: Units = [0x20] + units(BrainText.fold(userText)) + [0x20]
                if contains(hay, [0x20] + foldedUnits + [0x20]) { return true }
            }
        } else if !userText.utf16.isEmpty && foldedUnits.count >= minUserName {
            // A name the listener typed is theirs: the assistant may say it back ("Espresso is a good place to start"). Whole words only.
            let hay: Units = [0x20] + units(BrainText.fold(userText)) + [0x20]
            let needle: Units = [0x20] + foldedUnits + [0x20]
            if contains(hay, needle) { return true }
        }
        // Several names in one mark: every part must be a returned name.
        var raw: [Units] = [units(inner)]
        var split = false
        for j in rawJoiners {
            var next: [Units] = []
            for p in raw {
                var from = 0
                while true {
                    let at = indexOf(p, j, from)
                    if at < 0 { break }
                    next.append(Array(p[from..<at]))
                    from = at + j.count
                    split = true
                }
                next.append(Array(p[from...]))
            }
            raw = next
        }
        var parts: [Units] = []
        for p in raw { parts.append([0x20] + units(BrainText.fold(string(p))) + [0x20]) }
        for j in wordJoiners {
            var next: [Units] = []
            for p in parts {
                var from = 0
                while true {
                    let at = indexOf(p, j, from)
                    if at < 0 { break }
                    next.append(Array(p[from..<at]) + [0x20])
                    from = at + j.count - 1
                    split = true
                }
                next.append(Array(p[from...]))
            }
            parts = next
        }
        if !split { return false }
        for p in parts {
            let t = BrainText.trim(string(p))
            if t.utf16.isEmpty { continue }
            if !registry.hasName(t) { return false }
        }
        return true
    }

    // MARK: Names the model wrote with no mark (the second pass)

    /// Words that start with a capital but are not names: the pronoun, the app's own words, the days and the months. A reply may use them
    /// anywhere (folded). A name-like word in this list is never flagged; it is also never a name the model may claim.
    private static let notNames: Set<String> = [
        "i", "im", "ill", "ive", "id", "ai", "dj", "ep", "lp", "url", "ui", "tv", "usb", "wifi", "bluetooth", "flac", "mp3",
        "taizo", "pixlaudio", "pixl", "spotify", "youtube", "music", "home", "settings", "android", "google", "premium", "plus",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
    ]

    /// Lower-case words that may sit inside a name between two capitalised words ("Kind of Blue", "Tyler the Creator").
    private static let nameConnectors: Set<String> = ["of", "the", "and", "de", "la", "le", "da", "van", "von", "x"]

    private struct Word {
        let start: Int
        let end: Int
        let cap: Bool
        let connector: Bool
    }

    private static func withoutSpaces(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars where u != " " { out.append(u) }
        return String(out)
    }

    /// The words of `t` in `from..<to` (letters and digits, with an apostrophe, hyphen or point between two of them, and `&`).
    private static func wordsOf(_ t: Units, _ from: Int, _ to: Int, _ out: inout [Word]) {
        var i = from
        while i < to {
            let c = t[i]
            if c == 0x26 {
                out.append(Word(start: i, end: i + 1, cap: false, connector: true))
                i += 1
            } else if isLetterOrDigit(c) {
                var j = i + 1
                while j < to {
                    let d = t[j]
                    if isLetterOrDigit(d) {
                        j += 1
                    } else if (d == 0x27 || d == 0x2019 || d == 0x2D || d == 0x2E) && j + 1 < to && isLetterOrDigit(t[j + 1])
                                && (d != 0x2E || isUpperCase(t[j - 1])) {
                        j += 1
                    } else {
                        break
                    }
                }
                var end = j
                // A possessive is not part of the name.
                if end - i > 2 && (t[end - 2] == 0x27 || t[end - 2] == 0x2019) && (t[end - 1] == 0x73 || t[end - 1] == 0x53) { end -= 2 }
                let folded = BrainText.fold(string(t[i..<end]))
                out.append(Word(start: i, end: end, cap: isUpperCase(c) && !notNames.contains(withoutSpaces(folded)),
                                connector: nameConnectors.contains(folded)))
                i = j
            } else {
                i += 1
            }
        }
    }

    /// True when the word at `at` starts a sentence or a line (or a list item): its capital is grammar, not a name.
    private static func startsSentence(_ t: Units, _ at: Int) -> Bool {
        var k = at - 1
        while k >= 0 {
            let c = t[k]
            if c == 0x20 || c == 0x2A || c == 0x5F || c == 0x28 || c == 0x22 || c == 0x2D || c == 0x2022 || c == 0x3E || c == 0x23 || c == 0x201C {
                k -= 1
                continue
            }
            if c >= 0x30 && c <= 0x39 {
                k -= 1
                continue
            }
            return c == 0x2E || c == 0x21 || c == 0x3F || c == 0x0A
        }
        return true
    }

    private static func runGrounded(_ run: String, _ registry: Registry, _ userText: String) -> Bool {
        isGrounded(run, registry, marked: false, userText: userText) || registry.inName(BrainText.trim(BrainText.fold(run)))
    }

    /// True when only spaces lie between two words (no punctuation, no line break).
    private static func adjacent(_ t: Units, _ a: Word, _ b: Word) -> Bool {
        var k = a.end
        while k < b.start {
            if t[k] != 0x20 { return false }
            k += 1
        }
        return true
    }

    /// Runs of capitalised words that lie outside every span of `taken`: a name written with no mark and no quote ("You might also try
    /// Radiohead or OK Computer"). A run that is not grounded (`isGrounded`) comes back as a bad span. A single capitalised word that starts
    /// a sentence is skipped (a sentence opener is not a name); a run of two or more that starts a sentence is checked whole and then without
    /// its first word ("Try Radiohead"). Lower-case names are not found: the check can only see what capitals show.
    public static func unmarkedNames(_ text: String, _ taken: [Span], _ registry: Registry, userText: String) -> [Span] {
        unmarkedNames(units(text), taken, registry, userText)
    }

    static func unmarkedNames(_ t: Units, _ taken: [Span], _ registry: Registry, _ userText: String) -> [Span] {
        var out: [Span] = []
        let sorted = taken.sorted { $0.start < $1.start }
        var words: [Word] = []
        var at = 0
        for s in sorted {
            if s.start > at { wordsOf(t, at, s.start, &words) }
            // A mark or a quote is a hard break between words.
            words.append(Word(start: s.start, end: s.start, cap: false, connector: false))
            if s.end > at { at = s.end }
        }
        if at < t.count { wordsOf(t, at, t.count, &words) }
        var i = 0
        while i < words.count {
            if !words[i].cap {
                i += 1
                continue
            }
            var j = i
            while true {
                if j + 1 < words.count && words[j + 1].cap && adjacent(t, words[j], words[j + 1]) {
                    j += 1
                    continue
                }
                if j + 2 < words.count && words[j + 1].connector && words[j + 2].cap && adjacent(t, words[j], words[j + 1])
                    && adjacent(t, words[j + 1], words[j + 2]) {
                    j += 2
                    continue
                }
                break
            }
            let initial = startsSentence(t, words[i].start)
            if !(initial && j == i) {
                let full = string(t[words[i].start..<words[j].end])
                if !runGrounded(full, registry, userText) {
                    var from = i
                    if initial && j > i {
                        // "Try Radiohead": the first word may be grammar.
                        var k = i + 1
                        if words[k].connector { k += 1 }
                        if k <= j {
                            let rest = string(t[words[k].start..<words[j].end])
                            if runGrounded(rest, registry, userText) {
                                i = j + 1
                                continue
                            }
                            from = k
                        }
                    }
                    let inner = string(t[words[from].start..<words[j].end])
                    out.append(Span(start: words[from].start, end: words[j].end, inner: inner, marked: false, bad: true))
                }
            }
            i = j + 1
        }
        return out
    }

    // MARK: Numbers

    /// Units that make a number a statement about the listener ("212 plays", "9%", "3 hours").
    private static let statUnits: [String] = [
        "plays", "play", "times", "time", "skips", "skip", "hours", "hour", "minutes", "minute", "days", "day", "weeks", "week",
        "months", "month", "songs", "tracks", "percent", "listens", "sessions",
    ]

    private static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

    /// A letter for the purpose of "a number inside a word": ASCII letters, and everything past ASCII (no Unicode tables in the core).
    private static func isLetter(_ c: UInt16) -> Bool { (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || c > 0x7F }

    /// The numbers written in `text` as plain tokens: digits with an optional decimal part ("1,240" is "1240", "9.5" stays).
    public static func numbersIn(_ text: String) -> [String] {
        let t = units(text)
        var out: [String] = []
        var i = 0
        while i < t.count {
            let c = t[i]
            if isDigit(c) && (i == 0 || !isLetter(t[i - 1])) {
                var sb: Units = []
                var j = i
                while j < t.count {
                    let d = t[j]
                    if isDigit(d) {
                        sb.append(d)
                    } else if d == 0x2C && j + 1 < t.count && isDigit(t[j + 1]) && j > i {
                        // thousands separator
                    } else if d == 0x2E && j + 1 < t.count && isDigit(t[j + 1]) && j > i {
                        sb.append(d)
                    } else {
                        break
                    }
                    j += 1
                }
                if j < t.count && isLetter(t[j]) {
                    // "3rd", "2pac": a number inside a word is not a statistic.
                    while j < t.count && isLetter(t[j]) { j += 1 }
                } else {
                    out.append(trimNumber(string(sb)))
                }
                i = j
            } else {
                i += 1
            }
        }
        return out
    }

    private static func trimNumber(_ s: String) -> String {
        var t = Array(s.utf16)
        while t.count > 1 && t[0] == 0x30 && t[1] != 0x2E { t.removeFirst() }
        if t.contains(0x2E) {
            while t.last == 0x30 { t.removeLast() }
            if t.last == 0x2E { t.removeLast() }
        }
        return string(t)
    }

    public struct Stat: Sendable {
        public let token: String
        public let start: Int
        public let end: Int
    }

    /// The numbers of `text` that state something about the listener: one that is followed by a unit word ("212 plays") or by `%`.
    /// Years and the numbers of a list's own items are not statistics and are left alone.
    public static func listenerNumbers(_ text: String) -> [Stat] {
        listenerNumbers(units(text))
    }

    static func listenerNumbers(_ t: Units) -> [Stat] {
        var out: [Stat] = []
        var i = 0
        while i < t.count {
            let c = t[i]
            if isDigit(c) && (i == 0 || !isLetter(t[i - 1])) {
                var j = i
                var sb: Units = []
                while j < t.count {
                    let d = t[j]
                    if isDigit(d) {
                        sb.append(d)
                    } else if d == 0x2C && j + 1 < t.count && isDigit(t[j + 1]) && j > i {
                        // separator
                    } else if d == 0x2E && j + 1 < t.count && isDigit(t[j + 1]) && j > i {
                        sb.append(d)
                    } else {
                        break
                    }
                    j += 1
                }
                var k = j
                while k < t.count && t[k] == 0x20 { k += 1 }
                var stat = false
                if k < t.count && t[k] == 0x25 {
                    stat = true
                } else if k > j || k < t.count {
                    var w = k
                    while w < t.count && isLetter(t[w]) { w += 1 }
                    if w > k {
                        let word = BrainText.fold(string(t[k..<w]))
                        for u in statUnits where KotlinText.equals(u, word) { stat = true; break }
                    }
                }
                if stat { out.append(Stat(token: trimNumber(string(sb)), start: i, end: j)) }
                i = j
            } else {
                i += 1
            }
        }
        return out
    }

    // MARK: The verdict

    public struct Verdict: Sendable {
        /// The text with the marks taken off, and anything that was not grounded replaced by the placeholder.
        public let cleaned: String
        public let ungroundedNames: [String]
        public let ungroundedNumbers: [String]

        public var ok: Bool { ungroundedNames.isEmpty && ungroundedNumbers.isEmpty }
    }

    /// Checks a final reply. `placeholder` replaces a name that was not grounded; a sentence that states a number no tool returned is
    /// dropped (when `dropUngroundedNumbers`); marks around grounded names are removed. `userText` is what the user wrote in this
    /// conversation (a number or a quoted phrase the user said first is theirs).
    public static func check(_ text: String, _ registry: Registry, userText: String, placeholder: String,
                             dropUngroundedNumbers: Bool, scanUnmarked: Bool = false) -> Verdict {
        let t = units(text)
        let marked = markedSpans(t)
        let quoted = quotedSpans(t, marked)
        var all = marked + quoted
        // A name the model wrote with no mark and no quote: found as a run of capitalised words outside every span.
        if scanUnmarked { all.append(contentsOf: unmarkedNames(t, all, registry, userText)) }
        all.sort { $0.start < $1.start }
        var badNames: [String] = []
        var sb: Units = []
        let ph = units(placeholder)
        var at = 0
        for s in all {
            sb.append(contentsOf: t[at..<s.start])
            if !s.bad && isGrounded(s.inner, registry, marked: s.marked, userText: userText) {
                // A mark is only a mark: the name stays, the brackets go. A quote stays as written.
                if s.marked { sb.append(contentsOf: units(s.inner)) } else { sb.append(contentsOf: t[s.start..<s.end]) }
            } else {
                var seen = false
                for b in badNames where KotlinText.equals(b, s.inner) { seen = true; break }
                if !seen { badNames.append(s.inner) }
                sb.append(contentsOf: ph)
            }
            at = s.end
        }
        sb.append(contentsOf: t[at...])
        var cleaned = sb
        var userNumbers = Set<String>()
        for n in numbersIn(userText) { userNumbers.insert(n) }
        var badNumbers: [String] = []
        for st in listenerNumbers(cleaned) {
            if !registry.hasNumber(st.token) && !userNumbers.contains(st.token) && !badNumbers.contains(st.token) {
                badNumbers.append(st.token)
            }
        }
        if dropUngroundedNumbers && !badNumbers.isEmpty { cleaned = units(dropSentencesWith(string(cleaned), badNumbers)) }
        return Verdict(cleaned: string(cleaned), ungroundedNames: badNames, ungroundedNumbers: badNumbers)
    }

    /// `text` without the sentences that state one of `tokens` as a listener number. A sentence ends at `.`, `!`, `?` or a line break.
    public static func dropSentencesWith(_ text: String, _ tokens: [String]) -> String {
        let t = units(text)
        var sb: Units = []
        var start = 0
        var i = 0
        while i < t.count {
            let c = t[i]
            if c == 0x2E || c == 0x21 || c == 0x3F || c == 0x0A {
                // A point between two digits ("9.5") is not the end of a sentence.
                if c == 0x2E && i > 0 && i + 1 < t.count && isDigit(t[i - 1]) && isDigit(t[i + 1]) {
                    i += 1
                    continue
                }
                appendUnless(&sb, Array(t[start...i]), tokens)
                start = i + 1
            }
            i += 1
        }
        if start < t.count { appendUnless(&sb, Array(t[start...]), tokens) }
        return BrainText.trim(string(sb))
    }

    private static func appendUnless(_ sb: inout Units, _ sentence: Units, _ tokens: [String]) {
        for st in listenerNumbers(sentence) where tokens.contains(st.token) { return }
        sb.append(contentsOf: sentence)
    }
}
