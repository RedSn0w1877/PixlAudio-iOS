import Foundation
import Testing
import PixlFoundation
import PixlModel
@testable import PixlLyrics

/// Swift-only tests of the Kotlin/Java semantics helpers, the XML reader, Gson accessors and the romanisers.
@Suite("Parsing — infrastructure")
struct ParsingInfrastructureTests {

    @Test func javaParseDouble() {
        #expect(ParseKit.parseDouble("1.5") == 1.5)
        #expect(ParseKit.parseDouble("  -2.5e2 ") == -250)
        #expect(ParseKit.parseDouble(".5") == 0.5)
        #expect(ParseKit.parseDouble("5.") == 5)
        #expect(ParseKit.parseDouble("1.5f") == 1.5)
        #expect(ParseKit.parseDouble("2D") == 2)
        #expect(ParseKit.parseDouble("0x1.8p1") == 3)
        #expect(ParseKit.parseDouble("Infinity") == .infinity)
        #expect(ParseKit.parseDouble("-Infinity") == -.infinity)
        #expect(ParseKit.parseDouble("NaN")?.isNaN == true)
        for bad in ["", " ", ".", "e5", "1e", "0x10", "nan", "inf", ".nan", "1_000", "1,5", "--1", "1.5s", "+"] {
            #expect(ParseKit.parseDouble(bad) == nil, "\(bad)")
        }
    }

    @Test func kotlinToLongAndRounding() {
        #expect(ParseKit.toLong("+12") == 12)
        #expect(ParseKit.toLong("-0") == 0)
        #expect(ParseKit.toLong("١٢") == 12) // Character.digit accepts any Nd digit
        #expect(ParseKit.toLong("9223372036854775807") == .max)
        #expect(ParseKit.toLong("9223372036854775808") == nil)
        #expect(ParseKit.toLong("-9223372036854775808") == .min)
        #expect(ParseKit.toLong(" 1") == nil)
        #expect(ParseKit.toLong("") == nil)
        #expect(ParseKit.javaRound(0.49999999999999994) == 0)
        #expect(ParseKit.javaRound(-2.5) == -2)
        #expect(ParseKit.javaRound(2.5) == 3)
        #expect(ParseKit.roundToInt(.nan) == nil)
        #expect(ParseKit.roundToInt(1e20) == .max)
        #expect(ParseKit.pad2(5) == "05")
        #expect(ParseKit.pad2(-5) == "-5")
        #expect(ParseKit.pad2(123) == "123")
        #expect(ParseKit.lrcTimestamp(61_239) == "01:01.23")
        #expect(ParseKit.lrcTimestamp(-1_500) == "00:-1.-50")
    }

    @Test func kotlinLinesAndStringHelpers() {
        #expect(ParseKit.lines("a\r\nb\rc\nd\n") == ["a", "b", "c", "d", ""])
        #expect(ParseKit.lines("") == [""])
        #expect(ParseKit.hasPrefix("e\u{301}x", "e")) // code units, not graphemes
        #expect(!ParseKit.contains("\u{E9}", "e"))
        #expect(ParseKit.substringAfter("a?>b?>c", "?>", missing: "z") == "b?>c")
        #expect(ParseKit.isFormatChar("\u{200B}") && !ParseKit.isFormatChar("\u{E0001}"))
        #expect(ParseKit.isISOControl("\u{85}") && !ParseKit.isISOControl("\u{A0}"))
    }

    @Test func gsonAccessors() throws {
        #expect(try GsonJSON.string(.number("1.50")) == "1.50")
        #expect(try GsonJSON.string(.array([.string("x")])) == "x")
        #expect(throws: GsonError.self) { try GsonJSON.string(.null) }
        #expect(throws: GsonError.self) { try GsonJSON.string(nil) }
        #expect(try GsonJSON.long(.number("180000.7")) == 180000)
        #expect(try GsonJSON.long(.number("1e3")) == 1000)
        #expect(try GsonJSON.long(.string("42")) == 42)
        #expect(throws: GsonError.self) { try GsonJSON.long(.string("4.2")) }
        #expect(try GsonJSON.int(.number("200.0")) == 200)
        #expect(try GsonJSON.int(.number("4294967496")) == 200)
        #expect(try GsonJSON.double(.string(" 2.5 ")) == 2.5)
        #expect(GsonJSON.bigDecimalLongValue("-12.9e1") == -129)
        #expect(GsonJSON.bigDecimalLongValue("1e100") == 0)
        #expect(GsonJSON.bigDecimalLongValue("abc") == nil)
    }

    // MARK: XML reader

    @Test func xmlRejectsDoctypeEntitiesAndMalformedDocuments() {
        let bad = [
            "<!DOCTYPE tt><tt/>",
            "<?xml version=\"1.0\"?><!DOCTYPE tt [<!ENTITY x \"y\">]><tt>&x;</tt>",
            "<tt>&nbsp;</tt>",
            "<tt><p></tt>",
            "<tt a=\"1\" a=\"2\"/>",
            "<tt a=1/>",
            "<tt>a ]]> b</tt>",
            "<tt>a & b</tt>",
            "<tt>\u{1}</tt>",
            "<tt/><tt/>",
            "<x:tt/>",
            "<tt xmlns:a=\"u\" xmlns:b=\"u\" a:x=\"1\" b:x=\"2\"/>",
            "text<tt/>",
            "<tt><!-- a -- b --></tt>",
            "<tt><?xml version=\"1.0\"?></tt>",
            String(repeating: "<a>", count: 300) + String(repeating: "</a>", count: 300),
        ]
        for text in bad {
            #expect(throws: LyricsXMLError.self, "\(text.prefix(60))") { try LyricsXMLParser.parse(text) }
        }
    }

    @Test func deepButValidDocumentsParseWithoutRecursionTrouble() throws {
        let depth = LyricsXMLParser.maxDepth - 2
        let ttml = "<tt><p begin=\"1.0\">" + String(repeating: "<span>", count: depth) + "deep"
            + String(repeating: "</span>", count: depth) + "</p></tt>"
        #expect(TtmlLyricsParser.parseToEnhancedLrc(ttml) == "[00:01.00]deep")
    }

    @Test func xmlBuildsTheDomTheTtmlParserNeeds() throws {
        let root = try LyricsXMLParser.parse("""
            <tt:tt xmlns:tt="urn:t" xml:lang="en"><!-- c --><tt:p begin="1.0" x='a&#10;b&amp;'>A&lt;B<![CDATA[<raw>]]>C<?pi x?>D</tt:p>
            <p>second</p></tt:tt>
            """)
        #expect(root.localName == "tt")
        let paragraphs = root.descendants(localName: "p")
        #expect(paragraphs.count == 2)
        let p = paragraphs[0]
        #expect(p.attribute("begin") == "1.0")
        #expect(p.attribute("x") == "a\nb&")
        #expect(p.attribute("missing") == "")
        #expect(p.children.map(\.kind) == [.text, .cdata, .text, .other, .text])
        #expect(p.children.map(\.text) == ["A<B", "<raw>", "C", "", "D"])
    }

    @Test func xmlNormalisesLineEndingsAndAttributeWhitespace() throws {
        let root = try LyricsXMLParser.parse("<tt a=\"x\ty\r\nz\">l1\r\nl2\rl3</tt>")
        #expect(root.attribute("a") == "x y z")
        #expect(root.children.first?.text == "l1\nl2\nl3")
    }

    @Test func ttmlTimeExpressions() throws {
        #expect(try TtmlLyricsParser.parseTimeExpression("7.531") == 7531)
        #expect(try TtmlLyricsParser.parseTimeExpression(" 4.5s ") == 4500)
        #expect(try TtmlLyricsParser.parseTimeExpression("7.5S") == nil)
        #expect(try TtmlLyricsParser.parseTimeExpression("1:02:03.5") == 3_723_500)
        #expect(try TtmlLyricsParser.parseTimeExpression("00:01.123456") == 1123)
        #expect(try TtmlLyricsParser.parseTimeExpression("5:00") == 300_000)
        #expect(try TtmlLyricsParser.parseTimeExpression("1:2:3:4") == nil)
        #expect(try TtmlLyricsParser.parseTimeExpression("") == nil)
        #expect(throws: (any Error).self) { try TtmlLyricsParser.parseTimeExpression("NaN") }
        #expect(TtmlLyricsParser.parseToEnhancedLrc("<tt><body><p begin=\"NaN\">x</p><p begin=\"1\">y</p></body></tt>") == nil)
        let many = "<tt><body>" + String(repeating: "<p begin=\"1\">x</p>", count: TtmlLyricsParser.maxParagraphs + 1) + "</body></tt>"
        #expect(TtmlLyricsParser.parseToEnhancedLrc(many) == nil)
    }

    @Test func ttmlTextNormalisation() {
        #expect(TtmlLyricsParser.sanitizeTextFragment("  \n  ") == "")
        #expect(TtmlLyricsParser.sanitizeTextFragment("   ") == " ")
        #expect(TtmlLyricsParser.sanitizeTextFragment("\u{A0}") == " ")
        #expect(TtmlLyricsParser.sanitizeTextFragment("a \t\u{B}b\u{200B}") == "a b")
        #expect(TtmlLyricsParser.normalizeInlineText(" a  \n  b \n") == " a\nb")
        #expect(TtmlLyricsParser.normalizeParagraphBody("  x   y \n\n z ") == "x y\nz")
    }

    // MARK: Romanisers

    @Test func romanisers() {
        #expect(MultiLangRomanizer.romanizeKorean("한국어 노래") == "hangugeo norae")
        #expect(MultiLangRomanizer.romanizeHindi("नमस्ते") == "nmste") // consonants carry no inherent vowel on Android
        #expect(MultiLangRomanizer.romanizeCyrillic("Привет, мир!") == "Privet, mir!")
        #expect(MultiLangRomanizer.romanizeCyrillic("е") == nil)
        #expect(MultiLangRomanizer.romanizeCyrillic("Hello") == nil)
        #expect(MultiLangRomanizer.romanizeChinese("我爱你", provider: NoCJKRomanization()) == "我 爱 你")
        #expect(MultiLangRomanizer.isScriptThatNeedsRomanization("Привет"))
        #expect(!MultiLangRomanizer.isScriptThatNeedsRomanization("Hello"))
        #expect(MultiLangRomanizer.isJapanese("世界", entireLyricsHasKana: true))
        #expect(!MultiLangRomanizer.isJapanese("世界"))
        #expect(LyricsUtils.capitalizeFirstLetter("ßa") == "Ssa")
        #expect(LyricsUtils.capitalizeFirstLetter("ǆx") == "ǅx")
    }
}
