// Port of the Android `LyricsDocCodec` (kotlinx.serialization `Json { ignoreUnknownKeys = true;
// encodeDefaults = true }`). `encode` produces the same bytes as Android: compact, declaration-order keys, every
// default written, nulls written as `null`, kotlinx string escaping. `decode` accepts what Android accepts —
// verified against the real Android codec in `Tests/PixlModelTests/Fixtures/lyricsdoc-android-golden.txt`:
// unknown keys (with any value) ignored, numbers optionally quoted or with a whole-number exponent, duplicate
// keys resolved last-wins, then the same `isValid` rules.

import Foundation
import PixlFoundation

public enum LyricsDocCodec {
    /// Largest accepted input, in UTF-16 code units (Kotlin `String.length`).
    public static let maxInputLength = 1_048_576
    /// Deepest accepted `{`/`[` nesting.
    public static let maxDepth = 32
    public static let maxLines = 10_000
    public static let maxVoices = 32
    public static let maxSyllables: Int64 = 100_000
    /// 24 h, the cap on `durationMs` and on line ends when no duration is given.
    public static let maxDurationMs: Int64 = 86_400_000

    // MARK: Encode

    /// The document as Android writes it.
    public static func encode(_ doc: LyricsDoc) -> String { JSONWriter.write(jsonValue(doc)) }

    /// The document as a JSON tree, keys in Android's declaration order with all defaults present.
    public static func jsonValue(_ doc: LyricsDoc) -> JSONValue {
        var root = JSONObject()
        root.append("format", .string(doc.format))
        root.append("version", .integer(doc.version))
        var meta = JSONObject()
        meta.append("title", .string(doc.metadata.title))
        meta.append("artist", .string(doc.metadata.artist))
        meta.append("album", .string(doc.metadata.album))
        meta.append("durationMs", doc.metadata.durationMs.map { .integer($0) } ?? .null)
        meta.append("source", doc.metadata.source.map { .string($0) } ?? .null)
        root.append("metadata", .object(meta))
        root.append("voices", .array(doc.voices.map { voice in
            var o = JSONObject()
            o.append("id", .string(voice.id))
            o.append("role", .string(voice.role))
            o.append("name", voice.name.map { .string($0) } ?? .null)
            return .object(o)
        }))
        root.append("lines", .array(doc.lines.map { line in
            var o = JSONObject()
            o.append("startMs", .integer(line.startMs))
            o.append("endMs", .integer(line.endMs))
            o.append("text", .string(line.text))
            o.append("voiceId", .string(line.voiceId))
            o.append("syllables", .array(line.syllables.map { s in
                var so = JSONObject()
                so.append("startMs", .integer(s.startMs))
                so.append("durationMs", .integer(s.durationMs))
                so.append("text", .string(s.text))
                return .object(so)
            }))
            return .object(o)
        }))
        return .object(root)
    }

    // MARK: Decode

    /// Parses and validates a document; nil when the input is oversized, too deep, malformed, or invalid.
    public static func decode(_ raw: String) -> LyricsDoc? {
        guard isBoundedJson(raw) else { return nil }
        guard let value = try? JSONParser(mode: .kotlinx, maxDepth: maxDepth + 1).parse(raw),
              let doc = document(from: value), isValid(doc) else { return nil }
        return doc
    }

    /// `isBoundedJson`: at most `maxInputLength` UTF-16 units, brackets balanced outside strings and never nested
    /// deeper than `maxDepth`, no unterminated string.
    public static func isBoundedJson(_ raw: String) -> Bool {
        if raw.utf16.count > maxInputLength { return false }
        var depth = 0
        var quoted = false
        var escaped = false
        for byte in raw.utf8 {
            if quoted {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    quoted = false
                }
            } else {
                switch byte {
                case UInt8(ascii: "\""): quoted = true
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                    if depth > maxDepth { return false }
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth < 0 { return false }
                default: break
                }
            }
        }
        return depth == 0 && !quoted
    }

    /// Decodes a JSON tree with the generated kotlinx deserializer's rules (no validation).
    public static func document(from value: JSONValue) -> LyricsDoc? {
        guard case .object(let object) = value else { return nil }
        var doc = LyricsDoc(lines: [])
        var hasLines = false
        for (key, member) in object {
            switch key {
            case "format":
                guard let s = KotlinxJSON.string(member) else { return nil }
                doc.format = s
            case "version":
                guard let v = KotlinxJSON.int(member) else { return nil }
                doc.version = Int(v)
            case "metadata":
                guard let m = metadata(from: member) else { return nil }
                doc.metadata = m
            case "voices":
                guard let items = member.arrayValue else { return nil }
                var voices: [Voice] = []
                voices.reserveCapacity(items.count)
                for item in items {
                    guard let v = voice(from: item) else { return nil }
                    voices.append(v)
                }
                doc.voices = voices
            case "lines":
                guard let items = member.arrayValue else { return nil }
                var lines: [TimedLine] = []
                lines.reserveCapacity(items.count)
                for item in items {
                    guard let l = line(from: item) else { return nil }
                    lines.append(l)
                }
                doc.lines = lines
                hasLines = true
            default:
                continue
            }
        }
        return hasLines ? doc : nil
    }

    static func metadata(from value: JSONValue) -> LyricsMetadata? {
        guard case .object(let object) = value else { return nil }
        var meta = LyricsMetadata()
        for (key, member) in object {
            switch key {
            case "title":
                guard let s = KotlinxJSON.string(member) else { return nil }
                meta.title = s
            case "artist":
                guard let s = KotlinxJSON.string(member) else { return nil }
                meta.artist = s
            case "album":
                guard let s = KotlinxJSON.string(member) else { return nil }
                meta.album = s
            case "durationMs":
                if member.isNull {
                    meta.durationMs = nil
                } else {
                    guard let v = KotlinxJSON.long(member) else { return nil }
                    meta.durationMs = v
                }
            case "source":
                if member.isNull {
                    meta.source = nil
                } else {
                    guard let s = KotlinxJSON.string(member) else { return nil }
                    meta.source = s
                }
            default:
                continue
            }
        }
        return meta
    }

    static func voice(from value: JSONValue) -> Voice? {
        guard case .object(let object) = value else { return nil }
        var voice = Voice()
        for (key, member) in object {
            switch key {
            case "id":
                guard let s = KotlinxJSON.string(member) else { return nil }
                voice.id = s
            case "role":
                guard let s = KotlinxJSON.string(member) else { return nil }
                voice.role = s
            case "name":
                if member.isNull {
                    voice.name = nil
                } else {
                    guard let s = KotlinxJSON.string(member) else { return nil }
                    voice.name = s
                }
            default:
                continue
            }
        }
        return voice
    }

    static func line(from value: JSONValue) -> TimedLine? {
        guard case .object(let object) = value else { return nil }
        var startMs: Int64?
        var endMs: Int64?
        var text: String?
        var voiceId = "lead"
        var syllables: [TimedSyllable] = []
        for (key, member) in object {
            switch key {
            case "startMs":
                guard let v = KotlinxJSON.long(member) else { return nil }
                startMs = v
            case "endMs":
                guard let v = KotlinxJSON.long(member) else { return nil }
                endMs = v
            case "text":
                guard let s = KotlinxJSON.string(member) else { return nil }
                text = s
            case "voiceId":
                guard let s = KotlinxJSON.string(member) else { return nil }
                voiceId = s
            case "syllables":
                guard let items = member.arrayValue else { return nil }
                var out: [TimedSyllable] = []
                out.reserveCapacity(items.count)
                for item in items {
                    guard let s = syllable(from: item) else { return nil }
                    out.append(s)
                }
                syllables = out
            default:
                continue
            }
        }
        guard let startMs, let endMs, let text else { return nil }
        return TimedLine(startMs: startMs, endMs: endMs, text: text, voiceId: voiceId, syllables: syllables)
    }

    static func syllable(from value: JSONValue) -> TimedSyllable? {
        guard case .object(let object) = value else { return nil }
        var startMs: Int64?
        var durationMs: Int64?
        var text: String?
        for (key, member) in object {
            switch key {
            case "startMs":
                guard let v = KotlinxJSON.long(member) else { return nil }
                startMs = v
            case "durationMs":
                guard let v = KotlinxJSON.long(member) else { return nil }
                durationMs = v
            case "text":
                guard let s = KotlinxJSON.string(member) else { return nil }
                text = s
            default:
                continue
            }
        }
        guard let startMs, let durationMs, let text else { return nil }
        return TimedSyllable(startMs: startMs, durationMs: durationMs, text: text)
    }

    // MARK: Validation

    /// `LyricsDocCodec.isValid`, rule for rule. String comparisons are by code unit, like Kotlin.
    public static func isValid(_ doc: LyricsDoc) -> Bool {
        if !doc.format.isIdentical(to: LyricsDoc.formatName) || doc.version != 1 || doc.lines.isEmpty
            || doc.lines.count > maxLines {
            return false
        }
        if doc.voices.isEmpty || doc.voices.count > maxVoices { return false }
        for i in doc.voices.indices {
            for j in doc.voices.indices where j < i && doc.voices[j].id.isIdentical(to: doc.voices[i].id) {
                return false
            }
        }
        if doc.voices.contains(where: { voice in
            voice.id.isKotlinBlank || !VoiceRole.all.contains(where: { $0.isIdentical(to: voice.role) })
        }) {
            return false
        }
        let duration = doc.metadata.durationMs
        if let duration, !(1...maxDurationMs).contains(duration) { return false }
        if zip(doc.lines, doc.lines.dropFirst()).contains(where: { $0.startMs > $1.startMs }) { return false }
        let syllableCount = doc.lines.reduce(Int64(0)) { $0 + Int64($1.syllables.count) }
        if syllableCount > maxSyllables { return false }
        let lineEndLimit = duration ?? maxDurationMs
        return doc.lines.allSatisfy { line in
            guard line.startMs >= 0, line.endMs > line.startMs, line.endMs <= lineEndLimit,
                  doc.voices.contains(where: { $0.id.isIdentical(to: line.voiceId) }),
                  !zip(line.syllables, line.syllables.dropFirst()).contains(where: { $0.startMs > $1.startMs })
            else { return false }
            let syllablesFit = line.syllables.allSatisfy { s in
                s.startMs >= line.startMs && s.startMs < line.endMs && s.durationMs > 0
                    && s.durationMs <= line.endMs - s.startMs
            }
            guard syllablesFit else { return false }
            if line.syllables.isEmpty { return true }
            return line.syllables.map(\.text).joined().isIdentical(to: line.text)
        }
    }
}
