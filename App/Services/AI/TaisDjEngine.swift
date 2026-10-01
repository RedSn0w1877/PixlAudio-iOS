import Foundation
import PixlLibrary
import PixlModel
import PixlNet

/// What the media router found for a DJ prompt (Android `DjRouteResult`).
nonisolated enum DjRouteResult: Sendable, Equatable {
    /// Songs already in the library, playable at once.
    case offline([Song])
    /// Catalogue results (Spotify, or YouTube Music when Spotify isn't linked), imported on tap.
    case online([SearchResultItem], source: SearchSource)
    case noResults

    var count: Int {
        switch self {
        case .offline(let songs): songs.count
        case .online(let items, _): items.count
        case .noResults: 0
        }
    }
}

/// One reply from Taizo (Android `TaizoTurn`).
nonisolated enum TaizoTurn: Sendable, Equatable {
    /// `aiIntro` decorates an already-resolved result; nil falls back to the plain count line.
    case media(DjIntent, DjRouteResult, aiIntro: String?)
    case conversation(String)
    case error(String)
}

/// TAIS Engine 3 (Android `TaisDjEngine`): a play/queue/find prompt (`TaisIntentParser.isMediaRequest`) goes
/// through the deterministic intent parser and the media router — instant, offline-capable, no key needed — and
/// gets a best-effort AI intro line (1.2 s budget); anything else is a real question for the configured AI provider
/// (`TAIZO_CHAT`, 25 s budget).
nonisolated struct TaisDjEngine: Sendable {
    static let chatTimeoutSeconds: Double = 25
    static let introTimeoutSeconds: Double = 1.2

    let router: TaisMediaRouter
    let orchestrator: AiOrchestrator

    func respond(_ prompt: String) async -> TaizoTurn {
        if TaisIntentParser.isMediaRequest(prompt) {
            let intent = TaisIntentParser.parse(prompt)
            let result = await router.route(intent)
            return .media(intent, result, aiIntro: await aiIntro(prompt: prompt, result: result))
        }
        do {
            let orchestrator = self.orchestrator
            let reply = try await withTimeout(seconds: Self.chatTimeoutSeconds) {
                try await orchestrator.generateContent(prompt: prompt, type: .taizoChat)
            }
            guard let reply else { return .error("The AI provider took too long. Try again, or ask me to find music.") }
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .error("The AI provider returned an empty response. Please try again.") : .conversation(trimmed)
        } catch is CancellationError {
            return .error("Couldn't reach an AI provider.")
        } catch {
            let message = (error as? AiGenerationError)?.message ?? String(describing: error)
            return .error(message.isEmpty ? "Couldn't reach an AI provider." : message)
        }
    }

    /// Android `buildAiIntro`: one short upbeat line, or nil (no results, no provider, slow, or failed).
    private func aiIntro(prompt: String, result: DjRouteResult) async -> String? {
        let count = result.count
        guard count > 0 else { return nil }
        let introPrompt = "user_request=\"\(prompt)\", results_found=\(count). Write ONE short, "
            + "upbeat sentence (max 12 words) introducing these results to the user. No quotes, no emoji."
        let orchestrator = self.orchestrator
        guard let raw = try? await withTimeout(seconds: Self.introTimeoutSeconds, {
            try await orchestrator.generateContent(prompt: introPrompt, type: .taizoChat)
        }) else { return nil }
        let line = Self.trimQuotes(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        return line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : line
    }

    /// Kotlin `trim('"')`.
    static func trimQuotes(_ text: String) -> String {
        var slice = Substring(text)
        while slice.first == "\"" { slice = slice.dropFirst() }
        while slice.last == "\"" { slice = slice.dropLast() }
        return String(slice)
    }
}

/// Resolves DJ intents (Android `TaisMediaRouter`): the library first (an exact title or artist already there starts
/// without a network round trip), then the Spotify catalogue (10 s), then YouTube Music (15 s), else the local
/// result. Remote providers come from the Search seam (`SearchProviding`, stages 11/12); an unavailable source
/// returns nothing and is skipped. iOS has no connectivity flag: an offline device simply gets no remote results.
nonisolated struct TaisMediaRouter: Sendable {
    static let offlineLimit = 50
    static let remoteLimit = 12

    let songs: @MainActor @Sendable () -> [Song]
    let remoteProviders: [any SearchProviding]

    func route(_ intent: DjIntent) async -> DjRouteResult {
        let library = await songs()
        let local = Self.routeOffline(intent, songs: library)
        if !intent.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty, intent.genres.isEmpty, intent.moods.isEmpty,
           case .offline = local {
            return local
        }
        let query = Self.buildQuery(intent)
        guard !query.isEmpty else { return local }
        for provider in remoteProviders {
            let timeout: Double = provider.source == .spotify ? 10 : 15
            let filter: SearchFilterType = provider.source == .spotify ? .catalog : .youtubeMusic
            let found = try? await withTimeout(seconds: timeout) {
                try await provider.search(query, filter: filter, limit: Self.remoteLimit)
            }
            let tracks = found?.filter(Self.isRemoteTrack) ?? []
            if !tracks.isEmpty { return .online(Array(tracks.prefix(Self.remoteLimit)), source: provider.source) }
        }
        return local
    }

    /// Android `TaisChatViewModel.resolveOnlineTracks`: imports catalogue results through the same pipeline the
    /// Search screen uses (`importAndPlay`: Spotify import → YouTube match, or the YouTube Music track) and returns
    /// the playable songs, in order. Tracks that can't be imported are skipped.
    func resolve(_ items: [SearchResultItem], source: SearchSource) async -> [Song] {
        guard let provider = remoteProviders.first(where: { $0.source == source }) else { return [] }
        var songs: [Song] = []
        for item in items {
            if Task.isCancelled { break }
            if let song = await provider.importAndPlay(item) { songs.append(song) }
        }
        return songs
    }

    static func isRemoteTrack(_ item: SearchResultItem) -> Bool {
        switch item {
        case .catalog, .youtubeMusic: true
        default: false
        }
    }

    /// `routeOffline`: title/artist search for a free-text query, genre matches for genres (both: genre matches
    /// whose artist or title contains every query token), at most 50.
    static func routeOffline(_ intent: DjIntent, songs: [Song]) -> DjRouteResult {
        let query = intent.searchQuery
        let hasQuery = !query.trimmingCharacters(in: .whitespaces).isEmpty
        var seen = Set<String>()
        let genreMatches = intent.genres.flatMap { songsByGenre($0, in: songs) }.filter { seen.insert($0.id).inserted }
        let matched: [Song]
        if hasQuery && !intent.genres.isEmpty {
            let tokens = query.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            matched = genreMatches.filter { song in
                tokens.allSatisfy { song.artist.localizedCaseInsensitiveContains($0) || song.title.localizedCaseInsensitiveContains($0) }
            }
        } else if hasQuery {
            matched = SearchIndex(songs: songs).searchSongs(query)
        } else {
            matched = genreMatches
        }
        return matched.isEmpty ? .noResults : .offline(Array(matched.prefix(offlineLimit)))
    }

    /// `getMusicByGenre`: the genre column equals the name or holds it in a comma-separated list (SQLite `LIKE`,
    /// ASCII case-insensitive), ordered by title.
    static func songsByGenre(_ genre: String, in songs: [Song]) -> [Song] {
        let target = genre.lowercased()
        return songs.filter { song in
            guard let value = song.genre?.lowercased(), !value.isEmpty else { return false }
            if value == target { return true }
            return value.split(separator: ",", omittingEmptySubsequences: false).contains { part in
                var token = Substring(part)
                if token.first == " " { token = token.dropFirst() }
                return token == Substring(target)
            }
        }.sorted { $0.title.utf8.lexicographicallyPrecedes($1.title.utf8) }
    }

    /// `buildQuery`: genres, moods, then the free text, distinct, space-joined.
    static func buildQuery(_ intent: DjIntent) -> String {
        var seen = Set<String>()
        return (intent.queryTerms + [intent.searchQuery])
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && seen.insert($0).inserted }
            .joined(separator: " ")
    }
}
