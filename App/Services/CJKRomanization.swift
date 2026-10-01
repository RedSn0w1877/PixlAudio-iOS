import CoreFoundation
import Foundation
import PixlLyrics

/// The Japanese and Chinese readings PixlLyrics' romaniser needs (Android: kuromoji + ICU for Japanese, pinyin4j for
/// Chinese), from Apple's built-in linguistics:
/// - Japanese: `CFStringTokenizer` with a Japanese locale splits the line into words and reports each word's Latin
///   transcription (`kCFStringTokenizerAttributeLatinTranscription`), joined with spaces and lower-cased like
///   Android's "Katakana-Latin; Lower" pipeline.
/// - Chinese: `StringTransform.mandarinToLatin` gives tone-marked pinyin for one character; tones are stripped and
///   `ü` written `u:` (pinyin4j's toneless form).
nonisolated struct AppleCJKRomanization: CJKRomanizationProvider {
    init() {}

    func romanizeJapanese(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let string = text as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(string))
        let locale = Locale(identifier: "ja") as CFLocale
        guard let tokenizer = CFStringTokenizerCreate(kCFAllocatorDefault, string, range,
                                                      kCFStringTokenizerUnitWord, locale) else { return nil }
        var words: [String] = []
        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while !tokenType.isEmpty {
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription)
                as? String, !latin.isEmpty {
                words.append(latin.lowercased())
            } else if let original = CFStringCreateWithSubstring(kCFAllocatorDefault, string, tokenRange) {
                words.append(original as String)
            }
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        let joined = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? nil : joined
    }

    func pinyinReading(for hanzi: Character) -> String? {
        guard let marked = String(hanzi).applyingTransform(.mandarinToLatin, reverse: false), !marked.isEmpty,
              marked != String(hanzi) else { return nil }
        var umlautFixed = ""
        for scalar in marked.unicodeScalars {
            switch scalar {
            case "ü", "ǖ", "ǘ", "ǚ", "ǜ": umlautFixed += "u:"
            default: umlautFixed.unicodeScalars.append(scalar)
            }
        }
        let toneless = umlautFixed.applyingTransform(.stripDiacritics, reverse: false) ?? umlautFixed
        return toneless.lowercased()
    }
}
