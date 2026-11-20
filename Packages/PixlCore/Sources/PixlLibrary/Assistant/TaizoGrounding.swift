// What one Ask Taizo conversation really held, for the grounding rule (docs/brain-spec.md, 1 principle 9, 9.4): every name a tool returned,
// every ref a tool issued (so the next call can use it, and a made-up ref is refused), every number a tool or the app stated.
//
// The final reply is checked against it (`check`, the pure `Grounding.check`): a track, album or artist the reply names that no tool returned
// is replaced and flagged, and a number about the listener that no tool returned drops its sentence. One per conversation: `reset` on a new
// chat, `noteHistory` when an older chat is opened again (its tool results are in the history the model is sent anyway).
// Mirrors Android's `TaizoGrounding.kt`.

import Foundation
import PixlFoundation

/// The conversation's record of what was returned and said.
public final class TaizoGrounding: @unchecked Sendable {
    /// The most characters of a name.
    public static let maxName = Grounding.maxSpan
    private static let maxUserLog = 8_000

    private let lock = NSLock()
    private var registry = Grounding.Registry()
    private var refs: [String: AssistantTrack] = [:]
    private var seeded = false
    private var userLog: [UInt16] = []
    private var seenContexts = Set<UInt64>()

    public init() {}

    /// True once `noteHistory` ran for this conversation (or it was started here).
    public var isSeeded: Bool { lock.withLock { seeded } }

    public var knownNames: Int { lock.withLock { registry.size } }

    public var refCount: Int { lock.withLock { refs.count } }

    public func reset() {
        lock.withLock {
            registry = Grounding.Registry()
            refs = [:]
            seeded = false
            userLog = []
            seenContexts = []
        }
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

    public func isKnownRef(_ ref: String) -> Bool { lock.withLock { refs[ref] != nil } }

    /// The refs of `list` that were issued in this conversation, in order; the others are added to `unknown`.
    public func known(_ list: [String], _ unknown: inout [String]) -> [String] {
        var out: [String] = []
        lock.withLock {
            for ref in list {
                if refs[ref] != nil { out.append(ref) } else { unknown.append(ref) }
            }
        }
        return out
    }

    // MARK: The reply

    /// Checks `reply` against what this conversation held; everything the listener wrote in it counts as theirs.
    public func check(_ reply: String, placeholder: String) -> Grounding.Verdict {
        let (reg, user) = lock.withLock { (registry, String(decoding: userLog, as: UTF16.self)) }
        return Grounding.check(reply, reg, userText: user, placeholder: placeholder, dropUngroundedNumbers: true)
    }

    // MARK: Helpers

    private func walk(_ element: JSONValue) {
        switch element {
        case .string(let s): noteName(s)
        case .array(let items):
            lock.withLock { registry.addNumber(items.count) }
            for item in items { walk(item) }
        case .object(let o):
            for member in o { walk(member.value) }
        default: break
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
