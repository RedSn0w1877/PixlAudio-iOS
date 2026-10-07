import Foundation
import MediaPlayer
import Observation
import PixlModel
import UIKit

/// The system Now Playing surface (Lock Screen, Control Center, Dynamic Island, AirPlay, headphones, the watch):
/// `MPNowPlayingInfoCenter` metadata + artwork, and `MPRemoteCommandCenter` play / pause / toggle / next / previous /
/// seek / shuffle / repeat / like routed to the engine. Elapsed time is published only on changes (play, pause, seek,
/// rate, song) — the system extrapolates from the rate, so nothing ticks.
@MainActor
final class NowPlayingController {
    private let engine: DualDeckEngine
    private let artwork: ArtworkPipeline
    private var commandTargets: [(command: MPRemoteCommand, token: Any)] = []
    private var artworkTask: Task<Void, Never>?
    private var currentSongId: String?
    private var currentArtwork: MPMediaItemArtwork?

    /// Toggles the favourite state of a song (the library owns favourites; nil hides "like").
    var onLike: ((Song) -> Void)?
    /// Whether a song is a favourite (for the like command's state).
    var isFavorite: ((Song) -> Bool)?
    /// Read under observation tracking by `followFavorites(revision:)`: a change re-reads the like state.
    private var favoritesRevision: (() -> Int)?
    /// Spotify Connect while it drives playback: the transport commands go there and the published position, rate
    /// and duration are the remote device's.
    weak var remote: (any RemotePlaybackOutput)?

    init(engine: DualDeckEngine, artwork: ArtworkPipeline = .shared) {
        self.engine = engine
        self.artwork = artwork
    }

    /// Registers the remote commands. Call once at launch.
    func install() {
        uninstall()
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand) { [weak self] engine, _ in
            if let remote = self?.remote { remote.remotePlay() } else { engine.play() }
        }
        add(center.pauseCommand) { [weak self] engine, _ in
            if let remote = self?.remote { remote.remotePause() } else { engine.pause() }
        }
        add(center.togglePlayPauseCommand) { [weak self] engine, _ in
            if let remote = self?.remote {
                remote.remoteIsPlaying ? remote.remotePause() : remote.remotePlay()
            } else {
                engine.playWhenReady ? engine.pause() : engine.play()
            }
        }
        add(center.nextTrackCommand) { [weak self] engine, _ in
            if let remote = self?.remote { remote.remoteSkipToNext() } else { engine.skipToNext() }
        }
        add(center.previousTrackCommand) { [weak self] engine, _ in
            if let remote = self?.remote { remote.remoteSkipToPrevious() } else { engine.skipToPrevious() }
        }
        add(center.changePlaybackPositionCommand) { [weak self] engine, value in
            guard case .position(let seconds) = value else { return }
            if let remote = self?.remote { remote.remoteSeek(toMs: Int64(seconds * 1000)) } else { engine.seek(toMs: Int64(seconds * 1000)) }
        }
        add(center.changeShuffleModeCommand) { engine, value in
            if case .shuffle(let type) = value { engine.setShuffleEnabled(type != .off) }
        }
        add(center.changeRepeatModeCommand) { engine, value in
            guard case .repeatMode(let type) = value else { return }
            switch type {
            case .one: engine.setRepeatMode(.one)
            case .all: engine.setRepeatMode(.all)
            default: engine.setRepeatMode(.off)
            }
        }
        add(center.likeCommand) { [weak self] engine, _ in
            guard let self, let song = engine.queue.current?.song else { return }
            self.onLike?(song)
            self.refreshCommandStates()
        }
        center.likeCommand.localizedTitle = String(localized: "Like")
        // Seek-by-interval and rating commands are not PixlAudio features.
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.dislikeCommand.isEnabled = false
        center.bookmarkCommand.isEnabled = false
        refreshCommandStates()
    }

    func uninstall() {
        for target in commandTargets { target.command.removeTarget(target.token) }
        commandTargets = []
    }

    /// Keeps the like command's state in step with favourite edits made anywhere else (the full player's heart, the
    /// song sheet, a restore, a Spotify like): `revision` (the library's) is read under observation tracking, and each
    /// change re-reads the current song's state. Nothing runs between changes.
    func followFavorites(revision: @escaping () -> Int) {
        favoritesRevision = revision
        trackFavorites()
    }

    private func trackFavorites() {
        guard let favoritesRevision else { return }
        withObservationTracking {
            _ = favoritesRevision()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshCommandStates()
                self?.trackFavorites()
            }
        }
    }

    /// The parts of a command event the handlers need (events are not Sendable; values are extracted first).
    private enum CommandValue: Sendable {
        case none
        case position(Double)
        case shuffle(MPShuffleType)
        case repeatMode(MPRepeatType)
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (DualDeckEngine, CommandValue) -> Void) {
        command.isEnabled = true
        // Handlers arrive on the main queue (as in DiagnosticsModel); the work is hopped to the main actor.
        let token = command.addTarget { @Sendable [weak self] event -> MPRemoteCommandHandlerStatus in
            let value: CommandValue
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                value = .position(e.positionTime)
            } else if let e = event as? MPChangeShuffleModeCommandEvent {
                value = .shuffle(e.shuffleType)
            } else if let e = event as? MPChangeRepeatModeCommandEvent {
                value = .repeatMode(e.repeatType)
            } else {
                value = .none
            }
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self.engine, value)
            }
            return .success
        }
        commandTargets.append((command, token))
    }

    // MARK: Publishing

    /// Republishes everything (song change, play/pause, seek, rate, queue).
    func update() {
        let center = MPNowPlayingInfoCenter.default()
        guard let entry = engine.queue.current else {
            center.nowPlayingInfo = nil
            currentSongId = nil
            currentArtwork = nil
            artworkTask?.cancel()
            return
        }
        let song = entry.song
        var durationMs = engine.currentDurationMs()
        var positionMs = engine.currentPositionMs()
        var rate = engine.playWhenReady ? Double(engine.rate) : 0.0
        if let remote {
            let remoteDuration = remote.remoteDurationMs()
            durationMs = remoteDuration > 0 ? remoteDuration : song.duration
            positionMs = remote.remotePositionMs()
            rate = remote.remoteIsPlaying ? 1.0 : 0.0
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.displayArtist,
            MPMediaItemPropertyAlbumTitle: song.album,
            MPMediaItemPropertyPlaybackDuration: Double(durationMs) / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(positionMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: engine.queue.currentIndex ?? 0,
            MPNowPlayingInfoPropertyPlaybackQueueCount: engine.queue.count,
            MPNowPlayingInfoPropertyExternalContentIdentifier: song.id,
        ]
        if let albumArtist = song.albumArtist { info[MPMediaItemPropertyAlbumArtist] = albumArtist }
        if let genre = song.genre { info[MPMediaItemPropertyGenre] = genre }
        if song.id != currentSongId {
            currentSongId = song.id
            currentArtwork = nil
            loadArtwork(for: song)
        }
        if let currentArtwork { info[MPMediaItemPropertyArtwork] = currentArtwork }
        center.nowPlayingInfo = info
        refreshCommandStates()
    }

    private func refreshCommandStates() {
        let center = MPRemoteCommandCenter.shared()
        center.changeShuffleModeCommand.currentShuffleType = engine.shuffleEnabled ? .items : .off
        switch engine.queue.repeatMode {
        case .off: center.changeRepeatModeCommand.currentRepeatType = .off
        case .one: center.changeRepeatModeCommand.currentRepeatType = .one
        case .all: center.changeRepeatModeCommand.currentRepeatType = .all
        }
        center.likeCommand.isEnabled = onLike != nil
        if let song = engine.queue.current?.song {
            center.likeCommand.isActive = isFavorite?(song) ?? song.isFavorite
        }
    }

    private func loadArtwork(for song: Song) {
        artworkTask?.cancel()
        guard let source = ArtworkSource(song: song) else { return }
        let songId = song.id
        artworkTask = Task { [weak self] in
            guard let self else { return }
            guard let image = await self.artwork.image(source, pixelSize: 600) else { return }
            guard !Task.isCancelled, self.currentSongId == songId else { return }
            self.currentArtwork = Self.makeArtwork(UIImage(cgImage: image.cgImage))
            self.update()
        }
    }

    /// Built outside the main actor: the request handler runs on a system queue.
    nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
