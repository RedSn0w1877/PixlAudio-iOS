import Foundation
import Observation
import PixlModel
import PixlNet
import UIKit

/// Spotify Connect output (shared spec with Android, docs/parity.md › Spotify Connect): plays PixlAudio's queue on
/// a Spotify Connect device (an Echo, a TV, a speaker, the desktop app) through the Web API's Player endpoints. The
/// device streams from Spotify; PixlAudio sends the track URIs and stays the remote. While a session runs
/// `PlaybackStore` forwards the transport here (`RemotePlaybackOutput`) and the local engine stays paused with its
/// queue model intact, so ending the session resumes on this phone exactly where the device was.
///
/// All networking and JSON run in PixlNet's actors (`SpotifyConnectClient`, `SpotifyConnectResolver`); this main-actor
/// object holds the published state and runs the pure reducer. Polling runs only while a session is up (≈ 1 s in
/// the foreground, 5 s in the background) and writes observable state only when the reducer reports a change.
@Observable
final class SpotifyConnectController: RemotePlaybackOutput {
    nonisolated enum Availability: Equatable, Sendable {
        /// Spotify isn't linked: the sheet hides the section.
        case notLinked
        /// Linked before Connect's scopes existed: "Reconnect Spotify to use Connect".
        case needsReconnect
        case ready
    }

    /// The device a session plays on, as the UI shows it. Its volume is `volumePercent` on the controller, so a
    /// volume change doesn't redraw everything that shows the device (the full player's output pill, the sheets).
    nonisolated struct ActiveDevice: Equatable, Sendable {
        var id: String
        var name: String
        var type: String
        var supportsVolume: Bool
        var symbolName: String { SpotifyConnectDevice.symbolName(forType: type) }
        /// Whether the phone's volume buttons drive it (it takes volume commands and isn't a phone or a tablet).
        var takesVolumeButtons: Bool { SpotifyConnectVolumeKeys.controls(type: type, supportsVolume: supportsVolume) }
    }

    // MARK: Published state

    private(set) var availability: Availability = .notLinked
    private(set) var devices: [SpotifyConnectDevice] = []
    private(set) var isRefreshing = false
    /// A device list was loaded at least once (the empty hint shows only then).
    private(set) var hasLoadedDevices = false
    private(set) var deviceListError: String?
    /// The device a session is being started on.
    private(set) var connectingDeviceId: String?
    /// nil while this phone plays.
    private(set) var active: ActiveDevice?
    /// The active device's volume (nil while none plays, or when it never reported one).
    private(set) var volumePercent: Int?

    /// Connect's own toasts (shown by `RootView` and the devices sheet, over whatever is on screen).
    @ObservationIgnored let toast = LibraryToast()
    /// The volume pop-up the volume buttons show (`SpotifyConnectVolumeHUD`).
    @ObservationIgnored let volumeHUD = SpotifyConnectVolumeHUDModel()
    /// The phone's volume buttons (real launches only; `AppEnvironment` sets it).
    @ObservationIgnored var volumeButtons: SpotifyConnectVolumeButtons? {
        didSet { updateVolumeButtons() }
    }
    /// Now Playing republishes when the remote state changes, and learns when a session starts or ends.
    @ObservationIgnored var onRemoteStateChanged: (() -> Void)?
    @ObservationIgnored var onSessionChanged: ((_ active: Bool) -> Void)?

    // MARK: Dependencies and session internals

    @ObservationIgnored private let isDemo: Bool
    @ObservationIgnored private let spotify: SpotifyService
    @ObservationIgnored private let playback: PlaybackStore
    @ObservationIgnored private let client: SpotifyConnectClient
    @ObservationIgnored private let resolver: SpotifyConnectResolver
    @ObservationIgnored private var session: SpotifyConnectSessionState?
    /// The queue's song ids when `slots` was built, and what each resolved to (`slots[i]` ↔ `playback.queue[i]`).
    @ObservationIgnored private var slotSongIds: [String] = []
    @ObservationIgnored private var slots: [SpotifyConnectSlot] = []
    @ObservationIgnored private var resolvedBySongId: [String: SpotifyConnectSlot] = [:]
    /// The song ids of the queue the last window was sent from (`session.window.queueIndices` index into it).
    @ObservationIgnored private var sentSongIds: [String] = []
    @ObservationIgnored private var sessionGeneration = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    @ObservationIgnored private var resyncTask: Task<Void, Never>?
    @ObservationIgnored private var volumeTask: Task<Void, Never>?
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    /// Volume requests: their own single-flight lane, so a press never waits behind a window send's searches.
    @ObservationIgnored private var volumeLane = SpotifyConnectVolumeLane()
    /// No "Spotify is busy" toast for volume before this (one per Retry-After gate).
    @ObservationIgnored private var volumeBusyToastUntilMs: Int64 = 0
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var lastRepeatSent: SpotifyRepeatState?
    /// Background resolution found more after a short first window: send the longer one at the next track change.
    @ObservationIgnored private var extendAtNextTrack = false
    @ObservationIgnored private var networkFailures = 0
    /// "Stop playing" is reading the device's position.
    @ObservationIgnored private var isStopping = false
    @ObservationIgnored private var isForeground = true
    /// The granted scope a 403 "Insufficient client scope" was seen with (cleared once the login changes).
    @ObservationIgnored private var scopeDeniedFor: String??
    @ObservationIgnored private var lifecycleObservers: [any NSObjectProtocol] = []
    /// Demo (UI tests): the position the fake device started from.
    @ObservationIgnored private var demoAnchor = (positionMs: Int64(0), at: Date())

    static let foregroundPollMs: Int64 = 1000
    static let backgroundPollMs: Int64 = 5000
    /// Entries resolved before the first `play` (the current one plus a few after it): tapping a device shouldn't
    /// wait for a whole queue of searches.
    static let eagerLookahead = 4
    static let eagerLookupBudget = 12
    /// How far background resolution looks past the current entry.
    static let backgroundScanLimit = 200
    /// Consecutive failed polls (no network, 5xx) before the session is given up.
    static let maxNetworkFailures = 15
    /// Percent per volume-button press (Android `VOLUME_STEP`).
    static let volumeStep = SpotifyConnectVolumeKeys.step
    /// After the device accepted a volume `PUT`, polls keep the local value this much longer.
    static let volumeSettleMs: Int64 = 1500

    init(launch: LaunchConfiguration, spotify: SpotifyService, playback: PlaybackStore) {
        isDemo = launch.isUITest
        self.spotify = spotify
        self.playback = playback
        client = SpotifyConnectClient(http: URLSessionHTTPClient(), session: spotify.session)
        let connectClient = client
        resolver = SpotifyConnectResolver(
            storage: launch.isUITest ? nil : SpotifyConnectPlatform.cacheURL().map(SpotifyConnectFileStorage.init(url:)),
            search: { query in try await connectClient.searchTracks(query) },
            isrc: SpotifyConnectPlatform.isrc)
        if isDemo { applyDemo(launch.screen) } else { observeLifecycle() }
    }

    private func now() -> Int64 { currentTimeMillis() }

    // MARK: Availability and devices

    /// Re-reads whether Spotify is linked with Connect's scopes.
    func refreshAvailability() async {
        guard !isDemo else { return }
        guard spotify.isLoggedIn else {
            set(\.availability, .notLinked)
            return
        }
        let granted = await spotify.session.grantedScope()
        if let denied = scopeDeniedFor, denied != granted { scopeDeniedFor = nil }
        let missing = !SpotifyConnect.missingScopes(granted: granted).isEmpty || scopeDeniedFor != nil
        set(\.availability, missing ? .needsReconnect : .ready)
    }

    /// The sheet opened or was pulled: list the devices again.
    func refreshDevices() async {
        guard !isDemo else { return }
        await refreshAvailability()
        guard availability == .ready else {
            set(\.devices, [])
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let list = SpotifyConnectDevice.sortedForDisplay(try await client.devices())
            set(\.devices, list)
            set(\.deviceListError, nil)
            if let active, let device = list.first(where: { $0.deviceId == active.id }) {
                // A device that refused a volume command stays without volume control, whatever the list says.
                let supportsVolume = SpotifyConnectReducer.supportsVolume(device.supportsVolume, in: session)
                set(\.active, ActiveDevice(id: active.id, name: device.name, type: device.type,
                                           supportsVolume: supportsVolume))
                // Not over a value PixlAudio just set (the list may predate the last `PUT`).
                if let polled = device.volumePercent, now() >= session?.volumeHoldUntilMs ?? 0 {
                    set(\.volumePercent, polled)
                    if var state = session { state.volumePercent = polled; session = state }
                }
                if var state = session, state.supportsVolume != supportsVolume {
                    state.supportsVolume = supportsVolume
                    session = state
                }
                updateVolumeButtons()
            }
        } catch is CancellationError {
            return
        } catch let error as SpotifyConnectError {
            if error == .missingScope { markScopeDenied() }
            set(\.deviceListError, error.userMessage)
        } catch {
            set(\.deviceListError, SpotifyConnectError.network(String(describing: error)).userMessage)
        }
        if !hasLoadedDevices { hasLoadedDevices = true }
    }

    /// Linking again ("Reconnect Spotify to use Connect"): drops only the token, then signs in with the new scopes.
    func reconnect(authenticate: @escaping @MainActor (URL) async throws -> URL) async {
        guard !isDemo else { return }
        await spotify.reconnect(authenticate: authenticate)
        scopeDeniedFor = nil
        await refreshDevices()
    }

    private func markScopeDenied() {
        Task {
            scopeDeniedFor = .some(await spotify.session.grantedScope())
            set(\.availability, .needsReconnect)
        }
    }

    /// Assigns only when the value changes (perf rule: no observable write for nothing).
    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<SpotifyConnectController, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    // MARK: Starting a session

    /// Plays PixlAudio's queue on `device`, from the current entry and position.
    func connect(to device: SpotifyConnectDevice) {
        guard availability == .ready, connectingDeviceId == nil, let deviceId = device.deviceId else { return }
        guard device.isControllable else {
            toast.show(SpotifyConnectError.deviceRestricted.userMessage)
            return
        }
        guard active?.id != deviceId else { return }
        guard playback.hasItem else {
            toast.show("Play something first, then choose a device")
            return
        }
        if isDemo {
            demoConnect(device)
            return
        }
        connectingDeviceId = deviceId
        connectTask = Task { [weak self] in
            await self?.performConnect(device, deviceId: deviceId)
            self?.connectingDeviceId = nil
        }
    }

    private func performConnect(_ device: SpotifyConnectDevice, deviceId: String) async {
        let start = playback.currentIndex ?? 0
        let position = playback.positionMs()
        rebuildSlots()
        do {
            try await resolveAhead(from: start)
        } catch {
            return
        }
        let window = SpotifyConnectWindow.make(slots: slots, from: start)
        guard let first = window.queueIndices.first else {
            toast.show(start < slots.count && slots[start...].allSatisfy({ $0 == .skipped })
                       ? "None of these songs are on Spotify" : "Couldn't find these songs on Spotify")
            return
        }
        let startPosition = first == start ? position : 0
        do {
            try await client.start(deviceId: deviceId, isActive: device.isActive, uris: window.uris, positionMs: startPosition)
        } catch is CancellationError {
            return
        } catch {
            report(error)
            return
        }
        let nowMs = now()
        let duration = playback.queue.indices.contains(first) ? playback.queue[first].duration : 0
        var state = SpotifyConnectSessionState(deviceId: deviceId, deviceName: device.name, deviceType: device.type,
                                               window: window, anchorMs: nowMs, volumePercent: device.volumePercent,
                                               supportsVolume: device.supportsVolume)
        SpotifyConnectReducer.sent(window, positionMs: startPosition, durationMs: duration,
                                   hasMore: SpotifyConnectWindow.hasMore(after: window, slots: slots), to: &state,
                                   nowMs: nowMs, grace: SpotifyConnectReducer.startGraceMs)
        let wasRemote = session != nil
        session = state
        sentSongIds = slotSongIds
        sessionGeneration += 1
        networkFailures = 0
        extendAtNextTrack = false
        resetVolumeLane()
        set(\.active, ActiveDevice(id: deviceId, name: device.name, type: device.type, supportsVolume: device.supportsVolume))
        set(\.volumePercent, device.volumePercent)
        // Before `attachRemote`: its `engine.pause()` must already see the volume buttons' hold on the audio session.
        updateVolumeButtons()
        playback.attachRemote(self, name: device.name, isPlaying: true)
        if first != playback.currentIndex { playback.remoteMoved(toQueueIndex: first) }
        if !wasRemote { onSessionChanged?(true) }
        onRemoteStateChanged?()
        // PixlAudio's queue is the order: Spotify's own shuffle stays off; repeat-one maps to `track`.
        lastRepeatSent = nil
        let shuffleOff = deviceId
        enqueue { [client = self.client] in try? await client.setShuffle(deviceId: shuffleOff, enabled: false) }
        remoteRepeatModeChanged(playback.repeatMode)
        startPolling()
        startBackgroundResolve(from: first, toastFrom: start)
        markDeviceActive(deviceId)
    }

    private func markDeviceActive(_ deviceId: String) {
        let updated = devices.map { device -> SpotifyConnectDevice in
            var copy = device
            copy.isActive = device.deviceId == deviceId
            return copy
        }
        set(\.devices, SpotifyConnectDevice.sortedForDisplay(updated))
    }

    // MARK: Resolution

    /// Rebuilds `slots` for the current queue from what is known (direct ids, earlier answers); entries not known
    /// yet are `.pending`.
    private func rebuildSlots() {
        let songs = playback.queue
        let ids = songs.map(\.id)
        if ids == slotSongIds { return }
        slotSongIds = ids
        slots = songs.map { song in
            if let known = resolvedBySongId[song.id] { return known }
            if let direct = SpotifyConnect.directURI(spotifyId: song.spotifyId) { return .uri(direct) }
            return .pending
        }
    }

    private func setSlot(_ slot: SpotifyConnectSlot, at index: Int) {
        guard slots.indices.contains(index) else { return }
        slots[index] = slot
        if slot != .pending { resolvedBySongId[slotSongIds[index]] = slot }
    }

    /// Resolves one queue entry (cache first, then search); `.pending` when the lookup failed.
    private func resolve(index: Int) async throws -> SpotifyConnectSlot {
        guard slots.indices.contains(index) else { return .skipped }
        if slots[index] != .pending { return slots[index] }
        // The queue changed since the slots were built: the resync that follows rebuilds them.
        guard let queued = playback.queue[safe: index], queued.id == slotSongIds[index] else { return .pending }
        let song = SpotifyConnectPlatform.song(queued)
        let slot = try await resolver.resolve(song)
        // The queue may have changed while the search ran.
        if slotSongIds.indices.contains(index), slotSongIds[index] == song.key { setSlot(slot, at: index) }
        return slot
    }

    /// Resolves from `start` until it holds the first playable entry plus `eagerLookahead` more (or the lookup budget
    /// is spent): enough to start without waiting for the whole queue.
    private func resolveAhead(from start: Int) async throws {
        var found = 0
        var lookups = 0
        var index = start
        while index < slots.count, found <= Self.eagerLookahead, lookups < Self.eagerLookupBudget {
            if slots[index] == .pending {
                lookups += 1
                _ = try await resolve(index: index)
            }
            switch slots[index] {
            case .uri: found += 1
            case .skipped: break
            case .pending: return // a failed lookup: order must hold, stop here
            }
            index += 1
        }
        try Task.checkCancellation()
    }

    /// Resolves the rest of the window in the background, then shows the "N songs … skipped" toast once.
    private func startBackgroundResolve(from first: Int, toastFrom start: Int) {
        resolveTask?.cancel()
        let generation = sessionGeneration
        resolveTask = Task { [weak self] in
            guard let self else { return }
            var index = first
            var uris = 0
            let end = min(self.slots.count, first + Self.backgroundScanLimit)
            while index < end, uris < SpotifyConnect.maxURIsPerPlay, !Task.isCancelled, generation == self.sessionGeneration {
                let slot: SpotifyConnectSlot
                do { slot = try await self.resolve(index: index) } catch { break }
                if slot == .pending { break }
                if case .uri = slot { uris += 1 }
                index += 1
            }
            await self.resolver.flush()
            guard !Task.isCancelled, generation == self.sessionGeneration, var state = self.session else { return }
            let skipped = SpotifyConnectWindow.skippedCount(slots: self.slots, in: start..<index)
            if let message = SpotifyConnectWindow.skippedMessage(skipped) { self.toast.show(message) }
            // A longer window is now possible: send it when the next track starts (no audible jump mid-song).
            if let current = state.queueIndex {
                let longer = SpotifyConnectWindow.make(slots: self.slots, from: current)
                if longer.count > state.window.count - state.windowPosition { self.extendAtNextTrack = true }
            }
            state.hasMoreAfterWindow = SpotifyConnectWindow.hasMore(after: state.window, slots: self.slots)
            self.session = state
        }
    }

    // MARK: Polling

    private func startPolling() {
        pollTask?.cancel()
        let generation = sessionGeneration
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, generation == self.sessionGeneration, self.session != nil else { return }
                let gate = await self.client.retryAfterRemainingMs
                let interval = max(self.isForeground ? Self.foregroundPollMs : Self.backgroundPollMs, gate)
                try? await Task.sleep(for: .milliseconds(interval))
                guard !Task.isCancelled, generation == self.sessionGeneration else { return }
                await self.pollOnce()
            }
        }
    }

    private func pollOnce() async {
        guard session != nil else { return }
        let polled: SpotifyPlaybackState?
        do {
            polled = try await client.playbackState()
            networkFailures = 0
        } catch is CancellationError {
            return
        } catch let error as SpotifyConnectError {
            switch error {
            case .rateLimited:
                return
            case .network, .unavailable, .failed:
                networkFailures += 1
                if networkFailures >= Self.maxNetworkFailures { endSession(message: "Lost the connection to Spotify") }
                return
            default:
                endSession(message: error.userMessage)
                if error == .missingScope { markScopeDenied() }
                return
            }
        } catch {
            return
        }
        guard var state = session else { return }
        let outcome = SpotifyConnectReducer.apply(polled, to: &state, nowMs: now())
        session = state
        switch outcome.change {
        case .none:
            break
        case .updated:
            publish(state)
        case .trackChanged(let index):
            playback.remoteMoved(toQueueIndex: index)
            publish(state)
            if extendAtNextTrack {
                extendAtNextTrack = false
                resendFromCurrent()
                return
            }
        case .takenOver(let reason):
            endSession(message: reason.message(deviceName: state.deviceName))
            return
        case .reachedEnd:
            reachedEnd()
            return
        }
        if outcome.needsNextWindow { resendFromCurrent() }
    }

    /// Pushes the remote state to the store, the active device and Now Playing (only on a reducer change).
    private func publish(_ state: SpotifyConnectSessionState) {
        playback.remotePlayingChanged(state.isPlaying)
        // The reducer keeps the local volume during the hold, so this never undoes a press.
        set(\.volumePercent, state.volumePercent)
        if var device = active, device.supportsVolume != state.supportsVolume {
            device.supportsVolume = state.supportsVolume
            active = device
            updateVolumeButtons()
        }
        onRemoteStateChanged?()
    }

    /// The device finished PixlAudio's last entry: repeat-all starts over, else the device is paused (its own
    /// autoplay would play something else) and the player shows the last song, paused.
    private func reachedEnd() {
        guard var state = session else { return }
        if playback.repeatMode == .all, let first = SpotifyConnectReducer.firstPlayable(slots, after: -1) {
            send(fromQueueIndex: first)
            return
        }
        SpotifyConnectReducer.setPlaying(false, &state, nowMs: now())
        state.progressMs = 0
        session = state
        publish(state)
        let deviceId = state.deviceId
        enqueue { [client = self.client] in try await client.pause(deviceId: deviceId) }
    }

    // MARK: Sending windows

    /// Sends the window starting at the entry the device plays, keeping its position (queue edits, window extension).
    /// The session is the truth for that entry: the store's index follows `remoteMoved` a main-actor turn later.
    private func resendFromCurrent() {
        guard let state = session else { return }
        rebuildSlots()
        let playingId = state.queueIndex.flatMap { sentSongIds[safe: $0] }
        let current: Int?
        if let index = state.queueIndex, let playingId, slotSongIds[safe: index] == playingId {
            current = index // the queue didn't move under it
        } else {
            current = playback.currentIndex // an edit: the store already holds the new order
        }
        guard let current else { return }
        send(fromQueueIndex: current, keepPosition: playback.queue[safe: current]?.id == playingId)
    }

    /// `PUT play` with the window from `index` (resolving what it needs first), at the device's current position
    /// when `keepPosition` (read when the request goes out), else from the start.
    private func send(fromQueueIndex index: Int, keepPosition: Bool = false) {
        guard session != nil else { return }
        let generation = sessionGeneration
        enqueue { [weak self] in
            guard let self, generation == self.sessionGeneration, let deviceId = self.session?.deviceId else { return }
            self.rebuildSlots()
            try await self.resolveAhead(from: index)
            let window = SpotifyConnectWindow.make(slots: self.slots, from: index)
            guard let first = window.queueIndices.first else {
                self.toast.show("This song isn't on Spotify")
                return
            }
            let position = keepPosition && first == index ? (self.session?.positionMs(at: self.now()) ?? 0) : 0
            try await self.client.play(deviceId: deviceId, uris: window.uris, positionMs: position)
            guard generation == self.sessionGeneration, var state = self.session else { return }
            let duration = self.playback.queue[safe: first]?.duration ?? 0
            SpotifyConnectReducer.sent(window, positionMs: position, durationMs: duration,
                                       hasMore: SpotifyConnectWindow.hasMore(after: window, slots: self.slots),
                                       to: &state, nowMs: self.now())
            self.session = state
            self.sentSongIds = self.slotSongIds
            self.playback.remoteMoved(toQueueIndex: first)
            self.publish(state)
            if window.count < SpotifyConnect.maxURIsPerPlay,
               SpotifyConnectWindow.hasMore(after: window, slots: self.slots) {
                self.startBackgroundResolve(from: first, toastFrom: first)
            }
        }
    }

    /// Runs commands one after another (the Web API doesn't order concurrent player calls); failures become toasts.
    private func enqueue(_ work: @escaping @MainActor () async throws -> Void) {
        let previous = commandTask
        commandTask = Task { [weak self] in
            _ = await previous?.value
            do {
                try await work()
            } catch is CancellationError {
            } catch {
                self?.report(error)
            }
        }
    }

    /// A failed call: a toast; the errors that make the session impossible end it.
    private func report(_ error: any Error) {
        guard let error = error as? SpotifyConnectError else {
            toast.show(SpotifyConnectError.network(String(describing: error)).userMessage)
            return
        }
        switch error {
        case .missingScope:
            markScopeDenied()
            if session != nil { endSession(message: error.userMessage) } else { toast.show(error.userMessage) }
        case .notSignedIn, .premiumRequired, .noActiveDevice, .deviceRestricted:
            if session != nil { endSession(message: error.userMessage) } else { toast.show(error.userMessage) }
        default:
            toast.show(error.userMessage)
        }
    }

    // MARK: RemotePlaybackOutput

    var remoteIsPlaying: Bool { session?.isPlaying ?? false }

    func remotePositionMs() -> Int64 {
        if isDemo { return demoPositionMs() }
        return session?.positionMs(at: now()) ?? 0
    }

    func remoteDurationMs() -> Int64 { session?.durationMs ?? 0 }

    func remotePlay() {
        guard var state = session else { return }
        if isDemo { demoSetPlaying(true); return }
        SpotifyConnectReducer.setPlaying(true, &state, nowMs: now())
        session = state
        publish(state)
        let deviceId = state.deviceId
        enqueue { [client = self.client] in try await client.resume(deviceId: deviceId) }
    }

    func remotePause() {
        guard var state = session else { return }
        if isDemo { demoSetPlaying(false); return }
        SpotifyConnectReducer.setPlaying(false, &state, nowMs: now())
        session = state
        publish(state)
        let deviceId = state.deviceId
        enqueue { [client = self.client] in try await client.pause(deviceId: deviceId) }
    }

    func remoteSeek(toMs positionMs: Int64) {
        guard var state = session, !isDemo else { return }
        SpotifyConnectReducer.seek(to: positionMs, &state, nowMs: now())
        session = state
        onRemoteStateChanged?()
        let deviceId = state.deviceId
        enqueue { [client = self.client] in try await client.seek(deviceId: deviceId, positionMs: positionMs) }
    }

    func remoteSkipToNext() {
        guard var state = session, !isDemo else { return }
        rebuildSlots()
        switch SpotifyConnectReducer.next(state: state, slots: slots, repeatAll: playback.repeatMode == .all) {
        case .next:
            let nextIndex = state.window.queueIndices[state.windowPosition + 1]
            SpotifyConnectReducer.advance(&state, durationMs: playback.queue[safe: nextIndex]?.duration ?? 0, nowMs: now())
            session = state
            playback.remoteMoved(toQueueIndex: nextIndex)
            publish(state)
            let deviceId = state.deviceId
            enqueue { [client = self.client] in try await client.next(deviceId: deviceId) }
        case .play(let index):
            send(fromQueueIndex: index)
        case .restart:
            remoteSeek(toMs: 0)
        case .none:
            break
        }
    }

    func remoteSkipToPrevious() {
        guard let state = session, !isDemo else { return }
        rebuildSlots()
        switch SpotifyConnectReducer.previous(state: state, slots: slots, nowMs: now()) {
        case .play(let index):
            sendPrevious(from: index)
        case .restart:
            remoteSeek(toMs: 0)
        case .next, .none:
            break
        }
    }

    /// The previous entry that is on Spotify, resolving backwards as needed.
    private func sendPrevious(from index: Int) {
        let generation = sessionGeneration
        enqueue { [weak self] in
            guard let self, generation == self.sessionGeneration else { return }
            var candidate = index
            while candidate >= 0 {
                if case .uri = try await self.resolve(index: candidate) { break }
                candidate -= 1
            }
            if candidate < 0 {
                self.remoteSeek(toMs: 0)
            } else {
                self.send(fromQueueIndex: candidate)
            }
        }
    }

    func remoteSkip(toQueueIndex index: Int) {
        guard session != nil, !isDemo else {
            if isDemo { playback.remoteMoved(toQueueIndex: index) }
            return
        }
        send(fromQueueIndex: index)
    }

    func remoteRepeatModeChanged(_ mode: RepeatMode) {
        guard let state = session, !isDemo else { return }
        let remote = SpotifyConnectReducer.remoteRepeat(repeatOne: mode == .one)
        guard remote != lastRepeatSent else { return }
        lastRepeatSent = remote
        let deviceId = state.deviceId
        enqueue { [client = self.client] in try await client.setRepeat(deviceId: deviceId, state: remote) }
    }

    /// Queue edits, shuffle, a new queue: coalesced, then re-sent when what the device will play changed.
    func remoteQueueChanged() {
        guard session != nil, !isDemo else { return }
        resyncTask?.cancel()
        resyncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.resync()
        }
    }

    private func resync() {
        guard var state = session, let current = playback.currentIndex else { return }
        let playingSongId = state.queueIndex.flatMap { sentSongIds.indices.contains($0) ? sentSongIds[$0] : nil }
        rebuildSlots()
        let candidate = SpotifyConnectWindow.make(slots: slots, from: current)
        let remaining = Array(state.window.uris.dropFirst(state.windowPosition))
        // Same song still current and the device's remaining list unchanged (or only extended at the end): just
        // re-index, nothing is sent — no audible jump for "Add to queue". Entries the device already played keep
        // their song's new index (-1 when it left the queue).
        if playbackSongId(at: current) == playingSongId, !remaining.isEmpty,
           candidate.uris.starts(with: remaining) {
            let played = state.window.queueIndices.prefix(state.windowPosition).map { old -> Int in
                guard let id = sentSongIds[safe: old] else { return -1 }
                return slotSongIds.firstIndex(of: id) ?? -1
            }
            state.window = SpotifyConnectWindow(uris: state.window.uris,
                                                queueIndices: played + Array(candidate.queueIndices.prefix(remaining.count)))
            state.hasMoreAfterWindow = SpotifyConnectWindow.hasMore(after: state.window, slots: slots)
            session = state
            sentSongIds = slotSongIds
            return
        }
        resendFromCurrent()
    }

    private func playbackSongId(at index: Int) -> String? { playback.queue[safe: index]?.id }

    // MARK: Volume

    /// The phone's volume buttons: `presses` steps of 5 % (Android `adjustVolume`), with the pop-up.
    func adjustVolume(byPresses presses: Int) {
        guard presses != 0, !isStopping, active?.supportsVolume == true else { return }
        setVolume(SpotifyConnectVolumeKeys.percent(after: presses, from: volumePercent), fromButtons: true)
    }

    /// The buttons can't go further without setting the phone's volume back (that didn't work on this phone): the
    /// slider in Devices still can.
    func volumeButtonsReachedEnd() {
        guard let name = active?.name else { return }
        toast.show("Use the slider in Devices to change \(name)'s volume further")
    }

    /// The device volume (only when the device supports it): shown at once and held against polls, then sent through
    /// the volume lane — the first change at once, then at most one request every 300 ms with the latest value, one
    /// at a time, quietly waiting out a 429.
    func setVolume(_ percent: Int, fromButtons: Bool = false) {
        guard let device = active, device.supportsVolume else { return }
        let clamped = min(max(percent, 0), 100)
        let changed = volumePercent != clamped
        set(\.volumePercent, clamped)
        if var state = session {
            SpotifyConnectReducer.setVolume(clamped, &state, nowMs: now())
            session = state
        }
        if fromButtons { volumeHUD.show(percent: clamped, deviceName: device.name) }
        guard !isDemo, changed || !volumeLane.isIdle else { return }
        volumeLane.enqueue(clamped)
        pumpVolumeLane()
    }

    /// Runs the lane until it has nothing left to send. One task at a time; a newer value joins it.
    private func pumpVolumeLane() {
        guard volumeTask == nil else { return }
        let generation = sessionGeneration
        volumeTask = Task { [weak self] in
            while true {
                guard !Task.isCancelled, let self else { return }
                guard generation == self.sessionGeneration, let deviceId = self.session?.deviceId else {
                    self.volumeTask = nil
                    return
                }
                // A gate a poll or a command hit: wait it out instead of failing fast.
                let gate = await self.client.retryAfterRemainingMs
                guard !Task.isCancelled else { return }
                // Only a change still waiting is held up (after the last send, the poller's gate is its own).
                if gate > 0, self.volumeLane.pending != nil {
                    self.volumeLane.gate(untilMs: self.now() + gate)
                    self.volumeBusy(waitMs: gate)
                }
                switch self.volumeLane.next(nowMs: self.now()) {
                case .idle:
                    self.volumeTask = nil
                    return
                case .wait(let ms):
                    try? await Task.sleep(for: .milliseconds(ms))
                case .send(let percent):
                    var failure: (any Error)?
                    do {
                        try await self.client.setVolume(deviceId: deviceId, percent: percent)
                    } catch {
                        failure = error
                    }
                    // Cancelled: the lane was reset (a new session, the session ended) and isn't this task's any
                    // more. Neither the answer nor a cancelled request's error (URLSession reports it as a network
                    // failure) may touch it or show a toast.
                    guard !Task.isCancelled else { return }
                    guard let failure else {
                        self.volumeLane.completed()
                        if generation == self.sessionGeneration, var state = self.session {
                            SpotifyConnectReducer.volumeSent(&state, nowMs: self.now(), settleMs: Self.volumeSettleMs)
                            self.session = state
                        }
                        continue
                    }
                    if failure is CancellationError {
                        // Not this task's cancellation (checked above): drop the value and free the lane, or every
                        // later change would wait for a task that has ended.
                        self.volumeLane.failed()
                        self.volumeTask = nil
                        return
                    }
                    switch failure as? SpotifyConnectError {
                    case .rateLimited(let ms)?:
                        self.volumeLane.rateLimited(retryAfterMs: ms, nowMs: self.now())
                        self.volumeBusy(waitMs: ms)
                    case .volumeNotSupported?:
                        self.volumeLane.failed()
                        self.volumeNotSupported()
                    default:
                        self.volumeLane.failed()
                        self.report(failure)
                    }
                }
            }
        }
    }

    /// One toast per Retry-After gate, and only for a wait that can be felt; the value is sent when it opens.
    private func volumeBusy(waitMs: Int64) {
        let nowMs = now()
        guard waitMs >= 3000, nowMs >= volumeBusyToastUntilMs else { return }
        volumeBusyToastUntilMs = nowMs + waitMs
        toast.show("Spotify is busy. The volume changes in \(max(1, (waitMs + 999) / 1000)) s")
    }

    /// The device refused a volume command (`VOLUME_CONTROL_DISALLOW`): no more slider or buttons for it.
    private func volumeNotSupported() {
        if var device = active, device.supportsVolume {
            device.supportsVolume = false
            active = device
            toast.show(SpotifyConnectError.volumeNotSupported.userMessage)
        }
        // Sticky for the session: later polls and device lists keep reporting `supports_volume`.
        if var state = session { SpotifyConnectReducer.refuseVolume(&state); session = state }
        volumeHUD.hide()
        updateVolumeButtons()
    }

    private func resetVolumeLane() {
        volumeTask?.cancel()
        volumeTask = nil
        volumeLane = SpotifyConnectVolumeLane()
        volumeBusyToastUntilMs = 0
    }

    /// The volume buttons listen while a device that takes them plays (`ActiveDevice.takesVolumeButtons`).
    private func updateVolumeButtons(handingOverToLocalPlayback: Bool = false) {
        volumeButtons?.setWanted(active?.takesVolumeButtons ?? false,
                                 handingOverToLocalPlayback: handingOverToLocalPlayback)
    }

    // MARK: Ending a session

    /// "Stop playing on <device>": read where the device is, pause it, and carry on on this phone from there.
    func disconnect() {
        guard let state = session, !isStopping else { return }
        if isDemo {
            endSession(message: nil)
            return
        }
        let generation = sessionGeneration
        isStopping = true
        stopTasks()
        Task { [weak self, client = self.client] in
            var index = state.queueIndex
            var position = state.positionMs(at: currentTimeMillis())
            var playing = state.isPlaying
            if let remote = try? await client.playbackState(), remote.device?.deviceId == state.deviceId,
               let uri = remote.itemURI, let at = state.window.position(of: uri, near: state.windowPosition) {
                index = state.window.queueIndices[at]
                position = remote.progressMs ?? position
                playing = remote.isPlaying
            }
            try? await client.pause(deviceId: state.deviceId)
            guard let self else { return }
            self.isStopping = false
            guard generation == self.sessionGeneration else { return }
            self.finish(index: index, positionMs: position, playLocally: playing, message: nil)
        }
    }

    /// Ends the session without touching the device (taken over, signed out, lost): this phone stays paused on the
    /// last known song and position.
    private func endSession(message: String?) {
        guard let state = session else { return }
        stopTasks()
        finish(index: state.queueIndex, positionMs: isDemo ? demoPositionMs() : state.positionMs(at: now()),
               playLocally: false, message: message)
    }

    private func finish(index: Int?, positionMs: Int64, playLocally: Bool, message: String?) {
        session = nil
        sessionGeneration += 1
        set(\.active, nil)
        set(\.volumePercent, nil)
        volumeHUD.hide()
        playback.resumeLocally(atQueueIndex: index.flatMap { $0 >= 0 ? $0 : nil }, positionMs: positionMs, play: playLocally)
        // After `resumeLocally`: playing here again keeps the audio session instead of giving it back and taking it
        // again (which would tell other apps to resume, then stop them).
        updateVolumeButtons(handingOverToLocalPlayback: playLocally)
        onSessionChanged?(false)
        onRemoteStateChanged?()
        if let message { toast.show(message) }
        Task { await refreshDevices() }
    }

    private func stopTasks() {
        pollTask?.cancel()
        resolveTask?.cancel()
        resyncTask?.cancel()
        commandTask?.cancel()
        connectTask?.cancel()
        pollTask = nil
        resolveTask = nil
        resyncTask = nil
        commandTask = nil
        resetVolumeLane()
    }

    // MARK: Lifecycle

    private func observeLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                                     queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.isForeground = false }
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                                                     queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isForeground = true
                // Catch up at once (the device kept playing while iOS suspended the app).
                if self.session != nil { self.startPolling(); Task { await self.pollOnce() } }
            }
        })
    }

    // MARK: Demo (UI tests: fake devices, no network)

    private func applyDemo(_ screen: DemoScreen?) {
        availability = screen == .devicesSpotifyReconnect ? .needsReconnect : .ready
        hasLoadedDevices = true
        devices = screen == .devicesSpotifyEmpty ? [] : SpotifyConnectDevice.sortedForDisplay(Self.demoDevices)
    }

    static let demoDevices: [SpotifyConnectDevice] = [
        SpotifyConnectDevice(deviceId: "demo-echo", name: "Kitchen Echo Show", type: "Speaker", volumePercent: 45, supportsVolume: true),
        SpotifyConnectDevice(deviceId: "demo-tv", name: "Living Room TV", type: "TV", volumePercent: 30, supportsVolume: true),
        SpotifyConnectDevice(deviceId: "demo-mac", name: "Studio Desktop", type: "Computer", isActive: true, volumePercent: 80, supportsVolume: true),
        SpotifyConnectDevice(deviceId: "demo-avr", name: "Den Receiver", type: "AVR", supportsVolume: false),
        SpotifyConnectDevice(deviceId: "demo-car", name: "Car", type: "Automobile", isRestricted: true),
    ]

    /// Demo: starts a session on the Echo (the "playing on" screenshots); the volume pop-up screens show it after
    /// one press up, pinned so the screenshot doesn't race its hide.
    func startDemoSessionIfNeeded(_ screen: DemoScreen?) {
        guard isDemo, let screen, screen.startsSpotifyConnectSession, let echo = Self.demoDevices.first else { return }
        demoConnect(echo)
        if screen.showsSpotifyVolumeHUD {
            let percent = SpotifyConnectVolumeKeys.percent(after: 1, from: echo.volumePercent)
            setVolume(percent)
            volumeHUD.show(percent: percent, deviceName: echo.name, pinned: true)
        }
    }

    private func demoConnect(_ device: SpotifyConnectDevice) {
        guard let deviceId = device.deviceId else { return }
        let index = playback.currentIndex ?? 0
        let window = SpotifyConnectWindow(uris: ["spotify:track:demo"], queueIndices: [index])
        session = SpotifyConnectSessionState(deviceId: deviceId, deviceName: device.name, deviceType: device.type, window: window,
                                             isPlaying: true, progressMs: 42_000, anchorMs: now(),
                                             durationMs: playback.queue[safe: index]?.duration ?? 0,
                                             volumePercent: device.volumePercent, supportsVolume: device.supportsVolume)
        demoAnchor = (42_000, Date())
        active = ActiveDevice(id: deviceId, name: device.name, type: device.type, supportsVolume: device.supportsVolume)
        volumePercent = device.volumePercent
        playback.attachRemote(self, name: device.name, isPlaying: true)
        markDeviceActive(deviceId)
    }

    private func demoPositionMs() -> Int64 {
        guard let state = session else { return 0 }
        guard state.isPlaying else { return demoAnchor.positionMs }
        return demoAnchor.positionMs + Int64(Date().timeIntervalSince(demoAnchor.at) * 1000)
    }

    private func demoSetPlaying(_ playing: Bool) {
        guard var state = session else { return }
        demoAnchor = (demoPositionMs(), Date())
        state.isPlaying = playing
        session = state
        playback.remotePlayingChanged(playing)
    }
}

private extension Array {
    /// The element at `index`, or nil out of range.
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
