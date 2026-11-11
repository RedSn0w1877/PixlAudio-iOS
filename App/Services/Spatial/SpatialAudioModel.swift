import Foundation
import Observation
import PixlModel

/// Spatial audio as the screens see it (`env.spatial`; cloud audio spec of 2026-11-10, section 6): the eight
/// settings, what plays now, where the cloud render of the playing song stands, and what the phone holds. The player
/// sheet's Spatial audio sheet and Settings › Playback › Sound read it and call it; they never touch the two services
/// behind it.
///
/// The work is done by those two services (PixlModel's `SpatialPlayback` and `SpatialLibrary`, built by
/// `SpatialPlaybackFactory` and `SpatialLibraryFactory`). This object only connects them:
/// - it owns the settings (`CloudAudioSettingsStore`) and gives every change to both services, in order;
/// - it mirrors the player's snapshot and the library's events for the screens;
/// - it is the one caller of `SpatialLibrary.request` for the song that is playing: whenever the player says the
///   selected profile's render is wanted (`SpatialPlaybackSnapshot.wantedRender`), it asks once. Whether anything
///   leaves the phone is the library's decision (the two cloud switches, the network, the caps).
///
/// Nothing here is per frame: the snapshot changes when the song, the selection, the output or the audible rendition
/// changes, never with the position.
@MainActor
@Observable
final class SpatialAudioModel {
    // MARK: What the screens read

    /// The settings in force (spec 6.1).
    private(set) var settings: CloudAudioSettings
    /// What the player does now.
    private(set) var snapshot: SpatialPlaybackSnapshot = .idle
    /// Where the library stands with the selected profile's render of the playing song (`none` when nothing plays or
    /// Spatial audio is off): its own answer, never `preview`. A render that cannot start yet says why
    /// (`waitingForNetwork`, `capReached`).
    private(set) var libraryStatus: RenditionStatus = .none
    /// "Songs ready: N · X GB on this phone".
    private(set) var usage: CloudAudioUsage = .empty
    /// "Remove downloaded renders" is running.
    private(set) var isRemovingRenders = false
    /// This build carries PixlAudio's own cloud keys and they open (what `spatial.cloud` defaults to).
    private(set) var hasBuiltInCloudKeys: Bool
    /// Cloud Studio's own switch, "Process songs in the cloud" (Settings › Sing › Cloud processing): the master. Off
    /// means no cloud activity of any kind, whatever `spatial.cloud` says (spec 6.1 "Two switches").
    private(set) var isCloudStudioOn: Bool

    /// `spatial.profile`: off, or the selected profile.
    var selection: SpatialSelection { settings.profile }

    /// Cloud renders are on: both switches are. The row for `spatial.cloud` shows `settings.cloud`; when this is
    /// false while that is true, the master switch is what holds renders back.
    var cloudRendersOn: Bool { settings.cloud && isCloudStudioOn }

    /// The playing song's status for the selected profile (spec 6.1): the library's once the cloud is involved, else
    /// `preview` while the on-device stage is what plays.
    var status: RenditionStatus { libraryStatus.shown(onDeviceAudible: snapshot.audible.isOnDevice) }

    /// The line under the profile list (spec 6.5); `statusLine.text` is the sentence.
    var statusLine: SpatialStatusLine {
        SpatialStatusLine.of(settings: settings, snapshot: snapshot, status: status, cloudRendersOn: cloudRendersOn)
    }

    /// "Spatial active" (spec 6.3), as the player sees it.
    var isActive: Bool { snapshot.isActive }

    // MARK: This song (Hoa, 2026-11-11)

    /// The sheet's "This song" switch is shown: a profile is selected and the playing song has a Spotify id (the key
    /// of `spatial.songsOff`). With Spatial audio off every song plays its original anyway.
    var showsThisSong: Bool { settings.profile.isOn && snapshot.songId != nil && snapshot.spotifyId != nil }

    /// The switch's state: Spatial audio plays for the current song (false: turned off for it, it plays its original
    /// at full quality). Read from the settings, so it flips the moment it is tapped; the player follows.
    var isOnForCurrentSong: Bool { !settings.isOffFor(snapshot.spotifyId) }

    /// The selection the current song plays with: `off` for a song turned off. The player's button shows it, so it
    /// reads Off for that song while the sheet's list keeps the profile picked for every other song.
    var currentSongSelection: SpatialSelection { settings.selection(for: snapshot.spotifyId) }

    // MARK: Plumbing

    /// The two services. The screens go through this object; tests and diagnostics may look.
    @ObservationIgnored let library: any SpatialLibrary
    @ObservationIgnored let playback: any SpatialPlayback
    @ObservationIgnored private let store: CloudAudioSettingsStore
    @ObservationIgnored private let currentSong: () -> Song?
    @ObservationIgnored private let builtInCloudKeys: () -> Bool
    @ObservationIgnored private let cloudStudioEnabled: () -> Bool
    @ObservationIgnored private var started = false
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []
    /// Settings reach the services one after another, in the order they were made.
    @ObservationIgnored private var applyChain: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    /// The render already asked for (asked again only once the player has stopped wanting it, or the settings changed).
    @ObservationIgnored private var requested: RenditionKey?
    /// Counts every word about the current render's state, so an answer that was on its way while a newer one
    /// arrived is dropped instead of overwriting it.
    @ObservationIgnored private var statusStamp = 0
    /// UI tests: the state was set by hand and nothing overwrites it.
    @ObservationIgnored private var isDemo = false

    /// - Parameters:
    ///   - currentSong: the song the player shows as current (`PlaybackStore.current`).
    ///   - builtInCloudKeys: whether built-in cloud keys are available now (`CloudSettings.builtInAvailable`); read
    ///     through observation, so the default of `spatial.cloud` follows it.
    ///   - cloudStudioEnabled: Cloud Studio's own switch (`CloudSettings.isEnabled`), the master; observed too.
    init(defaults: UserDefaults, library: any SpatialLibrary, playback: any SpatialPlayback,
         currentSong: @escaping () -> Song?, builtInCloudKeys: @escaping () -> Bool,
         cloudStudioEnabled: @escaping () -> Bool) {
        self.library = library
        self.playback = playback
        self.currentSong = currentSong
        self.builtInCloudKeys = builtInCloudKeys
        self.cloudStudioEnabled = cloudStudioEnabled
        let store = CloudAudioSettingsStore(defaults: defaults)
        self.store = store
        let available = builtInCloudKeys()
        hasBuiltInCloudKeys = available
        isCloudStudioOn = cloudStudioEnabled()
        settings = store.load(builtInCloudKeys: available)
    }

    /// The model the app runs on: both services from their factories.
    static func make(_ context: SpatialAudioContext) -> SpatialAudioModel {
        let library = SpatialLibraryFactory.make(context)
        let playback = SpatialPlaybackFactory.make(context, library: library)
        let playbackStore = context.playback
        let cloudSettings = context.cloud.settings
        let model = SpatialAudioModel(defaults: context.defaults, library: library, playback: playback,
                                      currentSong: { playbackStore.current },
                                      builtInCloudKeys: { cloudSettings.builtInAvailable },
                                      cloudStudioEnabled: { cloudSettings.isEnabled })
        // UI tests: the states the screenshots show (`start()` never runs there).
        if context.launch.isUITest { SpatialDemo.apply(launch: context.launch, to: model) }
        return model
    }

    // MARK: Lifecycle

    /// Gives both services the settings and starts listening to them (`AppEnvironment.start()`; not in UI tests).
    func start() {
        guard !started else { return }
        started = true
        observeCloudStudio()
        let library = self.library, playback = self.playback, settings = self.settings
        let setup = Task { [weak self] in
            // Listen before anything is applied, so no change is missed.
            let snapshots = await playback.events()
            let events = await library.events()
            self?.listen(snapshots: snapshots, events: events)
            await library.apply(settings)
            await playback.apply(settings)
            let first = await playback.snapshot()
            let usage = await library.usage()
            guard let self, !self.isDemo else { return }
            self.playbackChanged(first)
            if self.usage != usage { self.usage = usage }
        }
        applyChain = setup
    }

    private func listen(snapshots: AsyncStream<SpatialPlaybackSnapshot>, events: AsyncStream<SpatialLibraryEvent>) {
        listeners.append(Task { [weak self] in
            for await snapshot in snapshots { self?.playbackChanged(snapshot) }
        })
        listeners.append(Task { [weak self] in
            for await event in events { self?.libraryChanged(event) }
        })
    }

    /// Follows two facts of Cloud Studio's settings: the built-in keys (a blob that turns out not to open switches
    /// the default of `spatial.cloud` off) and its own switch, the master of every cloud activity.
    private func observeCloudStudio() {
        let (available, enabled) = withObservationTracking {
            (builtInCloudKeys(), cloudStudioEnabled())
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeCloudStudio() }
        }
        if enabled != isCloudStudioOn {
            isCloudStudioOn = enabled
            // Switched on: a render the player wants may be asked for now.
            if enabled {
                requested = nil
                syncCurrentRender()
            }
        }
        if available != hasBuiltInCloudKeys {
            hasBuiltInCloudKeys = available
            reloadSettings()
        }
    }

    // MARK: What the screens do

    /// Picks a profile, or Off. Picking a profile is what turns Spatial audio on.
    func select(_ selection: SpatialSelection) {
        guard settings.profile != selection else { return }
        settings.profile = selection
        store.setProfile(selection)
        settingsChanged()
    }

    /// Spatial audio's own cloud switch: ask the cloud for the real render (off: on-device only).
    func setCloud(_ isOn: Bool) {
        // Written even when it equals the default: from now on it is the person's choice.
        store.setCloud(isOn)
        guard settings.cloud != isOn else { return }
        settings.cloud = isOn
        settingsChanged()
    }

    /// "Prepare songs ahead".
    func setPrepareAhead(_ isOn: Bool) {
        guard settings.prepareAhead != isOn else { return }
        settings.prepareAhead = isOn
        store.setPrepareAhead(isOn)
        settingsChanged()
    }

    /// The sheet's "This song" switch: Spatial audio on or off for the song that plays, remembered for every later
    /// play of it (`spatial.songsOff`). Off, it plays its original: the player bypasses the stage, goes back from a
    /// render to its own audio, and nothing is asked of the cloud or prepared ahead for it.
    func setOnForCurrentSong(_ isOn: Bool) {
        guard let spotifyId = snapshot.spotifyId else { return }
        setSongOff(spotifyId, off: !isOn)
    }

    /// `spatial.songsOff` for one song.
    func setSongOff(_ spotifyId: String, off: Bool) {
        guard !spotifyId.isEmpty, settings.isOffFor(spotifyId) != off else { return }
        if off { settings.songsOff.insert(spotifyId) } else { settings.songsOff.remove(spotifyId) }
        store.setSongOff(spotifyId, off: off)
        settingsChanged()
    }

    /// Developer mode: where Spatial audio may play.
    func setRoute(_ mode: SpatialRouteMode) {
        guard settings.route != mode else { return }
        settings.route = mode
        store.setRoute(mode)
        settingsChanged()
    }

    /// Developer mode: the local budget for downloaded renders.
    func setStorageMB(_ megabytes: Int) {
        let value = CloudAudioSettings.clampedStorageMB(megabytes)
        guard settings.storageMB != value else { return }
        settings.storageMB = value
        store.setStorageMB(value)
        settingsChanged()
    }

    /// Developer mode: the month's cap for library jobs, in dollars (nil: no limit).
    func setMonthlyCapUSD(_ cap: Double?) {
        let value = CloudAudioSettings.monthlyCap(fromStored: CloudAudioSettings.storedMonthlyCap(cap))
        guard settings.monthlyCapUSD != value else { return }
        settings.monthlyCapUSD = value
        store.setMonthlyCapUSD(value)
        settingsChanged()
    }

    /// Developer mode: songs a day the background queue may send.
    func setDailyAhead(_ songs: Int) {
        let value = CloudAudioSettings.clampedDailyAhead(songs)
        guard settings.dailyAhead != value else { return }
        settings.dailyAhead = value
        store.setDailyAhead(value)
        settingsChanged()
    }

    /// Reads the stored settings again (after a restore, or when the built-in keys' state changed).
    func reloadSettings() {
        let loaded = store.load(builtInCloudKeys: hasBuiltInCloudKeys)
        guard loaded != settings else { return }
        settings = loaded
        settingsChanged()
    }

    /// Asks the library what the phone holds (the settings page calls it when it appears).
    func refreshUsage() async {
        guard !isDemo else { return }
        let usage = await library.usage()
        if self.usage != usage { self.usage = usage }
    }

    /// "Remove downloaded renders": every local render goes (nothing in the shared library does).
    func removeDownloadedRenders() async {
        guard !isRemovingRenders else { return }
        isRemovingRenders = true
        let usage = await library.removeAll()
        isRemovingRenders = false
        if self.usage != usage { self.usage = usage }
        // The playing song may want its render again.
        requested = nil
        syncCurrentRender()
    }

    /// Developer mode's per-song diagnostics: the local renders of the playing song, with their manifests (source
    /// codec, stem mode, loudness).
    func renditionsOfCurrentSong() async -> [LocalRendition] {
        guard let videoId = snapshot.videoId else { return [] }
        return await library.localRenditions(videoId: videoId)
    }

    /// UI tests: a fixed state for a screenshot (nothing overwrites it afterwards).
    func setDemo(snapshot: SpatialPlaybackSnapshot, libraryStatus: RenditionStatus, usage: CloudAudioUsage = .empty) {
        isDemo = true
        self.snapshot = snapshot
        self.libraryStatus = libraryStatus
        self.usage = usage
    }

    // MARK: Connecting the two services

    private func settingsChanged() {
        // Another profile, or the cloud switched on: what was asked for no longer covers what is wanted.
        requested = nil
        guard started else { return }
        let library = self.library, playback = self.playback, settings = self.settings
        let previous = applyChain
        applyChain = Task {
            await previous?.value
            await library.apply(settings)
            await playback.apply(settings)
        }
        syncCurrentRender()
    }

    private func playbackChanged(_ new: SpatialPlaybackSnapshot) {
        guard !isDemo else { return }
        if snapshot != new { snapshot = new }
        if new.wantedRender == nil { requested = nil }
        syncCurrentRender()
    }

    private func libraryChanged(_ event: SpatialLibraryEvent) {
        guard !isDemo else { return }
        switch event {
        case .statusChanged(let key, let status):
            if key == currentKey { setLibraryStatus(status) }
        case .renditionReady(let rendition):
            if rendition.key == currentKey { setLibraryStatus(RenditionStatus.ready) }
        case .renditionRemoved(let key):
            if key == currentKey {
                setLibraryStatus(RenditionStatus.none)
                requested = nil
            }
        case .usageChanged(let usage):
            if self.usage != usage { self.usage = usage }
        }
    }

    /// The selected profile's render of the playing song; nil for a song Spatial audio is turned off for (nothing is
    /// asked for it, and its status is `none`).
    private var currentKey: RenditionKey? {
        guard let videoId = snapshot.videoId, let profile = settings.profileFor(snapshot.spotifyId) else { return nil }
        return RenditionKey(videoId: videoId, profile: profile)
    }

    private func setLibraryStatus(_ status: RenditionStatus) {
        statusStamp &+= 1
        if libraryStatus != status { libraryStatus = status }
    }

    /// Brings `libraryStatus` up to date for the song that is playing, and runs spec 6.2 for it: when the player wants
    /// the selected profile's render and it was not asked for yet, the library is asked, once. Otherwise the library
    /// is only asked where the render stands.
    private func syncCurrentRender() {
        statusTask?.cancel()
        statusTask = nil
        guard let key = currentKey else {
            setLibraryStatus(RenditionStatus.none)
            return
        }
        statusStamp &+= 1
        let stamp = statusStamp
        let library = self.library
        if started, snapshot.wantedRender == key, key != requested, let song = currentSong(), song.id == snapshot.songId {
            requested = key
            let request = RenditionRequest(song: song, videoId: key.videoId, profile: key.profile, reason: .playing)
            // Never cancelled: a request, once made, is the library's to finish.
            Task { [weak self] in
                let answer = await library.request(request)
                guard let self, self.statusStamp == stamp, self.currentKey == key else { return }
                self.setLibraryStatus(answer)
            }
        } else {
            statusTask = Task { [weak self] in
                let answer = await library.status(key)
                guard !Task.isCancelled, let self, self.statusStamp == stamp, self.currentKey == key else { return }
                self.setLibraryStatus(answer)
            }
        }
    }
}
