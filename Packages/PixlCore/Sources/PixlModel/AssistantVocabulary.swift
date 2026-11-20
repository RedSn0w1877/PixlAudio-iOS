// The words and limits Ask Taizo's ten music tools share (docs/brain-spec.md, 9.3, stage 4): the tool names, the enum values of their
// parameters and the sentinels. PixlNet builds the tool schemas from them and PixlLibrary's `AssistantRules` reads the requests with
// them, so the two cannot drift apart (the two modules cannot import each other). The values mirror Android's `AssistantRules`.

/// Shared vocabulary of the ten music tools.
public enum AssistantVocabulary {
    // MARK: Tool names, in the order they are sent (appended after the 16 older tools; never reordered)

    public static let resolveTracks = "resolve_tracks"
    public static let recommend = "recommend"
    public static let buildMix = "build_mix"
    public static let startStation = "start_station"
    public static let steerSession = "steer_session"
    public static let explainTrack = "explain_track"
    public static let explainTaste = "explain_taste"
    public static let lookupGenre = "lookup_genre"
    public static let similarArtists = "similar_artists"
    public static let newReleases = "new_releases"

    /// The ten music tools, in the order they are sent.
    public static let musicToolNames: [String] = [
        resolveTracks, recommend, buildMix, startStation, steerSession,
        explainTrack, explainTaste, lookupGenre, similarArtists, newReleases,
    ]

    /// The music tools that are NOT `strict`. A request holds at most 20 strict tools and 15 of the 16 older tools already are
    /// (deviation 222): the five small read-only tools are closed, fully required and validated locally, but not strict.
    public static let nonStrictMusicTools: Set<String> = [explainTrack, explainTaste, lookupGenre, similarArtists, newReleases]

    // MARK: Parameter values

    public static let anyWord = "any"
    public static let energy: [String] = [anyWord, "lower", "higher"]
    public static let novelty: [String] = [anyWord, "familiar", "new"]
    public static let tempo: [String] = [anyWord, "slow", "mid", "fast"]
    public static let seedKinds: [String] = ["song", "artist", "album", "playlist", "genre"]
    public static let stationModes: [String] = ["familiar", "blend", "discover"]
    public static let steerChanges: [String] = [
        "more_artist", "less_artist", "more_genre", "less_genre", "energy_up", "energy_down", "more_familiar", "more_new",
    ]
    public static let steerScopes: [String] = ["session", "always"]
    public static let explainScopes: [String] = ["summary", "islands", "genres", "dayparts", "recent_moves", "model"]
    public static let releaseScopes: [String] = ["my_artists", "adjacent", "country"]

    // MARK: Limits

    public static let defaultResults = 25
    public static let maxRecommend = 50
    public static let minMix = 10
    public static let maxMix = 60
    public static let defaultMix = 30
    public static let maxResolveItems = 25
    public static let maxSeedRefs = 5
    public static let maxTitle = 60
    /// `novelty_share_pct` when the sentence said nothing about it (0 is a real answer: no new music).
    public static let shareUnset = -1
}
