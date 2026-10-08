// Spotify Connect: the remote session as a value and the pure reducer that folds each `GET /me/player` poll into
// it. The app's controller owns the network and the timers; everything decided here — which queue entry plays,
// whether someone took over, when to send the next window, whether anything visible changed (perf: no state write
// when nothing did) — is unit-tested in PixlNetTests.

import Foundation

/// What PixlAudio knows about the device it plays on.
public struct SpotifyConnectSessionState: Sendable, Hashable {
    public var deviceId: String
    public var deviceName: String
    public var deviceType: String
    /// The `uris` last sent, and the queue index each plays.
    public var window: SpotifyConnectWindow
    /// The window position playing now (as last seen or as a command made it).
    public var windowPosition: Int
    public var isPlaying: Bool
    /// The progress at `anchorMs` (local clock); interpolated in between polls while playing.
    public var progressMs: Int64
    public var anchorMs: Int64
    /// The remote item's duration (0 = unknown).
    public var durationMs: Int64
    public var volumePercent: Int?
    public var supportsVolume: Bool
    /// Until then polls may still show the state from before our last command (the Web API doesn't guarantee the
    /// order of player calls): they are ignored instead of read as a track change or a takeover.
    public var graceUntilMs: Int64
    /// Whether PixlAudio's queue has more to play after the window (set by the controller after each send).
    public var hasMoreAfterWindow: Bool
    /// The URI for which the next window was already requested (once per arrival at the window's end).
    public var extendedAtURI: String?
    /// Until then polls keep the volume PixlAudio set (the device may not have applied the last `PUT` yet, and a
    /// burst of volume-button presses steps from the local value, not from a stale poll).
    public var volumeHoldUntilMs: Int64
    /// The device refused a volume command (`VOLUME_CONTROL_DISALLOW`) although it reports `supports_volume`: no
    /// volume control for the rest of the session, whatever later polls say (else every poll would offer it again and
    /// every press would fail again).
    public var volumeRefused: Bool

    public init(deviceId: String, deviceName: String, deviceType: String, window: SpotifyConnectWindow,
                windowPosition: Int = 0, isPlaying: Bool = true, progressMs: Int64 = 0, anchorMs: Int64,
                durationMs: Int64 = 0, volumePercent: Int? = nil, supportsVolume: Bool = false,
                graceUntilMs: Int64 = 0, hasMoreAfterWindow: Bool = false, volumeHoldUntilMs: Int64 = 0,
                volumeRefused: Bool = false) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.window = window
        self.windowPosition = windowPosition
        self.isPlaying = isPlaying
        self.progressMs = progressMs
        self.anchorMs = anchorMs
        self.durationMs = durationMs
        self.volumePercent = volumePercent
        self.supportsVolume = supportsVolume
        self.graceUntilMs = graceUntilMs
        self.hasMoreAfterWindow = hasMoreAfterWindow
        self.volumeHoldUntilMs = volumeHoldUntilMs
        self.volumeRefused = volumeRefused
        if volumeRefused { self.supportsVolume = false }
    }

    /// The queue index playing now.
    public var queueIndex: Int? {
        window.queueIndices.indices.contains(windowPosition) ? window.queueIndices[windowPosition] : nil
    }

    public var currentURI: String? { window.uris.indices.contains(windowPosition) ? window.uris[windowPosition] : nil }

    /// The position, interpolated from the last poll (never past the duration).
    public func positionMs(at nowMs: Int64) -> Int64 {
        guard isPlaying else { return max(progressMs, 0) }
        let position = progressMs + max(nowMs - anchorMs, 0)
        return durationMs > 0 ? min(position, durationMs) : position
    }
}

/// Who or what ended the session.
public enum SpotifyConnectTakeover: Sendable, Hashable {
    /// Another device became the active one.
    case otherDevice(name: String?)
    /// The device plays something PixlAudio didn't send (another app, the Spotify app).
    case otherContent
    /// Nothing plays anywhere any more (204).
    case stopped

    public func message(deviceName: String) -> String {
        switch self {
        case .otherDevice(let name?): "Playback moved to \(name)"
        case .otherDevice(nil): "Playback moved to another device"
        case .otherContent: "Spotify started playing something else on \(deviceName)"
        case .stopped: "Playback stopped on \(deviceName)"
        }
    }
}

/// What one poll means.
public struct SpotifyConnectPollOutcome: Sendable, Hashable {
    public enum Change: Sendable, Hashable {
        /// Nothing visible changed: write nothing.
        case none
        /// Play state, progress (beyond interpolation), duration or volume changed.
        case updated
        /// Another queue entry plays now.
        case trackChanged(queueIndex: Int)
        /// The session is over.
        case takenOver(SpotifyConnectTakeover)
        /// The device finished the last entry of PixlAudio's queue.
        case reachedEnd
    }

    public var change: Change
    /// The device is on the window's last entry and the queue has more: send the next window.
    public var needsNextWindow: Bool

    public init(_ change: Change, needsNextWindow: Bool = false) {
        self.change = change
        self.needsNextWindow = needsNextWindow
    }
}

/// The reducer.
public enum SpotifyConnectReducer {
    /// A poll's progress within this of the interpolated one is not a change.
    public static let progressToleranceMs: Int64 = 1500
    /// Grace after a command.
    public static let commandGraceMs: Int64 = 2500
    /// Grace after starting a session (the device may have to wake up and buffer).
    public static let startGraceMs: Int64 = 6000
    /// How long polls keep a volume PixlAudio set.
    public static let volumeHoldMs: Int64 = 3000

    /// Folds a poll (`nil` = 204, nothing playing) into `state`.
    public static func apply(_ poll: SpotifyPlaybackState?, to state: inout SpotifyConnectSessionState,
                             nowMs: Int64) -> SpotifyConnectPollOutcome {
        let inGrace = nowMs < state.graceUntilMs
        guard let poll else { return SpotifyConnectPollOutcome(inGrace ? .none : .takenOver(.stopped)) }
        if let device = poll.device, let id = device.deviceId, id != state.deviceId {
            return SpotifyConnectPollOutcome(inGrace ? .none : .takenOver(.otherDevice(name: device.name)))
        }
        guard let uri = poll.itemURI, let position = state.window.position(of: uri, near: state.windowPosition) else {
            if inGrace { return SpotifyConnectPollOutcome(.none) }
            // After the last entry Spotify may go on with its own suggestions (autoplay): that is the end, not a
            // takeover.
            if state.windowPosition == state.window.count - 1, !state.hasMoreAfterWindow, poll.itemURI != nil {
                return SpotifyConnectPollOutcome(.reachedEnd)
            }
            return SpotifyConnectPollOutcome(.takenOver(.otherContent))
        }
        // Inside the grace period only a poll that already shows what the last command asked for counts.
        if inGrace && position != state.windowPosition { return SpotifyConnectPollOutcome(.none) }

        var change = SpotifyConnectPollOutcome.Change.none
        let wasPlaying = state.isPlaying
        if position != state.windowPosition {
            state.windowPosition = position
            state.extendedAtURI = nil
            if let index = state.queueIndex { change = .trackChanged(queueIndex: index) }
        }
        let progress = poll.progressMs ?? 0
        let duration = poll.itemDurationMs ?? state.durationMs
        let expected = state.positionMs(at: nowMs)
        if poll.isPlaying != state.isPlaying || abs(progress - expected) > progressToleranceMs
            || duration != state.durationMs || change != .none {
            if change == .none { change = .updated }
        }
        // Inside the volume hold the local value stands (a poll from before the last `PUT` would snap it back).
        if let volume = poll.device?.volumePercent, volume != state.volumePercent, nowMs >= state.volumeHoldUntilMs {
            state.volumePercent = volume
            if change == .none { change = .updated }
        }
        if let supports = poll.device?.supportsVolume, !state.volumeRefused, supports != state.supportsVolume {
            state.supportsVolume = supports
            if change == .none { change = .updated }
        }
        if change != .none {
            state.isPlaying = poll.isPlaying
            state.progressMs = progress
            state.anchorMs = nowMs
            state.durationMs = duration
        }

        // The last entry stopped by itself at its start or its end: the queue is done.
        let atLast = position == state.window.count - 1
        if atLast, !state.hasMoreAfterWindow, wasPlaying, !poll.isPlaying, !inGrace,
           progress <= 1000 || (duration > 0 && progress >= duration - progressToleranceMs) {
            return SpotifyConnectPollOutcome(.reachedEnd)
        }

        var needsNext = false
        if atLast, state.hasMoreAfterWindow, state.extendedAtURI != uri {
            state.extendedAtURI = uri
            needsNext = true
        }
        return SpotifyConnectPollOutcome(change, needsNextWindow: needsNext)
    }

    // MARK: Optimistic updates (what a command will do, shown at once)

    /// A new window was sent: the device starts its first entry at `positionMs`.
    public static func sent(_ window: SpotifyConnectWindow, positionMs: Int64, durationMs: Int64, hasMore: Bool,
                            to state: inout SpotifyConnectSessionState, nowMs: Int64, grace: Int64 = commandGraceMs) {
        state.window = window
        state.windowPosition = 0
        state.isPlaying = true
        state.progressMs = positionMs
        state.anchorMs = nowMs
        state.durationMs = durationMs
        state.hasMoreAfterWindow = hasMore
        state.extendedAtURI = nil
        state.graceUntilMs = nowMs + grace
    }

    public static func setPlaying(_ playing: Bool, _ state: inout SpotifyConnectSessionState, nowMs: Int64) {
        state.progressMs = state.positionMs(at: nowMs)
        state.anchorMs = nowMs
        state.isPlaying = playing
        state.graceUntilMs = nowMs + commandGraceMs
    }

    /// PixlAudio set the device volume (the slider, the volume buttons): clamped to 0…100 and held against polls for
    /// `volumeHoldMs`.
    public static func setVolume(_ percent: Int, _ state: inout SpotifyConnectSessionState, nowMs: Int64) {
        state.volumePercent = min(max(percent, 0), 100)
        state.volumeHoldUntilMs = nowMs + volumeHoldMs
    }

    /// The device refused a volume command: no volume control until the session ends.
    public static func refuseVolume(_ state: inout SpotifyConnectSessionState) {
        state.volumeRefused = true
        state.supportsVolume = false
    }

    /// Whether a device that reports `supports_volume` takes volume commands in this session.
    public static func supportsVolume(_ reported: Bool, in state: SpotifyConnectSessionState?) -> Bool {
        reported && state?.volumeRefused != true
    }

    /// The device accepted a volume `PUT`: polls keep the value a little longer, until the device reports it.
    public static func volumeSent(_ state: inout SpotifyConnectSessionState, nowMs: Int64, settleMs: Int64 = 1500) {
        state.volumeHoldUntilMs = max(state.volumeHoldUntilMs, nowMs + settleMs)
    }

    public static func seek(to positionMs: Int64, _ state: inout SpotifyConnectSessionState, nowMs: Int64) {
        state.progressMs = max(positionMs, 0)
        state.anchorMs = nowMs
        state.graceUntilMs = nowMs + commandGraceMs
    }

    /// `POST next` inside the window.
    public static func advance(_ state: inout SpotifyConnectSessionState, durationMs: Int64, nowMs: Int64) {
        guard state.windowPosition + 1 < state.window.count else { return }
        state.windowPosition += 1
        state.progressMs = 0
        state.anchorMs = nowMs
        state.durationMs = durationMs
        state.isPlaying = true
        state.extendedAtURI = nil
        state.graceUntilMs = nowMs + commandGraceMs
    }

    // MARK: Transport decisions

    /// How "next" reaches the device.
    public enum Skip: Sendable, Hashable {
        /// `POST next`: the target is the window's next entry.
        case next
        /// `PUT play` with a window starting at this queue index.
        case play(fromQueueIndex: Int)
        /// Nothing after the current entry.
        case none
        /// `PUT seek` to 0 (previous more than 3 s in).
        case restart
    }

    /// PixlAudio's "next": the following queue entry that is on Spotify (repeat-all wraps to the first).
    public static func next(state: SpotifyConnectSessionState, slots: [SpotifyConnectSlot], repeatAll: Bool) -> Skip {
        guard let current = state.queueIndex else { return .none }
        if state.windowPosition + 1 < state.window.count { return .next }
        if let target = firstPlayable(slots, after: current) { return .play(fromQueueIndex: target) }
        if repeatAll, let first = firstPlayable(slots, after: -1) { return .play(fromQueueIndex: first) }
        return .none
    }

    /// PixlAudio's "previous": restart when more than 3 s in (as the engine does), else the previous queue entry
    /// that is on Spotify.
    public static func previous(state: SpotifyConnectSessionState, slots: [SpotifyConnectSlot], nowMs: Int64,
                                restartThresholdMs: Int64 = 3000) -> Skip {
        guard let current = state.queueIndex else { return .none }
        if state.positionMs(at: nowMs) > restartThresholdMs { return .restart }
        var index = current - 1
        while index >= 0 {
            if case .uri = slots[index] { return .play(fromQueueIndex: index) }
            if slots[index] == .pending { return .play(fromQueueIndex: index) }
            index -= 1
        }
        return .restart
    }

    /// The first entry after `index` that is on Spotify or not looked up yet.
    public static func firstPlayable(_ slots: [SpotifyConnectSlot], after index: Int) -> Int? {
        var i = index + 1
        while i < slots.count {
            if slots[i] != .skipped { return i }
            i += 1
        }
        return nil
    }

    /// The device's repeat state for PixlAudio's mode. Repeat-all isn't Spotify's `context` (the `uris` start at the
    /// current entry, so `context` would loop from there): PixlAudio wraps itself and keeps the device at `off`.
    public static func remoteRepeat(repeatOne: Bool) -> SpotifyRepeatState { repeatOne ? .track : .off }
}
