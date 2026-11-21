// The name a phone shows to other phones ("Song drop to Hoa's Pixel?", "From Hoa's Pixel") (Song Tap, spec 5). A
// transliteration of `SongTapNames.kt`; the golden `names.jsonl` proves both agree.
//
// The listener sets it in Settings (default: the device's name). It is clean text: control, zero width and bidirectional
// characters stripped (the same `SongTapText` rules as a beamed title), spaces collapsed and trimmed, at most `maxChars`
// characters (Unicode scalars, not UTF-16 units, not Swift `Character`s).
//
// How a name travels: in the advertisement ("short name") an iPhone puts it in its local name, which is all a peripheral can
// advertise next to its service UUID (iOS may cut it further); an Android phone puts a manufacturer block with company id
// 0xFFFF in its scan response, and a phone reading an advertisement uses that block when there is one and otherwise the
// local name, through `fromAdvert` either way. Over a connection the sender's full name comes from the Name characteristic.
// A name is a label for the listener, never an identity: two phones can have the same name, and a stranger can claim any.

public enum SongTapNames {
    public static let maxChars = 20

    /// At most this many UTF-8 bytes of the name fit the advertisement next to its 1 byte header.
    public static let advertNameMaxBytes = 24

    /// The most a clean name can be in UTF-8 (20 scalars of up to 4 bytes).
    public static let maxNameBytes = maxChars * 4

    /// What a phone is called when it has no usable name.
    public static let fallback = "Phone"

    /// `raw` as a clean name of at most `maxChars` scalars; empty when nothing usable is left. Idempotent.
    public static func clean(_ raw: String) -> String {
        let cps = SongTapText.sanitize(SongTapText.toCodePoints(raw), maxBytes: maxNameBytes)
        let cut = cps.count > maxChars ? Array(cps[0..<maxChars]) : cps
        // The cut can leave a trailing space; sanitize again drops it (and stays within the limits).
        return SongTapText.fromCodePoints(SongTapText.sanitize(cut, maxBytes: maxNameBytes))
    }

    /// `clean`, or `fallback` when nothing is left.
    public static func orFallback(_ raw: String) -> String {
        let c = clean(raw)
        return c.isEmpty ? fallback : c
    }

    /// True when `name` is already exactly what `clean` returns and is not empty.
    public static func isValid(_ name: String) -> Bool { !name.isEmpty && clean(name) == name }

    /// The short name for the advertisement: the clean name cut at a scalar boundary to `advertNameMaxBytes` bytes (never ends
    /// with a space).
    public static func advertName(_ name: String) -> String {
        let cps = SongTapText.toCodePoints(clean(name))
        return SongTapText.fromCodePoints(SongTapText.sanitize(cps, maxBytes: advertNameMaxBytes))
    }

    /// The name read out of an advertisement (the block's name bytes, or a phone's local name): clean, possibly shorter; nil
    /// when nothing usable.
    public static func fromAdvert(_ raw: String) -> String? {
        let c = clean(raw)
        return c.isEmpty ? nil : c
    }
}
