// The ten music tools of Ask Taizo (docs/brain-spec.md, 9.3): a tool call in, the JSON the model reads out, over a `MusicBackend`.
//
// The assistant never ranks and never invents a track. Every track in a result comes from the backend (the engine, the alias table, a
// search) and is noted in `grounding` as it is returned, so the reply check can tell a returned name from an invented one; a ref the model
// passes that no tool issued in this conversation is refused and reported, never guessed at. Results are capped (25 by default), carry refs
// the next call can use, and say what they do not know instead of leaving it out. Mirrors Android's `TaizoMusicTools.kt`.
//
// Pure of the app: tested with a fake backend (`MusicToolRunnerTests`).

import Foundation
import PixlFoundation
import PixlModel

/// Runs the ten music tools.
public actor MusicToolRunner {
    /// Network lookups one turn may start (the YouTube budget of the day is smaller still, and the backend enforces it).
    public static let maxLookupsPerTurn = 40

    private let backend: any MusicBackend
    public nonisolated let grounding: TaizoGrounding

    /// Names looked up on the network in the turn that is running: a runaway loop cannot spend the day's YouTube requests.
    private var lookedUpThisTurn = 0

    /// Lookups the backend skipped in this turn because the day's budget was spent (the model is told, not left to retry).
    public private(set) var budgetSpentThisTurn = false

    public init(backend: any MusicBackend, grounding: TaizoGrounding) {
        self.backend = backend
        self.grounding = grounding
    }

    public func beginTurn() {
        lookedUpThisTurn = 0
        budgetSpentThisTurn = false
        named.removeAll()
        newCardIds.removeAll()
    }

    // MARK: Cards under the answer (docs/brain-spec.md, 9.3 "What the listener gets"): no model call behind any of these

    /// Mixes kept so their cards can still play, save and change.
    public static let maxMixes = 16

    private var builtMixes: [String: AssistantMix] = [:]
    private var mixOrder: [String] = []
    /// Mixes `build_mix` made in this turn whose card has not been taken yet.
    private var newCardIds: [String] = []
    /// The genres and artists the explain tools of this turn returned (for the one-tap "Less X").
    private var named: [AssistantCards.Named] = []

    private func remember(_ mix: AssistantMix) {
        builtMixes[mix.mixId] = mix
        mixOrder.removeAll { $0 == mix.mixId }
        mixOrder.append(mix.mixId)
        while mixOrder.count > Self.maxMixes { builtMixes[mixOrder.removeFirst()] = nil }
    }

    /// The cards of the mixes `build_mix` made since the last call, in order (the chat shows them under the answer).
    public func takeNewMixCards() -> [MixCard] {
        let ids = newCardIds
        newCardIds.removeAll()
        return ids.compactMap { builtMixes[$0] }.map(MixCard.of)
    }

    /// The card of a mix this chat built, or nil.
    public func mixCard(_ mixId: String) -> MixCard? { builtMixes[mixId].map(MixCard.of) }

    /// The title of a mix this chat built ("Made for you" for any other id): the name a saved playlist gets.
    public func mixTitle(_ mixId: String) -> String {
        let t = builtMixes[mixId]?.title ?? ""
        return BrainText.isBlank(t) ? "Made for you" : t
    }

    /// A chip tapped under a card: the stored request with that delta, built again by the engine. No model call, no tool call of the
    /// conversation: the tracks it returns are noted as held, so a reply that names one is not an invented name. Nil when the engine had
    /// nothing to build or the mix is not this chat's.
    public func adjustMix(mixId: String, chip: AssistantRules.Chip) async -> MixCard? {
        guard let next = await backend.adjustMix(mixId: mixId, chip: chip) else { return nil }
        for p in next.tracks { notePick(p) }
        grounding.noteName(next.title)
        // The card takes the new list in place of the old one: the old record goes, so chips never push another card out.
        builtMixes[mixId] = nil
        mixOrder.removeAll { $0 == mixId }
        remember(next)
        return MixCard.of(next)
    }

    /// The genres and artists the explain tools of this turn returned; the chat offers "Less X" only for one of these that the listener asked about.
    public func namedThisTurn() -> [AssistantCards.Named] { named }

    private func noteNamed(_ kind: Int, _ raw: String) {
        let n = BrainText.trim(raw)
        if n.isEmpty { return }
        if !named.contains(where: { $0.kind == kind && $0.name == n }) { named.append(AssistantCards.Named(kind: kind, name: n)) }
    }

    /// True for the ten music tools.
    public nonisolated static func handles(_ name: String) -> Bool { AssistantVocabulary.musicToolNames.contains(name) }

    /// Runs one call and returns the JSON text the model reads.
    public func run(_ name: String, _ input: JSONObject) async -> String {
        let result: JSONValue
        switch name {
        case AssistantVocabulary.resolveTracks: result = await resolveTracks(input)
        case AssistantVocabulary.recommend: result = await recommend(input)
        case AssistantVocabulary.buildMix: result = await buildMix(input)
        case AssistantVocabulary.startStation: result = await startStation(input)
        case AssistantVocabulary.steerSession: result = await steer(input)
        case AssistantVocabulary.explainTrack: result = await explainTrack(input)
        case AssistantVocabulary.explainTaste: result = await explainTaste(input)
        case AssistantVocabulary.lookupGenre: result = await lookupGenre(input)
        case AssistantVocabulary.similarArtists: result = await similarArtists(input)
        case AssistantVocabulary.newReleases: result = await newReleases(input)
        default: return JSONWriter.write(Self.obj([("error", .string("Unknown tool: \(name)"))]))
        }
        // Every name and number in the result is something the reply may say: noted here, so the rule holds wherever the tools run.
        let text = JSONWriter.write(result)
        grounding.noteToolResult(text)
        return text
    }

    // MARK: resolve_tracks

    private func resolveTracks(_ input: JSONObject) async -> JSONValue {
        var asked: [(title: String, artist: String)] = []
        for item in JSONValue.object(input)["items"]?.arrayValue ?? [] {
            guard let o = item.objectValue else { continue }
            asked.append((BrainText.trim(Self.str(o, "title") ?? ""), BrainText.trim(Self.str(o, "artist") ?? "")))
        }
        let wanted = Array(asked.prefix(AssistantRules.maxResolveItems))
        // The network part of a turn is bounded: past the cap an item is skipped, not looked up (the alias table and library are free).
        let room = max(Self.maxLookupsPerTurn - lookedUpThisTurn, 0)
        let allowed = wanted.prefix(room).filter { !$0.title.isEmpty }
        let looked = allowed.isEmpty ? [] : await backend.resolve(Array(allowed))
        lookedUpThisTurn += allowed.count
        var byItem: [String: AssistantLookup] = [:]
        for i in allowed.indices {
            let key = allowed[i].title + "\u{0}" + allowed[i].artist
            if byItem[key] == nil { byItem[key] = i - allowed.startIndex < looked.count ? looked[i - allowed.startIndex] : AssistantLookup(track: nil) }
        }
        var found = 0
        var results: [JSONValue] = []
        for (index, item) in wanted.enumerated() {
            var members: [(String, JSONValue)] = [("index", .integer(index))]
            let lookup = item.title.isEmpty
                ? AssistantLookup(track: nil)
                : (byItem[item.title + "\u{0}" + item.artist] ?? AssistantLookup(track: nil, skipped: true))
            if let track = lookup.track {
                found += 1
                grounding.noteTrack(track)
                members += Self.trackMembers(track)
            } else {
                members.append(("not_found", .bool(true)))
                if lookup.failed {
                    members.append(("reason", .string("the search could not be made (no connection or a failed request): this does not mean the song does not exist")))
                } else if lookup.skipped {
                    budgetSpentThisTurn = true
                    members.append(("reason", .string("not looked up: PixlAudio's lookups for this chat or this day are used up")))
                }
            }
            results.append(Self.obj(members))
        }
        grounding.noteCount(found)
        grounding.noteCount(wanted.count)
        var out: [(String, JSONValue)] = [("results", .array(results))]
        if asked.count > wanted.count { out.append(("ignored_over_limit", .integer(asked.count - wanted.count))) }
        out.append(("note", .string("Use the refs in later calls. Drop every not_found item; do not name it as a recommendation.")))
        return Self.obj(out)
    }

    // MARK: recommend / build_mix

    private func recommend(_ input: JSONObject) async -> JSONValue {
        var unknown: [String] = []
        var unknownIds: [String] = []
        let seeds = grounding.known(Self.strings(input, "seed_refs"), &unknown)
        let query = AssistantRules.normalize(
            title: "", seedRefs: seeds, genreIds: grounding.knownGenreIds(Self.ints(input, "genre_ids"), &unknownIds), moodIds: [],
            yearFrom: Self.int(input, "year_from"), yearTo: Self.int(input, "year_to"), energy: Self.str(input, "energy"), tempo: nil,
            novelty: Self.str(input, "novelty"), noveltySharePct: -1, count: Self.int(input, "count"), excludeArtistRefs: [],
            minCount: 1, maxCount: AssistantRules.maxRecommend, defaultCount: AssistantRules.defaultResults)
        let rec = await backend.recommend(query)
        let picks = Array(rec.picks.prefix(query.count))
        for p in picks { notePick(p) }
        grounding.noteCount(picks.count)
        var out: [(String, JSONValue)] = [("picks", .array(picks.map(Self.pickJson))), ("count", .integer(picks.count))]
        out += Self.filterMembers(rec.unsupportedFilters)
        out += Self.seedsNotUsedMembers(rec.seedsNotUsed)
        if rec.coldStart {
            out.append(("note", .string("PixlAudio has little of the listener's history yet; these follow the radios' own order, not their taste.")))
        }
        out += Self.unknownRefMembers(unknown)
        out += Self.unknownIdMembers(unknownIds)
        return Self.obj(out)
    }

    private func buildMix(_ input: JSONObject) async -> JSONValue {
        var unknown: [String] = []
        var unknownIds: [String] = []
        let seeds = grounding.known(Self.strings(input, "seed_refs"), &unknown)
        let excluded = grounding.known(Self.strings(input, "exclude_artist_refs"), &unknown)
        let query = AssistantRules.normalize(
            title: Self.str(input, "title"), seedRefs: seeds, genreIds: grounding.knownGenreIds(Self.ints(input, "genre_ids"), &unknownIds),
            moodIds: grounding.knownMoodIds(Self.ints(input, "mood_ids"), &unknownIds),
            yearFrom: Self.int(input, "year_from"), yearTo: Self.int(input, "year_to"), energy: Self.str(input, "energy"),
            tempo: Self.str(input, "tempo"), novelty: nil, noveltySharePct: Self.intOr(input, "novelty_share_pct", -1),
            count: Self.intOr(input, "length", AssistantRules.defaultMix), excludeArtistRefs: excluded, minCount: AssistantRules.minMix,
            maxCount: AssistantRules.maxMix, defaultCount: AssistantRules.defaultMix)
        guard let mix = await backend.buildMix(query) else {
            var out: [(String, JSONValue)] = [
                ("built", .bool(false)),
                ("note", .string("PixlAudio has nothing to build this from yet (no songs and no cached radios). Say so; do not make a list yourself.")),
            ]
            out += Self.unknownRefMembers(unknown)
            out += Self.unknownIdMembers(unknownIds)
            return Self.obj(out)
        }
        remember(mix)
        newCardIds.append(mix.mixId)
        var out = mixMembers(mix)
        out += Self.unknownRefMembers(unknown)
        out += Self.unknownIdMembers(unknownIds)
        return Self.obj(out)
    }

    private func mixMembers(_ mix: AssistantMix) -> [(String, JSONValue)] {
        for p in mix.tracks { notePick(p) }
        let shown = Array(mix.tracks.prefix(AssistantRules.defaultResults))
        grounding.noteCount(mix.tracks.count)
        grounding.noteCount(shown.count)
        var out: [(String, JSONValue)] = [
            ("built", .bool(true)), ("mix_id", .string(mix.mixId)), ("title", .string(mix.title)),
            ("total", .integer(mix.tracks.count)), ("tracks", .array(shown.map(Self.pickJson))),
        ]
        out += Self.filterMembers(mix.unsupportedFilters)
        out += Self.seedsNotUsedMembers(mix.seedsNotUsed)
        out.append(("note", .string("The app shows this mix as a card with Play and Save. To play it from chat, call play_songs with song_ids [\"mix:\(mix.mixId)\"].")))
        return out
    }

    // MARK: start_station / steer_session

    private func startStation(_ input: JSONObject) async -> JSONValue {
        let kind = Self.str(input, "seed_kind") ?? ""
        let seed = BrainText.trim(Self.str(input, "seed_ref") ?? "")
        if seed.isEmpty { return Self.failed("started", "seed_ref is empty.") }
        if kind == "song" && !grounding.isKnownRef(seed) && AssistantRules.parseRef(seed) != nil {
            return Self.failed("started", "That ref was not returned by a tool in this chat. Call resolve_tracks first.")
        }
        if kind == "song" && AssistantRules.parseRef(seed) == nil {
            return Self.failed("started", "A song seed must be a ref (sp:<id> or yt:<id>) from resolve_tracks.")
        }
        let outcome = await backend.startStation(seedRef: seed, seedKind: kind, mode: Self.str(input, "mode") ?? "")
        var out: [(String, JSONValue)] = [("started", .bool(outcome.started))]
        if let first = outcome.firstTrack {
            grounding.noteTrack(first)
            out.append(("first_track", Self.obj(Self.trackMembers(first))))
        }
        if !outcome.started && !outcome.reason.isEmpty { out.append(("reason", .string(outcome.reason))) }
        if !outcome.note.isEmpty { out.append(("note", .string(outcome.note))) }
        return Self.obj(out)
    }

    private func steer(_ input: JSONObject) async -> JSONValue {
        let change = Self.str(input, "change") ?? ""
        let target = BrainText.trim(Self.str(input, "target") ?? "")
        if AssistantRules.parseRef(target) != nil && !grounding.isKnownRef(target) {
            return Self.obj([("applied", .bool(false)), ("tail_changed", .integer(0)),
                             ("note", .string("That ref was not returned by a tool in this chat. Call resolve_tracks first."))])
        }
        if change.hasSuffix("_genre") {
            // A genre is changed by an id lookup_genre returned in this chat, never by one written from memory.
            guard let id = Int(target), id > 0, grounding.genreName(id) != nil else {
                return Self.obj([("applied", .bool(false)), ("tail_changed", .integer(0)),
                                 ("note", .string("That is not a genre id lookup_genre returned in this chat, so nothing was changed. Call lookup_genre first."))])
            }
        }
        let outcome = await backend.steer(change: change, target: target, scope: Self.str(input, "scope") ?? "")
        grounding.noteCount(outcome.tailChanged)
        var out: [(String, JSONValue)] = [("applied", .bool(outcome.applied)), ("tail_changed", .integer(outcome.tailChanged))]
        if !outcome.note.isEmpty { out.append(("note", .string(outcome.note))) }
        return Self.obj(out)
    }

    // MARK: explain_track / explain_taste

    private func explainTrack(_ input: JSONObject) async -> JSONValue {
        let ref = BrainText.trim(Self.str(input, "ref") ?? "")
        if AssistantRules.parseRef(ref) != nil && !grounding.isKnownRef(ref) {
            return Self.obj([("found", .bool(false)),
                             ("note", .string("That ref was not returned by a tool in this chat. Call resolve_tracks first; do not guess why."))])
        }
        guard let e = await backend.explainTrack(ref: ref) else {
            return Self.obj([("found", .bool(false)),
                             ("note", .string("PixlAudio has nothing recorded about that track. Say you can't tell why; do not guess."))])
        }
        grounding.noteName(e.title)
        grounding.noteArtists(e.artist)
        for a in e.whyArgs { grounding.noteName(a) }
        // The credited primary artist, not a comma split of the display line ("Tyler, The Creator" is one artist).
        noteNamed(AssistantCards.namedArtist, BrainText.isBlank(e.primaryArtist) ? (TaizoGrounding.splitCredits(e.artist).first ?? e.artist) : e.primaryArtist)
        for g in e.genres ?? [] { noteNamed(AssistantCards.namedGenre, g) }
        var unknown: [String] = []
        var out: [(String, JSONValue)] = [
            ("found", .bool(true)), ("ref", .string(e.ref)), ("title", .string(e.title)), ("artist", .string(e.artist)),
        ]
        if let arm = e.arm { out.append(("arm", .string(arm))) } else { unknown.append("arm") }
        if let why = e.whyKey, !why.isEmpty {
            out.append(("why_key", .string(why)))
            out.append(("why_args", .array(e.whyArgs.map { .string($0) })))
        } else {
            unknown.append("why")
        }
        if let factors = e.factors, !factors.isEmpty {
            out.append(("top_factors", .array(factors.map { Self.obj([("name", .string($0.name)), ("direction", .string($0.up ? "up" : "down"))]) })))
            out.append(("factors_note", .string("Read the way the engine ranks today, from the vector the pick was served with; say it is \"as the engine ranks today\".")))
        } else {
            unknown.append("top_factors")
        }
        var facts: [(String, JSONValue)] = []
        if let genres = e.genres {
            for g in genres { grounding.noteName(g) }
            facts.append(("genres", .array(genres.map { .string($0) })))
            if e.genresSuggested {
                facts.append(("genres_note", .string("These genres were suggested by the assistant for a song no source knew; say they are a suggestion, not a fact.")))
            }
        } else {
            unknown.append("genres")
        }
        if e.year > 0 { facts.append(("year", .integer(e.year))) } else { unknown.append("year") }
        if let plays = e.plays {
            facts.append(("plays", .integer(plays)))
            grounding.noteCount(plays)
        } else {
            unknown.append("plays")
        }
        if let rate = e.completionRate {
            facts.append(("completion_rate_pct", .integer(Int(rate * 100.0 + 0.5))))
        } else {
            unknown.append("completion_rate")
        }
        out.append(("facts", Self.obj(facts)))
        out.append(("unknown", .array(unknown.map { .string($0) })))
        out.append(("note", .string("Report only these fields. Anything in unknown is unknown: say so.")))
        return Self.obj(out)
    }

    private func explainTaste(_ input: JSONObject) async -> JSONValue {
        let scope = AssistantRules.oneOf(Self.str(input, "scope"), AssistantRules.explainScopes, "summary")
        let t = await backend.explainTaste(scope: scope)
        for line in t.lines {
            grounding.noteName(line.name)
            grounding.noteName(line.value)
            if !line.detail.isEmpty { grounding.noteName(line.detail) }
            // A genre the answer states is something "Less X" can be about.
            if line.isGenre { noteNamed(AssistantCards.namedGenre, line.name) }
        }
        let facts: [JSONValue] = t.lines.map { l in
            var m: [(String, JSONValue)] = [("name", .string(l.name)), ("value", .string(l.value))]
            if !l.detail.isEmpty { m.append(("detail", .string(l.detail))) }
            return Self.obj(m)
        }
        return Self.obj([
            ("scope", .string(t.scope)), ("facts", .array(facts)), ("unknown", .array(t.unknown.map { .string($0) })),
            ("note", .string("Report only these facts, with these numbers. Anything in unknown is unknown: say so.")),
        ])
    }

    // MARK: lookup_genre / similar_artists / new_releases

    private func lookupGenre(_ input: JSONObject) async -> JSONValue {
        let r = await backend.lookupGenre(BrainText.trim(Self.str(input, "query") ?? ""))
        guard let g = r.genre else {
            for n in r.nearest { grounding.noteName(n.name) }
            return Self.obj([
                ("found", .bool(false)), ("nearest", .array(r.nearest.map(Self.refJson))),
                ("note", .string("Not in the genre atlas. Use one of the nearest ids, or say it is not there; do not invent an id.")),
            ])
        }
        grounding.noteName(g.name)
        for x in g.parents + g.children + g.related + g.influences { grounding.noteName(x.name) }
        for d in g.descriptors { grounding.noteName(d) }
        grounding.noteName(g.region)
        let cap = AssistantRules.defaultResults
        var out: [(String, JSONValue)] = [
            ("found", .bool(true)), ("kind", .string(g.isMood ? "mood" : "genre")), ("id", .integer(g.id)), ("name", .string(g.name)),
        ]
        if !g.description.isEmpty { out.append(("description", .string(g.description))) }
        out.append(("parents", .array(g.parents.map(Self.refJson))))
        out.append(("children", .array(g.children.prefix(cap).map(Self.refJson))))
        out.append(("related", .array(g.related.prefix(cap).map(Self.refJson))))
        out.append(("influences", .array(g.influences.prefix(cap).map(Self.refJson))))
        if !g.region.isEmpty { out.append(("region", .string(g.region))) }
        if g.era > 0 { out.append(("era", .integer(g.era))) }
        if !g.descriptors.isEmpty { out.append(("descriptors", .array(g.descriptors.map { .string($0) }))) }
        return Self.obj(out)
    }

    private func similarArtists(_ input: JSONObject) async -> JSONValue {
        let count = AssistantRules.clampInt(Self.intOr(input, "count", AssistantRules.defaultResults), 1, AssistantRules.defaultResults)
        let r = await backend.similarArtists(artist: BrainText.trim(Self.str(input, "artist") ?? ""), count: count,
                                             onlyUnplayed: JSONValue.object(input)["only_unplayed"]?.boolValue == true)
        let artists = Array(r.artists.prefix(count))
        for a in artists { grounding.noteName(a.name) }
        grounding.noteCount(artists.count)
        let rows: [JSONValue] = artists.enumerated().map { index, a in
            var m: [(String, JSONValue)] = [("name", .string(a.name))]
            if !a.ref.isEmpty { m.append(("ref", .string(a.ref))) }
            // A position, not a percentage: the closest one found is always first, and its edge may be a weak one.
            m.append(("rank", .integer(index + 1)))
            m.append(("sources", .array(a.sources.map { .string($0) })))
            return Self.obj(m)
        }
        var out: [(String, JSONValue)] = [("artists", .array(rows))]
        if !r.note.isEmpty { out.append(("note", .string(r.note))) }
        return Self.obj(out)
    }

    private func newReleases(_ input: JSONObject) async -> JSONValue {
        let count = AssistantRules.clampInt(Self.intOr(input, "count", AssistantRules.defaultResults), 1, AssistantRules.defaultResults)
        let scope = AssistantRules.oneOf(Self.str(input, "scope"), AssistantRules.releaseScopes, "my_artists")
        let r = await backend.newReleases(scope: scope, count: count)
        let releases = Array(r.releases.prefix(count))
        for x in releases {
            grounding.noteName(x.title)
            grounding.noteArtists(x.artist)
        }
        grounding.noteCount(releases.count)
        let rows: [JSONValue] = releases.map { x in
            var m: [(String, JSONValue)] = [("title", .string(x.title)), ("artist", .string(x.artist)), ("type", .string(x.type))]
            if x.year > 0 { m.append(("year", .integer(x.year))) }
            if !x.ref.isEmpty { m.append(("ref", .string(x.ref))) }
            return Self.obj(m)
        }
        var out: [(String, JSONValue)] = [("scope", .string(scope)), ("releases", .array(rows))]
        if !r.note.isEmpty { out.append(("note", .string(r.note))) }
        return Self.obj(out)
    }

    // MARK: Shared pieces

    private func notePick(_ p: AssistantPick) {
        grounding.noteTrack(p.track)
        for a in p.whyArgs { grounding.noteName(a) }
    }

    nonisolated static func pickJson(_ p: AssistantPick) -> JSONValue {
        var m = trackMembers(p.track)
        if !p.whyKey.isEmpty {
            m.append(("why_key", .string(p.whyKey)))
            m.append(("why_args", .array(p.whyArgs.map { .string($0) })))
        }
        return obj(m)
    }

    nonisolated static func trackMembers(_ t: AssistantTrack) -> [(String, JSONValue)] {
        var m: [(String, JSONValue)] = [("ref", .string(t.ref)), ("title", .string(t.title)), ("artist", .string(t.artist))]
        if t.year > 0 { m.append(("year", .integer(t.year))) }
        m.append(("in_library", .bool(t.inLibrary)))
        return m
    }

    nonisolated static func refJson(_ g: AssistantGenreRef) -> JSONValue { obj([("id", .integer(g.id)), ("name", .string(g.name))]) }

    nonisolated static func filterMembers(_ unsupported: [String]) -> [(String, JSONValue)] {
        if unsupported.isEmpty { return [] }
        return [("filters_not_applied", .array(unsupported.map { .string($0) })),
                ("filters_note", .string("PixlAudio has no data for these filters yet, so they were not applied. Tell the user."))]
    }

    nonisolated static func seedsNotUsedMembers(_ refs: [String]) -> [(String, JSONValue)] {
        if refs.isEmpty { return [] }
        return [("seeds_not_used", .array(refs.map { .string($0) })),
                ("seeds_note", .string("PixlAudio could not get songs similar to these seeds right now (offline, or today's lookups are used up), so the picks do not follow them. Tell the user; do not say the list is like them."))]
    }

    nonisolated static func unknownIdMembers(_ unknown: [String]) -> [(String, JSONValue)] {
        if unknown.isEmpty { return [] }
        return [("ids_ignored", .array(unknown.map { .string($0) })),
                ("ids_note", .string("These genre or mood ids were not returned by lookup_genre in this chat, so they were left out. Call lookup_genre for the id first."))]
    }

    nonisolated static func unknownRefMembers(_ unknown: [String]) -> [(String, JSONValue)] {
        if unknown.isEmpty { return [] }
        return [("refs_ignored", .array(unknown.map { .string($0) })),
                ("refs_note", .string("These refs were not returned by a tool in this chat, so they were left out."))]
    }

    nonisolated static func failed(_ key: String, _ reason: String) -> JSONValue { obj([(key, .bool(false)), ("reason", .string(reason))]) }

    nonisolated static func obj(_ members: [(String, JSONValue)]) -> JSONValue {
        .object(JSONObject(members.map { (key: $0.0, value: $0.1) }))
    }

    // MARK: Reading the input (a missing or wrongly typed value reads as absent)

    nonisolated static func str(_ o: JSONObject, _ key: String) -> String? { o[key]?.stringValue }

    nonisolated static func int(_ o: JSONObject, _ key: String) -> Int { intOr(o, key, 0) }

    nonisolated static func intOr(_ o: JSONObject, _ key: String, _ fallback: Int) -> Int {
        guard let v = o[key]?.int64Value else { return fallback }
        return Int(clamping: v)
    }

    nonisolated static func strings(_ o: JSONObject, _ key: String) -> [String] {
        (o[key]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    nonisolated static func ints(_ o: JSONObject, _ key: String) -> [Int] {
        (o[key]?.arrayValue ?? []).compactMap { $0.int64Value.map { Int(clamping: $0) } }
    }
}
