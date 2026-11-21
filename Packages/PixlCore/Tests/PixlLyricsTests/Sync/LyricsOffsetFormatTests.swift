import Testing
@testable import PixlLyrics

@Suite("Lyrics offset text")
struct LyricsOffsetFormatTests {
    @Test func theRowsValuesUseOneRealMinus() {
        #expect(LyricsOffsetFormat.text(offsetMs: 0) == "0 s")
        #expect(LyricsOffsetFormat.text(offsetMs: 500) == "+0.5 s")
        #expect(LyricsOffsetFormat.text(offsetMs: 400) == "+0.4 s")
        #expect(LyricsOffsetFormat.text(offsetMs: -100) == "\u{2212}0.1 s")
        #expect(LyricsOffsetFormat.text(offsetMs: -1_500) == "\u{2212}1.5 s")
        #expect(LyricsOffsetFormat.text(offsetMs: 12_300) == "+12.3 s")
        #expect(!LyricsOffsetFormat.text(offsetMs: -2_000).contains("-"))
    }
}
