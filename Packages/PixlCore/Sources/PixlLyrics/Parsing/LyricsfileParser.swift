// Port of the Android `data/network/lyrics/LyricsfileParser.kt`: draft 1.0 Lyricsfile (LRCLIB's `lyricsfile`
// field) → `Lyrics`. Absolute millisecond times, word text kept verbatim (its spaces decide word boundaries).
// Any structural problem, a non-zero/ambiguous `offset_ms`, or reversed word times rejects the whole file.

import Foundation
import PixlFoundation
import PixlModel

public enum LyricsfileParser {
    /// Largest accepted input (UTF-16 units, as Kotlin counts).
    public static let maxInputLength = 512_000

    /// Line- or word-synced lyrics, or nil.
    public static func parse(_ raw: String?) -> Lyrics? {
        guard let raw, !ParseKit.isBlank(raw), raw.utf16.count <= maxInputLength else { return nil }
        guard let doc = try? LyricsfileYAML.load(raw), case .mapping = doc else { return nil }
        guard (doc["version"]?.javaString ?? "null") == "1.0" else { return nil }
        // Draft offset semantics are unresolved; don't silently invent an interpretation.
        let offset = doc["offset_ms"] ?? {
            if case .mapping? = doc["metadata"] { return doc["metadata"]?["offset_ms"] }
            return nil
        }()
        if let offset, ParseKit.toLong(offset.javaString) != 0 { return nil }
        guard case .sequence(let sourceLines)? = doc["lines"] else { return nil }
        if sourceLines.count > 10_000 { return nil }

        var lines: [SyncedLine] = []
        for value in sourceLines {
            guard case .mapping = value else { return nil }
            guard case .scalar(let text)? = value["text"] else { return nil }
            guard let time = millis(value["start_ms"]) else { return nil }
            var words: [SyncedWord]?
            if case .sequence(let wordValues)? = value["words"] {
                var previousSpace = true
                var out: [SyncedWord] = []
                for wordValue in wordValues {
                    guard case .mapping = wordValue else { return nil }
                    guard case .scalar(let wordText)? = wordValue["text"] else { return nil }
                    guard let wordTime = millis(wordValue["start_ms"]) else { return nil }
                    let startsNew = previousSpace || wordText.startsWithKotlinWhitespace
                    previousSpace = wordText.endsWithKotlinWhitespace
                    if ParseKit.isBlank(wordText) { continue }
                    out.append(SyncedWord(time: wordTime, word: ParseKit.trim(wordText),
                                          startsNewWord: startsNew))
                }
                words = out.isEmpty ? nil : out
            }
            if let words, zip(words, words.dropFirst()).contains(where: { $0.time > $1.time }) { return nil }
            lines.append(SyncedLine(time: time, line: text, words: words))
        }
        if lines.isEmpty { return nil }
        return Lyrics(plain: lines.map(\.line), synced: lines, areFromRemote: true)
    }

    /// A whole, finite millisecond count in 0…86 400 000, from any scalar text Kotlin's `toDoubleOrNull` reads.
    private static func millis(_ value: LyricsfileYAMLNode?) -> Int? {
        guard let value, let d = ParseKit.parseDouble(value.javaString) else { return nil }
        if !d.isFinite || d < 0 || d > 86_400_000 || d != Double(KotlinMath.toLong(d)) { return nil }
        return Int(KotlinMath.toInt(d))
    }
}
