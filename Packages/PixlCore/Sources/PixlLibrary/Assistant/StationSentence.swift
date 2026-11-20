// "Start a station from Radiohead" with no network (docs/brain-spec.md, 14 stage 4: "with no network the on-device model still starts a
// station from a sentence"). A port of Android's `StationSentence.kt`.

import Foundation

/// A station request is a small fixed shape, so it is read by rules, with no model and no connection: the name it asks for is then looked up in
/// the listener's own library and the genre atlas, which are on the phone. The phone's model is not needed to read this, and is never asked to
/// name a track: the engine fills the station.
///
/// Returns the name asked for, or nil for a sentence that is not a station request (those go the old way).
public enum StationSentence {
    private static let verbs = ["start", "play", "put on", "begin", "make", "build", "give me", "open", "launch", "turn on"]
    private static let fillers: Set<String> = ["me", "a", "an", "the", "some", "my", "new", "little", "quick", "radio", "station"]
    private static let links = ["from", "of", "for", "based on", "built from", "built on", "around", "on", "like", "with", "using"]
    private static let notNames: Set<String> = ["this", "that", "it", "this song", "this artist", "that song"]
    private static let maxName = 60

    public static func parse(_ prompt: String) -> String? {
        var text = KotlinText.lowercase(BrainText.trim(prompt))
        if text.isEmpty { return nil }
        text = trimEnd(text, [0x2E, 0x21, 0x3F, 0x20])
        if text.hasSuffix(" please") { text = BrainText.trim(String(text.dropLast(" please".count))) }
        if text.hasPrefix("please ") { text = String(text.dropFirst("please ".count)).trimmingCharacters(in: .whitespaces) }
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let last = words.last else { return nil }

        // "<name> radio" / "play <name> station": the request ends with the word.
        if (last == "radio" || last == "station") && words.count >= 3, let verb = verbs.first(where: { text.hasPrefix($0 + " ") }) {
            var middle = String(text.dropFirst(verb.count + 1))
            if middle.hasSuffix(" " + last) { middle = String(middle.dropLast(last.count + 1)) }
            middle = BrainText.trim(middle)
            if let name = cleanName(middle), !middle.contains(" station "), !middle.contains(" radio ") { return name }
        }

        // "[verb] [a] [..] station|radio <link> <name>": find the first station/radio word, then a link word, then the name.
        guard let at = words.firstIndex(where: { $0 == "station" || $0 == "radio" }) else { return nil }
        // What stands before the word must be a verb phrase and fillers only (or nothing).
        let before = words[0..<at].joined(separator: " ")
        if !before.isEmpty {
            guard let verb = verbs.first(where: { before == $0 || before.hasPrefix($0 + " ") }) else { return nil }
            let rest = BrainText.trim(String(before.dropFirst(verb.count)))
            if !rest.isEmpty, rest.split(separator: " ", omittingEmptySubsequences: true).contains(where: { !fillers.contains(String($0)) }) {
                return nil
            }
        }
        let after = words[(at + 1)...].joined(separator: " ")
        guard let link = links.first(where: { after.hasPrefix($0 + " ") }) else { return nil }
        return cleanName(BrainText.trim(String(after.dropFirst(link.count))))
    }

    /// The name without quotes or a leading article, or nil when nothing useful is left.
    private static func cleanName(_ raw: String) -> String? {
        let quotes: Set<UInt32> = [0x22, 0x27, 0x201C, 0x201D]
        var t = BrainText.trim(trimBoth(BrainText.trim(raw), quotes))
        for article in ["the ", "some ", "my "] where t.hasPrefix(article) && t.utf16.count > article.utf16.count + 1 {
            t = String(t.dropFirst(article.count))
            break
        }
        let n = t.utf16.count
        if n < 2 || n > maxName { return nil }
        if fillers.contains(t) || notNames.contains(t) { return nil }
        return t
    }

    private static func trimEnd(_ s: String, _ chars: Set<UInt32>) -> String {
        var scalars = Array(s.unicodeScalars)
        while let last = scalars.last, chars.contains(last.value) { scalars.removeLast() }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars)
        return String(out)
    }

    private static func trimBoth(_ s: String, _ chars: Set<UInt32>) -> String {
        var scalars = Array(s.unicodeScalars)
        while let last = scalars.last, chars.contains(last.value) { scalars.removeLast() }
        while let first = scalars.first, chars.contains(first.value) { scalars.removeFirst() }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars)
        return String(out)
    }
}
