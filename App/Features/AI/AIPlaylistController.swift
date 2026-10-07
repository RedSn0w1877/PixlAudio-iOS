import Foundation
import Observation
import PixlLibrary
import PixlModel
import PixlNet

/// The AI playlist state holder (Android `AiStateHolder`, a `@Singleton`): drives the AI playlist sheet (Daily
/// Mix's sparkle button) and the AI Playlist Lab (Library › Create playlist › With AI), refines the Daily Mix with a
/// prompt, and maps failures to Android's messages. Lives in `AIService`, so a generation keeps running (and its
/// state survives) when the sheet is dismissed and reopened.
///
/// With the on-device model selected (the default since 2026-10-07) the requests go to `OnDevicePlaylistCurator`
/// instead of PixlNet's generator, whose cloud prompt doesn't fit the on-device window.
@Observable
final class AIPlaylistController {
    private(set) var isGenerating = false
    private(set) var isSuccess = false
    private(set) var status: String?
    private(set) var error: String?

    @ObservationIgnored private var lastPrompt: String?
    @ObservationIgnored private var lastMinLength = 5
    @ObservationIgnored private var lastMaxLength = 15
    @ObservationIgnored private var task: Task<Void, Never>?

    @ObservationIgnored private let generator: AiPlaylistGenerator
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let home: HomeStore
    @ObservationIgnored private let playback: PlaybackStore
    @ObservationIgnored private let router: Router
    @ObservationIgnored private let libraryEditor: @MainActor () -> LibraryEditor
    /// The on-device curator (nil in UI tests: the scripted provider answers through the generator).
    @ObservationIgnored private let curator: OnDevicePlaylistCurator?
    /// The on-device model is the selected provider.
    @ObservationIgnored private let usesOnDeviceCurator: @MainActor () -> Bool

    init(generator: AiPlaylistGenerator, settings: SettingsStore, library: LibraryStore, home: HomeStore,
         playback: PlaybackStore, router: Router, libraryEditor: @escaping @MainActor () -> LibraryEditor,
         curator: OnDevicePlaylistCurator? = nil, usesOnDeviceCurator: @escaping @MainActor () -> Bool = { false }) {
        self.generator = generator
        self.settings = settings
        self.library = library
        self.home = home
        self.playback = playback
        self.router = router
        self.libraryEditor = libraryEditor
        self.curator = curator
        self.usesOnDeviceCurator = usesOnDeviceCurator
    }

    // MARK: Sheet state

    /// `dismissAiPlaylistSheet`: the sheet closes and every flag resets (a running generation keeps going).
    func reset() {
        error = nil
        isSuccess = false
        isGenerating = false
        status = nil
    }

    func clearError() { error = nil }

    /// `retryLastPlaylistGeneration`.
    func retry() {
        guard let lastPrompt else { return }
        generate(prompt: lastPrompt, minLength: lastMinLength, maxLength: lastMaxLength)
    }

    // MARK: Generation (`generateAiPlaylist`)

    /// Curates a playlist from the library for `prompt`. Play mode (the sheet) replaces the Daily Mix, starts it and
    /// opens the player; save mode (the Lab) creates an AI playlist named after the request.
    func generate(prompt: String, minLength: Int, maxLength: Int, saveAsPlaylist: Bool = false, playlistName: String? = nil) {
        lastPrompt = prompt
        lastMinLength = minLength
        lastMaxLength = maxLength
        task?.cancel()
        task = Task { [weak self] in
            await self?.runGeneration(prompt: prompt, minLength: minLength, maxLength: maxLength,
                                      saveAsPlaylist: saveAsPlaylist, playlistName: playlistName)
        }
    }

    private func runGeneration(prompt: String, minLength: Int, maxLength: Int, saveAsPlaylist: Bool, playlistName: String?) async {
        let allSongs = library.songs
        isGenerating = true
        error = nil
        isSuccess = false
        defer {
            isGenerating = false
            status = nil
        }

        status = "Analyzing your library stats..."
        let existingNames = Set(library.playlists.map { $0.name.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })

        status = "Selecting best candidates..."
        let context = await requestContext(allSongs: allSongs, candidateLimit: 120)

        status = "Consulting the Daily Mix guide..."
        let result = await curate(prompt: prompt, allSongs: allSongs, minLength: minLength, maxLength: maxLength,
                                  context: context, type: .playlist)
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let songs) where !songs.isEmpty:
            if saveAsPlaylist {
                let name = Self.resolvePlaylistName(requestedName: playlistName, prompt: prompt, existingNames: existingNames)
                libraryEditor().createPlaylist(name: name, songIds: songs.map(\.id), isAiGenerated: true)
                status = "Success! Your mix is ready."
                isSuccess = true
                LibraryToast.shared.show("AI Playlist created!")
                try? await Task.sleep(for: .milliseconds(1200))
                reset()
            } else {
                status = "Starting playback..."
                isSuccess = true
                home.setDailyMix(songs)
                playback.play(songs, startIndex: 0)
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                router.dismissSheet()
                reset()
                // Android opens the player sheet under the AI sheet; iOS presents it once the sheet has gone.
                try? await Task.sleep(for: .milliseconds(450))
                if router.sheet == nil, router.cover == nil { router.present(AppCover.nowPlaying) }
            }
        case .success:
            status = nil
            error = "AI couldn't find any songs for your prompt."
        case .failure(let failure):
            status = nil
            error = Self.resolveErrorMessage(failure.message)
        }
    }

    // MARK: Daily Mix refinement (`regenerateDailyMixWithPrompt`)

    /// Re-curates today's Daily Mix around `prompt` (`DAILY_MIX` prompt type, 60–100 % of the current mix size).
    /// Returns the toast Android shows.
    @discardableResult
    func refineDailyMix(prompt: String) async -> String {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Write an idea for your Daily Mix" }
        let allSongs = library.songs
        let current = home.content.dailyMix
        isGenerating = true
        error = nil
        defer {
            isGenerating = false
            status = nil
        }
        status = "Refining your Daily Mix..."
        let desiredSize = current.isEmpty ? 25 : current.count
        let minLength = max(Int(Double(desiredSize) * 0.6), 10)
        let maxLength = max(desiredSize, 20)
        status = "Scanning for vibes..."
        let context = await requestContext(allSongs: allSongs, candidateLimit: 100)
        status = "Applying AI filters..."
        let result = await curate(prompt: prompt, allSongs: allSongs, minLength: minLength, maxLength: maxLength,
                                  context: context, type: .dailyMix)
        switch result {
        case .success(let songs) where !songs.isEmpty:
            home.setDailyMix(songs)
            return "Daily Mix updated with AI"
        case .success:
            return "AI couldn't find songs for this mix"
        case .failure(let failure):
            error = Self.resolveErrorMessage(failure.message)
            return "Could not update: \(Self.errorDetail(failure.message))"
        }
    }

    /// The on-device curator when the on-device model is selected, else PixlNet's generator (Android's prompt).
    private func curate(prompt: String, allSongs: [Song], minLength: Int, maxLength: Int, context: RequestContext,
                        type: AiSystemPromptType) async -> Result<[Song], AiPlaylistGenerationError> {
        if let curator, usesOnDeviceCurator() {
            let candidates = context.candidates.isEmpty ? context.ranked : context.candidates
            return await curator.curate(OnDevicePlaylistCurator.Request(
                prompt: prompt, minimum: minLength, maximum: maxLength, allSongs: allSongs, candidates: candidates,
                playCounts: context.playCounts, taste: context.taste, type: type))
        }
        return await generator.generate(userPrompt: prompt, allSongs: allSongs, minLength: minLength, maxLength: maxLength,
                                        candidateSongs: context.candidates, rankedCandidates: context.ranked,
                                        playCounts: context.playCounts, userDigest: context.digest,
                                        settings: generationSettings, type: type)
    }

    // MARK: Request context

    private var generationSettings: AiPlaylistGenerator.Settings {
        AiPlaylistGenerator.Settings(safeTokenLimit: settings.ai.safeTokenLimit, sampleSize: settings.ai.sampleSize,
                                     includeExtendedFields: settings.ai.includeExtendedFields)
    }

    nonisolated struct RequestContext: Sendable {
        var candidates: [Song]
        var ranked: [Song]
        var playCounts: [String: Int]
        var digest: String
        /// The digest's genres, artists and phase without ids (the on-device curator's taste line).
        var taste = OnDeviceCuration.Taste()
    }

    /// The candidate pool (`DailyMixManager.generateDailyMix`, today's seed), the AI ranking fallback
    /// (`getTopCandidatesForAi`, seed + 42), per-song play counts and the listening-profile digest — computed off the
    /// main thread from the library and the playback history.
    private func requestContext(allSongs: [Song], candidateLimit: Int) async -> RequestContext {
        await home.history.ensureLoaded()
        let events = home.history.events
        let clock = home.history.clock
        let playlistNames = library.playlists.map(\.name)
        let safe = settings.ai.safeTokenLimit
        let digestMode = settings.ai.digestMode
        let extended = settings.ai.includeExtendedFields
        return await Task.detached(priority: .userInitiated) {
            Self.computeContext(allSongs: allSongs, events: events, nowMs: clock.nowMs(), timeZone: clock.timeZone,
                                playlistNames: playlistNames, candidateLimit: candidateLimit, safeTokenLimit: safe,
                                digestMode: digestMode, includeExtendedFields: extended)
        }.value
    }

    nonisolated static func computeContext(allSongs: [Song], events: [PlaybackEvent], nowMs: Int64, timeZone: TimeZone,
                                           playlistNames: [String], candidateLimit: Int, safeTokenLimit: Bool,
                                           digestMode: String, includeExtendedFields: Bool) -> RequestContext {
        let engagements = HomeStore.engagementStats(events)
        let favorites = Set(allSongs.filter(\.isFavorite).map(\.id))
        let epochDay = ZoneClock(timeZone).localDate(at: nowMs).epochDay
        let candidates = DailyMix.personalizedPicks(allSongs: allSongs, favoriteSongIds: favorites, engagements: engagements,
                                                    storedSignals: [:], nowMs: nowMs, limit: candidateLimit,
                                                    seed: DailyMix.dailySeed(epochDay: epochDay)).map(\.song)
        let ranked = candidates.isEmpty
            ? DailyMix.personalizedPicks(allSongs: allSongs, favoriteSongIds: [], engagements: engagements, storedSignals: [:],
                                         nowMs: nowMs, limit: 100, seed: DailyMix.aiCandidatesSeed(epochDay: epochDay)).map(\.song)
            : []
        let summary = PlaybackStats.buildSummary(range: .all, songs: allSongs, nowMillis: nowMs, events: events, timeZone: timeZone)
        let listening = AiListeningSummary(
            totalPlayCount: summary.totalPlayCount, uniqueSongs: summary.uniqueSongs,
            topGenres: summary.topGenres.map(\.genre), topArtists: summary.topArtists.map(\.artist),
            dayBuckets: summary.dayListeningDistribution?.buckets.map {
                AiListeningSummary.DayBucket(startMinute: $0.startMinute, totalDurationMs: $0.totalDurationMs)
            },
            songs: summary.songs.map {
                AiListeningSummary.SongStat(songId: $0.songId, title: $0.title, artist: $0.artist, playCount: $0.playCount,
                                            totalDurationMs: $0.totalDurationMs)
            })
        let digest = AiProfileDigest.generate(allSongs: allSongs, summary: listening, playlistNames: playlistNames,
                                              isSafeLimit: safeTokenLimit, digestMode: digestMode,
                                              includeExtendedFields: includeExtendedFields)
        let taste = OnDeviceCuration.Taste(
            genres: Array(listening.topGenres.filter { $0 != PlaybackStats.unknownGenreLabel }.prefix(3)),
            artists: Array(listening.topArtists.prefix(3)),
            phase: listening.dayBuckets.flatMap { buckets in
                OnDeviceCuration.phase(buckets: buckets.map { (startMinute: $0.startMinute, durationMs: $0.totalDurationMs) })
            })
        return RequestContext(candidates: candidates, ranked: ranked, playCounts: engagements.mapValues(\.playCount),
                              digest: digest, taste: taste)
    }

    // MARK: Messages (`resolveAiErrorMessage` / `extractAiErrorDetail`)

    nonisolated static let apiKeyMessage = "Please configure a valid API key for the selected AI provider in Settings."

    /// The message without a leading "AI Error:" (Android strips it before classifying).
    nonisolated static func errorDetail(_ message: String) -> String {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: #"^AI\s*Error:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(range)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Unknown error" : text
    }

    /// Android's error table, in order. (Android also consults an `AiProviderException` in the cause chain; the
    /// generator's failure already carries the friendly text, so here — as on Android in practice — only the text
    /// rules apply.)
    ///
    /// iOS first: the on-device model's failures (not supported on this iPhone, turned off, still downloading, too
    /// long, stopped by the safety filters, language, busy, slow) keep their own message. Android's rows below match
    /// network words, which an on-device failure must never be read as.
    nonisolated static func resolveErrorMessage(_ message: String) -> String {
        if let onDevice = OnDeviceFailure.matching(message) { return onDevice.message }
        let detail = errorDetail(message)
        func has(_ words: String...) -> Bool { words.contains { detail.localizedCaseInsensitiveContains($0) } }
        if has("api key not valid", "invalid api key", "incorrect api key", "invalid key") { return apiKeyMessage }
        if has("timed out", "timeout") { return "Request timed out. The AI provider is slow or overloaded. Try again in a moment." }
        if has("network", "connect", "resolve host", "SocketException", "no internet", "offline", "wifi") {
            return "No Internet Connection. Please check your WiFi or mobile data and try again."
        }
        if has("airplane") { return "Airplane mode is on. Turn it off to use AI features." }
        if has("permission", "denied", "forbidden", "403") {
            return "Permission denied by the AI provider. Check that this API key has access to the selected model and that the provider API is enabled."
        }
        if has("unauthorized", "401") { return apiKeyMessage }
        if has("rate limit", "429", "too many requests") {
            return "Rate limited. The AI provider needs a short break. Wait 30 seconds and try again."
        }
        if has("safety", "blocked", "filtered") { return "Content was blocked by the AI's safety filters. Try rephrasing your request." }
        if has("valid playlist", "JSON array", "invalid response") {
            return "The AI returned an unexpected format. Try again or switch to a more capable model."
        }
        if has("No API key", "not configured") { return apiKeyMessage }
        if has("cooldown") { return "AI providers are cooling down after recent errors. Wait a few minutes and try again." }
        if has("empty response") {
            return "The AI returned an empty response. This typically means the model filtered the content. Try a different prompt."
        }
        return "AI Error: \(detail)"
    }

    // MARK: Playlist names (`resolveAiPlaylistName` / `generateShortAiTitle`)

    nonisolated static let titleStopWords: Set<String> = [
        "a", "an", "the", "and", "or", "for", "to", "of", "in", "on", "with", "by", "from",
        "de", "la", "el", "los", "las", "y", "o", "para", "con", "por", "del", "al", "un", "una",
        "core", "request", "mood", "target", "activity", "context", "era", "focus", "prioritize",
        "genres", "avoid", "preferred", "language", "energy", "level", "discovery", "where",
        "familiar", "deep", "cuts", "keep", "transitions", "smooth", "repetitive", "artist",
        "clustering", "songs", "listener", "favorites", "explicit", "lyrics", "alternatives",
        "whenever", "possible",
    ]

    /// The requested name (else a short title from the prompt), made unique with " 2", " 3", … (case-insensitive).
    nonisolated static func resolvePlaylistName(requestedName: String?, prompt: String, existingNames: Set<String>) -> String {
        let existing = Set(existingNames.map { $0.lowercased() })
        let requested = requestedName?.trimmingCharacters(in: .whitespaces) ?? ""
        let base = requested.isEmpty ? shortTitle(prompt) : requested
        let candidate = base.trimmingCharacters(in: .whitespaces).isEmpty ? "AI Mix" : base
        if !existing.contains(candidate.lowercased()) { return candidate }
        var counter = 2
        while existing.contains("\(candidate) \(counter)".lowercased()) { counter += 1 }
        return "\(candidate) \(counter)"
    }

    /// Two meaningful words of the core request (or the prompt), title-cased, at most 26 characters.
    nonisolated static func shortTitle(_ prompt: String) -> String {
        var source = prompt
        if let match = prompt.range(of: #"(?i)core request:\s*([^.]*)"#, options: .regularExpression) {
            let core = prompt[match].replacingOccurrences(of: #"(?i)^core request:\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !core.isEmpty { source = core }
        }
        let normalized = source.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let tokens = normalized.split(separator: " ").map(String.init).filter { $0.count >= 3 && !titleStopWords.contains($0) }
        let compact: String
        if tokens.count >= 2 {
            compact = tokens.prefix(2).joined(separator: " ")
        } else if tokens.count == 1 {
            compact = "\(tokens[0]) mix"
        } else {
            compact = fallbackTitle(normalized)
        }
        let titled = compact.split(separator: " ", omittingEmptySubsequences: false)
            .map { part in part.prefix(1).uppercased() + part.dropFirst() }
            .joined(separator: " ")
        let cut = String(titled.prefix(26)).trimmingCharacters(in: .whitespaces)
        return cut.isEmpty ? "AI Mix" : cut
    }

    nonisolated static func fallbackTitle(_ text: String) -> String {
        func any(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        if any(["workout", "gym", "run", "cardio"]) { return "Workout Mix" }
        if any(["focus", "study", "work", "productivity"]) { return "Focus Flow" }
        if any(["chill", "relax", "calm", "lofi"]) { return "Chill Vibes" }
        if any(["party", "dance", "club"]) { return "Party Mix" }
        if any(["night", "late", "sleep"]) { return "Night Vibes" }
        if any(["road", "trip", "drive"]) { return "Road Trip" }
        if any(["romantic", "love"]) { return "Love Notes" }
        if any(["sad", "melancholic"]) { return "Blue Hour" }
        return "Fresh Mix"
    }
}
