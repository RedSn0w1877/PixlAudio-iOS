// Port of the Android `MultiLangRomanizer` (utils/LyricsUtils.kt): script detection plus the built-in Korean,
// Hindi (Devanagari), Punjabi (Gurmukhi) and Cyrillic romanisers, and the Chinese pinyin rules (erhua, context and
// polyphone overrides) around a per-character reading. Android reads Japanese with kuromoji + ICU and Chinese
// characters with pinyin4j; PixlCore has no dictionaries, so those come from a `CJKRomanizationProvider` the app
// injects (default: none). Everything works on UTF-16 code units, exactly like the Kotlin `Char` loops.

import Foundation
import PixlFoundation

/// Supplies the dictionary-backed readings the Android app gets from kuromoji (Japanese) and pinyin4j (Chinese).
public protocol CJKRomanizationProvider: Sendable {
    /// Full romaji for a Japanese line (Android: kuromoji tokens → katakana → ICU "Katakana-Latin; Lower"), or nil
    /// when unavailable.
    func romanizeJapanese(_ text: String) -> String?
    /// The first toneless lower-case pinyin reading of one Han character (pinyin4j `toHanyuPinyinStringArray`'s first
    /// entry; `ü` as `u:`), or nil when the character has none.
    func pinyinReading(for hanzi: Character) -> String?
}

/// No Japanese or Chinese readings (the default): those lines get no romanisation, and Chinese characters fall
/// back to themselves inside mixed text, as Android does when pinyin4j has no reading.
public struct NoCJKRomanization: CJKRomanizationProvider {
    public init() {}
    public func romanizeJapanese(_ text: String) -> String? { nil }
    public func pinyinReading(for hanzi: Character) -> String? { nil }
}

public enum MultiLangRomanizer {

    // MARK: Script detection (per UTF-16 unit)

    /// Hiragana/Katakana, or Han when the whole song has kana.
    public static func isJapanese(_ text: String, entireLyricsHasKana: Bool = false) -> Bool {
        if text.utf16.contains(where: { (0x3040...0x309F).contains($0) || (0x30A0...0x30FF).contains($0) }) { return true }
        return entireLyricsHasKana && text.utf16.contains(where: { (0x4E00...0x9FFF).contains($0) })
    }

    public static func isKorean(_ text: String) -> Bool { text.utf16.contains { (0xAC00...0xD7A3).contains($0) } }
    public static func isHindi(_ text: String) -> Bool { text.utf16.contains { (0x0900...0x097F).contains($0) } }
    public static func isPunjabi(_ text: String) -> Bool { text.utf16.contains { (0x0A00...0x0A7F).contains($0) } }
    public static func isCyrillic(_ text: String) -> Bool { text.utf16.contains { (0x0400...0x04FF).contains($0) } }
    public static func isChinese(_ text: String) -> Bool { text.utf16.contains { (0x4E00...0x9FFF).contains($0) } }

    /// Kana, CJK ideographs, Hangul, Devanagari, Gurmukhi or Cyrillic present.
    public static func isScriptThatNeedsRomanization(_ text: String) -> Bool {
        text.utf16.contains { c in
            (0x3040...0x309F).contains(c) || (0x30A0...0x30FF).contains(c) || (0x4E00...0x9FFF).contains(c)
                || (0xAC00...0xD7A3).contains(c) || (0x0900...0x097F).contains(c) || (0x0A00...0x0A7F).contains(c)
                || (0x0400...0x04FF).contains(c)
        }
    }

    // MARK: Japanese / Chinese

    /// Japanese romaji from the provider (Android returns null when kuromoji is unavailable).
    public static func romanizeJapanese(_ text: String, provider: any CJKRomanizationProvider) -> String? {
        provider.romanizeJapanese(text)
    }

    /// Pinyin with erhua (`儿` after a Hanzi becomes an `r` suffix), the context table, the polyphone table, then the
    /// provider's reading (the character itself when there is none); non-Hanzi characters pass through.
    public static func romanizeChinese(_ text: String, provider: any CJKRomanizationProvider) -> String? {
        let chars = Array(text.utf16)
        var out: [UInt16] = []
        var idx = 0
        func isHanzi(_ c: UInt16) -> Bool { (0x4E00...0x9FA5).contains(c) }
        while idx < chars.count {
            let c = chars[idx]
            let next: UInt16? = idx + 1 < chars.count ? chars[idx + 1] : nil
            let prev: UInt16? = idx > 0 ? chars[idx - 1] : nil
            if next == 0x513F && isHanzi(c) && c != 0x513F {
                var erhua = pinyin(c, prev: prev, provider: provider)
                if erhua.hasSuffix("ng") { erhua.removeLast(2); erhua += "r" }
                else if erhua.hasSuffix("n") { erhua.removeLast(); erhua += "r" }
                if !erhua.hasSuffix("r") { erhua += "r" }
                out.append(contentsOf: erhua.utf16)
                out.append(0x20)
                idx += 2
                continue
            }
            if isHanzi(c) {
                out.append(contentsOf: pinyin(c, prev: prev, provider: provider).utf16)
                out.append(0x20)
                idx += 1
                continue
            }
            out.append(c)
            idx += 1
        }
        return collapseRegexSpaces(String(decoding: out, as: UTF16.self))
    }

    private static let contextPinyin: [UInt16: [UInt16: String]] = {
        var map: [UInt16: [UInt16: String]] = [:]
        for (prev, char, reading) in RomanizerTables.contextPinyin {
            map[prev.utf16.first!, default: [:]][char.utf16.first!] = reading
        }
        return map
    }()

    private static let polyphoneOverride: [UInt16: String] =
        Dictionary(RomanizerTables.polyphoneOverride.map { ($0.0.utf16.first!, $0.1) }, uniquingKeysWith: { _, new in new })

    /// `getPinyin`: context table, polyphone table, provider (trailing tone digits removed), else the character.
    private static func pinyin(_ c: UInt16, prev: UInt16?, provider: any CJKRomanizationProvider) -> String {
        if let prev, let reading = contextPinyin[prev]?[c] { return reading }
        if let reading = polyphoneOverride[c] { return reading }
        let character = Character(Unicode.Scalar(c)!)
        guard let reading = provider.pinyinReading(for: character) else { return String(character) }
        return ParseKit.trim(reading, start: false) { "012345".unicodeScalars.contains($0) }
    }

    /// `replace(Regex("\\s+"), " ").trim()`.
    static func collapseRegexSpaces(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var inSpace = false
        for scalar in s.unicodeScalars {
            if ParseKit.isRegexSpace(scalar) {
                if !inSpace { out.append(" ") }
                inSpace = true
            } else {
                out.append(scalar)
                inSpace = false
            }
        }
        return ParseKit.trim(String(out))
    }

    // MARK: Korean

    private static func table(_ pairs: [(String, String)]) -> [[UInt16]: String] {
        Dictionary(pairs.map { (Array($0.0.utf16), $0.1) }, uniquingKeysWith: { _, new in new })
    }

    private static let hangulCho = table(RomanizerTables.hangulCho)
    private static let hangulJung = table(RomanizerTables.hangulJung)
    private static let hangulJong = table(RomanizerTables.hangulJong)

    /// Revised-romanisation-style Hangul: syllables decomposed into jamo; a final consonant is resolved against the
    /// next initial (`jong` context keys) before being written.
    public static func romanizeKorean(_ text: String) -> String {
        var out: [UInt16] = []
        var prevFinal: [UInt16]?
        func append(_ units: [UInt16]) { out.append(contentsOf: units) }
        func appendString(_ s: String) { out.append(contentsOf: s.utf16) }
        for c in text.utf16 {
            if (0xAC00...0xD7A3).contains(c) {
                let syllableIndex = Int(c) - 0xAC00
                let choIndex = syllableIndex / (21 * 28)
                let jungIndex = (syllableIndex % (21 * 28)) / 28
                let jongIndex = syllableIndex % 28
                let cho = [UInt16(0x1100 + choIndex)]
                let jung = [UInt16(0x1161 + jungIndex)]
                let jong: [UInt16]? = jongIndex == 0 ? nil : [UInt16(0x11A7 + jongIndex)]
                if let prevFinal {
                    if let mapped = hangulJong[prevFinal + cho] ?? hangulJong[prevFinal] { appendString(mapped) }
                    else { append(prevFinal) }
                }
                if let mapped = hangulCho[cho] { appendString(mapped) } else { append(cho) }
                if let mapped = hangulJung[jung] { appendString(mapped) } else { append(jung) }
                prevFinal = jong
            } else {
                if let final = prevFinal {
                    if let mapped = hangulJong[final] { appendString(mapped) } else { append(final) }
                    prevFinal = nil
                }
                out.append(c)
            }
        }
        if let final = prevFinal {
            if let mapped = hangulJong[final] { appendString(mapped) } else { append(final) }
        }
        return String(decoding: out, as: UTF16.self)
    }

    // MARK: Hindi / Punjabi

    private static let devanagari = table(RomanizerTables.devanagari)
    private static let gurmukhi = table(RomanizerTables.gurmukhi)

    /// Devanagari: two-unit table entries first, then single units; unmapped units pass through.
    public static func romanizeHindi(_ text: String) -> String {
        let units = Array(text.utf16)
        var out: [UInt16] = []
        var i = 0
        while i < units.count {
            if i + 1 < units.count, let mapped = devanagari[[units[i], units[i + 1]]] {
                out.append(contentsOf: mapped.utf16)
                i += 2
                continue
            }
            if let mapped = devanagari[[units[i]]] { out.append(contentsOf: mapped.utf16) } else { out.append(units[i]) }
            i += 1
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// Gurmukhi: the addak (U+0A71) doubles the next consonant's first letter; otherwise like `romanizeHindi`.
    public static func romanizePunjabi(_ text: String) -> String {
        let units = Array(text.utf16)
        var out: [UInt16] = []
        var i = 0
        while i < units.count {
            let c = units[i]
            if c == 0x0A71 {
                if i + 1 < units.count, let nextMapped = gurmukhi[[units[i + 1]]], let first = nextMapped.utf16.first {
                    out.append(first)
                }
                i += 1
                continue
            }
            if i + 1 < units.count, let mapped = gurmukhi[[c, units[i + 1]]] {
                out.append(contentsOf: mapped.utf16)
                i += 2
                continue
            }
            if let mapped = gurmukhi[[c]] { out.append(contentsOf: mapped.utf16) } else { out.append(c) }
            i += 1
        }
        return String(decoding: out, as: UTF16.self)
    }

    // MARK: Cyrillic

    private static func letterSet(_ list: [String]) -> Set<UInt16> { Set(list.map { $0.utf16.first! }) }

    private static let generalCyrillic = table(RomanizerTables.generalCyrillic)
    private static let russianMap = table(RomanizerTables.russian)
    private static let ukrainianMap = table(RomanizerTables.ukrainian)
    private static let serbianMap = table(RomanizerTables.serbian)
    private static let bulgarianMap = table(RomanizerTables.bulgarian)
    private static let belarusianMap = table(RomanizerTables.belarusian)
    private static let kyrgyzMap = table(RomanizerTables.kyrgyz)
    private static let macedonianMap = table(RomanizerTables.macedonian)

    private static let russianLetters = letterSet(RomanizerTables.russianLetters)
    private static let ukrainianLetters = letterSet(RomanizerTables.ukrainianLetters)
        .union(letterSet(RomanizerTables.ukrainianSpecific))
    private static let serbianLetters = letterSet(RomanizerTables.serbianLetters).union(letterSet(RomanizerTables.serbianSpecific))
    private static let bulgarianLetters = letterSet(RomanizerTables.bulgarianLetters)
    private static let belarusianLetters = letterSet(RomanizerTables.belarusianLetters)
        .union(letterSet(RomanizerTables.belarusianSpecific))
    private static let kyrgyzLetters = letterSet(RomanizerTables.kyrgyzLetters).union(letterSet(RomanizerTables.kyrgyzSpecific))
    private static let macedonianLetters = letterSet(RomanizerTables.macedonianLetters)
        .union(letterSet(RomanizerTables.macedonianSpecific))

    /// Some unit is in `letters`, and every Cyrillic-block unit is.
    private static func isLanguage(_ units: [UInt16], _ letters: Set<UInt16>) -> Bool {
        units.contains(where: letters.contains)
            && units.allSatisfy { letters.contains($0) || !(0x0400...0x04FF).contains($0) }
    }

    /// Picks the language by its alphabet (Russian, Ukrainian, Serbian, Bulgarian, Belarusian, Kyrgyz, Macedonian,
    /// else generic) and transliterates word by word. nil for no Cyrillic, or a lone `е`/`Е`.
    public static func romanizeCyrillic(_ text: String) -> String? {
        if text.isEmpty { return nil }
        let units = Array(text.utf16)
        let cyrillic = units.filter { (0x0400...0x04FF).contains($0) }
        if cyrillic.isEmpty || (cyrillic.count == 1 && (cyrillic[0] == 0x0435 || cyrillic[0] == 0x0415)) { return nil }
        if isLanguage(units, russianLetters) { return processCyrillicWordByWord(units, russianMap, isRussian: true) }
        if isLanguage(units, ukrainianLetters) { return processUkrainian(units) }
        if isLanguage(units, serbianLetters) { return processCyrillicWordByWord(units, serbianMap) }
        if isLanguage(units, bulgarianLetters) { return processCyrillicWordByWord(units, bulgarianMap) }
        if isLanguage(units, belarusianLetters) { return processBelarusian(units) }
        if isLanguage(units, kyrgyzLetters) { return processCyrillicWordByWord(units, kyrgyzMap) }
        if isLanguage(units, macedonianLetters) { return processCyrillicWordByWord(units, macedonianMap) }
        return processCyrillicWordByWord(units, [:])
    }

    @inline(__always)
    private static func isPunctuationUnit(_ c: UInt16) -> Bool {
        c == 0x2E || c == 0x2C || c == 0x21 || c == 0x3F || c == 0x3B // . , ! ? ;
    }

    @inline(__always)
    private static func isRegexSpaceUnit(_ c: UInt16) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0B || c == 0x0C || c == 0x0D
    }

    /// `split("((?<=\\s|[.,!?;])|(?=\\s|[.,!?;]))".toRegex()).filter { it.isNotEmpty() }`: every whitespace and
    /// `.,!?;` unit becomes its own token.
    private static func cyrillicWords(_ units: [UInt16]) -> [[UInt16]] {
        var words: [[UInt16]] = []
        var current: [UInt16] = []
        for c in units {
            if isRegexSpaceUnit(c) || isPunctuationUnit(c) {
                if !current.isEmpty { words.append(current); current = [] }
                words.append([c])
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// The word is a lone `.,!?;` or blank (Kotlin whitespace).
    private static func isSeparatorWord(_ word: [UInt16]) -> Bool {
        if word.count == 1 && isPunctuationUnit(word[0]) { return true }
        return word.allSatisfy { u in Unicode.Scalar(u).map(ParseKit.isWhitespace) ?? false }
    }

    @inline(__always)
    private static func isUpperCaseUnit(_ c: UInt16) -> Bool {
        guard let s = Unicode.Scalar(c) else { return false }
        return s.properties.isUppercase
    }

    private static func appendMapped(_ out: inout [UInt16], _ key: [UInt16], _ specific: [[UInt16]: String]) {
        if let mapped = specific[key] ?? generalCyrillic[key] { out.append(contentsOf: mapped.utf16) }
        else { out.append(contentsOf: key) }
    }

    private static func endsWith(_ out: [UInt16], _ suffix: String) -> Bool {
        let s = Array(suffix.utf16)
        return out.count >= s.count && Array(out[(out.count - s.count)...]) == s
    }

    private static func processCyrillicWordByWord(_ units: [UInt16], _ specificMap: [[UInt16]: String],
                                                  isRussian: Bool = false) -> String {
        var out: [UInt16] = []
        for word in cyrillicWords(units) {
            if isSeparatorWord(word) {
                out.append(contentsOf: word)
                continue
            }
            var charIndex = 0
            while charIndex < word.count {
                let c = word[charIndex]
                let prevChar: UInt16? = charIndex > 0 ? word[charIndex - 1] : nil

                // ъ: silent separator.
                if c == 0x044A || c == 0x042A { charIndex += 1; continue }

                // ь: palatalise the previous output consonant.
                if c == 0x044C || c == 0x042C {
                    let rules: [(String, Int, String)] = [
                        ("t", 1, "t\u{02B2}"), ("d", 1, "d\u{02B2}"), ("n", 1, "ny"), ("l", 1, "ly"), ("s", 1, "sy"),
                        ("z", 1, "zy"), ("r", 1, "ry"), ("p", 1, "py"), ("b", 1, "by"), ("m", 1, "my"), ("v", 1, "vy"),
                        ("f", 1, "fy"), ("k", 1, "ky"), ("g", 1, "gy"), ("kh", 2, "khy"),
                    ]
                    for (suffix, drop, replacement) in rules where endsWith(out, suffix) {
                        out.removeLast(drop)
                        out.append(contentsOf: replacement.utf16)
                        break
                    }
                    charIndex += 1
                    continue
                }

                // Russian е: "ye" at the start or after a vowel/sign, else "e".
                if isRussian && (c == 0x0435 || c == 0x0415) {
                    let vowels = Array("аеёиоуыэюяАЕЁИОУЫЭЮЯ".utf16)
                    let afterVowelOrStart = charIndex == 0 || prevChar == nil
                        || (prevChar.flatMap { Unicode.Scalar($0) }.map(ParseKit.isWhitespace) ?? false)
                        || vowels.contains(prevChar!)
                        || [0x044C, 0x044A, 0x042C, 0x042A].contains(prevChar!)
                    let upper = isUpperCaseUnit(c)
                    out.append(contentsOf: (afterVowelOrStart ? (upper ? "Ye" : "ye") : (upper ? "E" : "e")).utf16)
                    charIndex += 1
                    continue
                }

                // ё: always "yo".
                if c == 0x0451 || c == 0x0401 {
                    out.append(contentsOf: (isUpperCaseUnit(c) ? "Yo" : "yo").utf16)
                    charIndex += 1
                    continue
                }

                // и after any character: the single-character mapping (no multi-character lookups).
                if (c == 0x0438 || c == 0x0418) && prevChar != nil {
                    appendMapped(&out, [c], specificMap)
                    charIndex += 1
                    continue
                }

                // Three-unit, then two-unit specific entries, then single units.
                if charIndex + 2 < word.count, let mapped = specificMap[Array(word[charIndex..<(charIndex + 3)])] {
                    out.append(contentsOf: mapped.utf16)
                    charIndex += 3
                    continue
                }
                if charIndex + 1 < word.count, let mapped = specificMap[Array(word[charIndex..<(charIndex + 2)])] {
                    out.append(contentsOf: mapped.utf16)
                    charIndex += 2
                    continue
                }
                appendMapped(&out, [c], specificMap)
                charIndex += 1
            }
        }
        return String(decoding: out, as: UTF16.self)
    }

    private static func processUkrainian(_ units: [UInt16]) -> String {
        var out: [UInt16] = []
        let softVowels = Array("АаЕеЄєИиІіЇїОоУуЮюЯяЫыЭэ".utf16)
        for word in cyrillicWords(units) {
            if isSeparatorWord(word) {
                out.append(contentsOf: word)
                continue
            }
            for charIndex in word.indices {
                let c = word[charIndex]
                if charIndex > 0, let prev = Unicode.Scalar(word[charIndex - 1]), TextScripts.isKotlinLetter(prev),
                   !softVowels.contains(word[charIndex - 1]) {
                    switch c {
                    case 0x042E: out.append(contentsOf: "Iu".utf16); continue
                    case 0x044E: out.append(contentsOf: "iu".utf16); continue
                    case 0x042F: out.append(contentsOf: "Ia".utf16); continue
                    case 0x044F: out.append(contentsOf: "ia".utf16); continue
                    default: break
                    }
                }
                appendMapped(&out, [c], ukrainianMap)
            }
        }
        return String(decoding: out, as: UTF16.self)
    }

    private static func processBelarusian(_ units: [UInt16]) -> String {
        var out: [UInt16] = []
        for word in cyrillicWords(units) {
            if isSeparatorWord(word) {
                out.append(contentsOf: word)
                continue
            }
            for charIndex in word.indices {
                let c = word[charIndex]
                let atStart = charIndex == 0
                    || (Unicode.Scalar(word[charIndex - 1]).map(ParseKit.isWhitespace) ?? false)
                if (c == 0x0435 || c == 0x0415) && atStart {
                    out.append(contentsOf: (c == 0x0435 ? "ye" : "Ye").utf16)
                } else {
                    appendMapped(&out, [c], belarusianMap)
                }
            }
        }
        return String(decoding: out, as: UTF16.self)
    }
}
