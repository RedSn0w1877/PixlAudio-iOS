import Foundation
import Testing
@testable import PixlFoundation

@Suite("JSON")
struct JSONTests {
    let strict = JSONParser()
    let kotlinx = JSONParser(mode: .kotlinx)

    @Test func parsesAndWritesCompactly() throws {
        let text = #" { "b" : [1, -2.5e3, true, false, null, "x"], "a": {"nested": {}} , "e": [] } "#
        let value = try strict.parse(text)
        #expect(value["b"]?.arrayValue?.count == 6)
        #expect(value["b"]?.arrayValue?[0].int64Value == 1)
        #expect(value["b"]?.arrayValue?[1].doubleValue == -2500)
        #expect(value["b"]?.arrayValue?[1].int64Value == nil)
        #expect(value["b"]?.arrayValue?[2].boolValue == true)
        #expect(value["b"]?.arrayValue?[4].isNull == true)
        // Member order is preserved on output.
        #expect(JSONWriter.write(value) == #"{"b":[1,-2.5e3,true,false,null,"x"],"a":{"nested":{}},"e":[]}"#)
    }

    @Test func duplicateKeysResolveToTheLastOne() throws {
        let value = try strict.parse(#"{"k":1,"k":2}"#)
        #expect(value["k"]?.int64Value == 2)
        #expect(value.objectValue?.members.count == 2)
    }

    @Test func decodesEscapesAndSurrogatePairs() throws {
        let value = try strict.parse(#""a\"b\\c\/d\b\f\n\r\té🎵""#)
        #expect(value.stringValue == "a\"b\\c/d\u{8}\u{C}\n\r\t\u{E9}🎵")
        #expect(try strict.parse(#""\uD83C""#).stringValue == "\u{FFFD}")
        #expect(throws: JSONParseError.self) { try strict.parse(#""\x""#) }
        #expect(throws: JSONParseError.self) { try strict.parse(#""\u12G4""#) }
    }

    @Test func writerUsesKotlinxEscaping() {
        let s = "q\"b\\s/\u{8}\u{C}\n\r\t\u{1}\u{1F}\u{7F}\u{2028}é🎵"
        var out = ""
        JSONWriter.writeString(s, into: &out)
        #expect(out == "\"q\\\"b\\\\s/\\b\\f\\n\\r\\t\\u0001\\u001f\u{7F}\u{2028}é🎵\"")
    }

    @Test func strictModeRejectsWhatRFC8259Rejects() {
        for bad in ["", "tru", "{\"a\":1,}", "[1,]", "{'a':1}", "{a:1}", "01", "+1", "1.", ".5", "NaN", "[1] x",
                    "\"raw\u{9}tab\"", "{\"a\" 1}", "[", "{\"a\":"] {
            #expect(throws: JSONParseError.self, "\(bad)") { try strict.parse(bad) }
        }
    }

    @Test func kotlinxModeAcceptsBareTokensAndRawControls() throws {
        #expect(try kotlinx.parse("tru") == .number("tru"))
        #expect(try kotlinx.parse("[005, -]") == .array([.number("005"), .number("-")]))
        #expect(try kotlinx.parse("\"raw\u{9}tab\"").stringValue == "raw\ttab")
        #expect(throws: JSONParseError.self) { try kotlinx.parse("{'a':1}") }
        #expect(throws: JSONParseError.self) { try kotlinx.parse("[1,]") }
    }

    @Test func depthLimit() {
        let deep = String(repeating: "[", count: 20) + String(repeating: "]", count: 20)
        #expect(throws: JSONParseError.self) { try JSONParser(maxDepth: 19).parse(deep) }
        #expect((try? JSONParser(maxDepth: 20).parse(deep)) != nil)
    }

    @Test func numberGrammar() {
        for good in ["0", "-0", "12", "1.5", "1e9", "1E+9", "-1.25e-3"] { #expect(JSONGrammar.isNumber(good), "\(good)") }
        for bad in ["", "-", "00", "01", "1.", "1e", "+1", ".1", "1e+", "0x10", "--1"] { #expect(!JSONGrammar.isNumber(bad), "\(bad)") }
        #expect(JSONGrammar.isStrictInteger("-42"))
        #expect(!JSONGrammar.isStrictInteger("4.0"))
        #expect(JSONValue.number("9223372036854775807").int64Value == Int64.max)
        #expect(JSONValue.number("9223372036854775808").int64Value == nil)
    }

    /// kotlinx `consumeNumericLiteral` behaviour, as observed from the real Android codec
    /// (see PixlModelTests `lyricsdoc-android-golden.txt`).
    @Test func kotlinxNumericLiterals() {
        let p = KotlinxJSON.parseNumericLiteral
        #expect(p("1000") == 1000)
        #expect(p("-7") == -7)
        #expect(p("005") == 5)
        #expect(p("-0") == 0)
        #expect(p("1e3") == 1000)
        #expect(p("2E3") == 2000)
        #expect(p("1000e-3") == 1)
        #expect(p("1e+2") == 100)
        #expect(p("9223372036854775807") == Int64.max)
        #expect(p("-9223372036854775808") == Int64.min)
        #expect(p("9223372036854775808") == nil)
        #expect(p("1000.0") == nil)
        #expect(p("1.5e3") == nil)
        #expect(p("15e-1") == nil)
        #expect(p("+5") == nil)
        #expect(p("") == nil)
        #expect(p("-") == nil)
        #expect(p("NaN") == nil)
        #expect(p("1-") == nil)
        #expect(KotlinxJSON.long(.string("1000")) == 1000)
        #expect(KotlinxJSON.long(.bool(true)) == nil)
        #expect(KotlinxJSON.int(.number("4294967297")) == nil)
        #expect(KotlinxJSON.int(.number("2147483647")) == Int32.max)
        #expect(KotlinxJSON.string(.number("5")) == nil)
    }
}
