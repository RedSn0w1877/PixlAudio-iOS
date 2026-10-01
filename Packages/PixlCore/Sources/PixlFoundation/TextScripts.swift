// Script and direction detection with the Android helpers' exact rules. Swift's standard library exposes neither
// the Unicode Script nor the Bidi_Class property, so the ranges the Android code relies on are tabulated here
// (Unicode 15.1 Scripts.txt / DerivedBidiClass.txt, the ranges that matter for lyrics).
//
// Android quirk kept on purpose: the helpers that iterate Kotlin `Char`s (UTF-16 code units) never see a
// supplementary code point as CJK or right-to-left — `Character.getDirectionality(surrogate)` is LEFT_TO_RIGHT
// (surrogates have Bidi_Class L) and `UnicodeScript.of(surrogate)` is UNKNOWN. The `…Char…`/`…Text` variants below
// reproduce that; the code-point variants (used by the tap-sync tokenizer) do see supplementary ideographs.

import Foundation

/// Script/direction predicates matching the Android app's helpers.
public enum TextScripts {

    // MARK: - Whitespace and letters (Kotlin semantics)

    /// Kotlin `Char.isWhitespace()`: `Character.isWhitespace || Character.isSpaceChar`, i.e. general category
    /// Zs/Zl/Zp plus U+0009…U+000D and U+001C…U+001F. (Swift's `Character.isWhitespace` also accepts U+0085.)
    @inlinable
    public static func isKotlinWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if v <= 0x20 { return v == 0x20 || (0x09...0x0D).contains(v) || (0x1C...0x1F).contains(v) }
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    /// Kotlin `Char.isLetter()`: general category Lu, Ll, Lt, Lm or Lo. BMP only (a surrogate is not a letter).
    @inlinable
    public static func isKotlinLetter(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.value <= 0xFFFF else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    /// Java regex `\p{P}`: any punctuation general category (Pc, Pd, Ps, Pe, Pi, Pf, Po).
    @inlinable
    public static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation: return true
        default: return false
        }
    }

    /// `Regex("^\\p{P}+$").matches(text)`: non-empty and every code point is punctuation.
    public static func isPunctuationOnly(_ text: String) -> Bool {
        var any = false
        for scalar in text.unicodeScalars {
            guard isPunctuation(scalar) else { return false }
            any = true
        }
        return any
    }

    // MARK: - CJK

    /// Han, Hiragana or Katakana script (`LyricsTapSync.isCjkCodePoint`). Code-point aware.
    public static func isHanOrKana(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return contains(hanRanges, v) || contains(hiraganaRanges, v) || contains(katakanaRanges, v)
    }

    /// Hangul script.
    public static func isHangul(_ scalar: Unicode.Scalar) -> Bool { contains(hangulRanges, scalar.value) }

    /// `PreparedLyricsBuilder.isCjk(Char)`: Han, Hiragana, Katakana or Hangul — evaluated per UTF-16 code unit on
    /// Android, so supplementary code points (CJK Extension B+) are **not** CJK here.
    public static func isCjkChar(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.value <= 0xFFFF else { return false }
        return isHanOrKana(scalar) || isHangul(scalar)
    }

    /// `LyricsTapSync.containsCjk`: any Han/Hiragana/Katakana code point (Hangul excluded).
    public static func containsHanOrKana(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isHanOrKana)
    }

    /// Whether the text contains any `isCjkChar` character.
    public static func containsCjkChar(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isCjkChar)
    }

    // MARK: - Shaping and direction

    /// `LyricsRenderStyle.needsShapedPieces`: scripts whose letters join (Arabic, Syriac, N'Ko, Mongolian…) or build
    /// clusters across syllables (Indic, Myanmar, Khmer, Tibetan) — cut into pieces they would lose their shaping.
    /// Per UTF-16 code unit, like Android.
    public static func needsShapedPieces(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let c = scalar.value
            if c < 0x0590 || c > 0xFFFF { continue }
            if (0x0600...0x08FF).contains(c) || (0x0900...0x0DFF).contains(c) || (0x0F00...0x0FFF).contains(c)
                || (0x1000...0x109F).contains(c) || (0x1780...0x18AF).contains(c) || (0xA8E0...0xA8FF).contains(c)
                || (0xFB50...0xFDFF).contains(c) || (0xFE70...0xFEFF).contains(c) {
                return true
            }
        }
        return false
    }

    /// Strong direction of a character, as `Character.getDirectionality(Char)` classifies it on Android.
    public enum StrongDirection: Sendable, Equatable {
        /// Bidi class R or AL.
        case rightToLeft
        /// Bidi class L.
        case leftToRight
        /// Anything else (numbers, punctuation, spaces, marks…).
        case neutral
    }

    /// Bidi strength of one UTF-16-representable character. Supplementary code points report `.leftToRight`,
    /// because Android sees them as surrogate code units (Bidi_Class L).
    public static func strongDirection(_ scalar: Unicode.Scalar) -> StrongDirection {
        let v = scalar.value
        if v > 0xFFFF { return .leftToRight }
        if v == 0x200F { return .rightToLeft } // RIGHT-TO-LEFT MARK
        if v == 0x200E { return .leftToRight } // LEFT-TO-RIGHT MARK
        if isRightToLeftBMP(scalar) { return .rightToLeft }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .otherLetter, .spacingMark, .letterNumber,
             .privateUse, .surrogate:
            return .leftToRight
        case .modifierLetter:
            // Most modifier letters are L; the spacing-clone prime/tone letters are ON.
            return (0x02B9...0x02BA).contains(v) || (0x02C2...0x02CF).contains(v) || (0x02D2...0x02DF).contains(v)
                || (0x02E5...0x02ED).contains(v) || v == 0x02EF || (0x02F0...0x02FF).contains(v)
                ? .neutral : .leftToRight
        case .unassigned:
            // Unassigned code points default to L outside the right-to-left blocks (handled above).
            return .leftToRight
        default:
            return .neutral
        }
    }

    /// `LyricsRenderStyle.isRtlText`: the first strong character decides; no strong character → false.
    public static func isRtlText(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch strongDirection(scalar) {
            case .rightToLeft: return true
            case .leftToRight: return false
            case .neutral: continue
            }
        }
        return false
    }

    /// `SyncTapScreen.isRtlWord`: the first letter (Kotlin `isLetter`) is right-to-left.
    public static func isRtlWord(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first(where: isKotlinLetter) else { return false }
        return strongDirection(first) == .rightToLeft
    }

    /// Bidi class R or AL for a BMP scalar (marks, digits and the few neutral symbols inside the RTL blocks excluded).
    static func isRightToLeftBMP(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        let inRtlBlock = (0x0590...0x08FF).contains(v) || (0xFB1D...0xFDFF).contains(v) || (0xFE70...0xFEFE).contains(v)
        guard inRtlBlock else { return false }
        // Right-to-left despite their category: N'Ko digits (R) and the ARABIC LETTER MARK (AL).
        if (0x07C0...0x07C9).contains(v) || v == 0x061C { return true }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format, .decimalNumber:
            return false // NSM, BN/AN (U+0600…U+0605, U+08E2), AN/EN digits
        default:
            break
        }
        // Neutral or number-class characters inside the right-to-left blocks.
        switch v {
        case 0x0609...0x060A, 0x060C, 0x060E...0x060F, 0x066A...0x066C, 0x06DD...0x06DE, 0x06E9, 0x07F6...0x07F9,
             0xFB29, 0xFD3E...0xFD3F, 0xFDCF, 0xFDFD...0xFDFF:
            return false
        default:
            return true
        }
    }

    // MARK: - Script tables (Unicode 15.1 Scripts.txt)

    static func contains(_ ranges: [ClosedRange<UInt32>], _ v: UInt32) -> Bool {
        // Tables are short and sorted; a linear scan with an early exit is cheapest.
        for range in ranges {
            if v < range.lowerBound { return false }
            if v <= range.upperBound { return true }
        }
        return false
    }

    static let hanRanges: [ClosedRange<UInt32>] = [
        0x2E80...0x2E99, 0x2E9B...0x2EF3, 0x2F00...0x2FD5, 0x3005...0x3005, 0x3007...0x3007, 0x3021...0x3029,
        0x3038...0x303B, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFA6D, 0xFA70...0xFAD9, 0x16FE2...0x16FE3,
        0x16FF0...0x16FF1, 0x20000...0x2A6DF, 0x2A700...0x2B739, 0x2B740...0x2B81D, 0x2B820...0x2CEA1,
        0x2CEB0...0x2EBE0, 0x2EBF0...0x2EE5D, 0x2F800...0x2FA1D, 0x30000...0x3134A, 0x31350...0x323AF,
    ]

    static let hiraganaRanges: [ClosedRange<UInt32>] = [
        0x3041...0x3096, 0x309D...0x309F, 0x1B001...0x1B11F, 0x1B132...0x1B132, 0x1B150...0x1B152, 0x1F200...0x1F200,
    ]

    static let katakanaRanges: [ClosedRange<UInt32>] = [
        0x30A1...0x30FA, 0x30FD...0x30FF, 0x31F0...0x31FF, 0x32D0...0x32FE, 0x3300...0x3357, 0xFF66...0xFF6F,
        0xFF71...0xFF9D, 0x1AFF0...0x1AFF3, 0x1AFF5...0x1AFFB, 0x1AFFD...0x1AFFE, 0x1B000...0x1B000,
        0x1B120...0x1B122, 0x1B155...0x1B155, 0x1B164...0x1B167,
    ]

    static let hangulRanges: [ClosedRange<UInt32>] = [
        0x1100...0x11FF, 0x302E...0x302F, 0x3131...0x318E, 0x3200...0x321E, 0x3260...0x327E, 0xA960...0xA97C,
        0xAC00...0xD7A3, 0xD7B0...0xD7C6, 0xD7CB...0xD7FB, 0xFFA0...0xFFBE, 0xFFC2...0xFFC7, 0xFFCA...0xFFCF,
        0xFFD2...0xFFD7, 0xFFDA...0xFFDC,
    ]
}
