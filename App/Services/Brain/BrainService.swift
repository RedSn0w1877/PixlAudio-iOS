import Foundation
import Observation
import PixlLibrary
import PixlModel
import PixlNet

/// What the queue shows on the Autoplay line (docs/brain-spec.md, 8.4). The switch itself is
/// `SettingsStore.ai.musicDiscoveryEnabled`.
@Observable
final class AutoplayState {
    /// The queue ended and picks are being looked for (the backstop window).
    var finding = false
    /// The picks come from the library alone (offline, or the YouTube source is off or had nothing).
    var fromLibrary = false
    /// Where the Autoplay line is drawn: the queue index of the first entry Autoplay added that is still to come.
    /// Nil while there is none (the line then closes the queue).
    var lineIndex: Int?
    /// Three skips in a row: Autoplay turned to something else (shown on the line for a few seconds).
    var changedDirection = false
    /// The queue is a station (8.3): what it is named after, a song's title or an artist's name. Nil for none.
    var stationTitle: String?
    var stationIsArtist = false
    /// What the station was started from (`Station.sourceSong`, `.sourceArtist`, `.sourceAlbum`, `.sourcePlaylist`).
    var stationSource = Station.sourceSong
    /// The Familiar / Blend / Discover switch (`Novelty.familiar`, `.blend`, `.discover`).
    var novelty = Novelty.blend
    /// The reason line of every queue entry that has one, by song id (8.8).
    var why: [String: QueueWhy] = [:]
}

/// The app's side of the music brain (docs/brain-spec.md, 2.1): it owns the brain's files through `BrainRepository`
/// and `BrainEngine` (PixlLibrary, where every decision and all storage live), hands every finished play to the
/// event recorder, and knows the tracks from outside the library that the engine put in a queue, so the app can
/// show them (Recently Played, the song sheet) and save them (Like, "Add to playlist").
///
/// Nothing here runs at app start: the files under `Application Support/Brain/` are read on first use.
final class BrainService {
    /// Reached by `LibraryEditor`, which is built in several places: Like and "Add to playlist" ask it whether an
    /// id that is not in the library is a track the engine played.
    static weak var shared: BrainService?

    let autoplay = AutoplayState()
    /// The station of the queue and the novelty switch (8.3): two small stored values, read on first use.
    let stations: StationStore
    /// Nil in UI tests: no files, no network.
    let repository: BrainRepository?
    /// The affinity tables, the session and the event log, behind one actor. Nil in UI tests.
    let engine: BrainEngine?
    /// Home's "Because you listened to" rows (8.1). Nil in UI tests.
    let homeRows: BrainHomeRows?
    /// Daily Mix and Your Mix with new music (8.2, stage 2a): built by `configureMixes`, never at launch. Nil in UI tests.
    private(set) var mixes: BrainMixes?
    /// The once-a-day background search for new music (3.7, stage 2a). Nil in UI tests.
    private(set) var refresh: BrainRefresh?
    /// New releases by the artists the listener plays (6.3): one small file Home reads without the brain's state. Nil in UI tests.
    let newReleases: NewReleases?
    /// What the Spotify sync receives with a track and used to drop (13.1). Nil in UI tests.
    let spotifyFacts: SpotifyFactStore?
    private let directory: URL?
    /// What the refresh asks of the rest of the app (set by `AppEnvironment`).
    var refreshIsAllowed: () -> Bool = { true }
    var isMusicPlaying: () -> Bool = { false }
    /// Created with the first refresh, never at launch (its path monitor starts then).
    private lazy var networkMonitor = NetworkConditionsMonitor()
    private var refreshTask: Task<Void, Never>?
    private var idleCheckTask: Task<Void, Never>?
    private var sceneActiveAtMs: Int64 = 0
    /// Called on the main actor after each recorded play (Autoplay reacts to skips and likes).
    var onReaction: ((Reaction) -> Void)?
    /// Marks the song that is playing (an `EventFlags` bit): set by `AppEnvironment` to the listening stats.
    var markPlaying: ((String, Int32) -> Void)?
    /// Created with the first play that ends, never at launch.
    private lazy var recorder: BrainRecorder? = engine.map { engine in
        BrainRecorder(engine: engine) { [weak self] reaction in
            await self?.deliver(reaction)
        }
    }

    private func deliver(_ reaction: Reaction) {
        onReaction?(reaction)
    }

    /// Tracks from outside the library known in this run: what Autoplay queued, and what the files hold.
    private var tracks: [String: EngineTrack] = [:]
    /// Bumped whenever `tracks` gains or replaces a track: the songs built from them are built once per value.
    private var tracksRevision = 0
    private var storedTracksTask: Task<Void, Never>?
    private var storedTracksLoaded = false
    private var deferredLoadTask: Task<Void, Never>?
    private var songsCache: [String: Song] = [:]
    private var songsCacheRevision = -1
    private let launchedAtMs = currentTimeMillis()

    /// Whether the library has an artist or an album under an id (set by `AppEnvironment`): a track from outside
    /// the library is pointed at the library's own artist of the same name (`EngineSongLinks`).
    var libraryLinks: (hasArtist: (Int64) -> Bool, hasAlbum: (Int64) -> Bool)?
    /// The queue's own song for a pick it still holds (set by `AppEnvironment`): after a restart the restored
    /// queue knows a pick before the stored tracks are read.
    var queuedPick: ((String) -> Song?)?
    /// The stored tracks were read after launch and Home may resolve more of the history (set by `AppEnvironment`).
    var onStoredTracksLoaded: (() -> Void)?

    /// `sources` is what a rebuild of the brain's state reads from the rest of the app (4.4); nothing is read
    /// until one runs.
    init(radioSource: (any RadioSource)?, isEnabled: Bool, sources: BrainEngine.Sources? = nil) {
        stations = StationStore(defaults: isEnabled ? UserDefaults.standard : nil)
        if isEnabled, let directory = Self.defaultDirectory() {
            let repository = BrainRepository(directory: directory, radioSource: radioSource)
            self.repository = repository
            let engine = BrainEngine(directory: directory, repository: repository, sources: sources)
            self.engine = engine
            homeRows = BrainHomeRows(directory: directory, repository: repository, engine: engine)
            self.directory = directory
            newReleases = NewReleases(store: AtomicReleaseFileStore(directory: directory), source: radioSource,
                                      repository: repository)
            let shapes: @Sendable () -> Bool
            if let given = sources?.spotifyShapesPicks {
                shapes = given
            } else {
                shapes = { true }
            }
            let facts = SpotifyFactStore(directory: directory, enabled: shapes)
            spotifyFacts = facts
            SpotifyFactsRelay.shared.set(facts)
        } else {
            newReleases = nil
            spotifyFacts = nil
            directory = nil
            repository = nil
            engine = nil
            homeRows = nil
        }
    }

    // MARK: Daily Mix and Your Mix (8.2) and the refresh (3.7)

    /// Builds the objects behind the mixes and the refresh. Reads nothing, fetches nothing: `sources` are closures.
    func configureMixes(sources: MixSources, budget: HostBudget?) {
        guard let directory, let repository, let engine else { return }
        let mixes = BrainMixes(directory: directory, repository: repository, engine: engine, sources: sources)
        self.mixes = mixes
        let library = sources.library
        let work = BrainRefreshWork(mixes: mixes, repository: repository, budget: budget,
                                    matchedVideoId: sources.matchedVideoId, newReleases: newReleases,
                                    librarySongs: { await library() })
        let allowed: @Sendable () async -> Bool = { @MainActor [weak self] in self?.refreshIsAllowed() ?? false }
        refresh = BrainRefresh(work: work, repository: repository, engine: engine, allowed: allowed)
    }

    /// The first moments of the process keep the brain's files closed (docs/brain-spec.md, 12.1 "App start"): a mix is
    /// read and built after this wait, off the main actor.
    func waitForStartup() async {
        let wait = BrainStartup.storedTracksWaitMs(sinceLaunchMs: currentTimeMillis() - launchedAtMs)
        if wait > 0 { try? await Task.sleep(for: .milliseconds(wait)) }
    }

    /// A mix was built: the one background job is asked for now, and never at app start.
    func mixWasBuilt() {
        Task { [weak self] in await self?.scheduleFromLastRun() }
    }

    /// Puts the system's request in place a day after the last run.
    func scheduleFromLastRun() async {
        guard let refresh else { return }
        let last = await refresh.lastRunMs()
        BrainBackground.schedule(lastRunMs: last)
    }

    /// One refresh now (the system gave a processing task, or the app has been quiet in the foreground). Nil when
    /// something does not allow it: the conditions of 3.7 (unmetered network, not low power) are checked here.
    @discardableResult
    func runRefresh() async -> BrainRefreshRunner.Report? {
        guard let refresh, refreshIsAllowed() else { return nil }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return nil }
        guard await isOnUnmeteredNetwork() else { return nil }
        let playing: @Sendable () async -> Bool = { @MainActor [weak self] in self?.isMusicPlaying() ?? false }
        return await refresh.run(playing: playing)
    }

    /// Wi-Fi or wired, not a hotspot, not Low Data Mode: Android asks WorkManager for an unmetered network, and iOS can
    /// only say "a network", so the run checks.
    private func isOnUnmeteredNetwork() async -> Bool {
        networkMonitor.startIfNeeded()
        for _ in 0..<10 where networkMonitor.conditions.network == .unknown {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let conditions = networkMonitor.conditions
        return (conditions.network == .wifi || conditions.network == .wired) && !conditions.isExpensive && !conditions.isConstrained
    }

    /// The foreground fallback of the system's task, which iOS runs when it decides to (or never): once the app has been
    /// in front for `RefreshSchedule.foregroundIdleMs` and a day has gone by, the same work runs at low priority.
    func sceneBecameActive() {
        sceneActiveAtMs = currentTimeMillis()
        idleCheckTask?.cancel()
        guard refresh != nil else { return }
        idleCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(RefreshSchedule.foregroundIdleMs))
            guard !Task.isCancelled else { return }
            await self?.runRefreshIfDue()
        }
    }

    func sceneLeft() {
        idleCheckTask?.cancel()
        idleCheckTask = nil
    }

    private func runRefreshIfDue() async {
        guard refreshTask == nil, let refresh, let engine else { return }
        let now = currentTimeMillis()
        // The brain was used (a play ended or a mix was built): a refresh is never the first thing it does.
        let loaded = await engine.isLoaded
        let ranBefore = await engine.storedValue(BrainRefresh.keyLast) != nil
        let used = loaded || ranBefore
        let due = RefreshSchedule.foregroundRunDue(
            nowMs: now, lastRunMs: await refresh.lastRunMs(), lastAttemptMs: await refresh.lastAttemptMs(),
            idleMs: now - sceneActiveAtMs, brainUsed: used, allowed: refreshIsAllowed())
        guard due else { return }
        refreshTask = Task(priority: .utility) { [weak self] in
            _ = await self?.runRefresh()
            self?.refreshTask = nil
            await self?.scheduleFromLastRun()
        }
    }

    // MARK: New releases (6.3) and the facts under a reason (8.8)

    /// The "New from artists you play" row, from the saved file only: no network, no brain state. Nil under six cards.
    func releaseRow(blocked: BlockedArtistMatcher, adjustments: TasteAdjustmentSet) async -> BrainReleaseRow? {
        await newReleases?.row(blocked: blocked, adjustments: adjustments)
    }

    /// The supporting facts of `song` (8.8): up to two true statements from the listener's own plays and the song itself.
    /// Resolves the song's ids, then reads the log off the engine's actor; nothing when the brain is off.
    func whyFacts(for song: Song) async -> [WhyFacts.Fact] {
        guard let repository, let engine, let facts = TrackCatalog.facts(of: song) else { return [] }
        let names = [facts.primaryArtist] + facts.otherArtists.prefix(PlayEvent.maxOtherAids)
        let ids = await repository.resolve(keys: facts.keys, durationMs: Int32(clamping: max(song.duration, 0)),
                                           artistNames: names)
        return await engine.whyFacts(rid: ids.rid, aid: ids.aids.first ?? 0, year: song.year)
    }

    // MARK: Don't count this (8.5) and Private session

    /// "Don't count this" on one song: the plays of its recording leave the picks at once and a rebuild makes the tables
    /// exact. The play in flight is flagged too, so it is logged as left out when it ends.
    func excludeSong(_ song: Song) async -> ExcludedPlays? {
        guard let repository, let engine, let facts = TrackCatalog.facts(of: song) else { return nil }
        markPlaying?(song.id, EventFlags.learnExcluded)
        let rid = await repository.resolveTracks([TrackRequest(keys: facts.keys,
                                                               durationMs: Int32(clamping: max(song.duration, 0)))])[0]
        if rid == 0 { return nil }
        return await engine.excludeRecordings(rids: [rid], targetKind: FeedbackKinds.targetSong, targetId: rid)
    }

    /// "Don't count the last hour": every live play of the last hour leaves the picks.
    func excludeLastHour(playingSongId: String?) async -> ExcludedPlays? {
        guard let engine else { return nil }
        if let playingSongId { markPlaying?(playingSongId, EventFlags.learnExcluded) }
        return await engine.excludeLastHour()
    }

    func undoExclusion(_ excluded: ExcludedPlays) async { await engine?.undoExclusion(excluded) }

    /// The private session (8.5): off at every app start (the engine holds it in memory only).
    func setPrivate(_ on: Bool) { Task { [engine] in await engine?.setPrivate(on) } }

    /// The Spotify switch went off: what the sync kept goes now, and the next rebuild leaves the rest out.
    func spotifyShapesTurnedOff() {
        spotifyFacts?.clear()
        Task { [engine] in await engine?.requestRebuild(force: true) }
    }

    // MARK: The event log (docs/brain-spec.md, 4.2)

    /// A play ended, however short. Returns at once: the recorder works off the main actor, one play at a time.
    func playFinished(_ play: FinishedPlay) { recorder?.playFinished(play) }

    /// The play in flight, as far as it got; nil clears it.
    func playOpen(_ play: FinishedPlay?) { recorder?.playOpen(play) }

    /// The listener liked or saved these songs: the one that is playing carries it into its event.
    func mark(_ songIds: [String], flag: Int32) {
        guard let markPlaying else { return }
        for songId in songIds { markPlaying(songId, flag) }
    }

    static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Brain", isDirectory: true)
    }

    // MARK: Engine tracks

    /// The song a track from outside the library plays as: `yt:<videoId>` through `pixlstream://<videoId>`, with the
    /// artist and album ids of the YouTube Music importer's scheme.
    nonisolated static func queueSong(for track: EngineTrack, nowMs: Int64 = currentTimeMillis()) -> Song {
        track.song(artistId: { SpotifyLibrary.unifiedArtistId("yt-artist:\($0.lowercased())") },
                   albumId: { album, artist in
                       SpotifyLibrary.unifiedAlbumId("yt-album:\(album.lowercased())|\(artist.lowercased())")
                   },
                   nowMs: nowMs)
    }

    /// Remembers tracks that are about to be queued and stores them, so they are still known after a restart.
    func register(_ newTracks: [EngineTrack]) {
        guard !newTracks.isEmpty else { return }
        for track in newTracks { tracks[track.songId] = track }
        tracksRevision &+= 1
        guard let repository else { return }
        Task.detached(priority: .utility) { await repository.registerPlayable(newTracks) }
    }

    /// The track that plays under `songId`: one the engine queued in this run, one the files hold (once they were
    /// read), or a pick the queue itself still holds (a queue restored after a restart, before the files are read).
    func track(songId: String) -> EngineTrack? {
        if let known = tracks[songId] { return known }
        guard let song = queuedPick?(songId), let track = EngineTrack(queueSong: song) else { return nil }
        tracks[songId] = track
        tracksRevision &+= 1
        return track
    }

    /// The queue's song for an id the library does not have (the song sheet of an engine item).
    func song(id: String) -> Song? { track(songId: id).map { linked(Self.queueSong(for: $0)) } }

    /// `song` with its artists pointed at the library's own artists of the same name, and no album when the
    /// library has none for it: "Go to artist" then opens the artist the listener has, not an empty page.
    func linked(_ song: Song) -> Song {
        guard let libraryLinks else { return song }
        return EngineSongLinks.link(song, hasArtist: libraryLinks.hasArtist, hasAlbum: libraryLinks.hasAlbum,
                                    libraryArtistId: { SpotifyLibrary.unifiedArtistId(KotlinText.lowercase($0)) })
    }

    /// The library rows a saved engine track gets: exactly what the YouTube Music importer writes for the same
    /// video, so the id (`yt:<videoId>`) and the rows agree whichever way the track came in.
    func libraryRows(songId: String, nowMs: Int64) -> (song: Song, album: Album, artist: Artist)? {
        guard let track = track(songId: songId) else { return nil }
        let song = YouTubeSongFactory.song(
            YouTubeMusicTrack(videoId: track.videoId, title: track.title, artist: track.artistDisplay, album: track.album,
                              thumbnailUrl: track.artUrl, durationMs: track.durationMs),
            now: nowMs)
        return (song, YouTubeSongFactory.album(for: song, now: nowMs), YouTubeSongFactory.artist(for: song))
    }

    /// Reads the stored tracks once (off the main actor) and returns every known engine track as a song by id:
    /// Recently Played resolves ids the library does not have through this. The songs are built once per set of
    /// tracks, not once per call.
    func engineSongs() async -> [String: Song] {
        guard let repository else { return [:] }
        if storedTracksTask == nil {
            storedTracksTask = Task { [weak self] in
                let stored = await repository.engineTracks()
                guard let self else { return }
                var added = false
                // A stored row replaces what was read back from a restored queue entry (which has no recording id).
                for track in stored where (self.tracks[track.songId]?.rid ?? 0) == 0 {
                    self.tracks[track.songId] = track
                    added = true
                }
                if added { self.tracksRevision &+= 1 }
                self.storedTracksLoaded = true
            }
        }
        await storedTracksTask?.value
        if songsCacheRevision == tracksRevision { return songsCache }
        let revision = tracksRevision
        let known = Array(tracks.values)
        var songs: [String: Song] = [:]
        if !known.isEmpty {
            songs = await Task.detached(priority: .utility) {
                let now = currentTimeMillis()
                var built: [String: Song] = [:]
                built.reserveCapacity(known.count)
                for track in known { built[track.songId] = BrainService.queueSong(for: track, nowMs: now) }
                return built
            }.value
        }
        songsCache = songs
        songsCacheRevision = revision
        return songs
    }

    /// For Home's own refresh, which also runs at launch: what is known by now, without waiting for a file. In the
    /// app's first seconds the stored tracks are not read; they are read a moment later, and Home is told when
    /// that turned up anything (docs/brain-spec.md, 12.1 "App start").
    func engineSongsForHome() async -> [String: Song] {
        guard repository != nil else { return [:] }
        if storedTracksLoaded || storedTracksTask != nil { return await engineSongs() }
        let wait = BrainStartup.storedTracksWaitMs(sinceLaunchMs: currentTimeMillis() - launchedAtMs)
        if wait == 0 { return await engineSongs() }
        if deferredLoadTask == nil {
            deferredLoadTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(wait))
                guard let self else { return }
                let before = self.tracksRevision
                _ = await self.engineSongs()
                if self.tracksRevision != before { self.onStoredTracksLoaded?() }
            }
        }
        return songsCacheRevision == tracksRevision ? songsCache : [:]
    }
}
