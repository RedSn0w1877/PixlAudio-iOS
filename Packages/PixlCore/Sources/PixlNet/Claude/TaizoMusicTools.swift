// The ten music tools of Ask Taizo (docs/brain-spec.md, 9.3, stage 4): resolve_tracks, recommend, build_mix, start_station,
// steer_session, explain_track, explain_taste, lookup_genre, similar_artists, new_releases. The schemas, their order and their wording
// mirror Android's `TaizoTools` (the tool list is the front of the cached prompt on both apps).
//
// Rules held here: appended after the 16 older tools in this order, never reordered; every object closed (`additionalProperties: false`);
// EVERY parameter required, and "no value" is an explicit sentinel (`[]`, `0`, `""`, `"any"`, and -1 for `novelty_share_pct`), so none of
// the 24 optional parameters a strict grammar allows is spent. Only five of the ten are `strict` (a request holds at most 20 strict
// tools and 15 of the older 16 already are: deviation 222); the other five are closed and fully required too, and their input is
// validated locally against the same schema before anything runs. The assistant never ranks and never invents a track: these tools turn
// a sentence into a structured request and the engine fills it.

import Foundation
import PixlFoundation
import PixlModel

extension TaizoTool {
    /// The music tools, in the order they are sent after the 16 older ones.
    public static let music: [TaizoTool] = [
        .resolveTracks, .recommend, .buildMix, .startStation, .steerSession,
        .explainTrack, .explainTaste, .lookupGenre, .similarArtists, .newReleases,
    ]

    /// True for the ten music tools.
    public var isMusicTool: Bool { Self.music.contains(self) }

    /// The schema and wording of a music tool. Never called for an older tool.
    var musicDefinition: ClaudeToolDefinition {
        typealias V = AssistantVocabulary
        let nonStrict = V.nonStrictMusicTools.contains(rawValue)
        switch self {
        case .resolveTracks:
            return ClaudeToolDefinition(
                name: rawValue,
                description: "Look up tracks you know by name, to get refs (sp:<id> or yt:<id>) the other tools take. Call this "
                    + "before you put any song you thought of yourself in a mix, a station or a reply: drop whatever comes back "
                    + "not_found. Results are in the order given, up to \(V.maxResolveItems). Use \"\" for an artist you don't know.",
                inputSchema: Schema.object([
                    ("items", Schema.arrayOfObjects(Schema.object([
                        ("title", Schema.string("The track's title.")),
                        ("artist", Schema.string("Its artist, or \"\" when unknown.")),
                    ], required: ["title", "artist"]), "The tracks to look up, up to \(V.maxResolveItems).")),
                ], required: ["items"]),
                strict: !nonStrict)
        case .recommend:
            return ClaudeToolDefinition(
                name: rawValue,
                description: "Picks for the user from PixlAudio's own engine (their taste, the radios, new music), filtered by what "
                    + "you pass. Do not rank or reorder the result. Genre ids come from lookup_genre; seed refs come from "
                    + "resolve_tracks or earlier results. Sentinels: [] for no seeds or genres, 0 for no year bound, \"any\" for no preference.",
                inputSchema: Schema.object([
                    ("seed_refs", Schema.stringArray("Refs of tracks the picks should be close to, up to \(V.maxSeedRefs), or [].")),
                    ("genre_ids", Schema.integerArray("Genre ids from lookup_genre; a pick passes when it has any of them, or [].")),
                    ("year_from", Schema.integer("Only music from this year on, or 0.")),
                    ("year_to", Schema.integer("Only music up to this year, or 0.")),
                    ("energy", Schema.enumeration(V.energy, "Calmer or livelier than the seeds, or any.")),
                    ("novelty", Schema.enumeration(V.novelty, "familiar = music they already know, new = music they have not played, or any.")),
                    ("count", Schema.integer("How many picks, 1-\(V.maxRecommend).")),
                ], required: ["seed_refs", "genre_ids", "year_from", "year_to", "energy", "novelty", "count"]),
                strict: !nonStrict)
        case .buildMix:
            return ClaudeToolDefinition(
                name: rawValue,
                description: "Build a saved mix from a request, e.g. \"something like Espresso but slower for a late drive\". The "
                    + "engine fills it; you do not pick tracks. The app shows it as a card with Play and Save. Genre and mood ids "
                    + "come from lookup_genre; seed refs from resolve_tracks. Sentinels: [] for none, 0 for no year bound, \"any\" "
                    + "for no preference, -1 for novelty_share_pct when the user did not say (0 means no new music at all).",
                inputSchema: Schema.object([
                    ("title", Schema.string("A short name for the mix, in the user's words, up to \(V.maxTitle) characters.")),
                    ("seed_refs", Schema.stringArray("Refs of tracks the mix should be close to, up to \(V.maxSeedRefs), or [].")),
                    ("genre_ids", Schema.integerArray("Genre ids from lookup_genre, or [].")),
                    ("mood_ids", Schema.integerArray("Mood ids from lookup_genre, or [].")),
                    ("year_from", Schema.integer("Only music from this year on, or 0.")),
                    ("year_to", Schema.integer("Only music up to this year, or 0.")),
                    ("energy", Schema.enumeration(V.energy, "Calmer or livelier than the seeds, or any.")),
                    ("tempo", Schema.enumeration(V.tempo, "slow, mid or fast, or any.")),
                    ("novelty_share_pct", Schema.integer("Share of new music, 0-100, or -1 when not said.")),
                    ("length", Schema.integer("How many songs, \(V.minMix)-\(V.maxMix).")),
                    ("exclude_artist_refs", Schema.stringArray("Refs of artists to leave out, or [].")),
                ], required: ["title", "seed_refs", "genre_ids", "mood_ids", "year_from", "year_to", "energy", "tempo",
                              "novelty_share_pct", "length", "exclude_artist_refs"]),
                strict: !nonStrict)
        case .startStation:
            return ClaudeToolDefinition(
                name: rawValue,
                description: "Start an endless station from a seed and play it now. The app may ask the user to confirm replacing their queue.",
                inputSchema: Schema.object([
                    ("seed_ref", Schema.string("A track ref (sp:<id> or yt:<id>) for song, an artist name for artist, a genre id for genre, "
                        + "or the name for album and playlist.")),
                    ("seed_kind", Schema.enumeration(V.seedKinds, "What the seed is.")),
                    ("mode", Schema.enumeration(V.stationModes, "familiar = mostly what they know, blend, discover = mostly new.")),
                ], required: ["seed_ref", "seed_kind", "mode"]),
                strict: !nonStrict)
        case .steerSession:
            return ClaudeToolDefinition(
                name: rawValue,
                description: "Change what plays next in the current queue, or (scope always) what PixlAudio recommends from now on. "
                    + "Only when the user asked for it in their latest message. scope always asks the user to confirm.",
                inputSchema: Schema.object([
                    ("change", Schema.enumeration(V.steerChanges, "What to change.")),
                    ("target", Schema.string("A ref or an artist name for the artist changes, a genre id for the genre changes, otherwise \"\".")),
                    ("scope", Schema.enumeration(V.steerScopes, "session = this queue only, always = a lasting taste change.")),
                ], required: ["change", "target", "scope"]),
                strict: !nonStrict)
        case .explainTrack:
            return ClaudeToolDefinition(
                name: rawValue,
                description: "Why a pick was served: the arm, the reason line, the strongest factors (names only, no weights) and facts "
                    + "(genres, year, plays, completion rate). Report only what it returns; a field listed in unknown is unknown.",
                inputSchema: Schema.object([
                    ("ref", Schema.string("The track's ref (sp:<id> or yt:<id>) from an earlier result, or \"now\" for the song playing.")),
                ], required: ["ref"]),
                strict: !nonStrict)
        case .explainTaste:
            return ClaudeToolDefinition(
                name: rawValue,
                description: "Part of the user's Your sound page: what their plays say, with real numbers, and what is not known yet. "
                    + "Call this for \"why do I keep getting X\" and \"what is my taste\". Report only what it returns.",
                inputSchema: Schema.object([
                    ("scope", Schema.enumeration(V.explainScopes, "Which part.")),
                ], required: ["scope"]),
                strict: !nonStrict)
        case .lookupGenre:
            return ClaudeToolDefinition(
                name: rawValue,
                description: "Look a genre or mood up in PixlAudio's genre atlas: id, description, parents, children, related, region, era. "
                    + "Use it to get ids for recommend and build_mix; never guess an id. A name it lacks returns the nearest names.",
                inputSchema: Schema.object([
                    ("query", Schema.string("A genre or mood name, or an id.")),
                ], required: ["query"]),
                strict: !nonStrict)
        case .similarArtists:
            return ClaudeToolDefinition(
                name: rawValue,
                description: "Artists close to one the user names, from the similarity graph PixlAudio built, with how sure it is.",
                inputSchema: Schema.object([
                    ("artist", Schema.string("The artist's name.")),
                    ("count", Schema.integer("How many, 1-\(V.defaultResults).")),
                    ("only_unplayed", Schema.boolean("True for only artists the user has not played.")),
                ], required: ["artist", "count", "only_unplayed"]),
                strict: !nonStrict)
        case .newReleases:
            return ClaudeToolDefinition(
                name: rawValue,
                description: "New releases PixlAudio has found for the user's artists (my_artists), for artists next to them (adjacent), "
                    + "or for their country (country). It only knows what its last refresh found.",
                inputSchema: Schema.object([
                    ("scope", Schema.enumeration(V.releaseScopes, "Whose releases.")),
                    ("count", Schema.integer("How many, 1-\(V.defaultResults).")),
                ], required: ["scope", "count"]),
                strict: !nonStrict)
        default:
            preconditionFailure("\(rawValue) is not a music tool")
        }
    }
}

extension TaizoTool.Schema {
    /// An array of integers.
    static func integerArray(_ description: String) -> JSONValue {
        ClaudeJSON.object([("type", .string("array")), ("items", ClaudeJSON.object([("type", .string("integer"))])),
                           ("description", .string(description))])
    }
}
