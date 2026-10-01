import AVFoundation
import CoreMedia
import Foundation
import PixlAudioCore
import PixlModel

/// One playable queue entry on a deck: the `AVPlayerItem` with its processing tap and the tap's parameters.
@MainActor
final class DeckItem {
    let entry: QueueEntry
    let playerItem: AVPlayerItem
    let asset: AVURLAsset
    let tap: TapItemParameters
    /// From the asset (falls back to the song's stored duration while unknown).
    let durationSeconds: Double
    /// True for local files (ReplayGain tags can be read).
    let isLocalFile: Bool
    /// The ReplayGain volume read from the file's tags (nil until read / when off).
    var replayGainVolume: Float?
    /// A seek requested before the item was ready to play (applied when it is).
    var pendingSeekSeconds: Double?
    /// The target of a seek still in flight (the timebase only moves once it completes).
    var seekTargetSeconds: Double?
    /// Distinguishes seeks so an older completion never clears a newer target.
    var seekGeneration = 0

    var song: Song { entry.song }

    init(entry: QueueEntry, playerItem: AVPlayerItem, asset: AVURLAsset, tap: TapItemParameters,
         durationSeconds: Double, isLocalFile: Bool) {
        self.entry = entry
        self.playerItem = playerItem
        self.asset = asset
        self.tap = tap
        self.durationSeconds = durationSeconds
        self.isLocalFile = isLocalFile
    }

    /// Position from the item's timebase (cheap; no observation).
    var positionSeconds: Double {
        if let pendingSeekSeconds { return pendingSeekSeconds }
        if let seekTargetSeconds { return seekTargetSeconds }
        if let timebase = playerItem.timebase {
            let t = CMTimebaseGetTime(timebase)
            if t.isValid && t.isNumeric { return max(t.seconds, 0) }
        }
        let t = playerItem.currentTime()
        return t.isValid && t.isNumeric ? max(t.seconds, 0) : 0
    }
}

nonisolated enum DeckItemError: Error, Equatable {
    case unresolvable(songId: String)
    case noAudioTrack(songId: String)
}

/// Builds `DeckItem`s: resolves the URL, attaches a registered streaming resource loader (stage 11's hook), loads
/// the audio track and duration, and installs the processing tap through an `AVAudioMix`.
@MainActor
final class DeckItemFactory {
    let effects: AudioEffectsParameters
    var resolver: any PlayableURLResolving
    let streaming: StreamingResourceLoaderRegistry
    /// Per-buffer tap log capacity (tests; 0 = off).
    var tapLogCapacity = 0

    init(effects: AudioEffectsParameters, resolver: any PlayableURLResolving = DefaultPlayableURLResolver(),
         streaming: StreamingResourceLoaderRegistry = .shared) {
        self.effects = effects
        self.resolver = resolver
        self.streaming = streaming
    }

    func makeItem(for entry: QueueEntry) async throws -> DeckItem {
        guard let url = await resolver.playableURL(for: entry.song) else {
            throw DeckItemError.unresolvable(songId: entry.song.id)
        }
        let asset = AVURLAsset(url: url)
        streaming.attach(to: asset)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            streaming.detach(from: asset)
            throw DeckItemError.noAudioTrack(songId: entry.song.id)
        }
        let duration = try? await asset.load(.duration)
        var seconds = duration.map { $0.isValid && $0.isNumeric ? $0.seconds : 0 } ?? 0
        if seconds <= 0 { seconds = Double(entry.song.duration) / 1000 }
        let parameters = TapItemParameters(logCapacity: tapLogCapacity)
        parameters.mediaDuration.store(seconds)
        let item = AVPlayerItem(asset: asset)
        // Pitch-preserving rate changes (sync editor speeds 0.75 / 0.5).
        item.audioTimePitchAlgorithm = .spectral
        item.audioMix = ProcessingTap.makeAudioMix(for: track, effects: effects, item: parameters)
        return DeckItem(entry: entry, playerItem: item, asset: asset, tap: parameters, durationSeconds: seconds,
                        isLocalFile: url.isFileURL)
    }

    func discard(_ item: DeckItem) {
        streaming.detach(from: item.asset)
    }
}

/// One `AVQueuePlayer` ("deck"). `DualDeckEngine` keeps two: the active one, and the idle one used for crossfades.
/// Gapless joins are host-clock hand-overs between the two decks (`preroll` + `start(rate:atHostTime:)`). Events reach
/// the engine on the main actor in order.
@MainActor
final class Deck {
    enum Event {
        /// The player's current item changed (auto-advance, removal or a new load).
        case currentItemChanged(DeckItem?)
        /// `timeControlStatus` changed.
        case statusChanged(AVPlayer.TimeControlStatus)
        /// The item played to its end.
        case itemEnded(DeckItem)
        /// The item failed (to load or to play to the end).
        case itemFailed(DeckItem, String)
    }

    let name: String
    let player = AVQueuePlayer()
    /// Items handed to the player, in queue order (the current one first).
    private(set) var items: [DeckItem] = []
    var onEvent: ((Deck, Event) -> Void)?

    private var currentItemObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var itemObservations: [ObjectIdentifier: [any NSObjectProtocol]] = [:]
    private var itemStatusObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]

    init(name: String) {
        self.name = name
        player.actionAtItemEnd = .advance
        // Taps must keep running: AirPlay video routing would bypass them (audio AirPlay still works).
        player.allowsExternalPlayback = false
        player.automaticallyWaitsToMinimizeStalling = true
        currentItemObservation = player.observe(\.currentItem, options: [.new]) { @Sendable [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.currentItemDidChange() } }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { @Sendable [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.statusDidChange() } }
        }
    }

    var currentItem: DeckItem? {
        guard let playerItem = player.currentItem else { return nil }
        return items.first { $0.playerItem === playerItem }
    }

    /// Items after the current one.
    var upcoming: [DeckItem] {
        guard let current = currentItem, let i = items.firstIndex(where: { $0 === current }) else { return [] }
        return Array(items[(i + 1)...])
    }

    var isPlaying: Bool { player.timeControlStatus != .paused || player.rate != 0 }

    // MARK: Loading

    /// Replaces everything with `item`, positioned at `seconds`.
    func load(_ item: DeckItem, at seconds: Double = 0) {
        removeAll()
        restoreStallWaiting()
        items = [item]
        observe(item)
        player.insert(item.playerItem, after: nil)
        if seconds > 0 {
            if item.playerItem.status == .readyToPlay { seek(to: seconds) } else { item.pendingSeekSeconds = seconds }
        }
    }

    /// Queues `item` after the last item. Returns false when the player refuses it.
    @discardableResult
    func append(_ item: DeckItem) -> Bool {
        let after = items.last?.playerItem
        guard player.canInsert(item.playerItem, after: after) else { return false }
        items.append(item)
        observe(item)
        player.insert(item.playerItem, after: after)
        return true
    }

    /// Removes the items after the current one.
    func removeUpcoming() -> [DeckItem] {
        let dropped = upcoming
        for item in dropped { remove(item) }
        return dropped
    }

    func remove(_ item: DeckItem) {
        player.remove(item.playerItem)
        forget(item)
    }

    /// Stops and empties the deck. Returns the items it held.
    @discardableResult
    func removeAll() -> [DeckItem] {
        let dropped = items
        player.pause()
        player.removeAllItems()
        for item in dropped { forget(item) }
        items = []
        return dropped
    }

    // MARK: Transport

    func play(rate: Float) {
        player.defaultRate = rate
        player.playImmediately(atRate: rate)
    }

    func pause() { player.pause() }

    // MARK: Scheduled start (gapless hand-over)

    /// True when `item` is this deck's current item and both it and the player are ready to play (preroll would
    /// raise otherwise).
    func isReadyToPreroll(_ item: DeckItem) -> Bool {
        currentItem === item && item.playerItem.status == .readyToPlay && player.status == .readyToPlay
    }

    /// Loads the current item's audio from its current time so a scheduled start is instant.
    func preroll(rate: Float) async -> Bool {
        guard let item = currentItem, isReadyToPreroll(item), player.rate == 0 else { return false }
        return await player.preroll(atRate: rate)
    }

    /// Starts the current item from its beginning at `hostTime` (host clock). Precise starts need stall waiting off.
    func start(rate: Float, atHostTime hostTime: CMTime) {
        player.automaticallyWaitsToMinimizeStalling = false
        player.defaultRate = rate
        player.setRate(rate, time: .zero, atHostTime: hostTime)
    }

    /// Back to the default stall handling (for streamed items) once no scheduled start is pending.
    func restoreStallWaiting() {
        if !player.automaticallyWaitsToMinimizeStalling { player.automaticallyWaitsToMinimizeStalling = true }
    }

    func setRate(_ rate: Float) {
        player.defaultRate = rate
        if player.rate != 0 { player.rate = rate }
    }

    /// Accurate seek on the current item (deferred until it is ready to play).
    func seek(to seconds: Double) {
        if let item = currentItem, item.playerItem.status != .readyToPlay {
            item.pendingSeekSeconds = seconds
            return
        }
        let time = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
        guard let item = currentItem else {
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            return
        }
        item.seekGeneration += 1
        let generation = item.seekGeneration
        item.seekTargetSeconds = max(seconds, 0)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { @Sendable [weak item] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let item, item.seekGeneration == generation else { return }
                    item.seekTargetSeconds = nil
                }
            }
        }
    }

    var positionSeconds: Double { currentItem?.positionSeconds ?? 0 }

    // MARK: Observation

    private func observe(_ item: DeckItem) {
        let id = ObjectIdentifier(item.playerItem)
        let center = NotificationCenter.default
        let ended = center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item.playerItem,
                                       queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.itemDidEnd(id) }
        }
        let failed = center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                                        object: item.playerItem, queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.itemDidFail(id, message: "Playback stopped before the end") }
        }
        itemObservations[id] = [ended, failed]
        itemStatusObservations[id] = item.playerItem.observe(\.status, options: [.new]) { @Sendable [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.itemStatusDidChange(id) } }
        }
    }

    private func forget(_ item: DeckItem) {
        let id = ObjectIdentifier(item.playerItem)
        for token in itemObservations[id] ?? [] { NotificationCenter.default.removeObserver(token) }
        itemObservations[id] = nil
        itemStatusObservations[id]?.invalidate()
        itemStatusObservations[id] = nil
        items.removeAll { $0 === item }
    }

    private func item(for id: ObjectIdentifier) -> DeckItem? {
        items.first { ObjectIdentifier($0.playerItem) == id }
    }

    private func currentItemDidChange() {
        // Drop items the player has already finished with (they precede the current one).
        if let playerItem = player.currentItem, let index = items.firstIndex(where: { $0.playerItem === playerItem }),
           index > 0 {
            for finished in items[..<index] { forget(finished) }
        } else if player.currentItem == nil {
            for finished in items { forget(finished) }
        }
        onEvent?(self, .currentItemChanged(currentItem))
    }

    private func statusDidChange() {
        onEvent?(self, .statusChanged(player.timeControlStatus))
    }

    private func itemDidEnd(_ id: ObjectIdentifier) {
        guard let item = item(for: id) else { return }
        onEvent?(self, .itemEnded(item))
    }

    private func itemDidFail(_ id: ObjectIdentifier, message: String) {
        guard let item = item(for: id) else { return }
        let detail = item.playerItem.error?.localizedDescription ?? message
        onEvent?(self, .itemFailed(item, detail))
    }

    private func itemStatusDidChange(_ id: ObjectIdentifier) {
        guard let item = item(for: id) else { return }
        switch item.playerItem.status {
        case .readyToPlay:
            if let seconds = item.pendingSeekSeconds, item === currentItem {
                item.pendingSeekSeconds = nil
                seek(to: seconds)
            }
        case .failed:
            onEvent?(self, .itemFailed(item, item.playerItem.error?.localizedDescription ?? "The item could not be loaded"))
        default:
            break
        }
    }
}
