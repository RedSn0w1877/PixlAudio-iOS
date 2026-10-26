import Foundation
import PixlFoundation
import PixlLibrary
import PixlModel
import PixlNet
import Synchronization

/// Ask Taizo's client tools (spec A4) on the app's stores: the library and the Spotify catalogue (Search's providers),
/// playback and the queue, playlists and likes (`LibraryEditor`), listening stats (the history Home reads — imported
/// history included), the taste profile and the taste changes (`TasteAdjustmentStore`), lyrics (`LyricsService`) and
/// Sing (`InstrumentalController`). The schemas and the confirmation rules are PixlNet's (`TaizoTool`,
/// `TaizoAssistant.confirmationQuestion`); the loop validates every input against its schema before `run` is called.
nonisolated struct TaizoToolbox: ClaudeToolExecuting {
    let environment: @MainActor @Sendable () -> AppEnvironment?
    /// The Spotify catalogue (nil when unavailable).
    let catalog: (any SearchProviding)?
    /// Catalogue tracks the model has seen in this conversation's searches, by `spotify:track:<id>`.
    let seen = TaizoCatalogCache()
    /// The user's own message for the turn that is running: the only thing that may justify a taste change.
    let turn = TaizoTurnState()

    var definitions: [ClaudeToolDefinition] { TaizoTool.definitions }

    func confirmation(for call: ClaudeToolUse) async -> String? {
        let environment = self.environment
        // The taste changes are read first: "clear all" asks only when there is something to clear.
        let store = await MainActor.run { environment()?.tasteAdjustments }
        await store?.ensureLoaded()
        let counts = await MainActor.run { (queue: environment()?.playback.queue.count ?? 0, taste: store?.count ?? 0) }
        return TaizoAssistant.confirmationQuestion(tool: call.name, input: call.input, currentQueueCount: counts.queue,
                                                   adjustmentCount: counts.taste)
    }

    func run(_ call: ClaudeToolUse) async -> ClaudeToolOutput {
        guard let tool = TaizoTool(rawValue: call.name) else { return .error("Unknown tool \(call.name).") }
        return await TaizoToolRunner.run(tool, input: call.input, environment: environment, catalog: catalog, seen: seen, turn: turn)
    }
}

/// Catalogue results by id, shared by the calls of one conversation.
nonisolated final class TaizoCatalogCache: Sendable {
    private let tracks = Mutex<[String: CatalogTrack]>([:])
    /// The seed of `search_library`'s "random" sort for this conversation, so paging with `offset` walks one shuffle.
    let randomSeed = Int64.random(in: Int64.min...Int64.max)

    func remember(_ track: CatalogTrack) -> String {
        let id = "spotify:track:\(track.spotifyId)"
        tracks.withLock { $0[id] = track }
        return id
    }

    func track(_ id: String) -> CatalogTrack? { tracks.withLock { $0[id] } }
}

/// What the running turn is about: the user's own message. Set by the chat before the loop starts, read by the
/// taste-change tools (`TasteChangeGuard`). Text from a web page, a lyric or a tool result never lands here.
nonisolated final class TaizoTurnState: Sendable {
    private let message = Mutex<String?>(nil)

    func begin(userMessage: String) { message.withLock { $0 = userMessage } }

    func end() { message.withLock { $0 = nil } }

    var userMessage: String? { message.withLock { $0 } }
}

/// The tools' work, on the main actor (the stores live there); anything heavy goes to a detached task.
@MainActor
enum TaizoToolRunner {
    static let maxSongsPerCall = TaizoTasteRules.maxSongsPerCall

    static func run(_ tool: TaizoTool, input: JSONObject, environment: @MainActor @Sendable () -> AppEnvironment?,
                    catalog: (any SearchProviding)?, seen: TaizoCatalogCache, turn: TaizoTurnState) async -> ClaudeToolOutput {
        guard let env = environment() else { return .error("PixlAudio isn't ready yet. Try again in a moment.") }
        // Blocked music is left out of what Taizo plays and queues, so the changes must be read first.
        await env.tasteAdjustments.ensureLoaded()
        switch tool {
        case .searchLibrary: return await searchLibrary(env, input, seen: seen)
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
        case .getTasteProfile: return await tasteProfile(env, input)
        case .getLibraryOverview: return await libraryOverview(env)
        case .adjustTaste: return await adjustTaste(env, input, turn: turn)
        case .listTasteAdjustments: return listTasteAdjustments(env)
        case .removeTasteAdjustment: return removeTasteAdjustment(env, input, turn: turn)
        }
    }

    // MARK: Search

    private static func searchLibrary(_ env: AppEnvironment, _ input: JSONObject, seen: TaizoCatalogCache) async -> ClaudeToolOutput {
        let songs = env.library.songs
        guard !songs.isEmpty else {
            return .json(ClaudeJSON.object([("count", .integer(0)), ("songs", .array([])), ("note", .string("The library is empty."))]))
        }
        func text(_ key: String) -> String? {
            let value = (input[key]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        func number(_ key: String) -> Int? { input[key].flatMap { KotlinxJSON.long($0) }.map { Int(clamping: $0) } }
        let query = LibraryQuery(
            text: text("query") ?? "", artist: text("artist"), album: text("album"), genre: text("genre"),
            yearFrom: number("year_from"), yearTo: number("year_to"), minPlays: number("min_plays"), maxPlays: number("max_plays"),
            likedOnly: input["liked_only"]?.boolValue ?? false, neverPlayed: input["never_played"]?.boolValue ?? false,
            sort: input["sort"]?.stringValue.flatMap(LibraryQuery.Sort.init(rawValue:)) ?? .relevance,
            limit: clamp(input["limit"], default: LibraryQuery.defaultLimit, range: 1...LibraryQuery.maxLimit),
            offset: clamp(input["offset"], default: 0, range: 0...Int.max))

        await TaizoTaste.prepare(env)
        let stats = await TaizoTaste.playStats(env)
        let index = TaizoTaste.cache.index(revision: env.library.songsRevision)
        // One shuffle per conversation: "random" pages (offset) are cut from the same order, so they don't repeat songs.
        let seed = seen.randomSeed
        let result = await Task.detached(priority: .userInitiated) { () -> (page: LibraryPage, index: SearchIndex?) in
            var index = index
            if index == nil, !query.text.isEmpty { index = SearchIndex(songs: songs) }
            return (LibraryQueryEngine.run(query, songs: songs, stats: stats, index: index, seed: seed), index)
        }.value
        if let built = result.index, TaizoTaste.cache.index(revision: env.library.songsRevision) == nil {
            TaizoTaste.cache.setIndex(built, revision: env.library.songsRevision)
        }
        let taste = env.tasteAdjustments.activeSet(nowMs: currentTimeMillis())
        let page = result.page
        var members: [(String, JSONValue)] = [
            ("count", .integer(page.songs.count)), ("total_matches", .integer(page.totalMatches)),
            ("offset", .integer(page.offset)),
        ]
        if let next = page.nextOffset { members.append(("next_offset", .integer(next))) }
        if page.totalIsLowerBound { members.append(("total_note", .string("At least this many; the words matched more than the search keeps."))) }
        members.append(("songs", .array(page.songs.map { songJSON($0, plays: stats[$0.id]?.plays ?? 0, taste: taste) })))
        return .json(ClaudeJSON.object(members))
    }

    private static func libraryOverview(_ env: AppEnvironment) async -> ClaudeToolOutput {
        let songs = env.library.songs
        await TaizoTaste.prepare(env)
        let stats = await TaizoTaste.playStats(env)
        let snapshot = env.library.snapshot
        let artists = snapshot.artists.count, albums = snapshot.albums.count, playlists = snapshot.playlists.count
        let overview = await Task.detached(priority: .userInitiated) {
            LibraryOverview.build(songs: songs, stats: stats, artists: artists > 0 ? artists : nil,
                                  albums: albums > 0 ? albums : nil, playlists: playlists)
        }.value
        return .json(overview.json())
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
                } else if let track = seen.track(id), let catalog, let song = await catalog.importForPlayback(.catalog(track)) {
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
            let revision = env.library.songsRevision
            let wanted = Array(queries.prefix(max(maxSongsPerCall - songs.count, 0)))
            // One index for every query, the one `search_library` keeps (built once per library revision): a fresh index
            // per query made a 200-query call rebuild it over the whole library 200 times.
            let cached = TaizoTaste.cache.index(revision: revision)
            let lookup = await Task.detached(priority: .userInitiated) { () -> (hits: [Song?], built: SearchIndex?) in
                let index = cached ?? SearchIndex(songs: library)
                return (wanted.map { index.searchSongs($0, limit: 1).first }, cached == nil ? index : nil)
            }.value
            if let built = lookup.built, env.library.songsRevision == revision,
               TaizoTaste.cache.index(revision: revision) == nil {
                TaizoTaste.cache.setIndex(built, revision: revision)
            }
            for (query, hit) in zip(wanted, lookup.hits) {
                if let hit {
                    songs.append(hit)
                    continue
                }
                if let catalog, let items = try? await catalog.search(query, filter: .catalog, limit: 1),
                   case .catalog(let track)? = items.first(where: { if case .catalog = $0 { true } else { false } }) {
                    if let song = librarySong(spotifyId: track.spotifyId) {
                        songs.append(song)
                    } else if let song = await catalog.importForPlayback(.catalog(track)) {
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

    /// Blocked music (Ask Taizo's taste changes) is never queued or played by Taizo: the songs left out, by name.
    private static func withoutBlocked(_ env: AppEnvironment, _ songs: [Song]) -> (kept: [Song], blocked: [String]) {
        let taste = env.tasteAdjustments.activeSet(nowMs: currentTimeMillis())
        if taste.isEmpty { return (songs, []) }
        var kept: [Song] = []
        var blocked: [String] = []
        for song in songs {
            if taste.isBlocked(song) {
                blocked.append("\(song.title) — \(song.displayArtist)")
            } else {
                kept.append(song)
            }
        }
        return (kept, blocked)
    }

    /// `skipped_blocked` for a result, when there is any (and what to tell the user).
    private static func blockedMember(_ blocked: [String]) -> [(String, JSONValue)] {
        guard !blocked.isEmpty else { return [] }
        return [("skipped_blocked", .array(blocked.prefix(20).map(JSONValue.string))),
                ("blocked_note", .string("These are blocked in the user's taste changes and were left out. Tell them; they can unblock with adjust_taste if they ask."))]
    }

    private static let allBlockedMessage = "Every one of those songs is blocked in the user's taste changes, so nothing was done. Tell them, and offer to unblock if they want."

    // MARK: Playback

    private static func playSongs(_ env: AppEnvironment, _ input: JSONObject, catalog: (any SearchProviding)?,
                                  seen: TaizoCatalogCache) async -> ClaudeToolOutput {
        let (resolved, missing) = await resolve(env, input, catalog: catalog, seen: seen)
        guard !resolved.isEmpty else { return .error("None of those songs could be found. Search first and use the ids returned.") }
        let (songs, blocked) = withoutBlocked(env, resolved)
        guard !songs.isEmpty else { return .error(allBlockedMessage) }
        let start = min(clamp(input["start_index"], default: 0, range: 0...Int.max), songs.count - 1)
        env.playback.play(songs, startIndex: start)
        var members: [(String, JSONValue)] = [
            ("now_playing", .string("\(songs[start].title) — \(songs[start].displayArtist)")),
            ("queue_length", .integer(songs.count)), ("not_found", .array(missing.map(JSONValue.string))),
        ]
        members += blockedMember(blocked)
        return .json(ClaudeJSON.object(members))
    }

    private static func addToQueue(_ env: AppEnvironment, _ input: JSONObject, catalog: (any SearchProviding)?,
                                   seen: TaizoCatalogCache) async -> ClaudeToolOutput {
        let (resolved, missing) = await resolve(env, input, catalog: catalog, seen: seen)
        guard !resolved.isEmpty else { return .error("None of those songs could be found. Search first and use the ids returned.") }
        let (songs, blocked) = withoutBlocked(env, resolved)
        guard !songs.isEmpty else { return .error(allBlockedMessage) }
        let next = input["play_next"]?.boolValue ?? false
        if !env.playback.hasItem {
            env.playback.play(songs, startIndex: 0)
        } else if next {
            env.playback.playNext(songs)
        } else {
            env.playback.addToQueue(songs)
        }
        var members: [(String, JSONValue)] = [
            ("added", .integer(songs.count)), ("position", .string(next ? "next" : "end of queue")),
            ("not_found", .array(missing.map(JSONValue.string))),
        ]
        members += blockedMember(blocked)
        return .json(ClaudeJSON.object(members))
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
        let (resolved, missing) = await resolve(env, input, catalog: catalog, seen: seen)
        guard !resolved.isEmpty else { return .error("None of those songs could be found. Search first and use the ids returned.") }
        let (songs, blocked) = withoutBlocked(env, resolved)
        guard !songs.isEmpty else { return .error(allBlockedMessage) }
        let playlist = env.libraryEditor.createPlaylist(name: name, songIds: songs.map(\.id), isAiGenerated: true)
        var members: [(String, JSONValue)] = [
            ("created", .string(playlist.name)), ("playlist_id", .string(playlist.id)),
            ("songs", .integer(playlist.songIds.count)), ("not_found", .array(missing.map(JSONValue.string))),
        ]
        members += blockedMember(blocked)
        return .json(ClaudeJSON.object(members))
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
        var blocked: [String] = []
        let hasIds = !(input["song_ids"]?.arrayValue ?? []).isEmpty || !(input["queries"]?.arrayValue ?? []).isEmpty
        if hasIds {
            let found = await resolve(env, input, catalog: catalog, seen: seen)
            let allowed = withoutBlocked(env, found.songs)
            missing = found.missing
            songs = allowed.kept
            blocked = allowed.blocked
            if !found.songs.isEmpty, songs.isEmpty { return .error(allBlockedMessage) }
        } else if let current = env.playback.current {
            songs = [current]
        } else {
            return .error("Nothing is playing; say which songs to add.")
        }
        guard !songs.isEmpty else { return .error("None of those songs could be found.") }
        let before = Set(playlist.songIds)
        env.libraryEditor.addSongs(songs.map(\.id), toPlaylist: playlist.id)
        let added = songs.filter { !before.contains($0.id) }.count
        var members: [(String, JSONValue)] = [
            ("playlist", .string(playlist.name)), ("added", .integer(added)),
            ("already_there", .integer(songs.count - added)), ("not_found", .array(missing.map(JSONValue.string))),
        ]
        members += blockedMember(blocked)
        return .json(ClaudeJSON.object(members))
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

    // MARK: Taste

    private static func tasteProfile(_ env: AppEnvironment, _ input: JSONObject) async -> ClaudeToolOutput {
        let period = input["period"]?.stringValue.flatMap(ListeningPeriod.init(toolValue:)) ?? .sixMonths
        let profile = await TaizoTaste.profile(env, period: period)
        return .json(profile.json())
    }

    /// `adjust_taste`: only on the user's own word (`TasteChangeGuard`), then each target is resolved against the library
    /// off the main thread and applied; the answer says what each change did and how to undo it.
    private static func adjustTaste(_ env: AppEnvironment, _ input: JSONObject, turn: TaizoTurnState) async -> ClaudeToolOutput {
        if case .refused(let why) = TasteChangeGuard.check(input: input, lastUserMessage: turn.userMessage) {
            return .error(why)
        }
        let songs = env.library.songs
        let planned = await Task.detached(priority: .userInitiated) {
            TasteToolPlanner.plan(input: input, songs: songs)
        }.value
        let plan: TasteToolPlanner.Plan
        switch planned {
        case .failure(let failure): return .error(failure.message)
        case .success(let value): plan = value
        }
        let outcomes = await env.tasteAdjustments.apply(plan.changes)
        return .json(TasteToolPlanner.report(plan: plan, outcomes: outcomes, nowMs: currentTimeMillis()))
    }

    private static func listTasteAdjustments(_ env: AppEnvironment) -> ClaudeToolOutput {
        .json(TasteToolPlanner.listJSON(env.tasteAdjustments.items, nowMs: currentTimeMillis()))
    }

    /// `remove_taste_adjustment`: one by id, or all (the loop already asked the user for that).
    private static func removeTasteAdjustment(_ env: AppEnvironment, _ input: JSONObject, turn: TaizoTurnState) -> ClaudeToolOutput {
        if case .refused(let why) = TasteChangeGuard.checkRemoval(lastUserMessage: turn.userMessage) { return .error(why) }
        let store = env.tasteAdjustments
        if input["all"]?.boolValue == true {
            let removed = store.removeAll()
            return .json(ClaudeJSON.object([("removed", .integer(removed)), ("remaining", .integer(0))]))
        }
        let id = (input["id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return .error("Pass the id of the change to remove (list_taste_adjustments), or all: true.") }
        guard store.remove(id: id) else {
            return .error("No taste change has the id \(id). list_taste_adjustments shows the ids.")
        }
        return .json(ClaudeJSON.object([("removed", .integer(1)), ("id", .string(id)), ("remaining", .integer(store.count))]))
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

    /// id, title, artist, album, year, plays (liked and the taste flag only when they apply).
    private static func songJSON(_ song: Song, plays: Int, taste: TasteAdjustmentSet) -> JSONValue {
        var members: [(String, JSONValue)] = [("id", .string(song.id)), ("title", .string(song.title)),
                                              ("artist", .string(song.displayArtist)), ("album", .string(song.album))]
        if song.year > 0 { members.append(("year", .integer(song.year))) }
        members.append(("plays", .integer(plays)))
        if song.isFavorite { members.append(("liked", .bool(true))) }
        if !taste.isEmpty {
            let evaluation = taste.evaluate(song)
            if evaluation.isBlocked {
                members.append(("taste", .string("blocked")))
            } else if evaluation.isExcluded {
                members.append(("taste", .string("muted")))
            } else if evaluation.factor > 1.0 {
                members.append(("taste", .string("boosted")))
            } else if evaluation.factor < 1.0 {
                members.append(("taste", .string("reduced")))
            }
        }
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
