import BackgroundTasks
import Foundation
import Observation
import PixlModel
import PixlNet

/// The Spotify account, library and matcher as the UI sees them — the port of `SpotifyAuthManager` +
/// `SpotifyRepository` + the two WorkManager workers + the dashboard / accounts view-models' shared state.
///
/// Work runs off the main thread: PixlNet's `SpotifySession` (PKCE, the one actor that refreshes tokens and saves the
/// rotated refresh token before using the new access token), `SpotifyLibrarySync` (snapshot-safe sync over
/// `PersistenceActor`) and `SpotifyMatchRunner` (YouTube matching through `SpotifyYouTubeBridge`). This store holds
/// only the published state and schedules passes (Android's unique work: one sync, one matcher at a time).
@Observable
final class SpotifyService {
    // MARK: Published state (Android `SpotifyDashboardUiState` / `AccountsUiState`)

    private(set) var isLoggedIn = false
    private(set) var accountName: String?
    private(set) var accountEmail: String?
    private(set) var playlists: [SpotifyPlaylistRow] = []
    /// Distinct imported tracks.
    private(set) var totalSongs = 0
    private(set) var matchedCount = 0
    private(set) var pendingMatchCount = 0
    private(set) var unmatchedCount = 0
    private(set) var isSyncing = false
    /// The playlist being imported ("Importing <name>…").
    private(set) var syncStatus: String?
    private(set) var isMatching = false
    private(set) var isSigningIn = false
    private(set) var isLoggingOut = false
    private(set) var isTesting = false
    private(set) var testReport: SpotifyPlaybackTestReport?
    private(set) var playlistAccessDenied = false
    /// A one-off message for the UI (sign-in result, failures), cleared by `clearMessage()`.
    private(set) var message: String?
    /// Whether a client id is configured (Info.plist or the override).
    private(set) var hasClientId = false
    private(set) var clientIdOverride = ""

    // MARK: Dependencies

    @ObservationIgnored let isDemo: Bool
    @ObservationIgnored private let preferences: SpotifyPreferences
    @ObservationIgnored private let accounts: AccountsStore
    @ObservationIgnored private let persistence: PersistenceActor?
    @ObservationIgnored private let http: any HTTPClient
    @ObservationIgnored let bridge: any SpotifyYouTubeBridge
    @ObservationIgnored let session: SpotifySession
    @ObservationIgnored private let api: SpotifyWebAPI
    @ObservationIgnored private var sync: SpotifyLibrarySync?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var matchTask: Task<Void, Never>?
    @ObservationIgnored private var matchRetryFailedPending = false
    @ObservationIgnored private var reloadLibrary: @MainActor @Sendable () async -> Void = {}
    @ObservationIgnored private var isPlaybackActive: @MainActor @Sendable () -> Bool = { false }
    @ObservationIgnored private var baseResolver: any PlayableURLResolving = DefaultPlayableURLResolver()
    @ObservationIgnored private let demo: SpotifyDemo?
    /// The last catalogue search results by id (`SpotifyCatalogSearchProvider`).
    @ObservationIgnored var catalogCache: [String: SpotifyTrack] = [:]

    static let backgroundTaskIdentifier = "io.github.redsn0w1877.pixlaudio.spotify-sync"
    /// Background refresh: at most every 6 hours, and only when the last full sync is older than 12 hours.
    static let backgroundInterval: TimeInterval = 6 * 3600
    static let staleAfterMs: Int64 = 12 * 3600 * 1000
    /// Matcher retry after network trouble (Android `BackoffPolicy.EXPONENTIAL, 60 s`).
    static let matchBackoffSeconds: Double = 60

    init(launch: LaunchConfiguration, accounts: AccountsStore, persistence: PersistenceActor?,
         preferences: SpotifyPreferences = SpotifyPreferences(), http: any HTTPClient = URLSessionHTTPClient(),
         bridge: (any SpotifyYouTubeBridge)? = nil) {
        isDemo = launch.isUITest
        self.preferences = preferences
        self.accounts = accounts
        self.persistence = isDemo ? nil : persistence
        self.http = http
        self.bridge = bridge ?? PixlNetYouTubeBridge(http: http)
        let prefs = preferences
        let session = SpotifySession(http: http, store: KeychainSpotifyTokenStore(), clientId: { prefs.clientId },
                                     sha256: SpotifyPlatform.sha256, randomBytes: SpotifyPlatform.randomBytes)
        self.session = session
        let api = SpotifyWebAPI(http: http, session: session)
        self.api = api
        demo = isDemo ? SpotifyDemo(screen: launch.screen) : nil
        hasClientId = !preferences.clientId.isEmpty
        clientIdOverride = preferences.clientIdOverride
        if let persistence, !isDemo {
            let reload: @MainActor @Sendable () async -> Void = { [weak self] in await self?.libraryChanged() }
            sync = SpotifyLibrarySync(api: api, store: persistence, sha256: SpotifyPlatform.sha256, flush: {
                try? await persistence.rebuildSpotifyUnifiedLibrary()
                await reload()
            })
        }
        if let demo { applyDemo(demo) }
    }

    /// Wires the library reload and the "is music playing" check (the matcher halves its concurrency while playing).
    func attach(reloadLibrary: @escaping @MainActor @Sendable () async -> Void,
                isPlaybackActive: @escaping @MainActor @Sendable () -> Bool) {
        self.reloadLibrary = reloadLibrary
        self.isPlaybackActive = isPlaybackActive
    }

    /// The resolver that plays Spotify songs through the YouTube bridge; other songs go to `base`.
    func playableURLResolver(base: any PlayableURLResolving) -> any PlayableURLResolving {
        baseResolver = base
        guard let persistence else { return base }
        return SpotifyPlayableURLResolver(base: base, bridge: bridge, persistence: persistence)
    }

    // MARK: Launch

    /// Reads the session and the stored library, then resumes unfinished matching (Android's repository `init`).
    func start() async {
        guard !isDemo else { return }
        isLoggedIn = await session.isLoggedIn()
        accountName = preferences.accountName
        accountEmail = preferences.accountEmail
        publishAccount()
        await refreshLibraryState()
        if pendingMatchCount > 0 { startMatching(retryFailed: false) }
        if isLoggedIn { scheduleBackgroundRefresh() }
    }

    private func libraryChanged() async {
        await reloadLibrary()
        await refreshLibraryState()
    }

    /// Playlists, track count and match counters from the store (`refreshMatchCounts` + the flows).
    func refreshLibraryState() async {
        guard let persistence else { return }
        let rows = (try? await persistence.allPlaylists()) ?? []
        let songs = (try? await persistence.allSongs()) ?? []
        let matched = (try? await persistence.countTracks(in: .matched)) ?? 0
        let manual = (try? await persistence.countTracks(in: .manual)) ?? 0
        let pending = (try? await persistence.countTracks(in: .pending)) ?? 0
        let unmatched = (try? await persistence.countTracks(in: .unmatched)) ?? 0
        if playlists != rows { playlists = rows }
        let total = Set(songs.map(\.spotifyId)).count
        if totalSongs != total { totalSongs = total }
        if matchedCount != matched + manual { matchedCount = matched + manual }
        if pendingMatchCount != pending { pendingMatchCount = pending }
        if unmatchedCount != unmatched { unmatchedCount = unmatched }
        if let sync {
            let denied = await sync.playlistAccessDenied
            if playlistAccessDenied != denied { playlistAccessDenied = denied }
        }
    }

    private func publishAccount() {
        if isSigningIn {
            accounts.spotify = .signingIn
        } else if isLoggedIn {
            accounts.spotify = .signedIn(displayName: accountName ?? accountEmail ?? "Linked account")
        } else {
            accounts.spotify = .signedOut
        }
    }

    // MARK: Client id

    func setClientIdOverride(_ value: String) {
        guard !isDemo else { return }
        preferences.setClientIdOverride(value)
        clientIdOverride = preferences.clientIdOverride
        hasClientId = !preferences.clientId.isEmpty
    }

    // MARK: Sign-in (Android `SpotifyLoginActivity`)

    /// Runs PKCE sign-in: `authenticate` presents the authorization page (ASWebAuthenticationSession via SwiftUI's
    /// `webAuthenticationSession`) and returns the `pixlaudio://spotify-callback` URL. On success the import starts.
    func signIn(authenticate: @escaping @MainActor (URL) async throws -> URL) async {
        guard !isDemo, !isSigningIn else { return }
        guard hasClientId else {
            message = "No Spotify client ID is set up in this build."
            return
        }
        guard let pending = await session.beginAuthorization(), let url = URL(string: pending.url) else {
            message = await session.lastError ?? "Couldn't start Spotify sign-in."
            return
        }
        isSigningIn = true
        publishAccount()
        defer {
            isSigningIn = false
            publishAccount()
        }
        let callback: URL
        do {
            callback = try await authenticate(url)
        } catch {
            // Cancelled by the user (or the sheet failed): nothing changes.
            return
        }
        switch await session.handleCallback(callback.absoluteString) {
        case .success:
            isLoggedIn = true
            await sync?.clearPlaylistAccessDenied()
            playlistAccessDenied = false
            message = "Connected to Spotify. Importing your library…"
            syncNow()
            scheduleBackgroundRefresh()
        case .failure(let error):
            message = "Spotify sign-in failed: \(error.message)"
        }
    }

    /// Android `reconnect` / `reauthorize`: drops only the token (the library and its matches stay), then signs in.
    func reconnect(authenticate: @escaping @MainActor (URL) async throws -> URL) async {
        guard !isDemo else { return }
        await session.clearSession()
        await sync?.clearPlaylistAccessDenied()
        playlistAccessDenied = false
        isLoggedIn = false
        publishAccount()
        await signIn(authenticate: authenticate)
    }

    /// Android `logout`: forgets the session and everything imported (matches included).
    func logout() async {
        guard !isDemo, !isLoggingOut else { return }
        isLoggingOut = true
        syncTask?.cancel()
        matchTask?.cancel()
        try? await sync?.clearLibrary()
        await session.clearSession()
        preferences.clearAccount()
        isLoggedIn = false
        accountName = nil
        accountEmail = nil
        playlistAccessDenied = false
        testReport = nil
        isLoggingOut = false
        publishAccount()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
        await libraryChanged()
    }

    func clearMessage() { message = nil }

    // MARK: Sync (Android `SpotifySyncWorker`)

    /// A user's sync: replaces a running one (Android `ExistingWorkPolicy.REPLACE`), never skips "fresh" playlists.
    func syncNow() {
        guard !isDemo, isLoggedIn, let sync else { return }
        syncTask?.cancel()
        isSyncing = true
        syncStatus = nil
        syncTask = Task {
            var resume = false
            var attempts = 0
            while !Task.isCancelled {
                do {
                    let result = try await sync.syncAll(resumeInterrupted: resume, onProgress: { _, _, name in
                        await self.setSyncStatus(name)
                    }, onProfile: { profile in
                        await self.cacheProfile(profile)
                    })
                    if result.syncedSongCount > 0 { startMatching(retryFailed: false) }
                    if result.isComplete {
                        preferences.setLastFullSync(currentTimeMillis())
                        break
                    }
                    resume = true
                } catch is CancellationError {
                    break
                } catch {
                    attempts += 1
                    if attempts >= 3 {
                        message = "Spotify import failed: \(error)"
                        break
                    }
                    try? await Task.sleep(for: .seconds(30 * Double(attempts)))
                }
            }
            isSyncing = false
            syncStatus = nil
            await refreshLibraryState()
        }
    }

    private func setSyncStatus(_ name: String) { syncStatus = name }

    private func cacheProfile(_ profile: SpotifyUserProfile) {
        preferences.cacheAccount(name: profile.displayName, email: profile.email)
        accountName = preferences.accountName
        accountEmail = preferences.accountEmail
        publishAccount()
    }

    // MARK: Matching (Android `SpotifyMatchWorker`)

    /// Starts a matching pass. A user's "Find audio" (`retryFailed`) re-queues unmatched tracks and replaces a running
    /// pass; the automatic chaining keeps a running one.
    func startMatching(retryFailed: Bool) {
        guard !isDemo, let persistence else { return }
        if matchTask != nil {
            guard retryFailed else { return }
            matchTask?.cancel()
        }
        isMatching = true
        let bridge = self.bridge
        let isPlaying = isPlaybackActive
        matchTask = Task {
            let matcher = TrackMatcher(search: bridge.search)
            let runner = SpotifyMatchRunner(store: persistence, matcher: { try await matcher.findMatch($0) })
            var requeue = retryFailed
            var backoff = Self.matchBackoffSeconds
            while !Task.isCancelled {
                let result: SpotifyMatchPassResult
                do {
                    result = try await runner.run(retryFailed: requeue, isPlaybackActive: { await isPlaying() },
                                                  shouldContinue: { !Task.isCancelled },
                                                  onProgress: { _, _ in await self.refreshLibraryState() })
                } catch {
                    break
                }
                requeue = false
                await refreshLibraryState()
                if result.retryLater {
                    try? await Task.sleep(for: .seconds(backoff))
                    backoff = min(backoff * 2, 3600)
                    continue
                }
                backoff = Self.matchBackoffSeconds
                if !result.moreWork { break }
            }
            matchTask = nil
            isMatching = false
            await libraryChanged()
        }
    }

    // MARK: Playback test

    func runPlaybackTest() {
        guard !isTesting else { return }
        if let demo {
            testReport = demo.testReport
            return
        }
        guard let persistence else { return }
        let resolver = SpotifyPlayableURLResolver(base: baseResolver, bridge: bridge, persistence: persistence)
        isTesting = true
        testReport = nil
        let test = SpotifyPlaybackTest(persistence: persistence, bridge: bridge, resolver: resolver, http: http)
        Task {
            let report = await test.run()
            testReport = report
            isTesting = false
            await refreshLibraryState()
        }
    }

    func dismissTestReport() { testReport = nil }

    // MARK: Catalogue (Android `SpotifyBrowseViewModel` / `SearchStateHolder`)

    func myTopTracks() async -> [SpotifyTrack] {
        if let demo { return demo.topTracks }
        return (try? await sync?.myTopTracks()) ?? []
    }

    func myTopArtists() async -> [SpotifyArtistFull] {
        if let demo { return demo.topArtists }
        return (try? await sync?.myTopArtists()) ?? []
    }

    func searchCatalog(_ query: String, types: String = "track,artist,album", limit: Int = 20) async throws -> SpotifyCatalogResults {
        if let demo { return demo.search(query) }
        guard let sync else { return SpotifyCatalogResults() }
        return try await sync.searchCatalog(query: query, types: types, limit: limit)
    }

    func artistTopTracks(_ artistId: String) async -> [SpotifyTrack] {
        if let demo { return demo.artistTopTracks(artistId) }
        return (try? await sync?.artistTopTracks(artistId)) ?? []
    }

    func artistAlbums(_ artistId: String) async -> [SpotifyAlbumFull] {
        if let demo { return demo.artistAlbums(artistId) }
        return (try? await sync?.artistAlbums(artistId)) ?? []
    }

    func albumTracks(_ albumId: String) async -> [SpotifyTrack] {
        if let demo { return demo.albumTracks(albumId) }
        return (try? await sync?.albumTracks(albumId)) ?? []
    }

    /// The Spotify ids already in the library (Search hides them from "More on Spotify").
    func knownSpotifyIds() async -> Set<String> {
        guard let persistence else { return [] }
        return Set(((try? await persistence.allSongs()) ?? []).map(\.spotifyId))
    }

    /// `importTracks` then the matcher (Android enqueues `SpotifyMatchWorker`). Returns how many were new, or nil on
    /// failure.
    func addToLibrary(_ tracks: [SpotifyTrack]) async -> Int? {
        if isDemo { return tracks.count }
        guard let sync, !tracks.isEmpty else { return nil }
        guard let added = try? await sync.importTracks(tracks) else { return nil }
        startMatching(retryFailed: false)
        return added
    }

    /// Android `playCatalogTrack`: import, like, match right away (the user is waiting), then the playable song.
    func importAndMatch(_ track: SpotifyTrack, like: Bool) async -> Song? {
        guard let sync, let persistence, let spotifyId = track.id else { return nil }
        guard (try? await sync.importTracks([track])) != nil else { return nil }
        let songId = SpotifyUnifiedLibrary.songId(spotifyId)
        if like { try? await persistence.setFavorites([songId], isFavorite: true, timestamp: currentTimeMillis()) }
        guard let record = try? await persistence.spotifySong(spotifyId: spotifyId) else { return nil }
        let matcher = TrackMatcher(search: bridge.search)
        let match: TrackMatch? = (try? await matcher.findMatch(record.matchable)) ?? nil
        try? await persistence.updateMatch(spotifyId: spotifyId, videoId: match?.videoId, score: match?.score,
                                           state: match == nil ? .unmatched : .matched)
        await libraryChanged()
        guard match != nil else { return nil }
        return currentSong(id: songId) ?? record.toSong()
    }

    /// Android `likeCatalogTrack`: import and like; the matcher finds the audio later.
    func importAndLike(_ track: SpotifyTrack) async -> Bool {
        guard let sync, let persistence, let spotifyId = track.id else { return false }
        guard (try? await sync.importTracks([track])) != nil else { return false }
        try? await persistence.setFavorites([SpotifyUnifiedLibrary.songId(spotifyId)], isFavorite: true, timestamp: currentTimeMillis())
        await libraryChanged()
        startMatching(retryFailed: false)
        return true
    }

    /// Android `playYouTubeMusicTrack`: stored as an already-matched row, playable at once.
    func importYouTubeMusic(_ result: YouTubeSearchResult) async -> Song? {
        guard let sync else { return nil }
        guard (try? await sync.importYouTubeMusicTracks([result])) != nil else { return nil }
        await libraryChanged()
        let syntheticId = SpotifyLibrary.youTubeMusicSyntheticId(result.videoId, sha256: SpotifyPlatform.sha256)
        return currentSong(id: SpotifyUnifiedLibrary.songId(syntheticId))
    }

    @ObservationIgnored var songLookup: @MainActor @Sendable (String) -> Song? = { _ in nil }

    private func currentSong(id: String) -> Song? { songLookup(id) }

    // MARK: Background refresh (BGTaskScheduler)

    /// Asks for the next background refresh (no-op when signed out).
    func scheduleBackgroundRefresh() {
        guard !isDemo, isLoggedIn else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.backgroundInterval)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// The background refresh: a resumable sync slice and a short matching slice inside the ~30 s iOS allows, then
    /// the next request. Runs only when the last complete sync is older than 12 hours.
    func backgroundRefresh() async {
        guard !isDemo, let sync, let persistence else { return }
        isLoggedIn = await session.isLoggedIn()
        guard isLoggedIn else { return }
        scheduleBackgroundRefresh()
        let started = Date()
        let budget: TimeInterval = 22
        if currentTimeMillis() - preferences.lastFullSyncMs > Self.staleAfterMs {
            if let result = try? await sync.syncAll(resumeInterrupted: true, shouldContinue: { Date().timeIntervalSince(started) < budget }),
               result.isComplete {
                preferences.setLastFullSync(currentTimeMillis())
            }
        }
        let remaining = budget - Date().timeIntervalSince(started)
        if remaining > 3 {
            let matcher = TrackMatcher(search: bridge.search)
            let runner = SpotifyMatchRunner(store: persistence, matcher: { try await matcher.findMatch($0) })
            _ = try? await runner.run(shouldContinue: { Date().timeIntervalSince(started) < budget })
        }
        await refreshLibraryState()
    }

    // MARK: Demo (UI tests)

    private func applyDemo(_ demo: SpotifyDemo) {
        isLoggedIn = demo.signedIn
        hasClientId = true
        guard demo.signedIn else {
            accounts.spotify = .signedOut
            return
        }
        accountName = demo.accountName
        accountEmail = demo.accountEmail
        playlists = demo.playlists
        totalSongs = demo.totalSongs
        matchedCount = demo.matched
        pendingMatchCount = demo.pending
        unmatchedCount = demo.unmatched
        testReport = demo.showsTestReport ? demo.testReport : nil
        accounts.spotify = .signedIn(displayName: demo.accountName)
    }
}
