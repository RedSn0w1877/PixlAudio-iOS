import Foundation
import Observation
import PixlModel
import PixlNet

/// Stage 11's object graph (built once in `AppEnvironment`): the YouTube session, InnerTube resolution, the sparse
/// stream cache and the streaming resource loader, downloads, prefetching, YouTube Music search and the device-code
/// sign-in. UI tests get the demo variant: no network objects at all, deterministic screen states.
@MainActor
@Observable
final class YouTubeServices {
    let isDemo: Bool
    let downloads: DownloadManager
    @ObservationIgnored let account: YouTubeAccount?
    @ObservationIgnored let service: InnerTubeService?
    @ObservationIgnored let cache: StreamCache?
    @ObservationIgnored let fetcher: StreamFetcher?
    @ObservationIgnored let deviceAuth: GoogleDeviceAuthClient?
    @ObservationIgnored let poTokens: PoTokenGenerator?
    @ObservationIgnored let searchProvider: (any SearchProviding)?
    @ObservationIgnored private let loader: YouTubeResourceLoader?
    @ObservationIgnored private var prefetcher: YouTubePrefetcher?
    @ObservationIgnored private let accounts: AccountsStore
    @ObservationIgnored private var started = false

    init(launch: LaunchConfiguration, library: LibraryStore, persistence: PersistenceActor?, accounts: AccountsStore) {
        self.accounts = accounts
        isDemo = launch.isUITest
        guard !launch.isUITest else {
            account = nil
            service = nil
            cache = nil
            fetcher = nil
            deviceAuth = nil
            poTokens = nil
            searchProvider = nil
            loader = nil
            downloads = DownloadManager(service: nil, fetcher: nil)
            return
        }
        let plain = URLSessionHTTPClient(session: YouTubeNetwork.makeSession())
        let poTokens = PoTokenGenerator(http: plain, freshVisitorData: {
            // A visitorData of its own (Android recreates one with every generator).
            let request = InnerTubeRequests.post(path: "visitor_id", body: InnerTubeRequests.visitorIdBody(),
                                                 profile: InnerTubeContexts.web)
            guard let response = try? await plain.send(request), response.isSuccessful,
                  let json = OrgJSON.parse(response.body)?.objectValue else { return nil }
            return InnerTubeParsing.visitorData(json)
        })
        self.poTokens = poTokens
        let account = YouTubeAccount(http: plain, poTokens: poTokens)
        self.account = account
        let deviceAuth = GoogleDeviceAuthClient(http: plain, store: account)
        self.deviceAuth = deviceAuth
        let innerTube = GoogleBearerHTTPClient(inner: plain, accessToken: { await deviceAuth.validAccessToken() })
        let service = InnerTubeService(innerTubeHTTP: innerTube, plainHTTP: plain, account: account,
                                       remote: RemoteClientConfigStore(http: plain))
        self.service = service
        let cache = StreamCache()
        self.cache = cache
        let fetcher = StreamFetcher(service: service, cache: cache, session: YouTubeNetwork.makeSession(timeout: 25))
        self.fetcher = fetcher
        loader = YouTubeResourceLoader(fetcher: fetcher, onComplete: { videoId in
            Task { await cache.evictIfNeeded(keeping: videoId) }
        })
        downloads = DownloadManager(service: service, fetcher: fetcher)
        searchProvider = YouTubeMusicSearchProvider(
            service: service,
            importer: YouTubeLibraryImporter(library: library, persistence: persistence, writesCache: true))
    }

    /// Hooks the streaming loader, the resolver and the prefetcher into the playback stack.
    func install(on playback: PlaybackServices?) {
        guard let playback, let loader, let cache, let service, let fetcher else { return }
        StreamingResourceLoaderRegistry.shared.register(scheme: YouTubeSongIdentity.scheme) { _ in loader }
        playback.engine.factory.resolver = StreamingPlayableURLResolver(base: playback.engine.factory.resolver, cache: cache)
        let prefetcher = YouTubePrefetcher(engine: playback.engine, service: service, fetcher: fetcher,
                                           network: NetworkConditionsMonitor())
        self.prefetcher = prefetcher
        playback.onUpcomingChanged = { [weak prefetcher] in prefetcher?.upcomingChanged() }
        playback.onPlayStateChanged = { [weak prefetcher] playing in prefetcher?.playingChanged(playing) }
    }

    /// Launch work (cheap): sign-in state, downloads, cache trim.
    func start() {
        guard !started, !isDemo else { return }
        started = true
        downloads.start()
        Task { await refreshAccountState() }
        if let cache { Task.detached(priority: .utility) { await cache.evictIfNeeded(keeping: nil) } }
    }

    /// Mirrors the session into `AccountsStore.youtube`.
    func refreshAccountState() async {
        guard let account else { return }
        accounts.youtube = await account.hasSession ? .signedIn(displayName: "YouTube") : .signedOut
    }

    // MARK: Sign-in (Android YouTubeAuthManager)

    /// Saves a cookie captured by the web sign-in or pasted by the user; false when it has no SAPISID.
    func saveCookie(_ cookie: String, visitorData: String?) async -> Bool {
        guard let account, YouTubeCookieText.hasSAPISID(cookie) else { return false }
        await account.saveCookie(cookie)
        if let visitorData { await account.saveVisitorData(visitorData) }
        await service?.invalidateAll()
        await refreshAccountState()
        return true
    }

    func signOut() async {
        await account?.signOut()
        await service?.invalidateAll()
        await refreshAccountState()
    }
}
