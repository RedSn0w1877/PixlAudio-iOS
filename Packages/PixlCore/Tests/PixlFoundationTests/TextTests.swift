import Foundation
import Testing
@testable import PixlFoundation

/// Ported from Android `presentation/lyrics/LyricsScriptShapingTest` plus the helper rules it relies on.
@Suite("Script detection")
struct TextScriptsTests {
    // LyricsScriptShapingTest.latinCjkAndHebrew_useSeparatePieces
    @Test func latinCjkAndHebrewUseSeparatePieces() {
        #expect(!TextScripts.needsShapedPieces("Never gonna give you up"))
        #expect(!TextScripts.needsShapedPieces("Ça plane pour moi, ñandú"))
        #expect(!TextScripts.needsShapedPieces("夜に駆ける 君の手を"))
        #expect(!TextScripts.needsShapedPieces("사랑해 오늘도"))
        #expect(!TextScripts.needsShapedPieces("Привет, мир"))
        // Hebrew is right-to-left but its letters do not join.
        #expect(!TextScripts.needsShapedPieces("שלום עולם"))
    }

    // LyricsScriptShapingTest.joiningAndClusteringScripts_drawShaped
    @Test func joiningAndClusteringScriptsDrawShaped() {
        #expect(TextScripts.needsShapedPieces("حبيبي يا نور العين"))
        #expect(TextScripts.needsShapedPieces("दिल से रे"))
        #expect(TextScripts.needsShapedPieces("ভালোবাসি"))
        #expect(TextScripts.needsShapedPieces("ក្ដី"))
        // One shaped word anywhere in a mixed line is enough.
        #expect(TextScripts.needsShapedPieces("Baby, حبيبي, tonight"))
        // Arabic presentation forms.
        #expect(TextScripts.needsShapedPieces("ﻻ"))
    }

    // LyricsScriptShapingTest.rtlDetection_followsFirstStrongCharacter
    @Test func rtlDetectionFollowsFirstStrongCharacter() {
        #expect(TextScripts.isRtlText("  «حبيبي» baby"))
        #expect(TextScripts.isRtlText("שלום"))
        #expect(!TextScripts.isRtlText("baby حبيبي"))
        #expect(!TextScripts.isRtlText("123 ..."))
    }

    @Test func rtlEdgeCases() {
        #expect(TextScripts.isRtlText("\u{200F}abc"))          // RLM is strong R
        #expect(!TextScripts.isRtlText("\u{200E}שלום"))         // LRM is strong L
        #expect(TextScripts.isRtlText("١٢٣ سلام"))             // Arabic-Indic digits are AN (weak), then AL
        #expect(TextScripts.isRtlText("\u{05B0}שלום"))          // a leading Hebrew point is NSM (neutral)
        #expect(TextScripts.isRtlText("ߊߟߎ"))                   // N'Ko
        #expect(TextScripts.isRtlText("ﺑ"))                     // Arabic presentation form B
        // Android quirk: a supplementary character is a surrogate pair there, and surrogates are strong L.
        #expect(!TextScripts.isRtlText("🎵 حبيبي"))
        #expect(!TextScripts.isRtlText(""))
        #expect(TextScripts.isRtlWord("«حب»"))
        #expect(!TextScripts.isRtlWord("love"))
        #expect(!TextScripts.isRtlWord("123"))
    }

    @Test func cjkVariantsFollowTheirAndroidHelpers() {
        // LyricsTapSync.isCjkCodePoint: Han, Hiragana, Katakana — not Hangul; supplementary ideographs count.
        #expect(TextScripts.isHanOrKana("夜"))
        #expect(TextScripts.isHanOrKana("に"))
        #expect(TextScripts.isHanOrKana("カ"))
        #expect(TextScripts.isHanOrKana("ｶ"))
        #expect(TextScripts.isHanOrKana("々"))
        #expect(TextScripts.isHanOrKana("𠀋"))
        #expect(!TextScripts.isHanOrKana("사"))
        #expect(!TextScripts.isHanOrKana("ー")) // prolonged sound mark is Common script
        #expect(!TextScripts.isHanOrKana("、"))
        #expect(!TextScripts.isHanOrKana("a"))
        // PreparedLyricsBuilder.isCjk(Char): adds Hangul; per UTF-16 unit, so supplementary ideographs do not count.
        #expect(TextScripts.isCjkChar("사"))
        #expect(TextScripts.isCjkChar("夜"))
        #expect(!TextScripts.isCjkChar("𠀋"))
        #expect(!TextScripts.isCjkChar("ー"))
        #expect(TextScripts.containsHanOrKana("Baby 夜"))
        #expect(!TextScripts.containsHanOrKana("사랑해"))
        #expect(TextScripts.containsCjkChar("사랑해"))
    }

    @Test func kotlinWhitespaceAndPunctuation() {
        for ws in ["\u{20}", "\u{09}", "\u{0A}", "\u{0B}", "\u{0C}", "\u{0D}", "\u{1C}", "\u{1F}", "\u{A0}", "\u{2007}",
                   "\u{202F}", "\u{3000}", "\u{2028}", "\u{2029}"] {
            #expect(TextScripts.isKotlinWhitespace(ws.unicodeScalars.first!), "U+\(String(ws.unicodeScalars.first!.value, radix: 16))")
        }
        for notWs in ["\u{85}", "\u{200B}", "\u{FEFF}", "a", "\u{00}"] {
            #expect(!TextScripts.isKotlinWhitespace(notWs.unicodeScalars.first!))
        }
        #expect(TextScripts.isPunctuationOnly("—"))
        #expect(TextScripts.isPunctuationOnly("…!?"))
        #expect(TextScripts.isPunctuationOnly("、。「」"))
        #expect(TextScripts.isPunctuationOnly("&"))    // & is Po, so it joins like Android's \p{P}
        #expect(!TextScripts.isPunctuationOnly(""))
        #expect(!TextScripts.isPunctuationOnly("a-b"))
        #expect(!TextScripts.isPunctuationOnly("+"))   // Sm, not P
    }
}

/// Ported from Android `PreparedLyricsBuilderTest.graphemeAndWordCounts` and
/// `LyricsMotionMathTest.graphemeBoundaries_keepCombiningMarksTogether`.
@Suite("Segmentation")
struct TextSegmentationTests {
    @Test func graphemeAndWordCounts() {
        #expect(TextSegmentation.graphemeCount("hello") == 5)
        #expect(TextSegmentation.graphemeCount("e\u{301}a") == 2)
        #expect(TextSegmentation.estimateWordCount("one two  three") == 3)
        #expect(TextSegmentation.estimateWordCount("我爱你") == 3)
        #expect(TextSegmentation.estimateWordCount("사랑해 baby") == 4)
        #expect(TextSegmentation.estimateWordCount("") == 0)
    }

    @Test func graphemeBoundariesKeepCombiningMarksTogether() {
        #expect(TextSegmentation.graphemeBoundariesUTF16("e\u{301}a") == [0, 2, 3])
        #expect(TextSegmentation.graphemeBoundariesUTF16("") == [0])
        // Surrogate pairs and ZWJ emoji sequences stay whole (offsets are UTF-16 like Kotlin).
        #expect(TextSegmentation.graphemeBoundariesUTF16("a🎵b") == [0, 1, 3, 4])
        #expect(TextSegmentation.graphemeBoundariesUTF16("👩‍❤️‍👨!") == [0, 8, 9])
    }

    @Test func kotlinStringHelpers() {
        #expect(" \u{A0}hi there\u{3000}\n".kotlinTrimmed() == "hi there")
        #expect("  hi ".kotlinTrimmedStart() == "hi ")
        #expect("  hi ".kotlinTrimmedEnd() == "  hi")
        #expect("\u{85}x\u{85}".kotlinTrimmed() == "\u{85}x\u{85}") // NEL is not Kotlin whitespace
        #expect(" \u{2028}".isKotlinBlank)
        #expect("".isKotlinBlank)
        #expect(!"\u{200B}".isKotlinBlank)
        #expect("\u{E9}" == "e\u{301}")                        // Swift: canonical equivalence
        #expect(!"\u{E9}".isIdentical(to: "e\u{301}"))           // Kotlin: code units differ
        #expect("🎵".kotlinLength == 2)
        #expect("lo ".endsWithKotlinWhitespace)
        #expect(!"lo".startsWithKotlinWhitespace)
        #expect(TextSegmentation.words("  one\u{A0}two\tthree ") == ["one", "two", "three"])
    }
}
