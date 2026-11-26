// The pure pieces of a track's DNA (docs/brain-spec.md, 3.2 to 3.4): which year to believe, how popular, how energetic
// and how happy it sounds, which language its title is in. A transliteration of the Android `:brain` module's
// `TrackDna.kt`. Integers only where the value is stored (so both apps store and compare it identically); doubles only
// inside a function, built from `+ - * /` and `BrainMath`.
//
// Unknown is a value: year 0, popularity -1, energy and valence -1, language 0. Nothing here guesses.

public enum TrackDna {
    // Where a year came from. The smaller number wins a tie.
    public static let yearNone = 0
    public static let yearMusicBrainz = 1
    public static let yearITunes = 2
    public static let yearSpotify = 3
    public static let yearYouTube = 4
    public static let yearDeezer = 5

    public static let gainUnknown = -32768
    public static let unknown = -1

    // Where a tempo came from (3.2 `tempoSource`). Stage 5 adds the on-device measurement (`AudioFeatures`).
    public static let tempoUnknown = 0
    public static let tempoDeezer = 1
    public static let tempoAcousticBrainz = 2
    /// Measured on the phone with a confidence of at least `AudioFeatures.trustConf`: preferred over Deezer's.
    public static let tempoOnDevice = 3
    /// Measured on the phone below that confidence: used only when no source has a tempo.
    public static let tempoOnDeviceWeak = 4

    public struct YearClaim: Sendable, Equatable {
        public var source: Int
        public var year: Int
        public init(source: Int, year: Int) {
            self.source = source
            self.year = year
        }
    }

    public struct Year: Sendable, Equatable {
        public var year: Int
        public var source: Int
        public init(year: Int, source: Int) {
            self.year = year
            self.source = source
        }
        public var known: Bool { year != 0 }
    }

    /// The earliest believable year over every source (3.3, "Year"). A claim before 1900 or after `maxYear` is noise and
    /// is ignored. Deezer alone is never believed: its date is often a re-release (wrong era on 6 of 16 in the probe),
    /// so a year that only Deezer gave stays unknown. `maxYear` is the current year plus one, passed in because the
    /// core has no clock.
    public static func mergeYear(_ claims: [YearClaim], maxYear: Int) -> Year {
        var best = 0
        var bestSource = yearNone
        var other = false
        for c in claims {
            if c.year < 1900 || c.year > maxYear { continue }
            if c.source != yearDeezer { other = true }
            if best == 0 || c.year < best || (c.year == best && c.source < bestSource) {
                best = c.year
                bestSource = c.source
            }
        }
        if best == 0 { return Year(year: 0, source: yearNone) }
        if !other { return Year(year: 0, source: yearNone) }
        return Year(year: best, source: bestSource)
    }

    /// The year of `2019`, `2019-03` or `2019-03-29`; 0 for anything else.
    public static func parseYear(_ text: String?) -> Int {
        guard let text else { return 0 }
        let u = Array(text.utf16)
        if u.count < 4 { return 0 }
        var n = 0
        for i in 0..<4 {
            let d = Int(u[i]) - 48
            if d < 0 || d > 9 { return 0 }
            n = n * 10 + d
        }
        if u.count > 4 && u[4] >= 0x30 && u[4] <= 0x39 { return 0 }
        return n >= 1900 && n <= 2200 ? n : 0
    }

    // MARK: Popularity, 0...1000

    private static let log10Of2Bits: UInt64 = 0x3FD3_4413_509F_79FF

    private static func log10Of(_ x: Double) -> Double { BrainMath.log2(x) * Double(bitPattern: log10Of2Bits) }

    private static func clampPop(_ v: Int64) -> Int { v < 0 ? 0 : (v > 1000 ? 1000 : Int(v)) }

    /// Deezer's `rank` (about 0 to 1,000,000) divided by 1,000; -1 when there is none.
    public static func popFromDeezerRank(_ rank: Int64) -> Int { rank <= 0 ? unknown : clampPop(rank / 1000) }

    /// A play count of the YouTube row ("47M plays"): `min(1000, round(1000 * log10(1 + plays) / 9.7))`.
    public static func popFromPlays(_ plays: Int64) -> Int {
        plays <= 0 ? unknown : clampPop(BrainMath.floorToLong(1000.0 * log10Of(1.0 + Double(plays)) / 9.7 + 0.5))
    }

    /// ListenBrainz distinct listeners: `min(1000, round(1000 * log10(1 + users) / 5.3))`.
    public static func popFromListeners(_ users: Int64) -> Int {
        users <= 0 ? unknown : clampPop(BrainMath.floorToLong(1000.0 * log10Of(1.0 + Double(users)) / 5.3 + 0.5))
    }

    /// The first source that knows, in the order Deezer, YouTube, ListenBrainz (3.3).
    public static func mergePopularity(deezer: Int, youtube: Int, listenBrainz: Int) -> Int {
        deezer >= 0 ? deezer : (youtube >= 0 ? youtube : (listenBrainz >= 0 ? listenBrainz : unknown))
    }

    /// A YouTube Music play count as text ("47M plays", "1.2B views", "950K plays", "12,345 plays", "3.4K"): the
    /// number, or 0 when the text holds none. Fractions are read to three places.
    public static func parsePlayCount(_ text: String?) -> Int64 {
        guard let text, !BrainText.isBlank(text) else { return 0 }
        let u = Array(text.utf16)
        var whole: Int64 = 0
        var frac: Int64 = 0
        var fracDigits = 0
        var seenDot = false
        var any = false
        var i = 0
        while i < u.count {
            let c = u[i]
            if c >= 0x30 && c <= 0x39 {
                any = true
                if !seenDot {
                    whole = whole &* 10 &+ Int64(c - 48)
                } else if fracDigits < 3 {
                    frac = frac &* 10 &+ Int64(c - 48)
                    fracDigits += 1
                }
            } else if c == 0x2E && any && !seenDot {
                seenDot = true
            } else if c == 0x2C && any && !seenDot {
                // a thousands separator
            } else if any {
                break
            }
            i += 1
        }
        if !any { return 0 }
        var mult: Int64 = 1
        if i < u.count {
            switch u[i] {
            case 0x4B, 0x6B: mult = 1_000
            case 0x4D, 0x6D: mult = 1_000_000
            case 0x42, 0x62: mult = 1_000_000_000
            default: break
            }
        }
        var scale: Int64 = 1
        for _ in 0..<fracDigits { scale *= 10 }
        return whole &* mult &+ (frac &* mult) / scale
    }

    // MARK: Energy, valence, moods (3.5)

    public struct Feel: Sendable, Equatable {
        public var energy: Int
        public var valence: Int
        public init(energy: Int, valence: Int) {
            self.energy = energy
            self.valence = valence
        }
        public var known: Bool { energy >= 0 }
    }

    private static let noFeel = Feel(energy: unknown, valence: unknown)

    /// Energy and valence of a track: the tag-weighted mean of its tags' descriptors, then
    /// `energy += clamp((gainDb + 9) * 4, -20, 20)` when the loudness is known (3.5). -1 when no tag has a descriptor.
    /// `gainDbX10` is Deezer's `gain` times 10, or `gainUnknown`.
    public static func feel(_ atlas: GenreAtlas, _ tags: Tags.Vector, gainDbX10: Int) -> Feel {
        var num: Int64 = 0
        var numV: Int64 = 0
        var den: Int64 = 0
        for t in tags.tags {
            guard let d = atlas.descriptor(t.atlasId) else { continue }
            num += Int64(t.q) * Int64(d.energy)
            numV += Int64(t.q) * Int64(d.valence)
            den += Int64(t.q)
        }
        if den == 0 { return noFeel }
        var energy = Int((2 * num + den) / (2 * den))
        let valence = Int((2 * numV + den) / (2 * den))
        if gainDbX10 != gainUnknown {
            var nudge = Int(BrainMath.floorDiv(Int64((gainDbX10 + 90) * 4), 10))
            if nudge < -20 { nudge = -20 }
            if nudge > 20 { nudge = 20 }
            energy += nudge
        }
        if energy < 0 { energy = 0 }
        if energy > 255 { energy = 255 }
        return Feel(energy: energy, valence: valence > 255 ? 255 : valence)
    }

    /// The tempo nudge on energy is at most this many points either way (stage 5).
    public static let tempoNudgeMax = 15

    /// Stage 5 (3.3: energy is "nudged by gain and tempo"): `feel`, then `energy += clamp(floor((bpm - mid) / 3), -15, 15)` where
    /// `mid` is the tag-weighted middle of the tags' descriptor tempo bands (`(tempoLo + tempoHi) / 2`), when the tempo is known and
    /// some tag has a band. Integer arithmetic on bpm x 10. Valence is not nudged.
    public static func feel(_ atlas: GenreAtlas, _ tags: Tags.Vector, gainDbX10: Int, tempoBpmX10: Int) -> Feel {
        let base = feel(atlas, tags, gainDbX10: gainDbX10)
        if !base.known || tempoBpmX10 <= 0 { return base }
        var num: Int64 = 0
        var den: Int64 = 0
        for t in tags.tags {
            guard let d = atlas.descriptor(t.atlasId) else { continue }
            if d.tempoLo <= 0 || d.tempoHi < d.tempoLo { continue }
            num += Int64(t.q) * Int64(d.tempoLo + d.tempoHi) * 5 // the middle, x 10
            den += Int64(t.q)
        }
        if den == 0 { return base }
        let midX10 = (2 * num + den) / (2 * den)
        var nudge = Int(BrainMath.floorDiv(Int64(tempoBpmX10) - midX10, 30))
        if nudge < -tempoNudgeMax { nudge = -tempoNudgeMax }
        if nudge > tempoNudgeMax { nudge = tempoNudgeMax }
        var energy = base.energy + nudge
        if energy < 0 { energy = 0 }
        if energy > 255 { energy = 255 }
        return Feel(energy: energy, valence: base.valence)
    }

    /// Up to 4 mood ids: the ones the tags' descriptors name most, by summed tag weight (ties: smaller id).
    public static func moods(_ atlas: GenreAtlas, _ tags: Tags.Vector) -> [Int] {
        var sums: [Int: Int] = [:]
        for t in tags.tags {
            guard let d = atlas.descriptor(t.atlasId) else { continue }
            for m in d.moods { sums[m, default: 0] += t.q }
        }
        let order = sums.sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }
        return order.prefix(4).map(\.key)
    }

    // MARK: Language of the title (3.2 `scriptLang`)

    public static let scriptUnknown = 0
    public static let scriptVietnamese = 1
    public static let scriptKorean = 2
    public static let scriptJapanese = 3
    public static let scriptChinese = 4
    public static let scriptLatin = 5
    public static let scriptCyrillic = 6
    public static let scriptThai = 7
    public static let scriptArabic = 8
    public static let scriptDevanagari = 9

    /// The language group of a title from the script ranges of its characters, with the artist's country (an ISO 3166
    /// code or empty) breaking a plain Latin title's tie. Vietnamese is told by the letters only Vietnamese uses
    /// (ă đ ơ ư and the stacked-accent block); a title in plain ASCII is Latin unless the country says otherwise.
    public static func scriptLang(_ title: String, artistCountry: String) -> Int {
        var hangul = 0, kana = 0, han = 0, vi = 0, cyr = 0, thai = 0, arab = 0, deva = 0, latin = 0
        for scalar in title.unicodeScalars {
            let c = scalar.value
            if (c >= 0xAC00 && c <= 0xD7AF) || (c >= 0x1100 && c <= 0x11FF) || (c >= 0x3130 && c <= 0x318F) {
                hangul += 1
            } else if (c >= 0x3040 && c <= 0x30FF) || (c >= 0x31F0 && c <= 0x31FF) || (c >= 0xFF66 && c <= 0xFF9F) {
                kana += 1
            } else if (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF) {
                han += 1
            } else if (c >= 0x1EA0 && c <= 0x1EF9) || c == 0x102 || c == 0x103 || c == 0x110 || c == 0x111 || c == 0x1A0
                        || c == 0x1A1 || c == 0x1AF || c == 0x1B0 {
                vi += 1
            } else if c >= 0x400 && c <= 0x4FF {
                cyr += 1
            } else if c >= 0xE00 && c <= 0xE7F {
                thai += 1
            } else if c >= 0x600 && c <= 0x6FF {
                arab += 1
            } else if c >= 0x900 && c <= 0x97F {
                deva += 1
            } else if (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0xC0 && c <= 0x24F) {
                latin += 1
            }
        }
        if hangul > 0 { return scriptKorean }
        if kana > 0 { return scriptJapanese }
        if han > 0 { return scriptChinese }
        if vi > 0 { return scriptVietnamese }
        if thai > 0 { return scriptThai }
        if arab > 0 { return scriptArabic }
        if deva > 0 { return scriptDevanagari }
        if cyr > 0 { return scriptCyrillic }
        if latin == 0 { return scriptUnknown }
        switch artistCountry {
        case "VN": return scriptVietnamese
        case "KR": return scriptKorean
        case "JP": return scriptJapanese
        case "CN", "TW", "HK": return scriptChinese
        default: return scriptLatin
        }
    }
}
