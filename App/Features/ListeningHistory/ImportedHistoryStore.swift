import Foundation
import Observation
import PixlBackup
import PixlLibrary
import PixlModel

/// Settings › Library & storage › Listening history (spec B): listening from outside the app — Spotify's recent plays
/// and taste (automatic), YouTube Music's history page (automatic, when signed in to YouTube), and the Spotify / Google
/// data downloads (file import) — kept on this phone and fed to the recommendations with Spotify ≫ YouTube Music
/// weights and a 180-day fade (PixlLibrary `ListeningHistoryWeights`).
///
/// The plays live in `ImportedHistoryBox` (an actor: a decade of Spotify is ~150,000 plays, never on the main thread);
/// this store publishes counters and keeps the library-independent `aggregate` Home and Prepare-ahead read.
///
/// **Read API for the assistant and insights** (spec B3) — everything listened to, in the app and imported:
/// `topArtists(_:limit:)`, `topTracks(_:limit:)`, `recentPlays(_:)`, `listeningSummary()`.
@Observable
final class ImportedHistoryStore {
    /// Bumped whenever the plays or the taste change (Home re-plans).
    private(set) var revision = 0
    private(set) var playCount = 0
    private(set) var artistCount = 0
    private(set) var spotifyPlayCount = 0
    private(set) var youTubePlayCount = 0
    /// The newest automatic sync (Spotify or YouTube Music), ms; 0 = never.
    private(set) var lastSyncMs: Int64 = 0
    private(set) var isSyncing = false
    private(set) var importState: ImportState = .idle
    /// Spotify refused the history scopes: the dashboard shows "Reconnect Spotify" with this reason.
    private(set) var needsSpotifyReconnect: Bool
    /// A data download was imported at least once (the Home card stops asking).
    private(set) var hasFileImport: Bool

    /// "Spotify listening history" (on by default; only does anything while signed in to Spotify).
    var spotifyEnabled: Bool {
        didSet { defaults?.set(spotifyEnabled, forKey: Keys.spotifyEnabled) }
    }
    /// "YouTube Music history" (on by default; only while signed in to YouTube).
    var youTubeEnabled: Bool {
        didSet { defaults?.set(youTubeEnabled, forKey: Keys.youTubeEnabled) }
    }
    /// The one-time Home card ("Make your mixes smarter") was closed.
    var homeCardDismissed: Bool {
        didSet { defaults?.set(homeCardDismissed, forKey: Keys.homeCardDismissed) }
    }

    enum ImportState: Equatable {
        case idle
        case reading(fraction: Double)
        case done(String)
        case failed(String)
    }

    nonisolated enum Keys {
        static let spotifyEnabled = "listening_history_spotify_enabled"
        static let youTubeEnabled = "listening_history_youtube_enabled"
        static let homeCardDismissed = "listening_history_home_card_dismissed"
        static let hasFileImport = "listening_history_has_file_import"
        static let needsSpotifyReconnect = "listening_history_needs_spotify_reconnect"
        static let lastSpotifySync = "listening_history_last_spotify_sync"
        static let lastYouTubeSync = "listening_history_last_youtube_sync"
    }

    /// What Home and Prepare-ahead read (empty until loaded).
    @ObservationIgnored private(set) var aggregate: ImportedHistoryAggregate = .empty
    @ObservationIgnored private let box: ImportedHistoryBox
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored let clock: HomeClock
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// The app's own history and library, for the read API (set by `AppEnvironment`).
    @ObservationIgnored var localSource: @MainActor () -> (events: [PlaybackEvent], songs: [Song]) = { ([], []) }

    /// `directory == nil` keeps everything in memory (UI tests); `seed` fills it for a demo screen.
    init(clock: HomeClock, directory: URL?, defaults: UserDefaults?, seed: [ImportedPlay] = []) {
        self.clock = clock
        self.defaults = defaults
        box = ImportedHistoryBox(directory: directory, seed: seed)
        spotifyEnabled = defaults?.object(forKey: Keys.spotifyEnabled) as? Bool ?? true
        youTubeEnabled = defaults?.object(forKey: Keys.youTubeEnabled) as? Bool ?? true
        homeCardDismissed = defaults?.bool(forKey: Keys.homeCardDismissed) ?? false
        hasFileImport = defaults?.bool(forKey: Keys.hasFileImport) ?? !seed.isEmpty
        needsSpotifyReconnect = defaults?.bool(forKey: Keys.needsSpotifyReconnect) ?? false
        lastSyncMs = max(Self.int64(defaults, Keys.lastSpotifySync), Self.int64(defaults, Keys.lastYouTubeSync))
        if directory == nil && !seed.isEmpty { lastSyncMs = clock.nowMs() - 2 * 3_600_000 }
    }

    static func make(launch: LaunchConfiguration) -> ImportedHistoryStore {
        if launch.isUITest {
            let clock = HomeClock.uiTest
            let seed = launch.screen == .listeningHistory
                ? DemoImportedHistory.plays(songs: DemoLibrary.songs, nowMs: clock.nowMs()) : []
            return ImportedHistoryStore(clock: clock, directory: nil, defaults: nil, seed: seed)
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return ImportedHistoryStore(clock: .live, directory: directory, defaults: .standard)
    }

    private static func int64(_ defaults: UserDefaults?, _ key: String) -> Int64 {
        Int64(defaults?.double(forKey: key) ?? 0)
    }

    // MARK: Loading

    /// Reads the stored plays once, off the main thread.
    func ensureLoaded() async {
        if isLoaded { return }
        if let loadTask { return await loadTask.value }
        let box = self.box, now = clock.nowMs()
        let task = Task { [weak self] in
            let snapshot = await box.load(nowMs: now)
            guard let self else { return }
            self.isLoaded = true
            self.apply(snapshot)
        }
        loadTask = task
        await task.value
    }

    private func apply(_ snapshot: ImportedHistoryBox.Snapshot) {
        aggregate = snapshot.aggregate
        playCount = snapshot.aggregate.totalPlays
        spotifyPlayCount = snapshot.aggregate.spotifyPlays
        youTubePlayCount = snapshot.aggregate.youTubePlays
        artistCount = snapshot.aggregate.artists.count
        revision &+= 1
    }

    // MARK: Automatic sync results

    func lastSync(_ source: ImportedPlaySource) -> Int64 {
        Self.int64(defaults, source == .ytmusic ? Keys.lastYouTubeSync : Keys.lastSpotifySync)
    }

    func setSyncing(_ syncing: Bool) { isSyncing = syncing }

    /// Plays and (Spotify) taste from an automatic sync. Returns how many plays were new.
    @discardableResult
    func addSynced(_ plays: [ImportedPlay], taste: ExternalTasteSnapshot? = nil, source: ImportedPlaySource) async -> Int {
        await ensureLoaded()
        let now = clock.nowMs()
        let result = await box.add(plays, taste: taste, nowMs: now)
        apply(result.snapshot)
        defaults?.set(Double(now), forKey: source == .ytmusic ? Keys.lastYouTubeSync : Keys.lastSpotifySync)
        lastSyncMs = max(lastSyncMs, now)
        return result.added
    }

    func setNeedsSpotifyReconnect(_ value: Bool) {
        guard needsSpotifyReconnect != value else { return }
        needsSpotifyReconnect = value
        defaults?.set(value, forKey: Keys.needsSpotifyReconnect)
    }

    // MARK: File import

    /// The largest file read whole (a Takeout ZIP with only the YouTube history is a few MB; Spotify's is tens).
    nonisolated static let maxFileBytes = 512 * 1024 * 1024

    /// Imports the picked ZIP / JSON files: progress in `importState`, then a one-line summary.
    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty, !isImporting else { return }
        importState = .reading(fraction: 0)
        let box = self.box, clock = self.clock
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor [weak self] in
                guard let self, case .reading = self.importState else { return }
                self.importState = .reading(fraction: fraction)
            }
        }
        Task { [weak self] in
            await self?.ensureLoaded()
            let outcome = await Self.read(urls, progress: report)
            guard let self else { return }
            switch outcome {
            case .failure(let message):
                self.importState = .failed(message)
            case .success(let read):
                let result = await box.add(read.plays, taste: nil, nowMs: clock.nowMs())
                self.apply(result.snapshot)
                if !read.plays.isEmpty {
                    self.hasFileImport = true
                    self.defaults?.set(true, forKey: Keys.hasFileImport)
                }
                self.importState = .done(Self.summary(read: read, added: result.added))
            }
        }
    }

    var isImporting: Bool {
        if case .reading = importState { return true }
        return false
    }

    func dismissImportResult() { importState = .idle }

    private nonisolated struct ReadFiles: Sendable {
        var plays: [ImportedPlay] = []
        var artists = 0
        var foundHTML = false
        var filesRead = 0
    }

    private nonisolated enum ReadOutcome: Sendable {
        case success(ReadFiles)
        case failure(String)
    }

    /// Reads and parses every picked file off the main thread.
    @concurrent
    private nonisolated static func read(_ urls: [URL], progress: @escaping @Sendable (Double) -> Void) async -> ReadOutcome {
        var files = ReadFiles()
        var lastError: String?
        for (index, url) in urls.enumerated() {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= maxFileBytes else {
                lastError = "\(url.lastPathComponent) is too big to read. Pick the history files inside it instead."
                continue
            }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                lastError = "Couldn't open \(url.lastPathComponent)."
                continue
            }
            let base = Double(index) / Double(urls.count)
            do {
                let result = try ListeningHistoryArchive.read(fileName: url.lastPathComponent, bytes: [UInt8](data)) {
                    progress(base + $0 / Double(urls.count))
                }
                files.plays += result.plays
                files.filesRead += result.filesRead
                if result.foundHTMLHistory { files.foundHTML = true }
            } catch {
                lastError = (error as? ListeningHistoryArchive.Failure) == .notHistory
                    ? "\(url.lastPathComponent) has no listening history in it."
                    : "\(url.lastPathComponent) couldn't be opened. Download it again and pick the ZIP as it arrived."
            }
        }
        files.artists = Set(Set(files.plays.map { $0.artist }).map(ImportedPlayIdentity.primaryArtistKey)).subtracting([""]).count
        if files.plays.isEmpty {
            if files.foundHTML {
                return .failure("This Takeout download has the history as a web page. Export it again and choose JSON as the history format.")
            }
            if files.filesRead > 0 { return .failure("No songs found in this history.") }
            return .failure(lastError ?? "No listening history found in this file.")
        }
        return .success(files)
    }

    private static func summary(read: ReadFiles, added: Int) -> String {
        if added == 0 { return "Already imported — nothing new in this file." }
        let plays = added.formatted()
        let artists = read.artists.formatted()
        return "Imported \(plays) \(added == 1 ? "play" : "plays") · \(artists) \(read.artists == 1 ? "artist" : "artists")"
    }

    // MARK: Clearing

    /// "Clear imported history": every imported play and the Spotify taste go; the app's own history stays.
    func clear() async {
        await ensureLoaded()
        apply(await box.clear(nowMs: clock.nowMs()))
        hasFileImport = false
        defaults?.set(false, forKey: Keys.hasFileImport)
        defaults?.removeObject(forKey: Keys.lastSpotifySync)
        defaults?.removeObject(forKey: Keys.lastYouTubeSync)
        lastSyncMs = 0
        importState = .idle
    }

    // MARK: Read API (spec B3)

    /// All plays (the app's own, then imported), gathered off the main thread.
    private func allPlays() async -> (plays: [ListeningPlay], taste: ExternalTasteSnapshot) {
        await ensureLoaded()
        let local = localSource()
        let (imported, taste) = await box.contents()
        let plays = await Task.detached(priority: .userInitiated) { () -> [ListeningPlay] in
            let songsById = Dictionary(local.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let mapper = ImportedHistoryMapper(library: local.songs)
            return ListeningHistoryInsights.plays(events: local.events, songsById: songsById)
                + ListeningHistoryInsights.plays(imported: imported, mapper: mapper)
        }.value
        return (plays, taste)
    }

    /// What the taste profile and the library stats read (Ask Taizo): every play, the app's and the imported ones, as
    /// listening plays; the imported plays themselves (they carry completions and skips); Spotify's own lists. Gathered
    /// off the main thread.
    func tasteSources() async -> TasteSources {
        await ensureLoaded()
        let local = localSource()
        let (imported, taste) = await box.contents()
        return await Task.detached(priority: .userInitiated) { () -> TasteSources in
            let songsById = Dictionary(local.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let mapper = ImportedHistoryMapper(library: local.songs)
            let plays = ListeningHistoryInsights.plays(events: local.events, songsById: songsById)
                + ListeningHistoryInsights.plays(imported: imported, mapper: mapper)
            return TasteSources(plays: plays, imported: imported, taste: taste)
        }.value
    }

    /// The strongest artists of a period (a Spotify or in-app play counts 1, a YouTube Music play 0.35).
    func topArtists(_ period: ListeningPeriod, limit: Int = 20) async -> [ArtistInsight] {
        let (plays, _) = await allPlays()
        let now = clock.nowMs()
        return await Task.detached { ListeningHistoryInsights.topArtists(plays, period: period, nowMs: now, limit: limit) }.value
    }

    func topTracks(_ period: ListeningPeriod, limit: Int = 20) async -> [TrackInsight] {
        let (plays, _) = await allPlays()
        let now = clock.nowMs()
        return await Task.detached { ListeningHistoryInsights.topTracks(plays, period: period, nowMs: now, limit: limit) }.value
    }

    /// The newest plays, newest first.
    func recentPlays(_ count: Int) async -> [ListeningPlay] {
        let (plays, _) = await allPlays()
        return await Task.detached { ListeningHistoryInsights.recentPlays(plays, count: count) }.value
    }

    /// Totals by source, top artists and Spotify genres, followed artists.
    func listeningSummary() async -> ListeningSummary {
        let (plays, taste) = await allPlays()
        let now = clock.nowMs()
        return await Task.detached { ListeningHistoryInsights.summary(plays, taste: taste, nowMs: now) }.value
    }

    /// Spotify's own top lists and followed artists, as last synced (empty when never synced).
    func spotifyTaste() async -> ExternalTasteSnapshot {
        await ensureLoaded()
        return await box.contents().taste
    }
}

/// Every play there is, for the taste profile.
nonisolated struct TasteSources: Sendable {
    var plays: [ListeningPlay]
    var imported: [ImportedPlay]
    var taste: ExternalTasteSnapshot
}

/// The imported plays and taste on disk (`imported_history.tsv`, `imported_taste.json` in Application Support).
actor ImportedHistoryBox {
    nonisolated struct Snapshot: Sendable {
        var aggregate: ImportedHistoryAggregate
    }

    private let playsURL: URL?
    private let tasteURL: URL?
    private var plays: [ImportedPlay]
    private var taste = ExternalTasteSnapshot()
    private var loaded: Bool

    init(directory: URL?, seed: [ImportedPlay]) {
        playsURL = directory?.appendingPathComponent(ImportedHistoryCodec.fileName)
        tasteURL = directory?.appendingPathComponent("imported_taste.json")
        plays = seed
        loaded = directory == nil
    }

    func load(nowMs: Int64) -> Snapshot {
        if !loaded {
            loaded = true
            if let playsURL, let data = try? Data(contentsOf: playsURL) {
                plays = ImportedHistoryCodec.decode(String(decoding: data, as: UTF8.self))
            }
            if let tasteURL, let data = try? Data(contentsOf: tasteURL),
               let stored = try? JSONDecoder().decode(ExternalTasteSnapshot.self, from: data) {
                taste = stored
            }
        }
        return snapshot(nowMs: nowMs)
    }

    func add(_ new: [ImportedPlay], taste newTaste: ExternalTasteSnapshot?, nowMs: Int64) -> (added: Int, snapshot: Snapshot) {
        _ = load(nowMs: nowMs)
        let merged = ImportedHistoryMerge.merge(existing: plays, adding: new)
        let changedPlays = merged.added > 0 || merged.plays != plays
        plays = merged.plays
        if changedPlays { writePlays() }
        if let newTaste {
            taste = newTaste
            writeTaste()
        }
        return (merged.added, snapshot(nowMs: nowMs))
    }

    func clear(nowMs: Int64) -> Snapshot {
        plays = []
        taste = ExternalTasteSnapshot()
        loaded = true
        if let playsURL { try? FileManager.default.removeItem(at: playsURL) }
        if let tasteURL { try? FileManager.default.removeItem(at: tasteURL) }
        return snapshot(nowMs: nowMs)
    }

    func contents() -> (plays: [ImportedPlay], taste: ExternalTasteSnapshot) { (plays, taste) }

    private func snapshot(nowMs: Int64) -> Snapshot {
        Snapshot(aggregate: ImportedHistoryAggregate.build(plays: plays, taste: taste, nowMs: nowMs))
    }

    private func writePlays() {
        guard let playsURL else { return }
        try? FileManager.default.createDirectory(at: playsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(ImportedHistoryCodec.encode(plays).utf8).write(to: playsURL, options: .atomic)
    }

    private func writeTaste() {
        guard let tasteURL, let data = try? JSONEncoder().encode(taste) else { return }
        try? data.write(to: tasteURL, options: .atomic)
    }
}

/// A few imported plays of the demo library (UI tests: the Listening history screen with numbers).
nonisolated enum DemoImportedHistory {
    static func plays(songs: [Song], nowMs: Int64) -> [ImportedPlay] {
        let hour: Int64 = 3_600_000
        return songs.prefix(12).enumerated().flatMap { index, song in
            (0..<(3 + index % 4)).map { k in
                ImportedPlay(source: index % 3 == 2 ? .takeout : .spotifyExport,
                             timestampMs: nowMs - Int64(index * 5 + k) * 26 * hour, title: song.title, artist: song.artist,
                             album: song.album, spotifyTrackId: song.spotifyId, msPlayed: min(song.duration, 200_000))
            }
        }
    }
}
