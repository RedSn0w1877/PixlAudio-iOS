import Foundation
import Observation
import PixlModel

/// The current song's studio instrumental (Android `PlayerViewModel.studioInstrumentalAvailable/Active`,
/// `switchToStudioInstrumental`, `switchToOriginalAudio` + `InstrumentalCrossfadeController`): whether a render exists,
/// whether it is what plays, and the switch — an in-sync 700 ms crossfade through the engine's idle deck. A new song
/// always starts with its own audio. Owners such as the lyrics tap-sync editor can suspend it to hear the vocals.
@MainActor
@Observable
final class InstrumentalController {
    /// A complete render exists for the current song.
    private(set) var isAvailable = false
    /// The instrumental is what plays.
    private(set) var isActive = false
    private(set) var isSwitching = false

    @ObservationIgnored private let playback: PlaybackStore
    @ObservationIgnored private let engine: DualDeckEngine?
    @ObservationIgnored private weak var studio: TaisStudio?
    @ObservationIgnored private var songId: String?
    @ObservationIgnored private var suspendedBy: Set<String> = []
    @ObservationIgnored private var restoreOnResume = false
    /// UI tests: songs that "have" an instrumental.
    @ObservationIgnored var demoAvailableSongIds: Set<String> = []

    init(playback: PlaybackStore, engine: DualDeckEngine?, studio: TaisStudio) {
        self.playback = playback
        self.engine = engine
        self.studio = studio
        observe()
    }

    /// Re-checks when the song changes or a render lands.
    private func observe() {
        withObservationTracking {
            let id = playback.current?.id
            _ = studio?.instrumentalRevision
            refresh(songId: id)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func refresh(songId: String?) {
        if songId != self.songId {
            self.songId = songId
            isActive = false
            restoreOnResume = false
        }
        guard let songId else {
            isAvailable = false
            return
        }
        isAvailable = demoAvailableSongIds.contains(songId) || InstrumentalFiles.bestAvailable(songId: songId) != nil
    }

    /// UI-test demo: the current song has a render (and it plays).
    func setDemo(available: Bool, active: Bool) {
        if available, let songId { demoAvailableSongIds.insert(songId) }
        refresh(songId: songId)
        isActive = available && active
    }

    /// Lyrics screen toggle / "Play instrumental" / "Play original".
    func toggle() {
        isActive ? playOriginal() : playInstrumental()
    }

    func playInstrumental() {
        guard !isSwitching, suspendedBy.isEmpty, let songId else { return }
        guard let engine else {
            if demoAvailableSongIds.contains(songId) { isActive = true }
            return
        }
        guard let url = InstrumentalFiles.bestAvailable(songId: songId) else {
            isAvailable = false
            return
        }
        isSwitching = true
        Task {
            let switched = await engine.switchCurrentAudio(to: url)
            isSwitching = false
            if switched, self.songId == songId { isActive = true }
        }
    }

    func playOriginal() {
        guard isActive, !isSwitching else { return }
        guard let engine else {
            isActive = false
            return
        }
        isSwitching = true
        let songId = self.songId
        Task {
            let switched = await engine.switchCurrentAudio(to: nil)
            isSwitching = false
            if switched || self.songId != songId { isActive = false }
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
        if suspendedBy.isEmpty, restoreOnResume {
            restoreOnResume = false
            playInstrumental()
        }
    }
}
