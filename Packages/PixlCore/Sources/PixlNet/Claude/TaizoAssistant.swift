// "Ask Taizo" — PixlAudio's music assistant (spec A4, owner update 2026-10-23: the assistant is Taizo). The pure half:
// the instructions, the listening context (cached with the instructions), the per-turn "now" block (the volatile
// facts — time, the song and position, the queue, lyrics — go in the latest user turn, never in the cached prefix),
// the client tool schemas, the confirmation rules and the saved-conversation format. Same wording on Android.

import Foundation
import PixlFoundation

public enum TaizoAssistant {
    /// The stable instruction block (first system block).
    public static let instructions = """
        You are Taizo, PixlAudio's music assistant, inside the PixlAudio music player on the user's phone. You help \
        with everything music: talking about the song that's playing (its meaning, lyrics, background, the artist), \
        finding and playing music, building playlists and the queue, controlling playback, and explaining the user's \
        listening habits.

        How to work:
        - Ground answers about the user's music in your tools: search_library for what they have, \
        search_spotify_catalog for anything else, get_listening_insights for their habits. Use the ids the tools \
        return; never invent ids.
        - Act when asked: play_songs, add_to_queue, create_playlist, add_to_playlist, playback_control, like_song, \
        start_sing. The app asks the user to confirm large or destructive actions itself, so just call the tool.
        - Use web_search and web_fetch for facts that may have changed or that you aren't sure of: artist and song \
        background, meanings, news, tours and concerts. Cite the pages you used.
        - Each user message starts with a <now> block (time, what's playing, position, queue, lyrics). It describes \
        the moment of that message; the newest one wins.
        - The <listening_context> block describes the user's library and taste. Use it to personalise, quietly.
        - Replies are read on a phone: short, warm and direct. Plain sentences; a short list only when it helps. No \
        headings, no tables. After acting, say in one line what you did.
        - If something can't be done (a song isn't on Spotify, nothing is playing), say so plainly and offer the \
        closest alternative.
        """

    /// The two system blocks: instructions, then the listening context with the cache breakpoint on it (the last
    /// stable block). Both are fixed for a conversation's life (saved with it), so the prefix stays cacheable.
    public static func system(instructions: String = instructions, context: String) -> [ClaudeSystemBlock] {
        [ClaudeSystemBlock(instructions), ClaudeSystemBlock(context, cacheBreakpoint: true)]
    }

    /// The server tools the assistant may use.
    public static let serverTools: [ClaudeServerTool] = [.webSearch, .webFetch]

    /// The user's message as sent: the now block, then what they typed.
    public static func userMessage(now: TaizoNowContext, text: String) -> String {
        now.render() + "\n\n" + text
    }

    // MARK: Confirmation

    /// Playlists this large ask before they are created.
    public static let largePlaylistThreshold = 50

    /// The question to confirm before a tool call runs, or nil to run it at once: creating a playlist with more than
    /// 50 songs, and replacing a queue that holds more than the song playing.
    public static func confirmationQuestion(tool: String, input: JSONObject, currentQueueCount: Int) -> String? {
        let count = (input["song_ids"]?.arrayValue?.count ?? 0) + (input["queries"]?.arrayValue?.count ?? 0)
        switch tool {
        case TaizoTool.createPlaylist.rawValue where count > largePlaylistThreshold:
            let name = input["name"]?.stringValue ?? "the playlist"
            return "Create “\(name)” with \(count) songs?"
        case TaizoTool.playSongs.rawValue where currentQueueCount > 1:
            return "Replace your queue (\(currentQueueCount) songs) with \(count == 1 ? "1 song" : "\(count) songs")?"
        default:
            return nil
        }
    }
}

// MARK: - Context

/// One song in a context list.
public struct TaizoSongLine: Sendable, Hashable {
    public var title: String
    public var artist: String
    /// "12 plays", "liked", an id … (optional).
    public var detail: String?

    public init(title: String, artist: String, detail: String? = nil) {
        self.title = title
        self.artist = artist
        self.detail = detail
    }

    var rendered: String {
        let base = "\(title) — \(artist)"
        guard let detail, !detail.isEmpty else { return base }
        return "\(base) (\(detail))"
    }
}

/// The user's library and taste (second system block; computed when a conversation starts).
public struct TaizoListeningContext: Sendable, Hashable {
    public var librarySongCount: Int
    public var libraryArtistCount: Int
    public var playlistNames: [String]
    /// "last 30 days" / "all time" — what the top lists cover.
    public var periodLabel: String
    public var topArtists: [String]
    public var topGenres: [String]
    public var topSongs: [TaizoSongLine]
    public var recentPlays: [TaizoSongLine]
    /// Imported Spotify / YouTube Music history, in a line ("48,210 imported plays; top: …"), when there is any.
    public var importedHistory: String?
    public var totalListeningHours: Int?

    public init(librarySongCount: Int, libraryArtistCount: Int, playlistNames: [String] = [], periodLabel: String = "recently",
                topArtists: [String] = [], topGenres: [String] = [], topSongs: [TaizoSongLine] = [],
                recentPlays: [TaizoSongLine] = [], importedHistory: String? = nil, totalListeningHours: Int? = nil) {
        self.librarySongCount = librarySongCount
        self.libraryArtistCount = libraryArtistCount
        self.playlistNames = playlistNames
        self.periodLabel = periodLabel
        self.topArtists = topArtists
        self.topGenres = topGenres
        self.topSongs = topSongs
        self.recentPlays = recentPlays
        self.importedHistory = importedHistory
        self.totalListeningHours = totalListeningHours
    }

    /// Caps that keep the block at a few thousand tokens.
    public static let maxPlaylists = 40
    public static let maxArtists = 15
    public static let maxGenres = 10
    public static let maxTopSongs = 15
    public static let maxRecent = 20

    public func render() -> String {
        var lines = ["<listening_context>"]
        lines.append("Library: \(librarySongCount) songs by \(libraryArtistCount) artists.")
        if !playlistNames.isEmpty {
            let shown = playlistNames.prefix(Self.maxPlaylists)
            let more = playlistNames.count > shown.count ? " (+\(playlistNames.count - shown.count) more)" : ""
            lines.append("Playlists: " + shown.joined(separator: "; ") + more)
        }
        if let hours = totalListeningHours, hours > 0 { lines.append("Listening time \(periodLabel): about \(hours) h.") }
        if !topArtists.isEmpty {
            lines.append("Top artists \(periodLabel): " + topArtists.prefix(Self.maxArtists).joined(separator: ", "))
        }
        if !topGenres.isEmpty {
            lines.append("Top genres \(periodLabel): " + topGenres.prefix(Self.maxGenres).joined(separator: ", "))
        }
        if !topSongs.isEmpty {
            lines.append("Top songs \(periodLabel):")
            lines += topSongs.prefix(Self.maxTopSongs).map { "- " + $0.rendered }
        }
        if !recentPlays.isEmpty {
            lines.append("Recently played (newest first):")
            lines += recentPlays.prefix(Self.maxRecent).map { "- " + $0.rendered }
        }
        if let importedHistory, !importedHistory.isEmpty { lines.append("Imported history: " + importedHistory) }
        if librarySongCount == 0 { lines.append("The library is empty: suggest music from the Spotify catalogue.") }
        lines.append("</listening_context>")
        return lines.joined(separator: "\n")
    }
}

/// The song that's playing.
public struct TaizoCurrentSong: Sendable, Hashable {
    public var id: String
    public var title: String
    public var artists: String
    public var album: String
    public var year: Int
    public var durationMs: Int64
    public var positionMs: Int64
    public var isPlaying: Bool
    public var spotifyId: String?
    public var isrc: String?
    public var hasInstrumental: Bool
    public var isLiked: Bool

    public init(id: String, title: String, artists: String, album: String, year: Int, durationMs: Int64, positionMs: Int64,
                isPlaying: Bool, spotifyId: String? = nil, isrc: String? = nil, hasInstrumental: Bool = false,
                isLiked: Bool = false) {
        self.id = id
        self.title = title
        self.artists = artists
        self.album = album
        self.year = year
        self.durationMs = durationMs
        self.positionMs = positionMs
        self.isPlaying = isPlaying
        self.spotifyId = spotifyId
        self.isrc = isrc
        self.hasInstrumental = hasInstrumental
        self.isLiked = isLiked
    }

    /// Identifies the song across turns (lyrics are sent again only when it changed).
    public var key: String { id }
}

/// The volatile facts of one user turn.
public struct TaizoNowContext: Sendable, Hashable {
    public var localTime: String
    public var song: TaizoCurrentSong?
    /// The next songs in the queue (up to 20).
    public var upNext: [TaizoSongLine]
    /// Plain lyrics of the current song (trimmed), when known.
    public var lyrics: String?
    /// Lyrics were already sent for this song in this conversation: only a reminder goes.
    public var lyricsAlreadySent: Bool

    public init(localTime: String, song: TaizoCurrentSong?, upNext: [TaizoSongLine] = [], lyrics: String? = nil,
                lyricsAlreadySent: Bool = false) {
        self.localTime = localTime
        self.song = song
        self.upNext = upNext
        self.lyrics = lyrics
        self.lyricsAlreadySent = lyricsAlreadySent
    }

    public static let maxUpNext = 20
    public static let maxLyricsCharacters = 3000

    public func render() -> String {
        var lines = ["<now>", "Local time: \(localTime)"]
        if let song {
            lines.append("Playing: \(song.title) — \(song.artists)" + (song.isPlaying ? "" : " (paused)"))
            var facts: [String] = []
            if !song.album.isEmpty { facts.append("album \(song.album)") }
            if song.year > 0 { facts.append("year \(song.year)") }
            facts.append("position \(Self.clock(song.positionMs)) of \(Self.clock(song.durationMs))")
            facts.append("song_id \(song.id)")
            if let spotifyId = song.spotifyId, !spotifyId.isEmpty { facts.append("spotify_id \(spotifyId)") }
            if let isrc = song.isrc, !isrc.isEmpty { facts.append("ISRC \(isrc)") }
            facts.append(song.hasInstrumental ? "instrumental ready for Sing" : "no instrumental yet")
            if song.isLiked { facts.append("liked") }
            lines.append(facts.joined(separator: "; "))
            if let lyrics = lyrics.map(Self.trimLyrics), !lyrics.isEmpty {
                if lyricsAlreadySent {
                    lines.append("Lyrics: as sent earlier in this conversation.")
                } else {
                    lines.append("Lyrics:")
                    lines.append(lyrics)
                }
            } else {
                lines.append("Lyrics: not available.")
            }
        } else {
            lines.append("Nothing is playing.")
        }
        if !upNext.isEmpty {
            lines.append("Up next:")
            lines += upNext.prefix(Self.maxUpNext).map { "- " + $0.rendered }
        }
        lines.append("</now>")
        return lines.joined(separator: "\n")
    }

    /// "3:07".
    static func clock(_ ms: Int64) -> String {
        let total = max(ms, 0) / 1000
        let seconds = total % 60
        return "\(total / 60):" + (seconds < 10 ? "0\(seconds)" : "\(seconds)")
    }

    /// Whole lines up to `maxLyricsCharacters`, blank runs collapsed, "…" when cut.
    public static func trimLyrics(_ text: String) -> String {
        var out: [String] = []
        var length = 0
        var previousBlank = true
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if previousBlank { continue }
                previousBlank = true
            } else {
                previousBlank = false
            }
            if length + line.count + 1 > maxLyricsCharacters {
                out.append("…")
                break
            }
            out.append(line)
            length += line.count + 1
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }
}

// MARK: - Tools

/// The assistant's client tools (spec A4), in their fixed order.
public enum TaizoTool: String, Sendable, Hashable, CaseIterable {
    case searchLibrary = "search_library"
    case searchSpotifyCatalog = "search_spotify_catalog"
    case playSongs = "play_songs"
    case addToQueue = "add_to_queue"
    case playbackControl = "playback_control"
    case createPlaylist = "create_playlist"
    case addToPlaylist = "add_to_playlist"
    case getListeningInsights = "get_listening_insights"
    case getLyrics = "get_lyrics"
    case startSing = "start_sing"
    case likeSong = "like_song"

    /// The tools the on-device model can use offline (no catalogue, no web).
    public static let offline: [TaizoTool] = [.searchLibrary, .playSongs, .addToQueue, .playbackControl, .createPlaylist,
                                              .addToPlaylist, .getListeningInsights, .getLyrics, .startSing, .likeSong]

    public static var definitions: [ClaudeToolDefinition] { allCases.map(\.definition) }

    public var definition: ClaudeToolDefinition {
        switch self {
        case .searchLibrary:
            return ClaudeToolDefinition(
                name: rawValue,
                description: "Search the user's own PixlAudio library (songs they saved or imported) by title, artist, "
                    + "album or genre. Call this before playing, queueing or adding songs the user already has, so you "
                    + "use real song ids, and whenever they ask what they have by an artist or in a genre.",
                inputSchema: Schema.object([
                    ("query", Schema.string("Title, artist, album or genre words. Empty for a sample of the library.")),
                    ("limit", Schema.integer("How many songs to return, 1 to 50 (default 20).")),
                ], required: ["query"]))
        case .searchSpotifyCatalog:
            return ClaudeToolDefinition(
                name: rawValue,
                description: "Search the whole Spotify catalogue for tracks. Call this when the user wants music they "
                    + "may not have yet, a specific track search_library didn't find, or new recommendations. Returns "
                    + "track ids (spotify:track:…) that play_songs, add_to_queue, create_playlist and add_to_playlist "
                    + "accept; they are added to the library when used.",
                inputSchema: Schema.object([
                    ("query", Schema.string("Search words, e.g. \"artist title\" or \"artist\".")),
                    ("limit", Schema.integer("How many tracks to return, 1 to 20 (default 10).")),
                ], required: ["query"]))
        case .playSongs:
            return ClaudeToolDefinition(
                name: rawValue,
                description: "Start playing songs now, replacing the queue. Call this when the user asks to play "
                    + "something. Pass ids from search_library or search_spotify_catalog; plain \"title artist\" "
                    + "queries are resolved for you when you have no id.",
                inputSchema: Schema.object([
                    ("song_ids", Schema.stringArray("Song ids (library ids or spotify:track:… ids), in play order.")),
                    ("queries", Schema.stringArray("\"title artist\" searches for songs without an id, played after the ids.")),
                    ("start_index", Schema.integer("Which of the songs plays first (0-based, default 0).")),
                ], required: ["song_ids"]))
        case .addToQueue:
            return ClaudeToolDefinition(
                name: rawValue,
                description: "Add songs to the queue without interrupting what's playing. Call this when the user says "
                    + "queue, add, or play after this / next.",
                inputSchema: Schema.object([
                    ("song_ids", Schema.stringArray("Song ids (library ids or spotify:track:… ids).")),
                    ("queries", Schema.stringArray("\"title artist\" searches for songs without an id.")),
                    ("play_next", Schema.boolean("true: right after the current song; false (default): at the end.")),
                ], required: ["song_ids"]))
        case .playbackControl:
            return ClaudeToolDefinition(
                name: rawValue,
                description: "Control playback: play, pause, next, previous, or seek to a position in the current "
                    + "song. Call this when the user asks to pause, resume, skip, go back or jump to a time or lyric.",
                inputSchema: Schema.object([
                    ("action", Schema.enumeration(["play", "pause", "next", "previous", "seek"], "What to do.")),
                    ("seek_ms", Schema.integer("For seek: the position in milliseconds from the start of the song.")),
                ], required: ["action"]))
        case .createPlaylist:
            return ClaudeToolDefinition(
                name: rawValue,
                description: "Create a new playlist in the user's library. Call this when the user asks for a playlist "
                    + "to keep (not just to play). Find the songs first with search_library / search_spotify_catalog.",
                inputSchema: Schema.object([
                    ("name", Schema.string("The playlist's name.")),
                    ("song_ids", Schema.stringArray("Song ids (library ids or spotify:track:… ids), in order.")),
                    ("queries", Schema.stringArray("\"title artist\" searches for songs without an id.")),
                ], required: ["name", "song_ids"]))
        case .addToPlaylist:
            return ClaudeToolDefinition(
                name: rawValue,
                description: "Add songs to one of the user's existing playlists (by its name or id). Call this when the "
                    + "user asks to add or save songs to a playlist they already have.",
                inputSchema: Schema.object([
                    ("playlist", Schema.string("The playlist's name (as in the listening context) or id.")),
                    ("song_ids", Schema.stringArray("Song ids (library ids or spotify:track:… ids). Empty: the song playing.")),
                    ("queries", Schema.stringArray("\"title artist\" searches for songs without an id.")),
                ], required: ["playlist", "song_ids"]))
        case .getListeningInsights:
            return ClaudeToolDefinition(
                name: rawValue,
                description: "Get the user's listening statistics for a period: top artists, songs and genres, listening "
                    + "time, sessions, skips and completions. Call this for questions about their habits, taste, "
                    + "favourites or how much they listen.",
                inputSchema: Schema.object([
                    ("period", Schema.enumeration(["day", "week", "month", "year", "all"], "The period to summarise.")),
                ], required: ["period"]))
        case .getLyrics:
            return ClaudeToolDefinition(
                name: rawValue,
                description: "Get the full lyrics of the song that's playing, or of another library song by id. Call "
                    + "this when the user asks about lyrics, a line, or the meaning of a song and the <now> block's "
                    + "lyrics are missing or cut.",
                inputSchema: Schema.object([
                    ("song_id", Schema.string("A library song id. Empty: the song that's playing.")),
                ], required: []))
        case .startSing:
            return ClaudeToolDefinition(
                name: rawValue,
                description: "Turn on Sing (karaoke: the vocals go quiet, the music keeps playing) for the song that's "
                    + "playing. Call this when the user wants to sing along or asks for the instrumental.",
                inputSchema: Schema.object([], required: []))
        case .likeSong:
            return ClaudeToolDefinition(
                name: rawValue,
                description: "Like or unlike a song (it shows in Liked songs). Call this when the user says they love, "
                    + "like or want to save a song, or asks to remove a like.",
                inputSchema: Schema.object([
                    ("song_id", Schema.string("A library song id. Empty: the song that's playing.")),
                    ("liked", Schema.boolean("true to like (default), false to remove the like.")),
                ], required: []))
        }
    }

    /// JSON Schema builders (strict-compatible: no numeric or length constraints, closed objects).
    enum Schema {
        static func object(_ properties: [(String, JSONValue)], required: [String]) -> JSONValue {
            ClaudeJSON.object([
                ("type", .string("object")),
                ("properties", ClaudeJSON.object(properties)),
                ("required", .array(required.map(JSONValue.string))),
                ("additionalProperties", .bool(false)),
            ])
        }

        static func string(_ description: String) -> JSONValue {
            ClaudeJSON.object([("type", .string("string")), ("description", .string(description))])
        }

        static func integer(_ description: String) -> JSONValue {
            ClaudeJSON.object([("type", .string("integer")), ("description", .string(description))])
        }

        static func boolean(_ description: String) -> JSONValue {
            ClaudeJSON.object([("type", .string("boolean")), ("description", .string(description))])
        }

        static func stringArray(_ description: String) -> JSONValue {
            ClaudeJSON.object([("type", .string("array")), ("items", ClaudeJSON.object([("type", .string("string"))])),
                               ("description", .string(description))])
        }

        static func enumeration(_ values: [String], _ description: String) -> JSONValue {
            ClaudeJSON.object([("type", .string("string")), ("enum", .array(values.map(JSONValue.string))),
                               ("description", .string(description))])
        }
    }
}
