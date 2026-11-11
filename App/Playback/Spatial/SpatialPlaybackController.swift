import AVFoundation
import Foundation
import Observation
import PixlAudioCore
import PixlLyrics
import PixlModel

/// What the deck factory asks Spatial audio while it builds an item for the song's own audio (never for Sing's).
@MainActor
protocol DeckSpatialSource: AnyObject {
    /// Returns once the on-device stage's tables are in the taps' parameters (or could not be read). They load once
    /// per launch, from the moment the app is assembled, so this rarely waits.
    func tablesReady() async
    /// Spec 6.3: the verified local render the song of `videoId` starts on instead of its own audio, or nil.
    /// `spotifyId`: the song's Spotify track; a song Spatial audio is turned off for (`spatial.songsOff`) never starts
    /// on a render.
    func startRendition(videoId: String, spotifyId: String?) async -> LocalRendition?
}

/// The player's side of Spatial audio (cloud audio spec of 2026-11-10, sections 6.1, 6.3 and 7; integration map
/// sections 2-6): it drives the on-device stage in every tap, decides which audio a song starts on, switches to a
/// render that lands while its song plays (and back), follows the route and Sing, and reports what is heard.
///
/// - The stage: one global target for every tap (`AudioEffectsParameters.spatial`), the selected profile while Spatial
///   audio is active (a profile, the route rule passing, Sing's instrumental not playing), else bypass. Taps ramp to it
///   over about 80 ms. Whether an item may run the stage at all is decided when it is built (`DeckItem.audio`): the
///   song's own audio only, never a render, never Sing's audio.
/// - The start of a song: `DeckItemFactory` asks `startRendition`; a verified local render plays instead of the stream.
/// - A render that lands mid-song (`SpatialLibraryEvent.renditionReady`), a profile change, Spatial audio off or the
///   route failing: `SpatialRenditionRules` decides, `DualDeckEngine.switchCurrentRendition` switches (Sing's swap with
///   a 250 ms linear fade, lined up by media time, at a quiet moment of the lyrics when they are loaded).
/// - It never asks the library for a render: the Spatial audio model does that from the snapshots published here.
/// - Off for one song (`spatial.songsOff`, Hoa, 2026-11-11): every decision above is made with that song's own
///   selection (`CloudAudioSettings.selection(for:)`), `off` for a song turned off. It starts on its own audio, the
///   stage bypasses it, and a render it plays when it is turned off goes back to its own audio by the same switch as
///   Spatial audio turned off.
@MainActor
final class SpatialPlaybackController: SpatialPlayback, DeckSpatialSource {
    /// What the controller follows outside the engine, read through observation.
    struct Inputs {
        /// Another device plays the music itself (Spotify Connect).
        var remoteDevicePlays: @MainActor () -> Bool
        /// Sing's instrumental plays (`on`), and Sing is in the middle of a switch of its own.
        var sing: @MainActor () -> (on: Bool, switching: Bool)
        /// A song's quiet moments from its word-timed lyrics (nil when they are not loaded) and the lyrics' offset.
        var gaps: @MainActor (_ songId: String) -> (index: SingGapIndex?, offsetMs: Int64)
    }

    /// How often a switch that has to wait (a seek, a transition, Sing) is asked again, one second apart.
    static let maxRetries = 30

    private let engine: DualDeckEngine
    private let library: any SpatialLibrary
    private let inputs: Inputs
    private let hub = SpatialEventHub<SpatialPlaybackSnapshot>()

    /// The settings in force (`apply`).
    private(set) var settings: CloudAudioSettings
    /// The session's output port.
    private var port: AVAudioSession.Port?
    private var remote = false
    private var singOn = false
    private var singSwitching = false
    /// What was last reported.
    private(set) var current = SpatialPlaybackSnapshot.idle

    private var tables: Task<Void, Never>?
    private var listener: Task<Void, Never>?
    private var pendingEvaluation: Task<Void, Never>?
    private var switching: Task<Void, Never>?
    /// Something changed while a lookup or a switch was under way: look again when it ends.
    private var reconcileAgain = false
    private var retry: Task<Void, Never>?
    private var retries = 0
    /// The item the retries and given-up switches count for.
    private var attemptsItem: ObjectIdentifier?
    /// Switches that failed for the current item: the next play uses the render instead.
    private var givenUp: Set<SpatialRenditionRules.Action> = []
    /// The render item last reported to the library as played.
    private var playedItem: ObjectIdentifier?
    /// The video of the current queue entry, kept while Sing's audio (which has none) plays.
    private var lastVideo: (entry: Int, videoId: String)?

    init(engine: DualDeckEngine, library: any SpatialLibrary, settings: CloudAudioSettings, inputs: Inputs) {
        self.engine = engine
        self.library = library
        self.settings = settings
        self.inputs = inputs
        port = engine.session.currentOutputPort
        engine.factory.spatial = self
        engine.onSpatialItemChanged = { [weak self] in self?.scheduleEvaluation() }
        engine.session.onRouteChange = { [weak self] in self?.routeChanged() }
        loadTables()
        observeInputs()
        listenToLibrary()
        publishStageTarget()
        current = makeSnapshot()
    }

    // MARK: SpatialPlayback

    func apply(_ settings: CloudAudioSettings) async {
        let previous = self.settings
        self.settings = settings
        // `songsOff`: the song that plays, or the one prepared next, may have been turned off or back on.
        guard previous.profile != settings.profile || previous.route != settings.route
            || previous.songsOff != settings.songsOff else { return }
        stateChanged(nextMayChange: true)
    }

    func snapshot() async -> SpatialPlaybackSnapshot { current }

    func events() async -> AsyncStream<SpatialPlaybackSnapshot> { hub.stream() }

    // MARK: DeckSpatialSource

    func tablesReady() async {
        await tables?.value
    }

    func startRendition(videoId: String, spotifyId: String?) async -> LocalRendition? {
        // A song turned off for Spatial audio starts on its original (its selection is `off`).
        guard routePasses, let profile = settings.profileFor(spotifyId) else { return nil }
        let render = await library.localRendition(RenditionKey(videoId: videoId, profile: profile))
        // The selection (or the song's own switch) may have moved while the library answered.
        guard let render, render.key == RenditionKey(videoId: videoId, profile: profile),
              SpatialRenditionRules.startsWithRender(selection: settings.selection(for: spotifyId),
                                                     routePasses: routePasses, hasLocalRender: true) else { return nil }
        return render
    }

    // MARK: State

    private var output: SpatialOutputKind { SpatialOutputRoute.kind(of: port, remoteDevicePlays: remote) }
    private var routePasses: Bool { SpatialActivation.routePasses(mode: settings.route, output: output) }
    /// The current queue entry's Spotify track (the item that plays, else the entry that loads): the key of
    /// `spatial.songsOff`.
    private var currentSpotifyId: String? { (engine.activeItem?.entry ?? engine.queue.current)?.song.spotifyId }
    /// The selection the current song plays with: the selected profile, or `off` when Spatial audio is turned off for
    /// that song (Hoa, 2026-11-11).
    private var currentSelection: SpatialSelection { settings.selection(for: currentSpotifyId) }
    /// "Spatial active" (spec 6.3), for the current song: never for a song turned off.
    private var isActive: Bool {
        SpatialActivation.isActive(selection: currentSelection, mode: settings.route, output: output,
                                   singInstrumentalOn: singOn)
    }

    /// Something changed that may change what is heard: the taps' target at once, then the snapshot and the switches.
    /// `nextMayChange`: the item prepared for the next song may have been built for another rendition.
    private func stateChanged(nextMayChange: Bool) {
        publishStageTarget()
        scheduleEvaluation()
        if nextMayChange { replanNextIfStale() }
    }

    /// One atomic store: cheap enough for every evaluation. It follows the current item too, not only the settings: a
    /// song turned off for Spatial audio bypasses the stage while the songs around it keep it.
    private func publishStageTarget() {
        engine.effects.spatial.play(isActive ? currentSelection.profile : nil)
    }

    private func routeChanged() {
        let port = engine.session.currentOutputPort
        guard port != self.port else { return }
        self.port = port
        stateChanged(nextMayChange: true)
    }

    private func observeInputs() {
        let inputs = self.inputs
        let (remote, sing) = withObservationTracking {
            (inputs.remoteDevicePlays(), inputs.sing())
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeInputs() }
        }
        let routeMoved = remote != self.remote
        let changed = routeMoved || sing.on != singOn || sing.switching != singSwitching
        self.remote = remote
        singOn = sing.on
        singSwitching = sing.switching
        if changed { stateChanged(nextMayChange: routeMoved) }
    }

    private func loadTables() {
        let shared = engine.effects.spatial
        tables = Task.detached(priority: .userInitiated) {
            do {
                shared.install(SpatialStageCoefficients(try SpatialPreviewResource.loadNow()))
            } catch {
                DiagnosticsLog.shared.log("spatial", "on-device tables unreadable: \(error)")
            }
        }
    }

    private func listenToLibrary() {
        let library = self.library
        listener = Task { [weak self] in
            let events = await library.events()
            for await event in events {
                guard let self else { return }
                self.libraryEvent(event)
            }
        }
    }

    private func libraryEvent(_ event: SpatialLibraryEvent) {
        switch event {
        case .renditionReady(let rendition):
            let video = rendition.key.videoId
            // Spec 6.3: a render for the song that plays switches in (when the rules allow); one for the next song
            // makes the item prepared for it be built again, so that song starts on it.
            if engine.activeItem?.audio.videoId == video || current.videoId == video { scheduleEvaluation() }
            if engine.preparedIncoming?.audio.videoId == video { replanNextIfStale() }
        case .renditionRemoved(let key):
            // The playing item keeps its open file; an item prepared on a removed render is built again.
            if case .render(let prepared)? = engine.preparedIncoming?.audio, prepared == key { engine.rescheduleNext() }
        case .statusChanged, .usageChanged:
            break
        }
    }

    /// Integration map 4.4: the item prepared for the next song (gapless or crossfade) holds the rendition chosen when
    /// it was built. When that is no longer the one a start would choose, it is built again.
    private func replanNextIfStale() {
        guard let prepared = engine.preparedIncoming else { return }
        // That song's own profile: none for a song turned off, so an item built on a render is built again on its own
        // audio (and one turned back on looks for its render again).
        let wanted = routePasses ? settings.profileFor(prepared.song.spotifyId) : nil
        switch prepared.audio {
        case .render(let key):
            if key.profile != wanted { engine.rescheduleNext() }
        case .own(let videoId?):
            guard let wanted else { return }
            let library = self.library
            Task { [weak self] in
                guard await library.localRendition(RenditionKey(videoId: videoId, profile: wanted)) != nil,
                      let self, self.engine.preparedIncoming === prepared else { return }
                self.engine.rescheduleNext()
            }
        case .own(.none), .other:
            break
        }
    }

    // MARK: Evaluation

    /// Coalesces bursts of changes (an item swap sets the current item more than once) into one evaluation.
    private func scheduleEvaluation() {
        guard pendingEvaluation == nil else { return }
        pendingEvaluation = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            self.pendingEvaluation = nil
            self.evaluate()
        }
    }

    private func evaluate() {
        let item = engine.activeItem
        let id = item.map(ObjectIdentifier.init)
        if id != attemptsItem {
            attemptsItem = id
            retries = 0
            givenUp = []
        }
        publishStageTarget()
        refreshSnapshot()
        notePlayedRender()
        reconcile()
    }

    private func refreshSnapshot() {
        let next = makeSnapshot()
        guard next != current else { return }
        current = next
        hub.send(next)
    }

    /// What is heard now (the snapshot's facts; `blockedBy` and `wantedRender` derive from them).
    private func makeSnapshot() -> SpatialPlaybackSnapshot {
        let item = engine.activeItem
        guard let entry = item?.entry ?? engine.queue.current else {
            return SpatialPlaybackSnapshot(selection: settings.profile, route: settings.route, output: output,
                                           routePasses: routePasses, singInstrumentalOn: singOn, audible: .stereo)
        }
        let spotifyId = entry.song.spotifyId
        var videoId = item?.entry.id == entry.id ? item?.audio.videoId : nil
        if let videoId {
            lastVideo = (entry.id, videoId)
        } else if let lastVideo, lastVideo.entry == entry.id {
            videoId = lastVideo.videoId
        }
        // The song's own profile (`isActive` reads the same entry): a song turned off plays stereo.
        let profile = settings.profileFor(spotifyId)
        let audible: SpatialAudible
        switch item?.audio {
        case .render(let key)?:
            audible = .render(key.profile)
        case .own?:
            // A song at a rate the stage does not take (or mono) plays without it: stereo, its render still wanted.
            let unsupported = item?.tap.spatialFormat.load(ordering: .relaxed) == SpatialItemFormat.unsupported
            if isActive, let profile, !unsupported { audible = .onDevice(profile) } else { audible = .stereo }
        case .other?:
            audible = .stereo
        case nil:
            // Loading: what the start will play, as far as it can be told.
            if isActive, let profile { audible = .onDevice(profile) } else { audible = .stereo }
        }
        return SpatialPlaybackSnapshot(songId: entry.song.id, videoId: videoId, spotifyId: spotifyId,
                                       selection: settings.profile, route: settings.route, output: output,
                                       routePasses: routePasses, singInstrumentalOn: singOn, audible: audible,
                                       songOff: settings.isOffFor(spotifyId))
    }

    /// The library removes the least recently played renders first: tell it when one starts playing.
    private func notePlayedRender() {
        guard let item = engine.activeItem, case .render(let key) = item.audio else { return }
        let id = ObjectIdentifier(item)
        guard playedItem != id else { return }
        playedItem = id
        let library = self.library
        Task { await library.markPlayed(key) }
    }

    // MARK: Switching

    private enum Attempt {
        /// Nothing to do.
        case none
        /// The item changed while the library answered: look again.
        case stale
        /// Something is under way: ask again in a second.
        case wait
        case tried(SpatialRenditionRules.Action, DualDeckEngine.SwitchOutcome)
    }

    private func reconcile() {
        if switching != nil {
            reconcileAgain = true
            return
        }
        guard let item = engine.activeItem else { return }
        reconcileAgain = false
        let playing = item.audio
        if case .other = playing { return }
        let library = self.library
        // The song's own profile: a song turned off looks up no render.
        let key = settings.profileFor(item.song.spotifyId).flatMap { profile in
            playing.videoId.map { RenditionKey(videoId: $0, profile: profile) }
        }
        switching = Task { [weak self] in
            var render: LocalRendition?
            if let key { render = await library.localRendition(key) }
            guard let self else { return }
            let attempt = await self.attempt(item: item, playing: playing, render: render?.key == key ? render : nil)
            self.switching = nil
            self.finished(attempt, item: item)
        }
    }

    private func attempt(item: DeckItem, playing: SpatialItemAudio, render: LocalRendition?) async -> Attempt {
        guard engine.activeItem === item else { return .stale }
        // Spec 6.3 with the song's own selection: `off` for a song turned off, so a render it plays goes back to its
        // own audio (the same in-sync 250 ms crossfade as Spatial audio switched off) and nothing switches in.
        let selection = settings.selection(for: item.song.spotifyId)
        let usable = render?.key.profile == selection.profile ? render : nil
        let situation = SpatialRenditionRules.Situation(
            playing: playing, selection: selection, routePasses: routePasses,
            singBusy: singOn || singSwitching, hasLocalRender: usable != nil,
            secondsLeft: item.durationSeconds - item.positionSeconds,
            transitionInFlight: engine.isRenditionSwitchBlocked)
        let action = SpatialRenditionRules.action(for: situation)
        if givenUp.contains(action) { return .none }
        switch action {
        case .none:
            return .none
        case .wait:
            return .wait
        case .switchToRender:
            guard let usable else { return .none }
            // The 20 s rule is for a render switching in over the song's own audio; a render of another profile
            // replaces the old one whatever is left (the person picked it).
            let minimum = playing.isRender ? 0 : SpatialRenditionRules.minimumSecondsLeft
            let outcome = await engine.switchCurrentRendition(to: .render(usable),
                                                              placement: quietPlacement(songId: item.song.id),
                                                              minimumSecondsLeft: minimum, requireAligned: true)
            return .tried(action, outcome)
        case .switchToOwnAudio:
            let outcome = await engine.switchCurrentRendition(to: .ownAudio, placement: nil, minimumSecondsLeft: 0,
                                                              requireAligned: false)
            return .tried(action, outcome)
        }
    }

    private func finished(_ attempt: Attempt, item: DeckItem) {
        if reconcileAgain {
            reconcileAgain = false
            scheduleEvaluation()
        }
        switch attempt {
        case .none:
            break
        case .stale:
            scheduleEvaluation()
        case .wait:
            scheduleRetry()
        case .tried(let action, let outcome):
            switch outcome {
            case .switched:
                break
            case .abortedBySeek:
                // The playhead moved while the other audio was set up: try again from where it is now.
                scheduleRetry()
            case .failed, .misaligned:
                // Spec 6.3 "otherwise the next play uses it"; a render that does not line up with the song is used
                // from the next play too (integration map 12, open item 5). A way back that failed (too close to the
                // song's end) lets the song finish: the next song starts normally.
                if engine.activeItem === item { givenUp.insert(action) }
            }
            scheduleEvaluation()
        }
    }

    private func scheduleRetry() {
        guard retry == nil, retries < Self.maxRetries else { return }
        retries += 1
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.retry = nil
            self.scheduleEvaluation()
        }
    }

    /// Spec 6.3 "at a quiet moment when the app can tell": the next gap between sung words (Sing's planner, from the
    /// lyrics' word timing, at most 600 ms away), else as soon as the render is ready; the fade is always ~250 ms.
    private func quietPlacement(songId: String) -> DualDeckEngine.SwitchPlacement {
        let inputs = self.inputs
        let engine = self.engine
        return { earliest in
            let gaps = inputs.gaps(songId)
            let placement = SingSwitchPlanner.plan(index: gaps.index, earliestPlayerMs: Int64((earliest * 1000).rounded()),
                                                   offsetMs: gaps.offsetMs, rate: Double(engine.rate))
            return (startSeconds: Double(placement.startPlayerMs) / 1000,
                    fadeSeconds: SpatialRenditionRules.switchFadeSeconds)
        }
    }
}
