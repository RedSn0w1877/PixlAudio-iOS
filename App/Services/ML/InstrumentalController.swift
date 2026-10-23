import Foundation
import Observation
import PixlLyrics
import PixlModel
import PixlNet

/// What the Sing button is doing for the current song.
nonisolated enum SingPhase: Equatable, Sendable {
    /// Nothing under way (the song's own audio plays, or an instrumental waits to be switched to by a tap).
    case idle
    /// The cloud is making the instrumental (`jobKey` is its Cloud Studio job); it switches in when it lands.
    case preparingCloud(jobKey: String)
    /// This phone is making the instrumental; it switches in when it is done.
    case preparingDevice
    /// The instrumental is here and the switch is about to start, or waits (the lyrics editor needs the vocals).
    case readyToSwitch
    /// The instrumental is loaded and waits a moment for a gap between sung words.
    case waitingForGap
    /// The switch is running.
    case switching
    /// The instrumental plays: the vocals are off.
    case on

    /// An instrumental is being made, in the cloud or on this phone.
    var isPreparing: Bool {
        switch self {
        case .preparingCloud, .preparingDevice: true
        default: false
        }
    }

    /// The cloud is making it.
    var isCloud: Bool {
        if case .preparingCloud = self { return true }
        return false
    }
}

/// The person asked for the vocals off while no instrumental existed: the song it is for, since when, and what makes
/// the instrumental. It lives in the controller, not in a view, so it outlives the lyrics screen; a new song or going
/// back to the original ends it.
nonisolated struct SingIntent: Equatable, Sendable {
    nonisolated enum Backend: Equatable, Sendable {
        case cloud(jobKey: String)
        case device
    }

    let songId: String
    let startedAt: Date
    var backend: Backend
}

/// A cloud Sing's progress for the button.
nonisolated struct SingCloudStatus: Equatable, Sendable {
    /// 0…1, how far the segment fills.
    var weight: Double
    /// What the job is doing, in plain words ("Uploading 40%", "Waiting for a GPU", "Separating vocals 55%").
    var text: String
    /// Cellular data is off and the phone is not on Wi-Fi, so a transfer cannot begin.
    var waitingForWiFi: Bool
}

/// What the Sing segment shows for a state of the button: its title, the value VoiceOver and the UI tests read (the
/// accessibility label stays "Sing"), what fills it and whether it carries the microphone or a spinner. Pure, so the
/// words are tested.
nonisolated struct SingButtonFace: Equatable, Sendable {
    var title: String
    var value: String
    /// 0…1, how far the segment fills; nil when nothing can be measured.
    var progress: Double?
    /// A spinner stands in for the icon: the switch is under way.
    var busy = false
    /// The microphone (not while something is being made).
    var showsIcon = false

    /// - Parameters:
    ///   - phase: `InstrumentalController.singPhase`.
    ///   - cloudStatus: the cloud job's progress while a cloud Sing is under way.
    ///   - rendering: this phone is rendering the song's instrumental (a tap's, or the automatic studio's).
    ///   - renderPercent: how far that render is; nil while it has no percentage yet.
    ///   - active: the instrumental plays.
    static func make(phase: SingPhase, cloudStatus: SingCloudStatus?, rendering: Bool, renderPercent: Int?,
                     active: Bool) -> SingButtonFace {
        if phase.isCloud {
            guard let cloudStatus else { return SingButtonFace(title: "Preparing…", value: "Preparing in the cloud") }
            if cloudStatus.waitingForWiFi {
                return SingButtonFace(title: "Waiting for Wi-Fi", value: "Waiting for Wi-Fi", progress: cloudStatus.weight)
            }
            return SingButtonFace(title: "Preparing…", value: "Preparing in the cloud — \(cloudStatus.text)",
                                  progress: cloudStatus.weight)
        }
        switch phase {
        case .waitingForGap:
            return SingButtonFace(title: "Switching…", value: "Waiting for a quiet moment", busy: true)
        case .switching:
            return SingButtonFace(title: "Switching…", value: "Switching", busy: true)
        default:
            break
        }
        if rendering || phase == .preparingDevice {
            guard let renderPercent else { return SingButtonFace(title: "Removing vocals…", value: "Removing vocals") }
            let text = "Removing vocals \(renderPercent) %"
            return SingButtonFace(title: text, value: text, progress: Double(renderPercent) / 100)
        }
        if active { return SingButtonFace(title: "Vocals off", value: "Vocals off", showsIcon: true) }
        return SingButtonFace(title: "Sing", value: phase == .readyToSwitch ? "Instrumental ready" : "Vocals on",
                              showsIcon: true)
    }
}

/// How a Sing's backing job ended without leaving the instrumental it was for.
nonisolated enum SingJobEnd: Equatable, Sendable {
    /// Failed or expired.
    case failed
    /// Cancelled (in the queue).
    case cancelled
    /// Finished, but no instrumental came of it.
    case empty

    /// nil while the job is still working. Asked only when the song has no instrumental, so `imported` means empty.
    static func end(of state: CloudJobState) -> SingJobEnd? {
        switch state {
        case .failed, .expired: .failed
        case .cancelled: .cancelled
        case .imported: .empty
        case .queued, .preparing, .uploading, .uploaded, .submitted, .running, .resultsReady, .downloading: nil
        }
    }
}

/// Who makes the instrumental when the person taps Sing and the song has none.
enum SingRoute: Equatable {
    /// A cloud job; the instrumental switches in when it lands.
    case cloud
    /// This phone. `reason` says why the cloud was not used, when the person should be told.
    case device(reason: String?)

    static let offReason = "Cloud processing is off — removing vocals on this phone instead."
    static let overCapReason = "This month's cloud budget is used up — removing vocals on this phone instead."

    /// The fallback table: cloud first, this phone second. A song whose cloud job failed goes to the phone on the next
    /// tap, and a missing cloud (UI tests) means the phone.
    static func decide(_ availability: SingCloudAvailability?, cloudFailedBefore: Bool) -> SingRoute {
        guard !cloudFailedBefore, let availability else { return .device(reason: nil) }
        switch availability {
        case .usable, .alreadyPending: return .cloud
        case .off: return .device(reason: offReason)
        case .notConfigured: return .device(reason: "Cloud processing isn't set up — removing vocals on this phone instead.")
        case .keysMissing:
            return .device(reason: "Cloud processing isn't available right now — removing vocals on this phone instead.")
        case .overCap: return .device(reason: overCapReason)
        case .notOnWiFi: return .device(reason: "Not on Wi-Fi — removing vocals on this phone instead.")
        case .tooLong:
            return .device(reason: "This song is too long for cloud processing — removing vocals on this phone instead.")
        case .nothingToDo: return .device(reason: nil)
        }
    }

    /// Why the phone does it after the cloud refused to start (the answer came back different from the check).
    static func reason(after outcome: CloudStartOutcome) -> String? {
        switch outcome {
        case .off: offReason
        case .overCap: overCapReason
        case .started, .nothingToDo: nil
        }
    }
}

/// The engine as the controller needs it (a stand-in in tests).
@MainActor
protocol InstrumentalSwitching: AnyObject {
    /// The playback speed.
    var rate: Float { get }
    func switchCurrentAudio(to url: URL?, placement: DualDeckEngine.SwitchPlacement?, requireAligned: Bool) async
        -> DualDeckEngine.SwitchOutcome
}

extension DualDeckEngine: InstrumentalSwitching {}

/// The current song's studio instrumental (Android `PlayerViewModel.studioInstrumentalAvailable/Active`,
/// `switchToStudioInstrumental`, `switchToOriginalAudio` + `InstrumentalCrossfadeController`): whether a render exists,
/// whether it is what plays, and the switch — an in-sync crossfade through the engine's idle deck. A new song always
/// starts with its own audio. Owners such as the lyrics tap-sync editor can suspend it to hear the vocals.
///
/// Sing (`requestSing`) is the person's "vocals off" wish for the current song. With an instrumental at hand it switches
/// at once. Without one it asks the cloud for one when the cloud can take the song (the Cloud Studio job lives on in
/// the queue), else this phone renders one; either way the wish is kept here, so it survives closing the lyrics screen,
/// and when the instrumental lands the song is still current the switch is made at the next gap between sung words.
/// Taps while it waits only cancel the waiting.
@MainActor
@Observable
final class InstrumentalController {
    /// A complete render exists for the current song.
    private(set) var isAvailable = false
    /// The instrumental is what plays.
    private(set) var isActive = false
    private(set) var isSwitching = false
    /// What Sing is doing for the current song (the button's state).
    private(set) var singPhase: SingPhase = .idle
    /// The cloud job's progress while a cloud Sing is under way.
    private(set) var cloudStatus: SingCloudStatus?

    @ObservationIgnored private let playback: PlaybackStore
    @ObservationIgnored private let engine: (any InstrumentalSwitching)?
    @ObservationIgnored private weak var studio: TaisStudio?
    /// Cloud Studio, bound after both exist (`AppEnvironment` creates it later).
    @ObservationIgnored weak var cloud: CloudStudio?
    /// Where the lyrics' timing and sync offset come from, and where the button's messages go.
    @ObservationIgnored var lyrics: LyricsController?
    /// The best render for a song (a stand-in in tests).
    @ObservationIgnored var instrumentalURL: (String) -> URL? = { InstrumentalFiles.bestAvailable(songId: $0) }
    @ObservationIgnored private var songId: String?
    @ObservationIgnored private var suspendedBy: Set<String> = []
    @ObservationIgnored private var restoreOnResume = false
    /// UI tests: songs that "have" an instrumental.
    @ObservationIgnored var demoAvailableSongIds: Set<String> = []
    /// UI tests: the phase the button shows.
    @ObservationIgnored private var demoPhase: SingPhase?

    /// The wish, while there is one.
    @ObservationIgnored private var intent: SingIntent?
    /// Where the wish stands once the instrumental is here.
    @ObservationIgnored private var stage = SwitchStage.waiting
    @ObservationIgnored private var isStartingSing = false
    /// Songs whose cloud job failed: the next tap on each goes to this phone.
    @ObservationIgnored private var cloudFailedSongs: Set<String> = []
    /// Only the latest observation chain re-arms itself.
    @ObservationIgnored private var observationEpoch = 0
    @ObservationIgnored private let network = SingNetworkWatcher()

    private enum SwitchStage {
        /// The instrumental has not landed.
        case waiting
        /// It has, and the switch waits (the lyrics editor is open).
        case held
        /// The engine is making the switch.
        case switching
        /// The engine has the instrumental loaded and waits for a gap between sung words.
        case waitingForGap
    }

    /// What the observation reads about the world; `apply` acts on it outside the tracking.
    private struct Snapshot {
        var songId: String?
        var remoteOutput: Bool
        var cloudJob: CloudJobRecord?
        var transfer: Double?
        var deviceJob: TaisStudio.JobState?
    }

    init(playback: PlaybackStore, engine: (any InstrumentalSwitching)?, studio: TaisStudio,
         lyrics: LyricsController? = nil) {
        self.playback = playback
        self.engine = engine
        self.studio = studio
        self.lyrics = lyrics
        observe()
    }

    // MARK: Observing

    /// Re-checks when the song changes, a render lands, or the job behind a Sing moves.
    private func observe() {
        observationEpoch &+= 1
        let epoch = observationEpoch
        let snapshot = withObservationTracking {
            readSnapshot()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observationEpoch == epoch else { return }
                self.observe()
            }
        }
        apply(snapshot)
    }

    /// `apply` again without re-arming the observation (a change the observation cannot see).
    private func reapply() {
        apply(readSnapshot())
    }

    private func readSnapshot() -> Snapshot {
        _ = studio?.instrumentalRevision
        var snapshot = Snapshot(songId: playback.current?.id, remoteOutput: playback.remoteOutputName != nil)
        if let intent {
            switch intent.backend {
            case .cloud(let jobKey):
                snapshot.cloudJob = cloud?.job(jobKey)
                snapshot.transfer = cloud?.transferProgress[jobKey]
            case .device:
                snapshot.deviceJob = studio?.state(.instrumental, songId: intent.songId)
            }
        }
        return snapshot
    }

    private func apply(_ snapshot: Snapshot) {
        if snapshot.songId != songId {
            // A new song always starts with its own audio, and the wish was for the last one.
            songId = snapshot.songId
            isActive = false
            restoreOnResume = false
            endIntent()
        }
        isAvailable = songId.map { demoAvailableSongIds.contains($0) || instrumentalURL($0) != nil } ?? false
        guard let intent else {
            refreshPhase()
            return
        }
        if snapshot.remoteOutput {
            // A Connect speaker plays, so nothing would be heard: the instrumental waits for the next tap.
            endIntent()
            return
        }
        if isAvailable {
            startSwitchIfReady()
            refreshPhase()
            return
        }
        switch intent.backend {
        case .cloud:
            guard let job = snapshot.cloudJob else {
                endIntent()
                return
            }
            updateCloudStatus(job, transfer: snapshot.transfer)
            if let end = SingJobEnd.end(of: job.state) { cloudJobEnded(end, songId: intent.songId) }
        case .device:
            switch snapshot.deviceJob?.phase {
            case .failed(let reason)?:
                say(reason)
                endIntent()
            case .cancelled?, .succeeded?:
                // Succeeded with no file to switch to (or a skip): nothing more is coming.
                endIntent()
            case .queued?, .running?, nil:
                break
            }
        }
        refreshPhase()
    }

    private func refreshPhase() {
        let phase: SingPhase
        if let demoPhase {
            phase = demoPhase
        } else if let intent {
            switch stage {
            case .switching: phase = .switching
            case .waitingForGap: phase = .waitingForGap
            case .held: phase = .readyToSwitch
            case .waiting:
                switch intent.backend {
                case .cloud(let jobKey): phase = .preparingCloud(jobKey: jobKey)
                case .device: phase = .preparingDevice
                }
            }
        } else {
            phase = isActive ? .on : .idle
        }
        if singPhase != phase { singPhase = phase }
    }

    // MARK: Sing

    /// The Sing button. Switch now when the song has an instrumental; otherwise make one (in the cloud when it can,
    /// else on this phone) and switch to it when it lands. A tap while that wait is on stops the waiting only.
    func requestSing(for song: Song) async {
        guard playback.current?.id == song.id, playback.remoteOutputName == nil, !isSwitching, !isStartingSing else { return }
        // A song change this very moment may not have reached the observation yet.
        if song.id != songId { reapply() }
        if intent?.songId == song.id {
            cancelSing()
            return
        }
        if isAvailable {
            toggle()
            return
        }
        // A render already under way on this phone (the automatic studio's, or an earlier tap's) is taken over.
        if let running = studio?.state(.instrumental, songId: song.id), running.isActive {
            beginDevice(song, message: running.detail ?? String(localized: "Removing the vocals…"))
            return
        }
        isStartingSing = true
        defer { isStartingSing = false }
        let failedBefore = cloudFailedSongs.remove(song.id) != nil
        var availability: SingCloudAvailability?
        // UI tests (no engine) never reach the cloud.
        if !failedBefore, engine != nil, let cloud, !cloud.isDemo { availability = await cloud.singAvailability(for: song) }
        guard playback.current?.id == song.id, intent == nil, !isSwitching else { return }
        if isAvailable {
            playInstrumental()
            return
        }
        switch SingRoute.decide(availability, cloudFailedBefore: failedBefore) {
        case .cloud:
            let (jobKey, outcome) = await startCloudSing(song, availability: availability)
            guard playback.current?.id == song.id, intent == nil else { return }
            if let jobKey {
                beginCloud(song, jobKey: jobKey)
            } else {
                beginDevice(song, message: outcome.flatMap(SingRoute.reason(after:)) ?? Self.deviceMessage)
            }
        case .device(let reason):
            beginDevice(song, message: reason ?? Self.deviceMessage)
        }
    }

    /// Stops waiting for the instrumental: the job (cloud or on this phone) carries on and its file is kept for next time.
    func cancelSing() {
        guard intent != nil, stage == .waiting || stage == .held else { return }
        endIntent()
        say(String(localized: "Okay. The instrumental will be ready next time."))
    }

    private static var deviceMessage: String {
        String(localized: "Removing the vocals on this iPhone. The first time takes a few minutes.")
    }

    /// Starts the song's Sing job in the cloud, or joins the one it already has. The key of the job to wait for, or nil
    /// (with the cloud's answer) when it didn't start.
    private func startCloudSing(_ song: Song, availability: SingCloudAvailability?) async -> (String?, CloudStartOutcome?) {
        guard let cloud else { return (nil, nil) }
        let outcome = await cloud.startSing(song: song)
        var jobKey: String?
        if case .alreadyPending(let key)? = availability {
            jobKey = key
        } else if outcome.didStart {
            jobKey = cloud.job(forSong: song.id)?.jobKey
        }
        guard let jobKey, cloud.job(jobKey)?.state.isPending == true else { return (nil, outcome) }
        return (jobKey, outcome)
    }

    private func beginCloud(_ song: Song, jobKey: String) {
        intent = SingIntent(songId: song.id, startedAt: Date(), backend: .cloud(jobKey: jobKey))
        stage = .waiting
        network.onChange = { [weak self] in self?.reapply() }
        network.start()
        if cloud?.settings.useCellular ?? true {
            say(String(localized: "Removing the vocals in the cloud. It switches in when it's ready."))
        } else {
            say(String(localized: "Removing the vocals in the cloud. It uploads when you're on Wi-Fi and switches in when it's ready."))
        }
        // Watch the new job too.
        observe()
    }

    private func beginDevice(_ song: Song, message: String) {
        intent = SingIntent(songId: song.id, startedAt: Date(), backend: .device)
        stage = .waiting
        // A render queued or running is kept; if it is the automatic studio's, this makes it the person's own.
        studio?.start(.instrumental, song: song)
        say(message)
        observe()
    }

    private func cloudJobEnded(_ end: SingJobEnd, songId: String) {
        switch end {
        case .failed, .empty:
            cloudFailedSongs.insert(songId)
            say(String(localized: "The cloud couldn't do this one. Tap Sing to remove vocals on this phone."))
        case .cancelled:
            break
        }
        endIntent()
    }

    private func updateCloudStatus(_ job: CloudJobRecord, transfer: Double?) {
        let waiting = !(cloud?.settings.useCellular ?? true) && !network.isUnmetered
            && (job.state == .uploading || job.state == .downloading) && (transfer ?? 0) == 0
        let status = SingCloudStatus(weight: CloudActiveJobMapper.weight(job, transfer: transfer),
                                     text: waiting ? "Waiting for Wi-Fi" : CloudActiveJobMapper.status(job, transfer: transfer),
                                     waitingForWiFi: waiting)
        if cloudStatus != status { cloudStatus = status }
    }

    /// The wish is over (granted, given up, or for a song that is gone).
    private func endIntent() {
        intent = nil
        stage = .waiting
        // The UI tests' demo button keeps the status it was given (a song change must not wipe it).
        if demoPhase == nil { cloudStatus = nil }
        network.stop()
        network.onChange = nil
        refreshPhase()
    }

    /// One short line for the person, on the lyrics screen's toast.
    private func say(_ text: String) {
        lyrics?.message = text
    }

    // MARK: Switching

    /// The instrumental is here: make the switch the wish was for. Held while the lyrics editor needs the vocals.
    private func startSwitchIfReady() {
        guard let intent, intent.songId == songId, isAvailable, !isActive, !isSwitching else { return }
        guard suspendedBy.isEmpty else {
            stage = .held
            return
        }
        guard let engine else {
            // UI tests have no player: a demo instrumental is simply on.
            if demoAvailableSongIds.contains(intent.songId) {
                isActive = true
                endIntent()
            }
            return
        }
        guard let url = instrumentalURL(intent.songId) else { return }
        stage = .switching
        cloudStatus = nil
        let index = gapIndex(forSong: intent.songId)
        let placement: DualDeckEngine.SwitchPlacement = { [weak self] earliest in
            self?.placeSwitch(earliestSeconds: earliest, index: index, rate: Double(engine.rate))
                ?? (startSeconds: earliest, fadeSeconds: Double(DualDeckEngine.instrumentalCrossfadeMs) / 1000)
        }
        runSwitch(engine, to: url, songId: intent.songId, placement: placement, requireAligned: true, forSing: true)
    }

    /// The song's quiet moments, from its word-timed lyrics (nil when they aren't loaded for this song).
    private func gapIndex(forSong id: String) -> SingGapIndex? {
        guard let lyrics, lyrics.preparedSongId == id, let prepared = lyrics.prepared else { return nil }
        return SingGapIndex(prepared)
    }

    /// The engine asks where the swap starts once the instrumental is loaded.
    private func placeSwitch(earliestSeconds: Double, index: SingGapIndex?,
                             rate: Double) -> (startSeconds: Double, fadeSeconds: Double) {
        let earliestMs = Int64((earliestSeconds * 1000).rounded())
        let placement = SingSwitchPlanner.plan(index: index, earliestPlayerMs: earliestMs,
                                               offsetMs: Int64(lyrics?.store.offsetMs ?? 0), rate: rate)
        if placement.startPlayerMs > earliestMs, stage == .switching {
            stage = .waitingForGap
            refreshPhase()
        }
        return (startSeconds: Double(placement.startPlayerMs) / 1000, fadeSeconds: Double(placement.fadeMs) / 1000)
    }

    private func runSwitch(_ engine: any InstrumentalSwitching, to url: URL, songId: String,
                           placement: DualDeckEngine.SwitchPlacement?, requireAligned: Bool, forSing: Bool) {
        isSwitching = true
        refreshPhase()
        Task {
            let outcome = await engine.switchCurrentAudio(to: url, placement: placement, requireAligned: requireAligned)
            isSwitching = false
            switchEnded(outcome, songId: songId, forSing: forSing)
        }
    }

    private func switchEnded(_ outcome: DualDeckEngine.SwitchOutcome, songId: String, forSing: Bool) {
        guard self.songId == songId else {
            endIntent()
            return
        }
        switch outcome {
        case .switched:
            isActive = true
            endIntent()
            // The lyrics editor opened while the switch ran: it needs the vocals.
            if !suspendedBy.isEmpty {
                restoreOnResume = true
                playOriginal()
            }
        case .failed:
            // A tap that did nothing (too close to the end of the song, say) says so, whoever started the switch.
            say(String(localized: "Couldn't switch to the instrumental. Tap Sing to try again."))
            endIntent()
        case .abortedBySeek:
            // The place it was planned for is gone: the instrumental stays ready and a tap switches at once.
            say(String(localized: "The instrumental is ready. Tap Sing to switch."))
            endIntent()
        case .misaligned:
            if forSing {
                say(String(localized: "The instrumental is ready, but it may not line up with this version of the song. Tap Sing to switch anyway."))
            }
            endIntent()
        }
    }

    // MARK: Manual switching

    /// UI-test demo: the current song has a render (and it plays).
    func setDemo(available: Bool, active: Bool) {
        if available, let songId { demoAvailableSongIds.insert(songId) }
        isAvailable = songId.map { demoAvailableSongIds.contains($0) || instrumentalURL($0) != nil } ?? false
        isActive = available && active
        refreshPhase()
    }

    /// UI-test demo: the Sing button in one of its in-flight states.
    func setDemoSing(_ phase: SingPhase, status: SingCloudStatus? = nil) {
        demoPhase = phase
        cloudStatus = status
        refreshPhase()
    }

    /// Lyrics screen toggle / "Play instrumental" / "Play original".
    func toggle() {
        isActive ? playOriginal() : playInstrumental()
    }

    /// Switches to the instrumental at once, at the same position.
    func playInstrumental() {
        guard !isSwitching, suspendedBy.isEmpty, let songId else { return }
        guard let engine else {
            if demoAvailableSongIds.contains(songId) {
                isActive = true
                endIntent()
            }
            return
        }
        guard let url = instrumentalURL(songId) else {
            isAvailable = false
            return
        }
        // A wish still waiting for this instrumental is granted by it.
        endIntent()
        runSwitch(engine, to: url, songId: songId, placement: nil, requireAligned: false, forSing: false)
    }

    func playOriginal() {
        guard isActive, !isSwitching else { return }
        endIntent()
        guard let engine else {
            isActive = false
            refreshPhase()
            return
        }
        isSwitching = true
        let songId = self.songId
        Task {
            let outcome = await engine.switchCurrentAudio(to: nil, placement: nil, requireAligned: false)
            isSwitching = false
            if outcome == .switched || self.songId != songId { isActive = false }
            refreshPhase()
        }
    }

    /// `InstrumentalCrossfadeController.suspend`: an owner that needs the vocals (the tap-sync editor).
    func suspend(owner: String) {
        let wasEmpty = suspendedBy.isEmpty
        suspendedBy.insert(owner)
        if wasEmpty, isActive {
            restoreOnResume = true
            playOriginal()
        }
    }

    func resume(owner: String) {
        suspendedBy.remove(owner)
        guard suspendedBy.isEmpty else { return }
        if restoreOnResume {
            restoreOnResume = false
            playInstrumental()
        } else if intent != nil {
            // A switch that waited for the editor to close.
            reapply()
        }
    }
}
