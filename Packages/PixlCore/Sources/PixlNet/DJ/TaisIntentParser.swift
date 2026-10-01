// Port of `data/tais/dj/{DjIntent,TaisIntentParser}.kt`: TAIS Engine 3's prompt → intent parser — keyword rules,
// not a language model. "play some chill acoustic songs" becomes PLAY + genres/moods; exact titles ("The Night We
// Met", "Love Story by Taylor Swift") stay a free-text query. Regex classes follow java.util.regex (ASCII `\w`/`\s`).

import Foundation

/// What the user wants done with what the router finds.
public enum DjAction: String, Sendable, Hashable, Codable {
    case play = "PLAY"
    case queue = "QUEUE"
    case find = "FIND"
}

/// A parsed DJ prompt.
public struct DjIntent: Sendable, Hashable {
    public var rawPrompt: String
    public var action: DjAction
    public var genres: [String]
    public var moods: [String]
    /// The leftover text, the free-text fallback when genre/mood matching finds nothing.
    public var searchQuery: String

    public init(rawPrompt: String, action: DjAction, genres: [String], moods: [String], searchQuery: String) {
        self.rawPrompt = rawPrompt
        self.action = action
        self.genres = genres
        self.moods = moods
        self.searchQuery = searchQuery
    }

    /// Every keyword worth querying with, genres first.
    public var queryTerms: [String] { genres + moods }
}

/// `TaisIntentParser`.
public enum TaisIntentParser {
    static let questionPrefixes = ["what", "why", "who", "when", "where", "how", "tell me", "explain", "is", "does", "do"]
    static let actionPhrases = ["play some", "play me some", "play", "queue up", "queue", "add", "find me", "find",
                                "search for", "search", "look for"]
    static let genreKeywords = ["rock", "pop", "acoustic", "jazz", "classical", "electronic", "edm", "hip hop", "hip-hop",
                                "rap", "metal", "country", "folk", "blues", "reggae", "r&b", "rnb", "soul", "indie",
                                "punk", "lofi", "lo-fi", "ambient", "techno", "house", "disco", "funk", "k-pop", "kpop"]
    /// Mood word → query term, in declaration order.
    static let moodKeywords: [(word: String, mood: String)] = [
        ("chill", "chill"), ("relaxing", "chill"), ("calm", "chill"), ("mellow", "chill"),
        ("energetic", "energetic"), ("upbeat", "energetic"), ("hype", "energetic"),
        ("sad", "sad"), ("melancholy", "sad"), ("emotional", "sad"),
        ("happy", "happy"), ("feel good", "happy"),
        ("romantic", "romantic"), ("love", "romantic"),
        ("workout", "workout"), ("gym", "workout"),
        ("party", "party"), ("dance", "party"),
        ("focus", "focus"), ("study", "focus"), ("concentration", "focus"),
        ("sleep", "sleep"), ("night", "sleep"),
    ]
    static let fillerWords = ["some", "songs", "song", "music", "tracks", "track", "please", "me", "a", "few", "the"]
    /// Prompts that are titles, not moods, even when they are only a keyword.
    static let ambiguousTitles: Set<String> = ["love", "night", "happy", "sad"]

    /// `parse(prompt)`.
    public static func parse(_ prompt: String) -> DjIntent {
        let normalized = normalizeRequest(prompt)
        let action = detectAction(normalized)
        let sortedPhrases = actionPhrases.enumerated().sorted { a, b in
            a.element.utf16.count != b.element.utf16.count ? a.element.utf16.count > b.element.utf16.count : a.offset < b.offset
        }.map(\.element)
        let phrase = sortedPhrases.first { startsWithPhrase(normalized, $0) }
        var request = NetText.trim(phrase.map { NetText.removePrefix(normalized, $0) } ?? normalized)
        request = NetText.removePrefix(request, "some ")
        request = NetText.removePrefix(request, "me some ")
        request = trimChar(NetText.trim(request), "\"")
        let parts = splitOnBy(request)
        let description = parts[0]
        let artist = parts.count > 1 ? parts[1] : ""
        let genres = genreKeywords.filter { containsWord(description, $0) }
        var moods: [String] = []
        for entry in moodKeywords where containsWord(description, entry.word) && !moods.contains(entry.mood) {
            moods.append(entry.mood)
        }
        var withoutKeywords = description
        for word in genreKeywords + moodKeywords.map(\.word) { withoutKeywords = removeWord(withoutKeywords, word) }
        var remaining = withoutKeywords
        for word in fillerWords { remaining = removeWord(remaining, word) }
        remaining = NetText.trim(collapseSpaces(remaining))
        let isDescription = NetText.isBlank(remaining) && (!genres.isEmpty || !moods.isEmpty)
            && !NetText.containsExact(prompt, "\"") && !ambiguousTitles.contains(description)
        // Keep exact titles intact: keyword extraction must not turn them into a mood playlist.
        let query = isDescription ? artist : NetText.trim([description, artist].filter { !NetText.isBlank($0) }.joined(separator: " "))
        return DjIntent(rawPrompt: prompt, action: action, genres: isDescription ? genres : [], moods: isDescription ? moods : [],
                        searchQuery: query)
    }

    /// `isMediaRequest(prompt)`: an action verb up front, or (outside questions) a pure genre/mood description.
    public static func isMediaRequest(_ prompt: String) -> Bool {
        let normalized = normalizeRequest(prompt)
        if NetText.isBlank(normalized) { return false }
        if actionPhrases.contains(where: { startsWithPhrase(normalized, $0) }) { return true }
        // Genre mentions in questions are conversation, not playback commands.
        if NetText.endsWith(normalized, "?") || questionPrefixes.contains(where: { startsWithPhrase(normalized, $0) }) { return false }
        let parsed = parse(normalized)
        return NetText.isBlank(parsed.searchQuery) && (!parsed.genres.isEmpty || !parsed.moods.isEmpty)
    }

    /// `normalizeRequest`: trim, lower case, drop a leading "can/could/would you" and "please", a trailing " please".
    static func normalizeRequest(_ prompt: String) -> String {
        let lower = NetText.lowercased(NetText.trim(prompt))
        var s = Array(lower.unicodeScalars)
        var index = 0
        for opener in ["can", "could", "would"] {
            let candidate = Array((opener + " you").unicodeScalars)
            if hasScalars(s, at: 0, candidate) {
                var j = candidate.count
                let runStart = j
                while j < s.count, NetText.isRegexSpace(s[j]) { j += 1 }
                if j > runStart { index = j }
                break
            }
        }
        let please = Array("please".unicodeScalars)
        if hasScalars(s, at: index, please) {
            var j = index + please.count
            let runStart = j
            while j < s.count, NetText.isRegexSpace(s[j]) { j += 1 }
            if j > runStart { index = j }
        }
        s = Array(s[index...])
        var view = String.UnicodeScalarView()
        view.append(contentsOf: s)
        return NetText.trim(NetText.removeSuffix(String(view), " please"))
    }

    static func startsWithPhrase(_ text: String, _ phrase: String) -> Bool {
        NetText.same(text, phrase) || NetText.startsWith(text, phrase + " ")
    }

    static func detectAction(_ normalized: String) -> DjAction {
        if ["queue", "add"].contains(where: { startsWithPhrase(normalized, $0) }) { return .queue }
        if ["find", "search", "look for"].contains(where: { startsWithPhrase(normalized, $0) }) { return .find }
        return .play
    }

    /// `(?<!\w)word(?!\w)` found in `text`.
    static func containsWord(_ text: String, _ word: String) -> Bool { !wordMatches(text, word).isEmpty }

    /// Every `(?<!\w)word(?!\w)` match replaced by a space.
    static func removeWord(_ text: String, _ word: String) -> String {
        let s = Array(text.unicodeScalars)
        let matches = wordMatches(text, word)
        if matches.isEmpty { return text }
        var out = String.UnicodeScalarView()
        var last = 0
        for m in matches {
            out.append(contentsOf: s[last..<m])
            out.append(" ")
            last = m + word.unicodeScalars.count
        }
        out.append(contentsOf: s[last...])
        return String(out)
    }

    private static func wordMatches(_ text: String, _ word: String) -> [Int] {
        let s = Array(text.unicodeScalars), w = Array(word.unicodeScalars)
        var out: [Int] = []
        var i = 0
        while i + w.count <= s.count {
            if hasScalars(s, at: i, w), i == 0 || !NetText.isWordChar(s[i - 1]),
               i + w.count == s.count || !NetText.isWordChar(s[i + w.count]) {
                out.append(i)
                i += max(w.count, 1)
                continue
            }
            i += 1
        }
        return out
    }

    private static func hasScalars(_ s: [Unicode.Scalar], at index: Int, _ w: [Unicode.Scalar]) -> Bool {
        guard index >= 0, index + w.count <= s.count else { return false }
        for k in 0..<w.count where s[index + k] != w[k] { return false }
        return true
    }

    /// `request.split(Regex("""\s+by\s+"""), limit = 2)`.
    static func splitOnBy(_ text: String) -> [String] {
        let s = Array(text.unicodeScalars)
        var i = 0
        while i < s.count {
            if NetText.isRegexSpace(s[i]) {
                var j = i
                while j < s.count, NetText.isRegexSpace(s[j]) { j += 1 }
                if j + 2 < s.count, s[j] == "b", s[j + 1] == "y", NetText.isRegexSpace(s[j + 2]) {
                    var k = j + 2
                    while k < s.count, NetText.isRegexSpace(s[k]) { k += 1 }
                    var first = String.UnicodeScalarView(), second = String.UnicodeScalarView()
                    first.append(contentsOf: s[0..<i])
                    second.append(contentsOf: s[k...])
                    return [String(first), String(second)]
                }
                i = j
                continue
            }
            i += 1
        }
        return [text]
    }

    /// `replace(Regex("""\s+"""), " ")`.
    static func collapseSpaces(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var inSpace = false
        for c in text.unicodeScalars {
            if NetText.isRegexSpace(c) {
                if !inSpace { out.append(" ") }
                inSpace = true
            } else {
                out.append(c)
                inSpace = false
            }
        }
        return String(out)
    }

    /// Kotlin `trim(char)`.
    static func trimChar(_ text: String, _ c: Unicode.Scalar) -> String {
        var s = Array(text.unicodeScalars)[...]
        while s.first == c { s = s.dropFirst() }
        while s.last == c { s = s.dropLast() }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: s)
        return String(view)
    }
}
