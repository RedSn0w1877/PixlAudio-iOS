/// How the lyrics timing row writes an offset: "0 s", "+0.5 s", "−0.1 s" (tenths of a second). The minus is the real
/// minus sign U+2212, the one the row's step buttons use, so the value and the buttons read in the same glyphs
/// (an ASCII hyphen is narrower and looks like a different mark beside them).
public enum LyricsOffsetFormat {
    public static let minus = "\u{2212}"

    public static func text(offsetMs: Int) -> String {
        guard offsetMs != 0 else { return "0 s" }
        let tenths = (abs(offsetMs) + 50) / 100
        return "\(offsetMs < 0 ? minus : "+")\(tenths / 10).\(tenths % 10) s"
    }
}
