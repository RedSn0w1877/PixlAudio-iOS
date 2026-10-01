// The on-disk JSON of an unsaved tap-sync draft — identical to the Android `LyricsSyncDraftStore`
// (`StoredSyncDraft` written by kotlinx.serialization `Json { ignoreUnknownKeys = true; encodeDefaults = true }`):
// compact, keys in Kotlin declaration order, every default written, nulls written as `null`, floats in Java's
// `Float.toString` form. Decoding follows kotlinx's rules (unknown keys skipped, numbers may be quoted, booleans
// lenient, missing required fields and nulls in non-null fields rejected), then `LyricsTapSync.isConsistent`.
// Verified against the real Android codec in `Tests/PixlLyricsTests/Fixtures/tapsync-android-golden.txt`.

import Foundation
import PixlFoundation
import PixlModel

/// Encodes and decodes stored tap-sync drafts.
public enum LyricsSyncDraftCodec {
    public static let format = "pixelplay-lyrics-sync-draft"
    public static let formatVersion = 1

    // MARK: Encode

    /// The draft as Android stores it, stamped with `nowMs` as `savedAtMs`.
    public static func encode(_ draft: SyncDraft, nowMs: Int64 = currentTimeMillis()) -> String {
        var root = JSONObject()
        root.append("format", .string(format))
        root.append("formatVersion", .integer(formatVersion))
        root.append("songId", .string(draft.songId))
        root.append("title", .string(draft.title))
        root.append("artist", .string(draft.artist))
        root.append("album", .string(draft.album))
        root.append("durationMs", .integer(draft.durationMs))
        root.append("cursor", .integer(draft.cursor))
        root.append("nudgeMs", .integer(draft.nudgeMs))
        root.append("version", .integer(draft.version))
        root.append("voices", .array(draft.voices.map { voice in
            var o = JSONObject()
            o.append("id", .string(voice.id))
            o.append("role", .string(voice.role))
            o.append("name", voice.name.map { .string($0) } ?? .null)
            return .object(o)
        }))
        root.append("lines", .array(draft.lines.map { line in
            var o = JSONObject()
            o.append("text", .string(line.text))
            o.append("voiceId", .string(line.voiceId))
            o.append("anchorMs", line.anchorMs.map { .integer($0) } ?? .null)
            o.append("translation", line.translation.map { .string($0) } ?? .null)
            o.append("firstToken", .integer(line.firstToken))
            o.append("tokenCount", .integer(line.tokenCount))
            o.append("locked", .bool(line.locked))
            o.append("skipped", .bool(line.skipped))
            return .object(o)
        }))
        root.append("tokens", .array(draft.tokens.map { token in
            var o = JSONObject()
            o.append("line", .integer(token.line))
            o.append("text", .string(token.text))
            o.append("rawStartMs", token.rawStartMs.map { .integer($0) } ?? .null)
            o.append("startSpeed", .number(javaFloatString(token.startSpeed)))
            o.append("rawEndMs", token.rawEndMs.map { .integer($0) } ?? .null)
            o.append("endSpeed", .number(javaFloatString(token.endSpeed)))
            o.append("exact", .bool(token.exact))
            return .object(o)
        }))
        root.append("savedAtMs", .integer(nowMs))
        return JSONWriter.write(.object(root))
    }

    /// Whether `encode` can write the draft the way Android can: kotlinx refuses non-finite floats
    /// (`allowSpecialFloatingPointValues = false`), so a draft with a NaN or infinite speed is not storable.
    public static func isEncodable(_ draft: SyncDraft) -> Bool {
        draft.tokens.allSatisfy { $0.startSpeed.isFinite && $0.endSpeed.isFinite }
    }

    // MARK: Decode

    /// Nil for anything that isn't a structurally sound draft of a known format version.
    public static func decode(_ raw: String) -> SyncDraft? {
        guard let value = try? JSONParser(mode: .kotlinx).parse(raw), case .object(let object) = value else {
            return nil
        }
        var format: String?
        var formatVersion: Int32?
        var songId: String?
        var title = ""
        var artist = ""
        var album = ""
        var durationMs: Int64 = 0
        var cursor: Int32 = 0
        var nudgeMs: Int32 = 0
        var version: Int32 = 1
        var voices: [Voice] = [Voice()]
        var lines: [SyncLine]?
        var tokens: [SyncToken]?
        for (key, member) in object {
            switch key {
            case "format": guard let s = KotlinxJSON.string(member) else { return nil }; format = s
            case "formatVersion": guard let v = KotlinxJSON.int(member) else { return nil }; formatVersion = v
            case "songId": guard let s = KotlinxJSON.string(member) else { return nil }; songId = s
            case "title": guard let s = KotlinxJSON.string(member) else { return nil }; title = s
            case "artist": guard let s = KotlinxJSON.string(member) else { return nil }; artist = s
            case "album": guard let s = KotlinxJSON.string(member) else { return nil }; album = s
            case "durationMs": guard let v = KotlinxJSON.long(member) else { return nil }; durationMs = v
            case "cursor": guard let v = KotlinxJSON.int(member) else { return nil }; cursor = v
            case "nudgeMs": guard let v = KotlinxJSON.int(member) else { return nil }; nudgeMs = v
            case "version": guard let v = KotlinxJSON.int(member) else { return nil }; version = v
            case "voices":
                guard let items = member.arrayValue else { return nil }
                var out: [Voice] = []
                out.reserveCapacity(items.count)
                for item in items {
                    guard let v = voice(from: item) else { return nil }
                    out.append(v)
                }
                voices = out
            case "lines":
                guard let items = member.arrayValue else { return nil }
                var out: [SyncLine] = []
                out.reserveCapacity(items.count)
                for item in items {
                    guard let l = line(from: item) else { return nil }
                    out.append(l)
                }
                lines = out
            case "tokens":
                guard let items = member.arrayValue else { return nil }
                var out: [SyncToken] = []
                out.reserveCapacity(items.count)
                for item in items {
                    guard let t = token(from: item) else { return nil }
                    out.append(t)
                }
                tokens = out
            case "savedAtMs": guard KotlinxJSON.long(member) != nil else { return nil }
            default: continue
            }
        }
        guard let format, let formatVersion, let songId, let lines, let tokens else { return nil }
        guard format.isIdentical(to: Self.format), formatVersion == Self.formatVersion else { return nil }
        let draft = SyncDraft(
            songId: songId,
            durationMs: durationMs.coerced(atLeast: 0),
            lines: lines,
            tokens: tokens,
            cursor: Int(cursor),
            voices: voices.isEmpty ? [Voice()] : voices,
            nudgeMs: Int(nudgeMs).coerced(in: -LyricsTapSync.maxNudgeMs, LyricsTapSync.maxNudgeMs),
            version: Int(version),
            title: title,
            artist: artist,
            album: album
        )
        return LyricsTapSync.isConsistent(draft) ? draft : nil
    }

    static func voice(from value: JSONValue) -> Voice? {
        guard case .object(let object) = value else { return nil }
        var voice = Voice()
        for (key, member) in object {
            switch key {
            case "id": guard let s = KotlinxJSON.string(member) else { return nil }; voice.id = s
            case "role": guard let s = KotlinxJSON.string(member) else { return nil }; voice.role = s
            case "name":
                if member.isNull {
                    voice.name = nil
                } else {
                    guard let s = KotlinxJSON.string(member) else { return nil }
                    voice.name = s
                }
            default: continue
            }
        }
        return voice
    }

    static func line(from value: JSONValue) -> SyncLine? {
        guard case .object(let object) = value else { return nil }
        var text: String?
        var voiceId = LyricsTapSync.leadVoiceId
        var anchorMs: Int64?
        var translation: String?
        var firstToken: Int32?
        var tokenCount: Int32?
        var locked = false
        var skipped = false
        for (key, member) in object {
            switch key {
            case "text": guard let s = KotlinxJSON.string(member) else { return nil }; text = s
            case "voiceId": guard let s = KotlinxJSON.string(member) else { return nil }; voiceId = s
            case "anchorMs":
                if member.isNull {
                    anchorMs = nil
                } else {
                    guard let v = KotlinxJSON.long(member) else { return nil }
                    anchorMs = v
                }
            case "translation":
                if member.isNull {
                    translation = nil
                } else {
                    guard let s = KotlinxJSON.string(member) else { return nil }
                    translation = s
                }
            case "firstToken": guard let v = KotlinxJSON.int(member) else { return nil }; firstToken = v
            case "tokenCount": guard let v = KotlinxJSON.int(member) else { return nil }; tokenCount = v
            case "locked": guard let b = lenientBool(member) else { return nil }; locked = b
            case "skipped": guard let b = lenientBool(member) else { return nil }; skipped = b
            default: continue
            }
        }
        guard let text, let firstToken, let tokenCount else { return nil }
        return SyncLine(text: text, voiceId: voiceId, anchorMs: anchorMs, translation: translation,
                        firstToken: Int(firstToken), tokenCount: Int(tokenCount), locked: locked, skipped: skipped)
    }

    static func token(from value: JSONValue) -> SyncToken? {
        guard case .object(let object) = value else { return nil }
        var line: Int32?
        var text: String?
        var rawStartMs: Int64?
        var startSpeed: Float = 1
        var rawEndMs: Int64?
        var endSpeed: Float = 1
        var exact = false
        for (key, member) in object {
            switch key {
            case "line": guard let v = KotlinxJSON.int(member) else { return nil }; line = v
            case "text": guard let s = KotlinxJSON.string(member) else { return nil }; text = s
            case "rawStartMs":
                if member.isNull {
                    rawStartMs = nil
                } else {
                    guard let v = KotlinxJSON.long(member) else { return nil }
                    rawStartMs = v
                }
            case "startSpeed": guard let f = finiteFloat(member) else { return nil }; startSpeed = f
            case "rawEndMs":
                if member.isNull {
                    rawEndMs = nil
                } else {
                    guard let v = KotlinxJSON.long(member) else { return nil }
                    rawEndMs = v
                }
            case "endSpeed": guard let f = finiteFloat(member) else { return nil }; endSpeed = f
            case "exact": guard let b = lenientBool(member) else { return nil }; exact = b
            default: continue
            }
        }
        guard let line, let text else { return nil }
        return SyncToken(line: Int(line), text: text, rawStartMs: rawStartMs, startSpeed: startSpeed,
                         rawEndMs: rawEndMs, endSpeed: endSpeed, exact: exact)
    }

    /// kotlinx `decodeBoolean` → `consumeBooleanLenient`: `true`/`false` in any ASCII case, quoted or not.
    static func lenientBool(_ value: JSONValue) -> Bool? {
        let token: String
        switch value {
        case .bool(let b): return b
        case .number(let t): token = t
        case .string(let t): token = t
        default: return nil
        }
        let lowered = String(decoding: token.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 | 0x20 : $0 }, as: UTF8.self)
        if lowered == "true" { return true }
        if lowered == "false" { return false }
        return nil
    }

    /// kotlinx `decodeFloat`: the (quoted or bare) token through `java.lang.Float.parseFloat`, which must be finite.
    static func finiteFloat(_ value: JSONValue) -> Float? {
        let token: String
        switch value {
        case .number(let t): token = t
        case .string(let t): token = t
        default: return nil
        }
        guard let f = javaParseFloat(token), f.isFinite else { return nil }
        return f
    }

    /// `java.lang.Float.parseFloat` for decimal input: surrounding characters ≤ U+0020 trimmed, an optional
    /// `f`/`F`/`d`/`D` suffix, a sign, digits with an optional fraction and exponent (`Infinity`/`NaN` are never
    /// finite, so they are rejected by the caller either way).
    static func javaParseFloat(_ token: String) -> Float? {
        var bytes = Array(token.utf8)[...]
        while let first = bytes.first, first <= 0x20 { bytes = bytes.dropFirst() }
        while let last = bytes.last, last <= 0x20 { bytes = bytes.dropLast() }
        if let last = bytes.last, [0x66, 0x46, 0x64, 0x44].contains(last) { bytes = bytes.dropLast() }
        var it = bytes
        if let sign = it.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") { it = it.dropFirst() }
        var digits = 0
        while let c = it.first, c >= 0x30 && c <= 0x39 { it = it.dropFirst(); digits += 1 }
        if it.first == UInt8(ascii: ".") {
            it = it.dropFirst()
            while let c = it.first, c >= 0x30 && c <= 0x39 { it = it.dropFirst(); digits += 1 }
        }
        guard digits > 0 else { return nil }
        if let e = it.first, e == UInt8(ascii: "e") || e == UInt8(ascii: "E") {
            it = it.dropFirst()
            if let sign = it.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") { it = it.dropFirst() }
            var exponentDigits = 0
            while let c = it.first, c >= 0x30 && c <= 0x39 { it = it.dropFirst(); exponentDigits += 1 }
            guard exponentDigits > 0 else { return nil }
        }
        guard it.isEmpty else { return nil }
        // Swift's parser rounds a decimal string to the nearest Float, as Java does.
        return Float(String(decoding: bytes, as: UTF8.self))
    }

    /// Java's `Float.toString`: the shortest decimal that round-trips, written as `ddd.ddd` when
    /// `10⁻³ ≤ |v| < 10⁷` and as `d.dddEn` otherwise (`1.0`, `0.75`, `1.0E-4`, `1.0E10`).
    public static func javaFloatString(_ value: Float) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == 0 { return value.sign == .minus ? "-0.0" : "0.0" }
        // Swift's description is also the shortest round-trip digit string; only the layout differs.
        var text = Substring(value.magnitude.description)
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(String(text[text.index(after: e)...].filter { $0 != "+" })) ?? 0
            text = text[..<e]
        }
        var integerPart = Substring(text)
        var fractionPart = Substring("")
        if let dot = text.firstIndex(of: ".") {
            integerPart = text[..<dot]
            fractionPart = text[text.index(after: dot)...]
        }
        // value = 0.DIGITS × 10^pointPosition after stripping leading zeros.
        var digits = Array(integerPart + fractionPart)
        var pointPosition = integerPart.count + exponent
        while digits.first == "0" {
            digits.removeFirst()
            pointPosition -= 1
        }
        while digits.last == "0" { digits.removeLast() }
        if digits.isEmpty { return "0.0" }
        let scientificExponent = pointPosition - 1 // value = d.ddd × 10^scientificExponent
        if digits.count == 1 {
            // Java (JDK 19+) never settles for one significant digit: among the two-digit decimals that round to
            // the value it takes the closest — `1.4E-45` for the smallest subnormal, where Swift prints `1e-45`.
            let scaled = Double(value.magnitude) / pow(10, Double(scientificExponent - 1))
            let two = Int(scaled.rounded(.toNearestOrEven))
            if (10...99).contains(two), Float("\(two)e\(scientificExponent - 1)") == value.magnitude {
                digits = Array(String(two))
                while digits.last == "0" { digits.removeLast() }
            }
        }
        let sign = value.sign == .minus ? "-" : ""
        if scientificExponent >= -3 && scientificExponent < 7 {
            if pointPosition <= 0 {
                return sign + "0." + String(repeating: "0", count: -pointPosition) + String(digits)
            }
            let integerDigits = pointPosition >= digits.count
                ? String(digits) + String(repeating: "0", count: pointPosition - digits.count)
                : String(digits[..<pointPosition])
            let fractionDigits = pointPosition >= digits.count ? "0" : String(digits[pointPosition...])
            return sign + integerDigits + "." + fractionDigits
        }
        let rest = digits.count > 1 ? String(digits[1...]) : "0"
        return sign + String(digits[0]) + "." + rest + "E" + String(scientificExponent)
    }
}
