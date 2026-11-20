// The pure parts of Ask Taizo's ten music tools (docs/brain-spec.md, 9.3, stage 4): the refs a tool call can use, the structured request
// a sentence becomes and how a request is cleaned and filtered, the chips under a mix card (deltas on the stored request, applied on the
// device with no model call), and the fixed list of factor names `explain_track` may use. A transliteration of the Android `:brain`
// module's `Assistant.kt` (`AssistantRules`).
//
// The assistant never ranks and never invents a track: it fills this structure, and the engine does the rest. Everything here is a plain
// function of its inputs (no I/O, no clock, no regular expressions), so the port reproduces `assistant.jsonl` bit for bit. Strings are
// scanned as UTF-16 code units, as the Kotlin does.

import PixlModel

/// The rules of the assistant's tools.
public enum AssistantRules {

    // MARK: Refs

    /// A track a tool returned, in the form the next call takes: `sp:<spotifyId>` (22 letters and digits) or `yt:<videoId>` (11).
    public struct Ref: Sendable, Equatable {
        public let kind: Int
        public let id: String

        public init(kind: Int, id: String) {
            self.kind = kind
            self.id = id
        }

        public var text: String { (kind == AssistantRules.refSpotify ? "sp:" : "yt:") + id }
    }

    public static let refSpotify = 0
    public static let refYouTube = 1
    public static let spotifyIdLength = 22
    public static let youTubeIdLength = 11

    public static func spotifyRef(_ id: String) -> String { "sp:" + id }
    public static func youTubeRef(_ videoId: String) -> String { "yt:" + videoId }

    /// The ref `text` is, or nil for anything else (a name, a half id, an id with a character a real id never has).
    public static func parseRef(_ text: String?) -> Ref? {
        guard let text else { return nil }
        let u = Array(text.utf16)
        if u.count == 3 + spotifyIdLength && u[0] == 0x73 && u[1] == 0x70 && u[2] == 0x3A {
            for i in 3..<u.count where !isAlnum(u[i]) { return nil }
            return Ref(kind: refSpotify, id: String(decoding: u[3...], as: UTF16.self))
        }
        if u.count == 3 + youTubeIdLength && u[0] == 0x79 && u[1] == 0x74 && u[2] == 0x3A {
            for i in 3..<u.count where !isAlnum(u[i]) && u[i] != 0x5F && u[i] != 0x2D { return nil }
            return Ref(kind: refYouTube, id: String(decoding: u[3...], as: UTF16.self))
        }
        return nil
    }

    private static func isAlnum(_ c: UInt16) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A)
    }

    // MARK: Sentinels and enums (9.3: every parameter is required, "no value" is explicit)

    public static let anyWord = AssistantVocabulary.anyWord
    public static let lower = "lower"
    public static let higher = "higher"
    public static let familiar = "familiar"
    public static let new = "new"
    public static let slow = "slow"
    public static let mid = "mid"
    public static let fast = "fast"

    public static let energy: [String] = AssistantVocabulary.energy
    public static let novelty: [String] = AssistantVocabulary.novelty
    public static let tempo: [String] = AssistantVocabulary.tempo
    public static let seedKinds: [String] = AssistantVocabulary.seedKinds
    public static let stationModes: [String] = AssistantVocabulary.stationModes
    public static let steerChanges: [String] = AssistantVocabulary.steerChanges
    public static let steerScopes: [String] = AssistantVocabulary.steerScopes
    public static let explainScopes: [String] = AssistantVocabulary.explainScopes
    public static let releaseScopes: [String] = AssistantVocabulary.releaseScopes

    /// `novelty_share_pct` when the sentence said nothing about it (0 is a real answer: no new music).
    public static let shareUnset = AssistantVocabulary.shareUnset

    public static let defaultResults = AssistantVocabulary.defaultResults
    public static let maxRecommend = AssistantVocabulary.maxRecommend
    public static let minMix = AssistantVocabulary.minMix
    public static let maxMix = AssistantVocabulary.maxMix
    public static let defaultMix = AssistantVocabulary.defaultMix
    public static let maxResolveItems = AssistantVocabulary.maxResolveItems
    public static let maxSeedRefs = AssistantVocabulary.maxSeedRefs
    public static let maxGenres = 8
    public static let maxExcludedArtists = 25
    public static let maxTitle = AssistantVocabulary.maxTitle

    public static func clampInt(_ v: Int, _ lo: Int, _ hi: Int) -> Int { v < lo ? lo : (v > hi ? hi : v) }

    private static func same(_ a: String, _ b: String) -> Bool { KotlinText.equals(a, b) }

    private static func has(_ list: [String], _ s: String) -> Bool {
        for x in list where same(x, s) { return true }
        return false
    }

    /// The one of `allowed` that `value` is (folded), or `fallback`.
    public static func oneOf(_ value: String?, _ allowed: [String], _ fallback: String) -> String {
        guard let value else { return fallback }
        let v = BrainText.trim(BrainText.fold(value))
        for a in allowed where same(a, v) { return a }
        return fallback
    }

    // MARK: The structured request

    /// What `recommend` and `build_mix` ask the engine for, with the sentinels already read: 0 is "no year bound", `any` is "no
    /// preference". `excludeGenreIds` is not a tool parameter: it exists for the chips ("Less trap"), which are deltas on this stored request.
    public struct Query: Sendable, Equatable {
        public var title: String
        public var seedRefs: [String]
        public var genreIds: [Int]
        public var moodIds: [Int]
        public var yearFrom: Int
        public var yearTo: Int
        public var energy: String
        public var tempo: String
        public var novelty: String
        /// 0...100, or `shareUnset`.
        public var noveltySharePct: Int
        /// Tracks wanted: 1...50 for `recommend`, 10...60 for `build_mix`.
        public var count: Int
        public var excludeArtistRefs: [String]
        public var excludeGenreIds: [Int]

        public init(title: String, seedRefs: [String], genreIds: [Int], moodIds: [Int], yearFrom: Int, yearTo: Int, energy: String,
                    tempo: String, novelty: String, noveltySharePct: Int, count: Int, excludeArtistRefs: [String],
                    excludeGenreIds: [Int] = []) {
            self.title = title
            self.seedRefs = seedRefs
            self.genreIds = genreIds
            self.moodIds = moodIds
            self.yearFrom = yearFrom
            self.yearTo = yearTo
            self.energy = energy
            self.tempo = tempo
            self.novelty = novelty
            self.noveltySharePct = noveltySharePct
            self.count = count
            self.excludeArtistRefs = excludeArtistRefs
            self.excludeGenreIds = excludeGenreIds
        }
    }

    /// Cleans what a tool call carried: bad refs dropped, ids de-duplicated, bounds ordered, every number clamped. Never fails.
    public static func normalize(title: String?, seedRefs: [String]?, genreIds: [Int]?, moodIds: [Int]?, yearFrom: Int, yearTo: Int,
                                 energy: String?, tempo: String?, novelty: String?, noveltySharePct: Int, count: Int,
                                 excludeArtistRefs: [String]?, minCount: Int, maxCount: Int, defaultCount: Int) -> Query {
        var from = yearFrom > 0 ? yearFrom : 0
        var to = yearTo > 0 ? yearTo : 0
        if from > 0 && to > 0 && from > to { swap(&from, &to) }
        let share = noveltySharePct < 0 ? shareUnset : clampInt(noveltySharePct, 0, 100)
        return Query(
            title: cleanTitle(title),
            seedRefs: refsOf(seedRefs, maxSeedRefs),
            genreIds: idsOf(genreIds, maxGenres),
            moodIds: idsOf(moodIds, maxGenres),
            yearFrom: from, yearTo: to,
            energy: oneOf(energy, Self.energy, anyWord),
            tempo: oneOf(tempo, Self.tempo, anyWord),
            novelty: oneOf(novelty, Self.novelty, anyWord),
            noveltySharePct: share,
            count: count <= 0 ? defaultCount : clampInt(count, minCount, maxCount),
            excludeArtistRefs: refsOf(excludeArtistRefs, maxExcludedArtists))
    }

    /// A title for a card: trimmed, one line, at most `maxTitle` characters (UTF-16 units, as on Android).
    public static func cleanTitle(_ raw: String?) -> String {
        guard let raw else { return "" }
        var out: [UInt16] = []
        var lastSpace = true
        for c in raw.utf16 {
            let space = c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09
            if space {
                if !lastSpace { out.append(0x20) }
                lastSpace = true
            } else {
                out.append(c)
                lastSpace = false
            }
        }
        var s = BrainText.trim(String(decoding: out, as: UTF16.self))
        let u = Array(s.utf16)
        if u.count > maxTitle { s = BrainText.trim(String(decoding: u[0..<maxTitle], as: UTF16.self)) }
        return s
    }

    private static func refsOf(_ list: [String]?, _ max: Int) -> [String] {
        guard let list else { return [] }
        var out: [String] = []
        for raw in list {
            guard let ref = parseRef(BrainText.trim(raw)) else { continue }
            let text = ref.text
            if !has(out, text) { out.append(text) }
            if out.count >= max { break }
        }
        return out
    }

    private static func idsOf(_ list: [Int]?, _ max: Int) -> [Int] {
        guard let list else { return [] }
        var out: [Int] = []
        for id in list {
            if id <= 0 { continue }
            if !out.contains(id) { out.append(id) }
            if out.count >= max { break }
        }
        return out
    }

    // MARK: Filtering what the engine returned

    /// What the filters read about one candidate. Unknown is 0 / -1 / empty: a filter with a bound never passes an unknown value. Energy and
    /// tempo are the tag-weighted means of the genres' descriptors (3.5), NOT measured on the track: the result says so.
    public struct Facts: Sendable {
        /// 0 when unknown.
        public var year: Int
        /// The atlas ids of the track's genres, ancestors included; empty when unknown.
        public var genreIds: [Int]
        /// True when the listener has never played it.
        public var novel: Bool
        /// Beats per minute of its genres' usual range; 0 when unknown.
        public var bpm: Int
        /// The primary artist, folded (`BrainText.fold`); "" when unknown.
        public var artistKey: String
        /// 0...255 from its genres' descriptors; -1 when unknown.
        public var energy: Int
        /// Indexes into the atlas's mood list from its genres; empty when unknown.
        public var moodIds: [Int]

        public init(year: Int, genreIds: [Int], novel: Bool, bpm: Int, artistKey: String = "", energy: Int = -1, moodIds: [Int] = []) {
            self.year = year
            self.genreIds = genreIds
            self.novel = novel
            self.bpm = bpm
            self.artistKey = artistKey
            self.energy = energy
            self.moodIds = moodIds
        }
    }

    public static let energyMiddle = 128
    public static let energyMargin = 12

    /// What a filter pass needs besides the request: what the data knows, and what the energy words are relative to.
    public struct FilterContext: Sendable {
        /// At least one candidate has a bpm: the tempo filter can be applied.
        public var tempoKnown: Bool
        public var energyKnown: Bool
        public var moodKnown: Bool
        /// The energy "lower" and "higher" are relative to (the seeds' mean), or `energyMiddle`.
        public var energyRef: Int
        /// Folded names of the artists the request excludes.
        public var excludedArtists: [String]

        public init(tempoKnown: Bool, energyKnown: Bool, moodKnown: Bool, energyRef: Int = AssistantRules.energyMiddle,
                    excludedArtists: [String] = []) {
            self.tempoKnown = tempoKnown
            self.energyKnown = energyKnown
            self.moodKnown = moodKnown
            self.energyRef = energyRef
            self.excludedArtists = excludedArtists
        }
    }

    public static let filterEnergy = "energy"
    public static let filterTempo = "tempo"
    public static let filterMood = "mood"

    /// The filters `q` asks for that no data answers: reported in the result instead of being quietly ignored.
    public static func unsupportedFilters(_ q: Query, _ ctx: FilterContext) -> [String] {
        var out: [String] = []
        if q.energy != anyWord && !ctx.energyKnown { out.append(filterEnergy) }
        if q.tempo != anyWord && !ctx.tempoKnown { out.append(filterTempo) }
        if !q.moodIds.isEmpty && !ctx.moodKnown { out.append(filterMood) }
        return out
    }

    public static func yearOk(_ year: Int, _ from: Int, _ to: Int) -> Bool {
        if from <= 0 && to <= 0 { return true }
        if year <= 0 { return false }
        if from > 0 && year < from { return false }
        if to > 0 && year > to { return false }
        return true
    }

    /// The bpm band of a tempo word: slow under 90, mid 90 to 120, fast over 120 (the three buckets a listener means).
    public static func tempoOk(_ bpm: Int, _ tempo: String) -> Bool {
        if tempo == anyWord { return true }
        if bpm <= 0 { return false }
        switch tempo {
        case slow: return bpm < 90
        case mid: return bpm >= 90 && bpm <= 120
        case fast: return bpm > 120
        default: return true
        }
    }

    /// `lower` is under the reference by at least `energyMargin`, `higher` over it by as much; an unknown energy never passes.
    public static func energyOk(_ energy: Int, _ word: String, _ ref: Int) -> Bool {
        if word == anyWord { return true }
        if energy < 0 { return false }
        switch word {
        case lower: return energy <= ref - energyMargin
        case higher: return energy >= ref + energyMargin
        default: return true
        }
    }

    public static func noveltyOk(_ novel: Bool, _ novelty: String) -> Bool {
        switch novelty {
        case new: return novel
        case familiar: return !novel
        default: return true
        }
    }

    public static func genreOk(_ wanted: [Int], _ have: [Int]) -> Bool {
        if wanted.isEmpty { return true }
        for g in have where wanted.contains(g) { return true }
        return false
    }

    public static func moodOk(_ wanted: [Int], _ have: [Int]) -> Bool { genreOk(wanted, have) }

    /// Whether `facts` passes `q`. A genre filter passes when ANY of the wanted ids is among the track's (ancestors included); an excluded
    /// genre or artist never passes. A filter the data cannot answer at all (see `unsupportedFilters`) is not applied.
    public static func passes(_ q: Query, _ facts: Facts, _ ctx: FilterContext) -> Bool {
        if !yearOk(facts.year, q.yearFrom, q.yearTo) { return false }
        if !noveltyOk(facts.novel, q.novelty) { return false }
        if !genreOk(q.genreIds, facts.genreIds) { return false }
        if !q.excludeGenreIds.isEmpty && genreOk(q.excludeGenreIds, facts.genreIds) { return false }
        if ctx.tempoKnown && !tempoOk(facts.bpm, q.tempo) { return false }
        if ctx.energyKnown && !energyOk(facts.energy, q.energy, ctx.energyRef) { return false }
        if ctx.moodKnown && !q.moodIds.isEmpty && !moodOk(q.moodIds, facts.moodIds) { return false }
        if !facts.artistKey.utf16.isEmpty && has(ctx.excludedArtists, facts.artistKey) { return false }
        return true
    }

    /// The share of new tracks a `build_mix` asks the planner for: the sentence's own share when it gave one, else the novelty word
    /// (`new` 0.6, `familiar` 0.1) or the listener's own appetite `base`. Always within 0...0.6 (the planner's cap).
    public static func noveltyShare(_ q: Query, base: Double) -> Double {
        let v: Double
        if q.noveltySharePct >= 0 {
            v = Double(q.noveltySharePct) / 100.0
        } else {
            switch q.novelty {
            case new: v = 0.6
            case familiar: v = 0.1
            default: v = base
            }
        }
        return BrainMath.clip(v, 0.0, MixPlanner.nuMax)
    }

    // MARK: Chips: deltas on the stored request (9.3, "What the listener gets")

    public static let chipLessArtist = 0
    public static let chipMoreGenre = 1
    public static let chipLessGenre = 2
    public static let chipShorter = 3
    public static let chipLonger = 4
    public static let chipMoreNew = 5
    public static let chipMoreFamiliar = 6
    public static let chipSlower = 7
    public static let chipFaster = 8
    public static let chipLowerEnergy = 9
    public static let chipHigherEnergy = 10

    /// One chip under a card: `kind` and, for the artist and genre chips, what it is about (`ref` for an artist, `genreId` for a genre).
    public struct Chip: Sendable, Equatable {
        public let kind: Int
        public let ref: String
        public let genreId: Int

        public init(kind: Int, ref: String = "", genreId: Int = 0) {
            self.kind = kind
            self.ref = ref
            self.genreId = genreId
        }
    }

    public static let lengthStep = 10
    public static let shareStep = 15

    /// The share a request with no share counts from when "more new" or "more familiar" is tapped.
    public static let shareBase = 25

    /// The request after `chip`. A chip that changes nothing (already at its limit) returns an equal request.
    public static func applyChip(_ q: Query, _ chip: Chip) -> Query {
        var r = q
        switch chip.kind {
        case chipLessArtist:
            guard let ref = parseRef(chip.ref)?.text, !has(q.excludeArtistRefs, ref), q.excludeArtistRefs.count < maxExcludedArtists
            else { return q }
            r.excludeArtistRefs = q.excludeArtistRefs + [ref]
            r.seedRefs = q.seedRefs.filter { !same($0, ref) }
        case chipMoreGenre:
            if chip.genreId <= 0 || q.genreIds.contains(chip.genreId) || q.genreIds.count >= maxGenres { return q }
            r.genreIds = q.genreIds + [chip.genreId]
            r.excludeGenreIds = q.excludeGenreIds.filter { $0 != chip.genreId }
        case chipLessGenre:
            if chip.genreId <= 0 { return q }
            r.genreIds = q.genreIds.filter { $0 != chip.genreId }
            r.excludeGenreIds = (q.excludeGenreIds.contains(chip.genreId) || q.excludeGenreIds.count >= maxGenres)
                ? q.excludeGenreIds : q.excludeGenreIds + [chip.genreId]
        case chipShorter: r.count = clampInt(q.count - lengthStep, minMix, maxMix)
        case chipLonger: r.count = clampInt(q.count + lengthStep, minMix, maxMix)
        case chipMoreNew:
            r.novelty = q.novelty == familiar ? anyWord : q.novelty
            r.noveltySharePct = clampInt(shareOf(q) + shareStep, 0, 100)
        case chipMoreFamiliar:
            r.novelty = q.novelty == new ? anyWord : q.novelty
            r.noveltySharePct = clampInt(shareOf(q) - shareStep, 0, 100)
        case chipSlower:
            switch q.tempo {
            case fast: r.tempo = mid
            case mid: r.tempo = slow
            default: r.tempo = slow
            }
        case chipFaster:
            switch q.tempo {
            case slow: r.tempo = mid
            case mid: r.tempo = fast
            default: r.tempo = fast
            }
        case chipLowerEnergy: r.energy = q.energy == higher ? anyWord : lower
        case chipHigherEnergy: r.energy = q.energy == lower ? anyWord : higher
        default: return q
        }
        return r
    }

    private static func shareOf(_ q: Query) -> Int { q.noveltySharePct >= 0 ? q.noveltySharePct : shareBase }

    /// The chips offered under a mix card: "Less [top artist]", "More [top genre]" and a length chip, in that order, each only when it
    /// can change something. `topArtistRef` and `topGenreId` come from the mix's own tracks (what it has most of); "" and 0 mean unknown.
    public static func chipsFor(_ q: Query, topArtistRef: String, topGenreId: Int) -> [Chip] {
        var out: [Chip] = []
        if let ref = parseRef(topArtistRef)?.text, !has(q.excludeArtistRefs, ref) { out.append(Chip(kind: chipLessArtist, ref: ref)) }
        if topGenreId > 0 && !q.genreIds.contains(topGenreId) { out.append(Chip(kind: chipMoreGenre, genreId: topGenreId)) }
        out.append(q.count > minMix ? Chip(kind: chipShorter) : Chip(kind: chipLonger))
        return out
    }

    // MARK: Factors: what explain_track may say (9.3)

    /// One reason a pick scored the way it did: a name from `factorNames`, and whether it pushed the pick up or down.
    public struct Factor: Sendable, Equatable {
        public let name: String
        public let up: Bool

        public init(name: String, up: Bool) {
            self.name = name
            self.up = up
        }
    }

    /// The fixed names `explain_track` uses for the features of 5.8 (index = feature). A feature with no name here is never reported:
    /// it is either not computed yet or says nothing a listener could use. No raw weight and no raw value leaves the device.
    public static let factorNames: [String?] = {
        var n = [String?](repeating: nil, count: Ranker.d)
        n[1] = "you have played this track before"
        n[2] = "you play this artist"
        n[3] = "you have been playing this artist lately"
        n[4] = "its genres match what you play"
        n[5] = "it fits one of your taste islands"
        n[6] = "it fits a large part of what you play"
        n[8] = "it is one of your liked songs"
        n[10] = "it is about due for a repeat"
        n[11] = "you have played it a lot lately"
        n[12] = "you played it in the last two hours"
        n[13] = "you played it in the last day"
        n[14] = "you played it in the last week"
        n[15] = "you played it in the last month"
        n[16] = "you have not played it for a while"
        n[17] = "you have never played this track"
        n[18] = "you have never played this artist"
        n[19] = "it is far from what you usually play"
        n[20] = "it is popular"
        n[22] = "it is close to tracks you just finished"
        n[23] = "it is close to tracks you just skipped"
        n[24] = "its genres are ones you just skipped"
        n[25] = "you finished the track before it"
        n[26] = "you have been skipping"
        n[36] = "this kind of pick has worked for you"
        n[37] = "it ranks high in the related lists"
        n[38] = "it is near the top of the radio list"
        n[39] = "it is a new release"
        return n
    }()

    /// The words of an affinity feature (1, 2, 3, 4, 36) when its value is NEGATIVE: the listener skips this artist, they do not play it. An
    /// affinity runs from -3 to 3, so a negative one needs its own sentence; a feature with no entry here has no negative form and a negative
    /// value is read as its ordinary name (only the affinities can be negative).
    public static let negativeNames: [String?] = {
        var n = [String?](repeating: nil, count: Ranker.d)
        n[1] = "you have skipped this track before"
        n[2] = "you often skip this artist"
        n[3] = "you have been skipping this artist lately"
        n[4] = "its genres match what you skip"
        n[36] = "this kind of pick has not worked for you"
        return n
    }()

    /// A factor is reported when its contribution is at least this far from 0.
    public static let factorMin = 0.05

    public static let factorsShown = 3

    /// The factors that moved `x` the most under the weights `w`: contribution `w_i * x_i` for every named feature, largest absolute value
    /// first, ties by the lower index; at most `factorsShown`, none below `factorMin`. `up` is the sign of the contribution.
    public static func topFactors(_ x: [Double], _ w: [Double]) -> [Factor] {
        var idx: [Int] = []
        var contrib = [Double](repeating: 0.0, count: Ranker.d)
        for i in 1..<Ranker.d {
            if factorNames[i] == nil { continue }
            let c = w[i] * x[i]
            // A negative affinity with a positive weight is a reason it was held back, said as a skip. With a negative weight the product is
            // positive and "you skip this artist" would read as a reason in its favour: such a factor is not reported.
            if negativeNames[i] != nil && x[i] < 0.0 && c > 0.0 { continue }
            contrib[i] = c
            let a = c < 0.0 ? -c : c
            if a >= factorMin { idx.append(i) }
        }
        // Selection of the largest |c|; indexes are visited in ascending order, so a tie keeps the lower index.
        var out: [Factor] = []
        var taken = [Bool](repeating: false, count: Ranker.d)
        while out.count < factorsShown {
            var best = -1
            var bestAbs = 0.0
            for i in idx {
                if taken[i] { continue }
                let a = contrib[i] < 0.0 ? -contrib[i] : contrib[i]
                if best < 0 || a > bestAbs {
                    best = i
                    bestAbs = a
                }
            }
            if best < 0 { break }
            taken[best] = true
            let negative = negativeNames[best] != nil && x[best] < 0.0
            out.append(Factor(name: negative ? negativeNames[best]! : factorNames[best]!, up: contrib[best] > 0.0))
        }
        return out
    }
}
