// What one Ask Taizo conversation really held, for the grounding rule (docs/brain-spec.md, 1 principle 9, 9.4): every name a tool returned,
// every ref a tool issued (so the next call can use it, and a made-up ref is refused), every number a tool or the app stated.
//
// The final reply is checked against it (`check`, the pure `Grounding.check`): a track, album or artist the reply names that no tool returned
// is replaced and flagged, and a number about the listener that no tool returned drops its sentence. One per conversation: `reset` on a new
// chat, `noteHistory` when an older chat is opened again (its tool results are in the history the model is sent anyway).
// Mirrors Android's `TaizoGrounding.kt`.

import Foundation
import PixlFoundation
import PixlModel

/// The conversation's record of what was returned and said.
public final class TaizoGrounding: @unchecked Sendable {
    /// The most characters of a name.
    public static let maxName = Grounding.maxSpan
    private static let maxUserLog = 8_000

    private let lock = NSLock()
    private var registry = Grounding.Registry()
    private var refs: [String: AssistantTrack] = [:]
    /// Refs a tool result of this conversation held (an older chat's history too) whose track was not kept: a similar artist's or a new
    /// release's ref, a ref of a chat that was opened again. Usable as a seed, never invented.
    private var seenRefs = Set<String>()
    /// The genre and mood ids `lookup_genre` returned (id to name): an id the model writes from memory is not one of them.
    private var genreNames: [Int: String] = [:]
    private var moodNames: [Int: String] = [:]
    private var seeded = false
    private var userLog: [UInt16] = []
    private var seenContexts = Set<UInt64>()

    /// The app's own words (what a reply may call its screens and switches): never an artist, album or track, so never a name to check.
    public static let appNames = ["Your Mix", "First Listen", "Made for you", "Your sound", "Familiar", "Blend", "Discover", "Taste changes"]

    /// What a reply says in place of a name no tool returned.
    public static let unverifiedName = "(a name I could not check)"

    /// What the listener reads when every sentence of a reply was left out by the check (the raw text is never shown in its place).
    public static let unverifiedReply = "I cannot say that from what PixlAudio has recorded."

    public init() { noteAppNames() }

    private func noteAppNames() {
        lock.withLock { for n in Self.appNames { registry.addName(n) } }
    }

    /// True once `noteHistory` ran for this conversation (or it was started here).
    public var isSeeded: Bool { lock.withLock { seeded } }

    public var knownNames: Int { lock.withLock { registry.size } }

    public var refCount: Int { lock.withLock { refs.count } }

    public func reset() {
        lock.withLock {
            registry = Grounding.Registry()
            refs = [:]
            seenRefs = []
            genreNames = [:]
            moodNames = [:]
            seeded = false
            userLog = []
            seenContexts = []
        }
        noteAppNames()
    }

    // MARK: What tools return

    /// A track a tool returned: its ref becomes usable, its title, album and every credited artist become names the reply may use.
    public func noteTrack(_ track: AssistantTrack) {
        lock.withLock { refs[track.ref] = track }
        noteName(track.title)
        if !BrainText.isBlank(track.album) { noteName(track.album) }
        noteArtists(track.artist)
    }

    /// A credited artist string ("A, B & C") or one name: the whole and each part.
    public func noteArtists(_ display: String) {
        noteName(display)
        for part in Self.splitCredits(display) { noteName(part) }
    }

    public func noteName(_ name: String?) {
        guard let name, !BrainText.isBlank(name), name.utf16.count <= Self.maxName else { return }
        lock.withLock { registry.addName(name) }
    }

    /// A whole tool result: its text (numbers and quotable words) and every short string in it as a name. Used for tools whose JSON the code
    /// does not shape itself (the older 16 tools, a web result), so a reply that names something they returned is grounded too.
    public func noteToolResult(_ json: String) {
        lock.withLock { registry.addText(json) }
        guard let element = try? JSONParser(mode: .kotlinx).parse(json) else { return }
        walk(element)
    }

    /// A number the app itself vouches for: how many items a result held.
    public func noteCount(_ n: Int) { lock.withLock { registry.addNumber(n) } }

    /// What the listener wrote: a name or number they said first is theirs. Kept for the whole conversation (bounded).
    public func noteUser(_ text: String) {
        if BrainText.isBlank(text) { return }
        lock.withLock {
            if userLog.count > Self.maxUserLog { userLog.removeFirst(userLog.count - Self.maxUserLog / 2) }
            userLog.append(contentsOf: text.utf16)
            userLog.append(0x0A)
        }
    }

    /// Plain text the app put in front of the model (the profile block, the now-playing block): numbers, and each line's chunks as names.
    public func noteContext(_ text: String) {
        if BrainText.isBlank(text) { return }
        let key = BrainHash.fnv1a64(text)
        let fresh = lock.withLock { seenContexts.insert(key).inserted }
        if !fresh { return }
        lock.withLock { registry.addText(text) }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            for chunk in Self.chunksOf(String(line)) { noteName(chunk) }
        }
    }

    /// What an older conversation's history holds: every tool result in it.
    public func noteHistory(_ history: [JSONValue]) {
        lock.withLock { seeded = true }
        for message in history {
            let role = message["role"]?.stringValue
            guard let raw = message["content"] else { continue }
            // A chat opened again carries only its words: what the user said is theirs, and what Taizo said was checked when it was said.
            if let text = raw.stringValue {
                if role == "user" { noteUser(text) } else { noteContext(Self.withoutMarks(text)) }
                continue
            }
            for block in raw.arrayValue ?? [] {
                let type = block["type"]?.stringValue
                if type == "text" {
                    let text = block["text"]?.stringValue ?? ""
                    if role == "user" { noteUser(text) } else { noteContext(Self.withoutMarks(text)) }
                } else if type == "tool_result" {
                    if let c = block["content"] {
                        if let s = c.stringValue {
                            noteToolResult(s)
                        } else {
                            for part in c.arrayValue ?? [] { if let s = part["text"]?.stringValue { noteToolResult(s) } }
                        }
                    }
                }
            }
        }
    }

    /// What a web search or fetch returned in this turn (the loop's `web_search_tool_result` and `web_fetch_tool_result` blocks): names and
    /// numbers the model READ there are not names it invented (deviation 219). Only those blocks count; the model's own text never does.
    public func noteServerResults(_ messages: [JSONValue]) {
        for message in messages {
            for block in message["content"]?.arrayValue ?? [] {
                guard let type = block["type"]?.stringValue, type.hasSuffix("_tool_result"), type != "tool_result" else { continue }
                // Its short strings (titles, names) count as names and its text as quotable words and numbers; a name that is only
                // somewhere inside a long page is not a registered name, so a pick must still come from `recommend` or `build_mix`.
                noteToolResult(JSONWriter.write(block))
            }
        }
    }

    private static func withoutMarks(_ text: String) -> String {
        text.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
    }

    // MARK: Refs

    public func trackOf(_ ref: String) -> AssistantTrack? { lock.withLock { refs[ref] } }

    public func isKnownRef(_ ref: String) -> Bool { lock.withLock { refs[ref] != nil || seenRefs.contains(ref) } }

    /// The name of a genre id `lookup_genre` returned in this conversation, or nil.
    public func genreName(_ id: Int) -> String? { lock.withLock { genreNames[id] } }

    /// The refs of `list` that were issued in this conversation, in order; the others are added to `unknown`.
    public func known(_ list: [String], _ unknown: inout [String]) -> [String] {
        var out: [String] = []
        lock.withLock {
            for ref in list {
                if refs[ref] != nil || seenRefs.contains(ref) { out.append(ref) } else { unknown.append(ref) }
            }
        }
        return out
    }

    /// The genre ids of `list` that `lookup_genre` returned in this conversation, in order; the others are added to `unknown` as "genre 12".
    /// An id of zero or less is the sentinel for "none" and passes.
    public func knownGenreIds(_ list: [Int], _ unknown: inout [String]) -> [Int] {
        var out: [Int] = []
        lock.withLock {
            for id in list {
                if id <= 0 || genreNames[id] != nil { out.append(id) } else { unknown.append("genre \(id)") }
            }
        }
        return out
    }

    /// Same for mood ids (a mood and a genre share numbers: an id of one list is not an id of the other).
    public func knownMoodIds(_ list: [Int], _ unknown: inout [String]) -> [Int] {
        var out: [Int] = []
        lock.withLock {
            for id in list {
                if id <= 0 || moodNames[id] != nil { out.append(id) } else { unknown.append("mood \(id)") }
            }
        }
        return out
    }

    // MARK: The reply

    /// Checks `reply` against what this conversation held; everything the listener wrote in it counts as theirs.
    /// A name written with no mark and no quote is checked too (`scanUnmarked`): the guarantee does not rest on the model marking names.
    public func check(_ reply: String, placeholder: String) -> Grounding.Verdict {
        check(reply, placeholder: placeholder, extraNames: [])
    }

    private func check(_ reply: String, placeholder: String, extraNames: [String], numbers: Bool = true) -> Grounding.Verdict {
        var (reg, user) = lock.withLock { (registry, String(decoding: userLog, as: UTF16.self)) }
        for n in extraNames { reg.addName(n) }
        return Grounding.check(reply, reg, userText: user, placeholder: placeholder, dropUngroundedNumbers: numbers, scanUnmarked: true)
    }

    /// A final reply as the listener reads it: a name no tool returned (and the listener did not say) is replaced, a sentence with a number
    /// about the listener no tool returned is left out, the marks are taken off. When nothing is left, a fixed sentence says so: the raw text
    /// is never shown in its place. `alsoKnown` is asked once with the names that failed, and returns those that are still real (the
    /// listener's own library, for an answer from the phone's model, which looks the library up itself); they pass for this reply only.
    /// `numbers` false checks names only: an answer whose numbers the app cannot see (the phone model's own lookups) is not cut by them.
    public func shown(_ raw: String, numbers: Bool = true, alsoKnown: (([String]) -> [String])? = nil) -> String {
        let text = BrainText.trim(raw)
        if text.isEmpty { return text }
        var verdict = check(text, placeholder: Self.unverifiedName, extraNames: [], numbers: numbers)
        if !verdict.ungroundedNames.isEmpty, let alsoKnown {
            let extra = alsoKnown(verdict.ungroundedNames)
            if !extra.isEmpty { verdict = check(text, placeholder: Self.unverifiedName, extraNames: extra, numbers: numbers) }
        }
        let cleaned = BrainText.trim(verdict.cleaned)
        return cleaned.isEmpty ? Self.unverifiedReply : cleaned
    }

    /// An intro line for a result card: the line itself, or nil when it names anything no tool or the listener gave (the card keeps its plain
    /// words). Names only: its numbers are the result count the app itself stated.
    public func introLine(_ raw: String) -> String? {
        let text = BrainText.trim(raw)
        if text.isEmpty { return nil }
        let verdict = check(text, placeholder: Self.unverifiedName, extraNames: [], numbers: false)
        return verdict.ungroundedNames.isEmpty ? text : nil
    }

    /// A reply that is still being written, as it may be shown: an unclosed mark or quote, the word being typed and a run of capitalised
    /// words at the end (a half-written name cannot be judged) are held back; the rest is checked like a final reply. Empty while nothing
    /// can be judged yet.
    public func streaming(_ raw: String) -> String {
        let held = Self.holdBack(raw)
        if BrainText.isBlank(held) { return "" }
        return check(held, placeholder: Self.unverifiedName).cleaned
    }

    private static let heldConnectors: Set<String> = ["of", "the", "and", "de", "la", "le", "da", "van", "von", "x", "&"]

    /// `raw` without its unfinished end (see `streaming`).
    public static func holdBack(_ raw: String) -> String {
        var s = raw
        if let open = s.range(of: "[[", options: .backwards), s.range(of: "]]", range: open.upperBound..<s.endIndex) == nil {
            s = String(s[..<open.lowerBound])
        }
        if s.reduce(0, { $1 == "\"" ? $0 + 1 : $0 }) % 2 == 1, let q = s.lastIndex(of: "\"") { s = String(s[..<q]) }
        if let o = s.lastIndex(of: "\u{201C}"), s[o...].firstIndex(of: "\u{201D}") == nil { s = String(s[..<o]) }
        // The word being typed.
        guard let lastBreak = s.lastIndex(where: { $0.isWhitespace }) else { return "" }
        s = String(s[...lastBreak])
        // A run of capitalised words (and the little words inside a name) at the end: the next word may belong to it.
        var end = s.endIndex
        while true {
            var j = end
            while j > s.startIndex, s[s.index(before: j)].isWhitespace { j = s.index(before: j) }
            var k = j
            while k > s.startIndex, !s[s.index(before: k)].isWhitespace { k = s.index(before: k) }
            if k == j { break }
            let word = s[k..<j]
            let letters = word.lowercased().filter { $0.isLetter || $0 == "&" }
            if (word.first?.isUppercase ?? false) || heldConnectors.contains(letters) { end = k } else { break }
        }
        return String(s[..<end])
    }

    /// Of `names`, those that are a title, an album or a credited artist of `songs`: the names a phone-model answer may say, because the
    /// model looks the library up itself (the same words, folded). One pass over the library; call it only when something failed the check.
    public static func libraryNames(among names: [String], in songs: [Song]) -> [String] {
        var wanted: [String: [String]] = [:]
        for n in names { wanted[BrainText.fold(n), default: []].append(n) }
        if wanted.isEmpty { return [] }
        let distinct = Set(names).count
        var found = Set<String>()
        func test(_ value: String) {
            if value.isEmpty { return }
            if let originals = wanted[BrainText.fold(value)] { for o in originals { found.insert(o) } }
        }
        for song in songs {
            if found.count == distinct { break }
            test(song.title)
            test(song.album)
            for part in splitCredits(song.artist) { test(part) }
            for a in song.artists { test(a.name) }
        }
        return names.filter { found.contains($0) }
    }

    // MARK: Helpers

    private func walk(_ element: JSONValue) {
        switch element {
        case .string(let s): noteName(s)
        case .array(let items):
            lock.withLock { registry.addNumber(items.count) }
            for item in items { walk(item) }
        case .object(let o):
            noteObject(o)
            for member in o { walk(member.value) }
        default: break
        }
    }

    /// The refs and the genre or mood ids an object of a tool result carries (a similar artist's ref, a lookup's id with its name).
    private func noteObject(_ o: JSONObject) {
        lock.withLock {
            if let ref = o["ref"]?.stringValue, AssistantRules.parseRef(ref) != nil { seenRefs.insert(ref) }
            if let id = o["id"]?.int64Value, id > 0, id <= Int64(Int32.max), let name = o["name"]?.stringValue, !BrainText.isBlank(name) {
                if o["kind"]?.stringValue == "mood" { moodNames[Int(id)] = name } else { genreNames[Int(id)] = name }
            }
        }
    }

    private static let creditJoiners = [", ", " & ", " x ", " X ", " feat. ", " ft. ", " feat ", " ft ", " featuring ", " with ", " / ", " + ", " and "]

    /// The parts of a credit line: "A, B & C" or "A feat. B" are A, B and C.
    public static func splitCredits(_ display: String) -> [String] {
        var parts = [Array(display.utf16)]
        for joiner in creditJoiners {
            var next: [[UInt16]] = []
            for p in parts { next.append(contentsOf: split(p, by: Array(joiner.utf16))) }
            parts = next
        }
        return parts.map { BrainText.trim(String(decoding: $0, as: UTF16.self)) }.filter { !$0.isEmpty }
    }

    private static let contextSeparators = [": ", ", ", " - ", " (", "; ", " | "]

    /// The pieces of a context line ("Title - Artist (212 plays)", "Top artists: A (9), B (4)") that may be a name.
    public static func chunksOf(_ line: String) -> [String] {
        var parts = [Array(line.utf16)]
        for sep in contextSeparators {
            var next: [[UInt16]] = []
            for p in parts { next.append(contentsOf: split(p, by: Array(sep.utf16))) }
            parts = next
        }
        var out: [String] = []
        for p in parts {
            var t = Array(BrainText.trim(String(decoding: p, as: UTF16.self)).utf16)
            while let last = t.last, last == 0x29 || last == 0x2E || last == 0x3B { t.removeLast() }
            let s = BrainText.trim(String(decoding: t, as: UTF16.self))
            let n = s.utf16.count
            if n >= 2 && n <= maxName { out.append(s) }
        }
        return out
    }

    /// Kotlin's `String.split(String)`: every occurrence is a cut, empty pieces stay.
    static func split(_ text: [UInt16], by separator: [UInt16]) -> [[UInt16]] {
        var out: [[UInt16]] = []
        var from = 0
        while true {
            let at = Grounding.indexOf(text, separator, from)
            if at < 0 { break }
            out.append(Array(text[from..<at]))
            from = at + separator.count
        }
        out.append(Array(text[from...]))
        return out
    }
}
