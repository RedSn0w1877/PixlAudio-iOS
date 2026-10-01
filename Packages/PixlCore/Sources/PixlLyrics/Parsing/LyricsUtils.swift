// Port of the Android `utils/LyricsUtils.kt` parsing half (`LyricsUtils` object): the format dispatcher
// `parseLyrics` (PixelPlay JSON documents, Musixmatch richsync, NetEase YRC, TTML, Kugou/Paxsenix word-by-word,
// LRC and enhanced word-tag LRC, plain text), same-timestamp translation pairing, romanisation and the LRC writers.
// Verified against the compiled Android implementation (`Tests/PixlLyricsTests/Fixtures/parsing/lyrics-android-golden.txt`).

import Foundation
import PixlFoundation
import PixlModel

public enum LyricsUtils {

    /// Parses lyrics in any supported format; plain text when nothing is timed. Never fails: unusable input gives
    /// `Lyrics(plain: [], synced: [])`.
    /// - Parameter romanization: Japanese/Chinese readings (the Android app uses kuromoji and pinyin4j); the default
    ///   provides none, so those lines get no romanisation. Korean, Hindi, Punjabi and Cyrillic are built in.
    public static func parseLyrics(_ lyricsText: String?,
                                   romanization: any CJKRomanizationProvider = NoCJKRomanization()) -> Lyrics {
        guard let lyricsText, !lyricsText.isEmpty else { return Lyrics(plain: [], synced: []) }

        let entireLyricsHasKana = lyricsText.utf16.contains { (0x3040...0x309F).contains($0) || (0x30A0...0x30FF).contains($0) }

        let normalizedInput = stripLeadingLyricsDocumentNoise(lyricsText)
        if ParseKit.hasPrefix(normalizedInput, "{") {
            if let doc = LyricsDocCodec.decode(normalizedInput) { return doc.toLyrics() }
            // JSON objects can also be YRC metadata lines; allow the YRC detector below.
            if ParseKit.contains(normalizedInput, "\"pixelplay-lyrics\"") { return Lyrics(plain: [], synced: []) }
        }
        if ParseKit.hasPrefix(normalizedInput, "[") && ParseKit.contains(normalizedInput, "\"ts\"") {
            return WordSyncTranspilers.richSync(normalizedInput)?.toLyrics() ?? Lyrics(plain: [], synced: [])
        }
        if containsYrcLine(normalizedInput) {
            return WordSyncTranspilers.yrc(normalizedInput)?.toLyrics() ?? Lyrics(plain: [], synced: [])
        }
        if looksLikeTtmlDocument(normalizedInput) {
            guard let converted = TtmlLyricsParser.parseToEnhancedLrc(normalizedInput) else {
                return Lyrics(plain: [], synced: [])
            }
            return parseLyrics(converted, romanization: romanization)
        }
        // Kugou / Paxsenix word-by-word: any non-metadata line `[number,number]` whose first number is > 999.
        if looksLikeKugouFormat(lyricsText) {
            return parseKugouLyrics(lyricsText)
        }

        var syncedLines: [SyncedLine] = []
        var plainLines: [String] = []
        var isSynced = false

        for rawLine in ParseKit.lines(lyricsText) {
            let line = sanitizeLrcLine(rawLine)
            if line.isEmpty || isMetadataLine(line) { continue }

            if let match = matchLrcLine(line) {
                isSynced = true
                let textWithTags = stripFormatCharacters(ParseKit.trim(match.rest))
                let text = stripLrcTimestamps(textWithTags)
                let lineTimestamp = match.timestampMs

                if containsWordTag(text) {
                    var words: [SyncedWord] = []
                    let parts = splitBeforeWordTags(text)
                    let displayText = removeWordTags(text)
                    var pendingWordBoundary = false

                    for part in parts {
                        if part.isEmpty { continue }
                        if let tag = parseWordTag(atStartOf: part) {
                            let wordText = stripFormatCharacters(tag.text)
                            var timedWordTextRaw = ParseKit.substringBefore(wordText, "\n")
                            timedWordTextRaw = ParseKit.substringBefore(timedWordTextRaw, "\r")
                            timedWordTextRaw = ParseKit.substringBefore(timedWordTextRaw, "\\n")
                            timedWordTextRaw = ParseKit.substringBefore(timedWordTextRaw, "\\r")
                            let startsNewWord = words.isEmpty || pendingWordBoundary
                                || timedWordTextRaw.startsWithKotlinWhitespace
                            let timedWordText = ParseKit.trim(timedWordTextRaw)
                            pendingWordBoundary = timedWordTextRaw.endsWithKotlinWhitespace
                            if !timedWordText.isEmpty {
                                words.append(SyncedWord(time: ParseKit.wrapToInt(tag.timestampMs), word: timedWordText,
                                                        startsNewWord: startsNewWord))
                            }
                        } else {
                            // Only leading untagged text becomes a timed word; trailing untagged chunks (inline
                            // translations) stay in the line text without stealing word timing.
                            if words.isEmpty {
                                let leading = stripFormatCharacters(part)
                                let startsNewWord = pendingWordBoundary || leading.startsWithKotlinWhitespace
                                let visibleLeading = ParseKit.trim(leading)
                                pendingWordBoundary = leading.endsWithKotlinWhitespace
                                if !visibleLeading.isEmpty {
                                    words.append(SyncedWord(time: ParseKit.wrapToInt(lineTimestamp), word: visibleLeading,
                                                            startsNewWord: words.isEmpty || startsNewWord))
                                }
                            } else if part.unicodeScalars.contains(where: ParseKit.isWhitespace) {
                                pendingWordBoundary = true
                            }
                        }
                    }

                    if !words.isEmpty {
                        syncedLines.append(SyncedLine(time: ParseKit.wrapToInt(lineTimestamp), line: displayText, words: words))
                    } else {
                        syncedLines.append(SyncedLine(time: ParseKit.wrapToInt(lineTimestamp), line: displayText))
                    }
                } else {
                    syncedLines.append(SyncedLine(time: ParseKit.wrapToInt(lineTimestamp), line: text))
                }
            } else {
                let stripped = stripLrcTimestamps(stripFormatCharacters(line))
                // After the first timed line, an untimed line continues the previous one.
                if isSynced, let last = syncedLines.popLast() {
                    let mergedLineText = last.line.isEmpty ? stripped : last.line + "\n" + stripped
                    if let words = last.words, !words.isEmpty {
                        syncedLines.append(SyncedLine(time: last.time, line: mergedLineText, words: words))
                    } else {
                        syncedLines.append(SyncedLine(time: last.time, line: mergedLineText))
                    }
                } else {
                    plainLines.append(stripped)
                }
            }
        }

        if isSynced && !syncedLines.isEmpty {
            let sorted = stableSortedByTime(syncedLines)
            let paired = pairTranslationLines(sorted).map { line -> SyncedLine in
                var copy = line
                copy.romanization = romanize(line.line, entireLyricsHasKana: entireLyricsHasKana, provider: romanization)
                return copy
            }
            let plainVersion = paired.map { line -> String in
                var out = line.line
                if let r = line.romanization, !r.isEmpty { out += "\n" + r }
                if let t = line.translation, !t.isEmpty { out += "\n" + t }
                return out
            }
            return Lyrics(plain: plainVersion, synced: paired)
        } else {
            let processedPlain = plainLines.map { line -> String in
                let romanized = romanize(line, entireLyricsHasKana: entireLyricsHasKana, provider: romanization)
                if let romanized, !romanized.isEmpty { return line + "\n" + romanized }
                return line
            }
            return Lyrics(plain: processedPlain)
        }
    }

    /// The romanisation `parseLyrics` attaches to a line (first matching script wins), capitalised and trimmed.
    static func romanize(_ line: String, entireLyricsHasKana: Bool, provider: any CJKRomanizationProvider) -> String? {
        let romanized: String?
        if MultiLangRomanizer.isJapanese(line, entireLyricsHasKana: entireLyricsHasKana) {
            romanized = MultiLangRomanizer.romanizeJapanese(line, provider: provider)
        } else if MultiLangRomanizer.isChinese(line) {
            romanized = MultiLangRomanizer.romanizeChinese(line, provider: provider)
        } else if MultiLangRomanizer.isKorean(line) {
            romanized = MultiLangRomanizer.romanizeKorean(line)
        } else if MultiLangRomanizer.isHindi(line) {
            romanized = MultiLangRomanizer.romanizeHindi(line)
        } else if MultiLangRomanizer.isPunjabi(line) {
            romanized = MultiLangRomanizer.romanizePunjabi(line)
        } else if MultiLangRomanizer.isCyrillic(line) {
            romanized = MultiLangRomanizer.romanizeCyrillic(line)
        } else {
            romanized = nil
        }
        return romanized.map { ParseKit.trim(capitalizeFirstLetter($0)) }
    }

    /// Kotlin `replaceFirstChar { if (it.isLowerCase()) it.titlecase(Locale.ROOT) else it.toString() }` on the first
    /// UTF-16 unit.
    static func capitalizeFirstLetter(_ s: String) -> String {
        guard let first = s.unicodeScalars.first, first.value <= 0xFFFF, first.properties.isLowercase else { return s }
        // Kotlin `Char.titlecase(Locale.ROOT)`: a multi-character upper case becomes its first character plus the
        // rest lower-cased ("ß" → "Ss"), otherwise the simple title case — i.e. Unicode's full title-case mapping.
        return first.properties.titlecaseMapping + String(s.unicodeScalars.dropFirst())
    }

    // MARK: Kugou / Paxsenix

    /// True when some non-metadata line is `[lineStartMs,lineDurationMs]…` with `lineStartMs > 999`.
    static func looksLikeKugouFormat(_ text: String) -> Bool {
        ParseKit.lines(text).contains { raw in
            let line = ParseKit.trim(raw)
            if line.isEmpty || isMetadataLine(line) { return false }
            guard let header = matchKugouLine(line) else { return false }
            return (ParseKit.toLong(header.start) ?? 0) > 999
        }
    }

    /// Kugou/Paxsenix word-by-word: `[lineStartMs,lineDurationMs]<wordOffsetMs,durationMs,flags>word…`, word offsets
    /// relative to the line start, an optional `[offset:N]` header shifting everything.
    static func parseKugouLyrics(_ text: String) -> Lyrics {
        let lines = ParseKit.lines(text)
        var globalOffsetMs: Int64 = 0
        if let header = lines.first(where: { ParseKit.hasPrefixIgnoringASCIICase(ParseKit.trim($0), "[offset:") }) {
            var value = ParseKit.trim(header)
            if ParseKit.hasPrefix(value, "[offset:") { value = String(value.unicodeScalars.dropFirst(8)) }
            if ParseKit.hasSuffix(value, "]") { value = String(value.unicodeScalars.dropLast()) }
            globalOffsetMs = ParseKit.toLong(ParseKit.trim(value)) ?? 0
        }

        var syncedLines: [SyncedLine] = []
        for raw in lines {
            let line = ParseKit.trim(raw)
            if line.isEmpty || isMetadataLine(line) { continue }
            guard let header = matchKugouLine(line), let start = ParseKit.toLong(header.start) else { continue }
            let lineStartMs = start &+ globalOffsetMs
            if lineStartMs <= 999 && globalOffsetMs == 0 { continue }
            let body = header.body

            var words: [SyncedWord] = []
            var previousEndsWithSpace = true
            for token in kugouWordTokens(body) {
                let wordOffsetMs = ParseKit.toLong(token.offset) ?? 0
                let rawText = token.text
                let startsNew = previousEndsWithSpace || rawText.startsWithKotlinWhitespace
                let wordText = ParseKit.trim(rawText)
                previousEndsWithSpace = rawText.endsWithKotlinWhitespace
                if wordText.isEmpty { continue }
                words.append(SyncedWord(time: ParseKit.wrapToInt(lineStartMs &+ wordOffsetMs), word: wordText,
                                        startsNewWord: startsNew))
            }

            let plainText = ParseKit.trim(replaceKugouTokensWithText(body))
            if plainText.isEmpty && words.isEmpty { continue }
            syncedLines.append(SyncedLine(time: ParseKit.wrapToInt(lineStartMs), line: plainText,
                                          words: words.isEmpty ? nil : words))
        }

        if syncedLines.isEmpty { return Lyrics(plain: [], synced: []) }
        let paired = pairTranslationLines(stableSortedByTime(syncedLines))
        return Lyrics(plain: paired.map(\.line), synced: paired, areFromRemote: false)
    }

    // MARK: Translation pairing

    /// Pairs consecutive lines with the same timestamp: the second (untimed-word, non-blank) line becomes the
    /// first one's translation, followed by any "by: …" credit lines at that time. One translation per original.
    static func pairTranslationLines(_ lines: [SyncedLine]) -> [SyncedLine] {
        if lines.count < 2 { return lines }
        // A failed alignment can stamp a whole song at zero; those are separate originals, not translations.
        if lines.allSatisfy({ $0.time == 0 }) && lines.contains(where: { !($0.words ?? []).isEmpty })
            && lines.flatMap({ $0.words ?? [] }).allSatisfy({ $0.time == 0 }) {
            return lines
        }
        var result: [SyncedLine] = []
        var i = 0
        while i < lines.count {
            let current = lines[i]
            let next = i + 1 < lines.count ? lines[i + 1] : nil
            if let next, next.time == current.time, (next.words ?? []).isEmpty, current.translation == nil,
               !ParseKit.isBlank(current.line), !ParseKit.isBlank(next.line) {
                var translationParts = [next.line]
                var consumed = 2
                while i + consumed < lines.count {
                    let trailing = lines[i + consumed]
                    if trailing.time != current.time || !isTranslationCreditLine(trailing.line) { break }
                    translationParts.append(trailing.line)
                    consumed += 1
                }
                var copy = current
                copy.translation = translationParts.joined(separator: "\n")
                result.append(copy)
                i += consumed
            } else {
                result.append(current)
                i += 1
            }
        }
        return result
    }

    /// Removes every `[m:ss]`, `[mm:ss.x]`… timestamp tag, then leading whitespace.
    static func stripLrcTimestamps(_ value: String) -> String {
        if value.isEmpty { return value }
        let s = Array(value.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < s.count {
            if s[i] == "[", let end = matchTimestampTag(s, i) {
                i = end
                continue
            }
            out.append(s[i])
            i += 1
        }
        return String(out).kotlinTrimmedStart()
    }

    /// `\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?]` at `i`; returns the index after `]`.
    private static func matchTimestampTag(_ s: [Unicode.Scalar], _ i: Int) -> Int? {
        var j = i + 1
        var minuteDigits = 0
        while j < s.count, minuteDigits < 2, ParseKit.isAsciiDigit(s[j]) { j += 1; minuteDigits += 1 }
        guard minuteDigits >= 1, j < s.count, s[j] == ":" else { return nil }
        j += 1
        guard j + 1 < s.count, ParseKit.isAsciiDigit(s[j]), ParseKit.isAsciiDigit(s[j + 1]) else { return nil }
        j += 2
        if j < s.count, s[j] == "]" { return j + 1 }
        // Optional fraction (the regex backtracks to no fraction, which needs `]` right here — handled above).
        guard j < s.count, s[j] == "." || s[j] == ":" else { return nil }
        var k = j + 1
        var fractionDigits = 0
        while k < s.count, fractionDigits < 3, ParseKit.isAsciiDigit(s[k]) { k += 1; fractionDigits += 1 }
        guard fractionDigits >= 1, k < s.count, s[k] == "]" else { return nil }
        return k + 1
    }

    /// `^\s*by\s*[:：].+` (case-insensitive) on the timestamp-stripped, trimmed line.
    static func isTranslationCreditLine(_ line: String) -> Bool {
        let normalized = ParseKit.trim(stripLrcTimestamps(line))
        if normalized.isEmpty { return false }
        let s = Array(normalized.unicodeScalars)
        var i = 0
        while i < s.count, ParseKit.isRegexSpace(s[i]) { i += 1 }
        guard i + 1 < s.count, s[i] == "b" || s[i] == "B", s[i + 1] == "y" || s[i + 1] == "Y" else { return false }
        i += 2
        while i < s.count, ParseKit.isRegexSpace(s[i]) { i += 1 }
        guard i < s.count, s[i] == ":" || s[i] == "\u{FF1A}" else { return false }
        i += 1
        guard i < s.count else { return false }
        return !s[i...].contains(where: ParseKit.isLineTerminator)
    }

    // MARK: Writers

    /// LRC text, one `[mm:ss.xx]line` per line sorted by time, each translation line repeated at the same time.
    public static func syncedToLrcString(_ syncedLines: [SyncedLine]) -> String {
        stableSortedByTime(syncedLines).flatMap { line -> [String] in
            let timestamp = "[" + ParseKit.lrcTimestamp(Int32(truncatingIfNeeded: line.time)) + "]"
            var out = [timestamp + line.line]
            if let translation = line.translation, !ParseKit.isBlank(translation) {
                for translationLine in ParseKit.lines(translation) where !ParseKit.isBlank(translationLine) {
                    out.append(timestamp + translationLine)
                }
            }
            return out
        }.joined(separator: "\n")
    }

    /// Plain lines joined by newlines, dropping the romanisation `parseLyrics` appended after a line break.
    public static func plainToString(_ plainLines: [String]) -> String {
        plainLines.map { ParseKit.substringBefore($0, "\n") }.joined(separator: "\n")
    }

    /// LRC (preferring synced lines) or plain text for storage.
    public static func toLrcString(_ lyrics: Lyrics, preferSynced: Bool = true) -> String {
        if preferSynced, let synced = lyrics.synced, !synced.isEmpty { return syncedToLrcString(synced) }
        if let plain = lyrics.plain, !plain.isEmpty { return plainToString(plain) }
        if let synced = lyrics.synced, !synced.isEmpty { return syncedToLrcString(synced) }
        return ""
    }

    // MARK: Line-level helpers

    /// Kotlin `sortedBy { it.time }` (stable).
    static func stableSortedByTime(_ lines: [SyncedLine]) -> [SyncedLine] {
        lines.enumerated().sorted { a, b in a.element.time != b.element.time ? a.element.time < b.element.time : a.offset < b.offset }
            .map(\.element)
    }

    /// Leading whitespace, BOMs and format characters before a document (`stripLeadingLyricsDocumentNoise`).
    static func stripLeadingLyricsDocumentNoise(_ value: String) -> String {
        ParseKit.trim(value, end: false) { ParseKit.isWhitespace($0) || $0.value == 0xFEFF || ParseKit.isFormatChar($0) }
    }

    /// `<tt…`, `<smil…` (any case), optionally after an `<?xml …?>` declaration.
    static func looksLikeTtmlDocument(_ value: String) -> Bool {
        func startsWithTtmlRoot(_ s: String) -> Bool {
            ParseKit.hasPrefixIgnoringASCIICase(s, "<tt") || ParseKit.hasPrefixIgnoringASCIICase(s, "<smil")
        }
        if startsWithTtmlRoot(value) { return true }
        if !ParseKit.hasPrefixIgnoringASCIICase(value, "<?xml") { return false }
        return startsWithTtmlRoot(ParseKit.substringAfter(value, "?>", missing: "").kotlinTrimmedStart())
    }

    /// `(?m)^\[\d+,\d+]\(` anywhere: a YRC line at the start of some line.
    static func containsYrcLine(_ value: String) -> Bool {
        let s = Array(value.unicodeScalars)
        var i = 0
        while i < s.count {
            let atLineStart = i == 0 || {
                let p = s[i - 1]
                if p == "\r" { return s[i] != "\n" }
                return p == "\n" || p.value == 0x85 || p.value == 0x2028 || p.value == 0x2029
            }()
            if atLineStart, s[i] == "[" {
                var j = i + 1
                var d1 = 0
                while j < s.count, ParseKit.isAsciiDigit(s[j]) { j += 1; d1 += 1 }
                if d1 > 0, j < s.count, s[j] == "," {
                    j += 1
                    var d2 = 0
                    while j < s.count, ParseKit.isAsciiDigit(s[j]) { j += 1; d2 += 1 }
                    if d2 > 0, j + 1 < s.count, s[j] == "]", s[j + 1] == "(" { return true }
                }
            }
            i += 1
        }
        return false
    }

    /// `sanitizeLrcLine`: drops line terminators, format and control characters (tabs kept), then leading
    /// whitespace and anything before the first `[`.
    static func sanitizeLrcLine(_ rawLine: String) -> String {
        if rawLine.isEmpty { return rawLine }
        var cleaned = ParseKit.trim(rawLine, start: false) { $0 == "\r" || $0 == "\n" }
        cleaned = ParseKit.filterNot(cleaned) { ParseKit.isFormatChar($0) || (ParseKit.isISOControl($0) && $0 != "\t") }
        cleaned = ParseKit.trim(cleaned, start: false) { $0.value == 0xFEFF }
        let trimmedPrefix = cleaned.kotlinTrimmedStart()
        let scalars = Array(trimmedPrefix.unicodeScalars)
        if let firstBracket = scalars.firstIndex(of: "["), firstBracket > 0 {
            return ParseKit.string(scalars[firstBracket...])
        }
        return trimmedPrefix
    }

    /// `stripFormatCharacters`: drops format and control characters (tabs kept); a lone quote becomes empty.
    static func stripFormatCharacters(_ value: String) -> String {
        let cleaned = ParseKit.filterNot(value) { ParseKit.isFormatChar($0) || (ParseKit.isISOControl($0) && $0 != "\t") }
        if cleaned == "\"" || cleaned == "'" { return "" }
        return cleaned
    }

    /// `^\[[a-zA-Z]+:.*]$` (whole line; `.` excludes line terminators).
    static func isMetadataLine(_ line: String) -> Bool {
        let s = Array(line.unicodeScalars)
        guard s.count >= 3, s[0] == "[", s[s.count - 1] == "]" else { return false }
        var i = 1
        while i < s.count, s[i].isASCII, s[i].properties.isAlphabetic { i += 1 }
        guard i > 1, i < s.count, s[i] == ":" else { return false }
        // `.*` then the final `]`: nothing between may be a line terminator.
        return !s[(i + 1)..<(s.count - 1)].contains(where: ParseKit.isLineTerminator)
    }

    struct LrcLineMatch {
        var timestampMs: Int64
        var rest: String
    }

    /// `^\[(\d{2}):(\d{2})[.:](\d{2,3})](.*)$` — whole line; two-digit fractions are hundredths.
    static func matchLrcLine(_ line: String) -> LrcLineMatch? {
        let s = Array(line.unicodeScalars)
        guard s.count >= 9, s[0] == "[", ParseKit.isAsciiDigit(s[1]), ParseKit.isAsciiDigit(s[2]), s[3] == ":",
              ParseKit.isAsciiDigit(s[4]), ParseKit.isAsciiDigit(s[5]), s[6] == "." || s[6] == ":",
              ParseKit.isAsciiDigit(s[7]), ParseKit.isAsciiDigit(s[8]) else { return nil }
        var j = 9
        var fractionDigits = 2
        if j < s.count, ParseKit.isAsciiDigit(s[j]) { j += 1; fractionDigits = 3 }
        guard j < s.count, s[j] == "]" else { return nil }
        let rest = s[(j + 1)...]
        if rest.contains(where: ParseKit.isLineTerminator) { return nil }
        let minutes = Int64(digitValue(s[1...2]))
        let seconds = Int64(digitValue(s[4...5]))
        let fraction = Int64(digitValue(s[7..<(7 + fractionDigits)]))
        let millis = fractionDigits == 2 ? fraction * 10 : fraction
        return LrcLineMatch(timestampMs: minutes * 60 * 1000 + seconds * 1000 + millis, rest: ParseKit.string(rest))
    }

    private static func digitValue(_ digits: ArraySlice<Unicode.Scalar>) -> Int {
        digits.reduce(0) { $0 * 10 + Int($1.value - 0x30) }
    }

    /// `<\d{2}:\d{2}[.:]\d{2,3}>` at `i`; returns (end index, timestamp ms).
    private static func matchWordTag(_ s: [Unicode.Scalar], _ i: Int) -> (end: Int, ms: Int64)? {
        guard i + 8 < s.count, s[i] == "<", ParseKit.isAsciiDigit(s[i + 1]), ParseKit.isAsciiDigit(s[i + 2]),
              s[i + 3] == ":", ParseKit.isAsciiDigit(s[i + 4]), ParseKit.isAsciiDigit(s[i + 5]),
              s[i + 6] == "." || s[i + 6] == ":", ParseKit.isAsciiDigit(s[i + 7]), ParseKit.isAsciiDigit(s[i + 8])
        else { return nil }
        var j = i + 9
        var fractionDigits = 2
        if j < s.count, ParseKit.isAsciiDigit(s[j]) { j += 1; fractionDigits = 3 }
        guard j < s.count, s[j] == ">" else { return nil }
        let minutes = Int64(digitValue(s[(i + 1)...(i + 2)]))
        let seconds = Int64(digitValue(s[(i + 4)...(i + 5)]))
        let fraction = Int64(digitValue(s[(i + 7)..<(i + 7 + fractionDigits)]))
        let millis = fractionDigits == 2 ? fraction * 10 : fraction
        return (j + 1, minutes * 60 * 1000 + seconds * 1000 + millis)
    }

    static func containsWordTag(_ text: String) -> Bool {
        let s = Array(text.unicodeScalars)
        for i in s.indices where s[i] == "<" && matchWordTag(s, i) != nil { return true }
        return false
    }

    /// `text.split(Regex("(?=<\\d{2}:\\d{2}[.:]\\d{2,3}>)"))` (Kotlin split keeps a leading empty part).
    static func splitBeforeWordTags(_ text: String) -> [String] {
        let s = Array(text.unicodeScalars)
        var parts: [String] = []
        var lastStart = 0
        for i in s.indices where s[i] == "<" && matchWordTag(s, i) != nil {
            parts.append(ParseKit.string(s[lastStart..<i]))
            lastStart = i
        }
        parts.append(ParseKit.string(s[lastStart...]))
        return parts
    }

    static func removeWordTags(_ text: String) -> String {
        let s = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < s.count {
            if s[i] == "<", let tag = matchWordTag(s, i) {
                i = tag.end
                continue
            }
            out.append(s[i])
            i += 1
        }
        return String(out)
    }

    /// `LRC_WORD_REGEX.matcher(part).find()` — a part produced by `splitBeforeWordTags` holds a tag only at its
    /// start; the word text runs to the next `<`.
    private static func parseWordTag(atStartOf part: String) -> (timestampMs: Int64, text: String)? {
        let s = Array(part.unicodeScalars)
        guard let tag = matchWordTag(s, 0) else { return nil }
        var j = tag.end
        while j < s.count, s[j] != "<" { j += 1 }
        return (tag.ms, ParseKit.string(s[tag.end..<j]))
    }

    /// `^\[(\d+),(\d+)](.*)$` (Kugou header) on a trimmed line.
    static func matchKugouLine(_ line: String) -> (start: String, duration: String, body: String)? {
        let s = Array(line.unicodeScalars)
        guard s.first == "[" else { return nil }
        var j = 1
        while j < s.count, ParseKit.isAsciiDigit(s[j]) { j += 1 }
        guard j > 1, j < s.count, s[j] == "," else { return nil }
        let start = ParseKit.string(s[1..<j])
        let durationStart = j + 1
        j = durationStart
        while j < s.count, ParseKit.isAsciiDigit(s[j]) { j += 1 }
        guard j > durationStart, j < s.count, s[j] == "]" else { return nil }
        let body = s[(j + 1)...]
        if body.contains(where: ParseKit.isLineTerminator) { return nil }
        return (start, ParseKit.string(s[durationStart..<j]), ParseKit.string(body))
    }

    /// `<(\d+),(\d+),(\d+)>([^<]*)` matches in order.
    private static func kugouWordTokens(_ body: String) -> [(offset: String, text: String, range: Range<Int>)] {
        let s = Array(body.unicodeScalars)
        var tokens: [(offset: String, text: String, range: Range<Int>)] = []
        var i = 0
        while i < s.count {
            if s[i] == "<", let token = matchKugouWord(s, i) {
                tokens.append(token)
                i = token.range.upperBound
                continue
            }
            i += 1
        }
        return tokens
    }

    private static func matchKugouWord(_ s: [Unicode.Scalar], _ i: Int) -> (offset: String, text: String, range: Range<Int>)? {
        var j = i + 1
        var groups: [Range<Int>] = []
        for g in 0..<3 {
            let start = j
            while j < s.count, ParseKit.isAsciiDigit(s[j]) { j += 1 }
            guard j > start, j < s.count, s[j] == (g < 2 ? "," : ">") else { return nil }
            groups.append(start..<j)
            j += 1
        }
        let textStart = j
        while j < s.count, s[j] != "<" { j += 1 }
        return (ParseKit.string(s[groups[0]]), ParseKit.string(s[textStart..<j]), i..<j)
    }

    private static func replaceKugouTokensWithText(_ body: String) -> String {
        let s = Array(body.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < s.count {
            if s[i] == "<", let token = matchKugouWord(s, i) {
                out.append(contentsOf: token.text.unicodeScalars)
                i = token.range.upperBound
                continue
            }
            out.append(s[i])
            i += 1
        }
        return String(out)
    }
}
