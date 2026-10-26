import Foundation
import PixlFoundation
import PixlLibrary
import PixlModel
import PixlNet
import Synchronization

/// Ask Taizo's client tools (spec A4) on the app's stores: the library and the Spotify catalogue (Search's providers),
/// playback and the queue, playlists and likes (`LibraryEditor`), listening stats (the history Home reads — imported
/// history included), lyrics (`LyricsService`) and Sing (`InstrumentalController`). The schemas and the confirmation
/// rules are PixlNet's (`TaizoTool`, `TaizoAssistant.confirmationQuestion`); the loop validates every input against its
/// schema before `run` is called.
nonisolated struct TaizoToolbox: ClaudeToolExecuting {
    let environment: @MainActor @Sendable () -> AppEnvironment?
    /// The Spotify catalogue (nil when unavailable).
    let catalog: (any SearchProviding)?
    /// Catalogue tracks the model has seen in this conversation's searches, by `spotify:track:<id>`.
    let seen = TaizoCatalogCache()

    var definitions: [ClaudeToolDefinition] { TaizoTool.definitions }

    func confirmation(for call: ClaudeToolUse) async -> String? {
        let environment = self.environment
        let queueCount = await MainActor.run { environment()?.playback.queue.count ?? 0 }
        return TaizoAssistant.confirmationQuestion(tool: call.name, input: call.input, currentQueueCount: queueCount)
    }

    func run(_ call: ClaudeToolUse) async -> ClaudeToolOutput {
        guard let tool = TaizoTool(rawValue: call.name) else { return .error("Unknown tool \(call.name).") }
        return await TaizoToolRunner.run(tool, input: call.input, environment: environment, catalog: catalog, seen: seen)
    }
}

/// Catalogue results by id, shared by the calls of one conversation.
nonisolated final class TaizoCatalogCache: Sendable {
    private let tracks = Mutex<[String: CatalogTrack]>([:])

    func remember(_ track: CatalogTrack) -> String {
        let id = "spotify:track:\(track.spotifyId)"
        tracks.withLock { $0[id] = track }
        return id
    }

    func track(_ id: String) -> CatalogTrack? { tracks.withLock { $0[id] } }
}

/// The tools' work, on the main actor (the stores live there); anything heavy goes to a detached task.
@MainActor
enum TaizoToolRunner {
    static let maxSongsPerCall = 200

    static func run(_ tool: TaizoTool, input: JSONObject, environment: @MainActor @Sendable () -> AppEnvironment?,
                    catalog: (any SearchProviding)?, seen: TaizoCatalogCache) async -> ClaudeToolOutput {
        guard let env = environment() else { return .error("PixlAudio isn't ready yet. Try again in a moment.") }
        switch tool {
        case .searchLibrary: return await searchLibrary(env, input)
        case .searchSpotifyCatalog: return await searchCatalog(env, input, catalog: catalog, seen: seen)
        case .playSongs: return await playSongs(env, input, catalog: catalog, seen: seen)
        case .addToQueue: return await addToQueue(env, input, catalog: catalog, seen: seen)
        case .playbackControl: return playbackControl(env, input)
        case .createPlaylist: return await createPlaylist(env, input, catalog: catalog, seen: seen)
        case .addToPlaylist: return await addToPlaylist(env, input, catalog: catalog, seen: seen)
        case .getListeningInsights: return await insights(env, input)
        case .getLyrics: return await lyrics(env, input)
        case .startSing: return startSing(env)
        case .likeSong: return likeSong(env, input)
        }
    }

    // MARK: Search

    private static func searchLibrary(_ env: AppEnvironment, _ input: JSONObject) async -> ClaudeToolOutput {
        let query = (input["query"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = clamp(input["limit"], default: 20, range: 1...50)
        let songs = env.library.songs
        guard !songs.isEmpty else { return .json(ClaudeJSON.object([("count", .integer(0)), ("songs", .array([])),
                                                                    ("note", .string("The library is empty."))])) }
        let found = await Task.detached(priority: .userInitiated) { () -> [Song] in
            if query.isEmpty {
                let liked = songs.filter(\.isFavorite)
                return Array((liked.isEmpty ? songs : liked).shuffled().prefix(limit))
            }
            var results = SearchIndex(songs: songs).searchSongs(query, limit: limit)
            if results.count < limit {
                var ids = Set(results.map(\.id))
                let lower = query.lowercased()
                for song in songs where (song.genre?.lowercased().contains(lower) ?? false) && ids.insert(song.id).inserted {
                    results.append(song)
                    if results.count >= limit { break }
                }
            }
            return results
        }.value
        return .json(ClaudeJSON.object([("count", .integer(found.count)), ("songs", .array(found.map(songJSON)))]))
    }

    private static func searchCatalog(_ env: AppEnvironment, _ input: JSONObject, catalog: (any SearchProviding)?,
                                      seen: TaizoCatalogCache) async -> ClaudeToolOutput {
        guard let catalog else { return .error("The Spotify catalogue isn't available in this build.") }
        let query = (input["query"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .error("Give a search query.") }
        let limit = clamp(input["limit"], default: 10, range: 1...20)
        let items: [SearchResultItem]
        do {
            items = try await catalog.search(query, filter: .catalog, limit: limit)
        } catch {
            return .error("Spotify search failed. Is Spotify connected in Settings › Accounts?")
        }
        let inLibrary = Set(env.library.songs.compactMap(\.spotifyId))
        var tracks: [JSONValue] = []
        for item in items {
            guard case .catalog(let track) = item else { continue }
            let id = seen.remember(track)
            tracks.append(ClaudeJSON.object([
                ("id", .string(id)), ("title", .string(track.title)), ("artist", .string(track.artist)),
                ("album", .string(track.album)), ("duration", .string(clock(track.durationMs))),
                ("in_library", .bool(inLibrary.contains(track.spotifyId))),
            ]))
        }
        if tracks.isEmpty { return .json(ClaudeJSON.object([("count", .integer(0)), ("tracks", .array([])),
                                                            ("note", .string("No tracks found."))])) }
        return .json(ClaudeJSON.object([("count", .integer(tracks.count)), ("tracks", .array(tracks))]))
    }

    // MARK: Resolving ids

    /// Library songs for ids and queries, importing catalogue tracks into the library when needed. Returns the songs
    /// in order and what couldn't be found.
    private static func resolve(_ env: AppEnvironment, _ input: JSONObject, catalog: (any SearchProviding)?,
                                seen: TaizoCatalogCache) async -> (songs: [Song], missing: [String]) {
        let ids = (input["song_ids"]?.arrayValue ?? []).compactMap(\.stringValue)
        let queries = (input["queries"]?.arrayValue ?? []).compactMap(\.stringValue)
        var songs: [Song] = []
        var missing: [String] = []
        var bySpotify: [String: Song]?
        func librarySong(spotifyId: String) -> Song? {
            if bySpotify == nil {
                bySpotify = Dictionary(env.library.songs.compactMap { song in song.spotifyId.map { ($0, song) } },
                                       uniquingKeysWith: { first, _ in first })
            }
            return bySpotify?[spotifyId]
        }
        for id in ids.prefix(maxSongsPerCall) {
            if let song = env.library.song(id: id) {
                songs.append(song)
            } else if id.hasPrefix("spotify:track:") {
                let spotifyId = String(id.dropFirst("spotify:track:".count))
                if let song = librarySong(spotifyId: spotifyId) {
                    songs.append(song)
                } else if let track = seen.track(id), let catalog, let song = await catalog.importAndPlay(.catalog(track)) {
                    songs.append(song)
                } else {
                    missing.append(id)
                }
            } else {
                missing.append(id)
            }
        }
        if !queries.isEmpty {
            let library = env.library.songs
            for query in queries.prefix(max(maxSongsPerCall - songs.count, 0)) {
                let hit = await Task.detached(priority: .userInitiated) {
                    SearchIndex(songs: library).searchSongs(query, limit: 1).first
                }.value
                if let hit {
                    songs.append(hit)
                    continue
                }
                if let catalog, let items = try? await catalog.search(query, filter: .catalog, limit: 1),
                   case .catalog(let track)? = items.first(where: { if case .catalog = $0 { true } else { false } }) {
                    if let song = librarySong(spotifyId: track.spotifyId) {
                        songs.append(song)
                    } else if let song = await catalog.importAndPlay(.catalog(track)) {
                        songs.append(song)
                    } else {
                        missing.append(query)
                    }
                } else {
                    missing.append(query)
                }
            }
        }
        return (songs, missing)
    }

    // MARK: Playback

    private static func playSongs(_ env: AppEnvironment, _ input: JSONObject, catalog: (any SearchProviding)?,
                                  seen: TaizoCatalogCache) async -> ClaudeToolOutput {
        let (songs, missing) = await resolve(env, input, catalog: catalog, seen: seen)
        guard !songs.isEmpty else { return .error("None of those songs could be found. Search first and use the ids returned.") }
        let start = min(clamp(input["start_index"], default: 0, range: 0...Int.max), songs.count - 1)
        env.playback.play(songs, startIndex: start)
        return .json(ClaudeJSON.object([
            ("now_playing", .string("\(songs[start].title) — \(songs[start].displayArtist)")),
            ("queue_length", .integer(songs.count)), ("not_found", .array(missing.map(JSONValue.string))),
        ]))
    }

    private static func addToQueue(_ env: AppEnvironment, _ input: JSONObject, catalog: (any SearchProviding)?,
                                   seen: TaizoCatalogCache) async -> ClaudeToolOutput {
        let (songs, missing) = await resolve(env, input, catalog: catalog, seen: seen)
        guard !songs.isEmpty else { return .error("None of those songs could be found. Search first and use the ids returned.") }
        let next = input["play_next"]?.boolValue ?? false
        if !env.playback.hasItem {
            env.playback.play(songs, startIndex: 0)
        } else if next {
            env.playback.playNext(songs)
        } else {
            env.playback.addToQueue(songs)
        }
        return .json(ClaudeJSON.object([
            ("added", .integer(songs.count)), ("position", .string(next ? "next" : "end of queue")),
            ("not_found", .array(missing.map(JSONValue.string))),
        ]))
    }

    private static func playbackControl(_ env: AppEnvironment, _ input: JSONObject) -> ClaudeToolOutput {
        let playback = env.playback
        let action = input["action"]?.stringValue ?? ""
        guard playback.hasItem else { return .error("Nothing is loaded to play. Use play_songs first.") }
        switch action {
        case "play": playback.resume()
        case "pause": playback.pause()
        case "next": playback.skipToNext()
        case "previous": playback.skipToPrevious()
        case "seek":
            guard let target = input["seek_ms"].flatMap({ KotlinxJSON.long($0) }) else {
                return .error("seek needs seek_ms.")
            }
            let duration = playback.durationMs()
            playback.seek(toMs: duration > 0 ? min(max(target, 0), duration) : max(target, 0))
        default:
            return .error("Unknown action \(action).")
        }
        return .json(ClaudeJSON.object([("done", .string(action)),
                                        ("current", .string(playback.current.map { "\($0.title) — \($0.displayArtist)" } ?? ""))]))
    }

    // MARK: Playlists and likes

    private static func createPlaylist(_ env: AppEnvironment, _ input: JSONObject, catalog: (any SearchProviding)?,
                                       seen: TaizoCatalogCache) async -> ClaudeToolOutput {
        let name = (input["name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .error("The playlist needs a name.") }
        let (songs, missing) = await resolve(env, input, catalog: catalog, seen: seen)
        guard !songs.isEmpty else { return .error("None of those songs could be found. Search first and use the ids returned.") }
        let playlist = env.libraryEditor.createPlaylist(name: name, songIds: songs.map(\.id), isAiGenerated: true)
        return .json(ClaudeJSON.object([
            ("created", .string(playlist.name)), ("playlist_id", .string(playlist.id)),
            ("songs", .integer(playlist.songIds.count)), ("not_found", .array(missing.map(JSONValue.string))),
        ]))
    }

    private static func addToPlaylist(_ env: AppEnvironment, _ input: JSONObject, catalog: (any SearchProviding)?,
                                      seen: TaizoCatalogCache) async -> ClaudeToolOutput {
        let wanted = (input["playlist"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let playlists = env.library.playlists
        let lower = wanted.lowercased()
        let playlist = playlists.first { $0.id == wanted }
            ?? playlists.first { $0.name.lowercased() == lower }
            ?? { () -> Playlist? in
                let partial = playlists.filter { $0.name.lowercased().contains(lower) }
                return partial.count == 1 ? partial[0] : nil
            }()
        guard let playlist, !wanted.isEmpty else {
            return .error("No playlist called \"\(wanted)\". Playlists: " + playlists.prefix(30).map(\.name).joined(separator: "; "))
        }
        var songs: [Song]
        var missing: [String] = []
        let hasIds = !(input["song_ids"]?.arrayValue ?? []).isEmpty || !(input["queries"]?.arrayValue ?? []).isEmpty
        if hasIds {
            (songs, missing) = await resolve(env, input, catalog: catalog, seen: seen)
        } else if let current = env.playback.current {
            songs = [current]
        } else {
            return .error("Nothing is playing; say which songs to add.")
        }
        guard !songs.isEmpty else { return .error("None of those songs could be found.") }
        let before = Set(playlist.songIds)
        env.libraryEditor.addSongs(songs.map(\.id), toPlaylist: playlist.id)
        let added = songs.filter { !before.contains($0.id) }.count
        return .json(ClaudeJSON.object([
            ("playlist", .string(playlist.name)), ("added", .integer(added)),
            ("already_there", .integer(songs.count - added)), ("not_found", .array(missing.map(JSONValue.string))),
        ]))
    }

    private static func likeSong(_ env: AppEnvironment, _ input: JSONObject) -> ClaudeToolOutput {
        let id = (input["song_id"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        guard let song = id.isEmpty ? env.playback.current : env.library.song(id: id) else {
            return .error(id.isEmpty ? "Nothing is playing." : "No library song has the id \(id).")
        }
        let liked = input["liked"]?.boolValue ?? true
        env.libraryEditor.setFavorite([song.id], liked)
        return .json(ClaudeJSON.object([("song", .string("\(song.title) — \(song.displayArtist)")), ("liked", .bool(liked))]))
    }

    // MARK: Insights, lyrics, Sing

    private static func insights(_ env: AppEnvironment, _ input: JSONObject) async -> ClaudeToolOutput {
        let range: StatsTimeRange
        switch input["period"]?.stringValue {
        case "day": range = .day
        case "week": range = .week
        case "year": range = .year
        case "all": range = .all
        default: range = .month
        }
        await env.home.history.ensureLoaded()
        let songs = env.library.songs, events = env.home.history.events, now = currentTimeMillis()
        let taste = env.musicTaste
        let learned = ClaudeJSON.object([("songs_learned", .integer(taste.learnedSongs)),
                                         ("completions", .integer(taste.completions)), ("early_skips", .integer(taste.skips))])
        let summary = await Task.detached(priority: .userInitiated) {
            PlaybackStats.buildSummary(range: range, songs: songs, nowMillis: now, events: events)
        }.value
        return .json(ClaudeJSON.object([
            ("period", .string(range.rawValue.lowercased())),
            ("listening_minutes", .integer(summary.totalDurationMs / 60_000)),
            ("plays", .integer(summary.totalPlayCount)),
            ("unique_songs", .integer(summary.uniqueSongs)),
            ("active_days", .integer(summary.activeDays)),
            ("longest_streak_days", .integer(summary.longestStreakDays)),
            ("sessions", .integer(summary.totalSessions)),
            ("average_session_minutes", .integer(summary.averageSessionDurationMs / 60_000)),
            ("peak_time", .string(summary.peakTimeline?.label ?? "")),
            ("top_artists", .array(summary.topArtists.prefix(10).map {
                ClaudeJSON.object([("name", .string($0.artist)), ("plays", .integer($0.playCount)),
                                   ("minutes", .integer($0.totalDurationMs / 60_000))])
            })),
            ("top_songs", .array(summary.topSongs.prefix(10).map {
                ClaudeJSON.object([("title", .string($0.title)), ("artist", .string($0.artist)), ("plays", .integer($0.playCount))])
            })),
            ("top_genres", .array(summary.topGenres.prefix(8).map {
                ClaudeJSON.object([("name", .string($0.genre)), ("plays", .integer($0.playCount))])
            })),
            ("taste_learning", learned),
        ]))
    }

    private static func lyrics(_ env: AppEnvironment, _ input: JSONObject) async -> ClaudeToolOutput {
        let id = (input["song_id"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        guard let song = id.isEmpty ? env.playback.current : env.library.song(id: id) else {
            return .error(id.isEmpty ? "Nothing is playing." : "No library song has the id \(id).")
        }
        var text: String?
        if case .loaded(let songId, let loaded, _) = env.lyrics.state, songId == song.id {
            text = TaizoContextBuilder.plainText(loaded)
        }
        if text?.isEmpty ?? true, let service = env.lyricsController.lyricsService {
            if let stored = await service.storedLyricsAsync(for: song) {
                text = TaizoContextBuilder.plainText(stored.lyrics)
            } else if case .success(let fetched) = await service.fetchFromRemote(song: song) {
                text = TaizoContextBuilder.plainText(fetched.lyrics)
            }
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error("No lyrics were found for \(song.title).")
        }
        let trimmed = text.count > 8000 ? String(text.prefix(8000)) + "\n…" : text
        return .json(ClaudeJSON.object([("song", .string("\(song.title) — \(song.displayArtist)")), ("lyrics", .string(trimmed))]))
    }

    private static func startSing(_ env: AppEnvironment) -> ClaudeToolOutput {
        guard let song = env.playback.current else { return .error("Nothing is playing. Play a song first.") }
        guard env.playback.remoteOutputName == nil else {
            return .error("Sing only works while the music plays on this iPhone, not on a connected speaker.")
        }
        let instrumental = env.tais.instrumental
        let ready = instrumental.isAvailable
        Task { await instrumental.requestSing(for: song) }
        return .json(ClaudeJSON.object([
            ("song", .string(song.title)),
            ("status", .string(ready ? "Sing is on: the vocals are going quiet."
                                     : "PixlAudio is making the instrumental; Sing turns on by itself when it's ready.")),
        ]))
    }

    // MARK: Helpers

    private static func songJSON(_ song: Song) -> JSONValue {
        var members: [(String, JSONValue)] = [("id", .string(song.id)), ("title", .string(song.title)),
                                              ("artist", .string(song.displayArtist)), ("album", .string(song.album))]
        if song.year > 0 { members.append(("year", .integer(song.year))) }
        if let genre = song.genre, !genre.isEmpty { members.append(("genre", .string(genre))) }
        members.append(("duration", .string(clock(song.duration))))
        if song.isFavorite { members.append(("liked", .bool(true))) }
        return ClaudeJSON.object(members)
    }

    private static func clamp(_ value: JSONValue?, default fallback: Int, range: ClosedRange<Int>) -> Int {
        guard let raw = value.flatMap({ KotlinxJSON.long($0) }) else { return fallback }
        return Int(min(max(raw, Int64(range.lowerBound)), Int64(range.upperBound)))
    }

    nonisolated static func clock(_ ms: Int64) -> String {
        let total = max(ms, 0) / 1000
        let seconds = total % 60
        return "\(total / 60):" + (seconds < 10 ? "0\(seconds)" : "\(seconds)")
    }
}
