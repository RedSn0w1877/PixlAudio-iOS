// What the ten music tools of Ask Taizo (docs/brain-spec.md, 9.3) need from the app, as plain types. `MusicToolRunner` turns a tool call into
// one of these calls and the answer into the JSON the model reads; `BrainAssistantEngine` (in the app target) is the implementation over the
// brain's real tables. The split exists so the tools can be tested with a fake that holds only what the test puts in it: the assistant never
// ranks and never invents anything, so every field below is something the engine or a store returned (or an explicit "unknown").
// Mirrors Android's `MusicBackend.kt`.

import PixlModel

/// The app's side of the ten music tools.
public protocol MusicBackend: Sendable {
    /// For each (title, artist) in order: the track it is, or not found. An item is `skipped` when the day's YouTube requests were used up
    /// before it could be asked (the alias table and the library are still tried first and cost nothing).
    func resolve(_ items: [(title: String, artist: String)]) async -> [AssistantLookup]

    /// Ranked picks for `query` from the engine's own pool (library, cached radios, arms), already filtered.
    func recommend(_ query: AssistantRules.Query) async -> AssistantRecommendation

    /// A saved list for `query`, or nil when the engine had nothing to build one from.
    func buildMix(_ query: AssistantRules.Query) async -> AssistantMix?

    /// The mix again with a chip applied (a delta on the stored request, no model call), or nil for a mix this chat never built.
    func adjustMix(mixId: String, chip: AssistantRules.Chip) async -> AssistantMix?

    /// Starts a station and plays it; the outcome says why when it could not start.
    func startStation(seedRef: String, seedKind: String, mode: String) async -> AssistantStationOutcome

    func steer(change: String, target: String, scope: String) async -> AssistantSteerOutcome

    /// What the engine really holds about `ref` ("now" is the song playing); fields it does not hold are nil (and listed as unknown by the tool).
    func explainTrack(ref: String) async -> AssistantTrackExplanation?

    func explainTaste(scope: String) async -> AssistantTasteExplanation

    func lookupGenre(_ query: String) async -> AssistantGenreLookup

    func similarArtists(artist: String, count: Int, onlyUnplayed: Bool) async -> AssistantSimilarArtists

    func newReleases(scope: String, count: Int) async -> AssistantReleaseList
}

/// One looked-up item: the track, or nil; `skipped` when the YouTube budget of the day stopped the search.
public struct AssistantLookup: Sendable {
    public var track: AssistantTrack?
    public var skipped: Bool

    public init(track: AssistantTrack?, skipped: Bool = false) {
        self.track = track
        self.skipped = skipped
    }
}

public struct AssistantTrack: Sendable, Hashable {
    public var ref: String
    public var title: String
    public var artist: String
    /// 0 when unknown.
    public var year: Int
    public var inLibrary: Bool
    public var album: String

    public init(ref: String, title: String, artist: String, year: Int = 0, inLibrary: Bool, album: String = "") {
        self.ref = ref
        self.title = title
        self.artist = artist
        self.year = year
        self.inLibrary = inLibrary
        self.album = album
    }
}

public struct AssistantPick: Sendable {
    public var track: AssistantTrack
    /// `WhyLine.nameOf` key, or "" for none.
    public var whyKey: String
    /// The names the reason is about (the artist of "Fans of X also play this").
    public var whyArgs: [String]

    public init(track: AssistantTrack, whyKey: String = "", whyArgs: [String] = []) {
        self.track = track
        self.whyKey = whyKey
        self.whyArgs = whyArgs
    }
}

public struct AssistantRecommendation: Sendable {
    public var picks: [AssistantPick]
    /// Filters the request asked for that no data answered, and so were not applied.
    public var unsupportedFilters: [String]
    /// True when the engine had nothing of the listener's to rank (a thin history): the picks are the radios' own order.
    public var coldStart: Bool

    public init(picks: [AssistantPick], unsupportedFilters: [String] = [], coldStart: Bool = false) {
        self.picks = picks
        self.unsupportedFilters = unsupportedFilters
        self.coldStart = coldStart
    }
}

public struct AssistantMix: Sendable {
    public var mixId: String
    public var title: String
    public var tracks: [AssistantPick]
    public var unsupportedFilters: [String]
    /// The request the mix was built from, kept for the chips (a delta on it is applied on the device, with no model call).
    public var query: AssistantRules.Query
    /// The artist and genre the mix has most of, for the chips ("Less Sabrina", "More R&B"): "" and 0 when unknown.
    public var topArtistRef: String
    public var topArtistName: String
    public var topGenreId: Int
    public var topGenreName: String

    public init(mixId: String, title: String, tracks: [AssistantPick], unsupportedFilters: [String] = [], query: AssistantRules.Query,
                topArtistRef: String = "", topArtistName: String = "", topGenreId: Int = 0, topGenreName: String = "") {
        self.mixId = mixId
        self.title = title
        self.tracks = tracks
        self.unsupportedFilters = unsupportedFilters
        self.query = query
        self.topArtistRef = topArtistRef
        self.topArtistName = topArtistName
        self.topGenreId = topGenreId
        self.topGenreName = topGenreName
    }
}

public struct AssistantStationOutcome: Sendable {
    public var started: Bool
    public var firstTrack: AssistantTrack?
    public var reason: String

    public init(started: Bool, firstTrack: AssistantTrack? = nil, reason: String = "") {
        self.started = started
        self.firstTrack = firstTrack
        self.reason = reason
    }
}

public struct AssistantSteerOutcome: Sendable {
    public var applied: Bool
    public var tailChanged: Int
    public var note: String

    public init(applied: Bool, tailChanged: Int = 0, note: String = "") {
        self.applied = applied
        self.tailChanged = tailChanged
        self.note = note
    }
}

/// The fields that are nil are unknown: the tool says so in `unknown`, and the model is told to say so.
public struct AssistantTrackExplanation: Sendable {
    public static let minPlaysForRate = 3

    public var ref: String
    public var title: String
    public var artist: String
    /// The arm the pick was served under (`Arm.nameOf`), or nil for a track the engine did not serve.
    public var arm: String?
    public var whyKey: String?
    public var whyArgs: [String]
    /// From the vector the pick was served with; nil when no served vector is stored.
    public var factors: [AssistantRules.Factor]?
    public var genres: [String]?
    /// 0 when unknown.
    public var year: Int
    /// How many times the listener played it, or nil when the engine has no record.
    public var plays: Int?
    /// Share of those plays that were finished, 0.0 to 1.0; nil with fewer than `minPlaysForRate`.
    public var completionRate: Double?

    public init(ref: String, title: String, artist: String, arm: String? = nil, whyKey: String? = nil, whyArgs: [String] = [],
                factors: [AssistantRules.Factor]? = nil, genres: [String]? = nil, year: Int = 0, plays: Int? = nil,
                completionRate: Double? = nil) {
        self.ref = ref
        self.title = title
        self.artist = artist
        self.arm = arm
        self.whyKey = whyKey
        self.whyArgs = whyArgs
        self.factors = factors
        self.genres = genres
        self.year = year
        self.plays = plays
        self.completionRate = completionRate
    }
}

public struct AssistantTasteLine: Sendable {
    public var name: String
    public var value: String
    public var detail: String

    public init(name: String, value: String, detail: String = "") {
        self.name = name
        self.value = value
        self.detail = detail
    }
}

/// One section of Your sound, as named facts. `unknown` lists what the engine cannot say yet (and why, in words a listener understands).
public struct AssistantTasteExplanation: Sendable {
    public var scope: String
    public var lines: [AssistantTasteLine]
    public var unknown: [String]

    public init(scope: String, lines: [AssistantTasteLine], unknown: [String] = []) {
        self.scope = scope
        self.lines = lines
        self.unknown = unknown
    }
}

public struct AssistantGenreRef: Sendable, Hashable {
    public var id: Int
    public var name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

public struct AssistantGenreInfo: Sendable {
    public var id: Int
    public var name: String
    public var description: String
    public var parents: [AssistantGenreRef]
    public var children: [AssistantGenreRef]
    public var related: [AssistantGenreRef]
    public var influences: [AssistantGenreRef]
    public var region: String
    /// 0 when unknown.
    public var era: Int
    public var descriptors: [String]
    /// A mood of the atlas's mood list (its id is the list position plus one), not a genre.
    public var isMood: Bool

    public init(id: Int, name: String, description: String = "", parents: [AssistantGenreRef] = [], children: [AssistantGenreRef] = [],
                related: [AssistantGenreRef] = [], influences: [AssistantGenreRef] = [], region: String = "", era: Int = 0,
                descriptors: [String] = [], isMood: Bool = false) {
        self.id = id
        self.name = name
        self.description = description
        self.parents = parents
        self.children = children
        self.related = related
        self.influences = influences
        self.region = region
        self.era = era
        self.descriptors = descriptors
        self.isMood = isMood
    }
}

public struct AssistantGenreLookup: Sendable {
    /// The one genre asked for; nil when the atlas does not have it (then `nearest` may name others).
    public var genre: AssistantGenreInfo?
    public var nearest: [AssistantGenreRef]

    public init(genre: AssistantGenreInfo? = nil, nearest: [AssistantGenreRef] = []) {
        self.genre = genre
        self.nearest = nearest
    }
}

public struct AssistantSimilarArtist: Sendable {
    public var name: String
    public var ref: String
    public var score: Double
    public var sources: [String]

    public init(name: String, ref: String = "", score: Double, sources: [String] = []) {
        self.name = name
        self.ref = ref
        self.score = score
        self.sources = sources
    }
}

public struct AssistantSimilarArtists: Sendable {
    public var artists: [AssistantSimilarArtist]
    public var note: String

    public init(artists: [AssistantSimilarArtist], note: String = "") {
        self.artists = artists
        self.note = note
    }
}

public struct AssistantRelease: Sendable {
    public var title: String
    public var artist: String
    public var type: String
    public var year: Int
    public var ref: String

    public init(title: String, artist: String, type: String, year: Int = 0, ref: String = "") {
        self.title = title
        self.artist = artist
        self.type = type
        self.year = year
        self.ref = ref
    }
}

public struct AssistantReleaseList: Sendable {
    public var releases: [AssistantRelease]
    public var note: String

    public init(releases: [AssistantRelease], note: String = "") {
        self.releases = releases
        self.note = note
    }
}

/// How the app's playback side resolves what tools return into songs (the part of the backend that touches the player).
public protocol AssistantPlayable: Sendable {
    /// The song a ref plays as: a library row, or an engine track registered in `playable` first. Nil for a ref this chat never saw.
    func songForRef(_ ref: String) async -> Song?

    /// The songs of a mix this chat built, in order, ready to play; nil for an unknown id.
    func songsForMix(_ mixId: String) async -> [Song]?

    /// Announces the tags (surface assistant, the pick's arm and served vector) the next play of `songs` carries.
    func expectTags(songs: [Song]) async
}
