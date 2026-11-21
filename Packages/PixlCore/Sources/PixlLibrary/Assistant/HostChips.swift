// The chips of "Ask the host" (Endless Listening): six, in this order, each answered on the phone with no model call. A port of Android's
// `HostChip` (`AskTaizoViewModel.kt`). The words are the app's (`EndlessStrings`); what each chip does is decided here.

public enum HostChip: Int, CaseIterable, Sendable {
    /// "Something new": the Familiar / Blend / Discover switch moves to Discover.
    case new
    /// "Back to familiar": the switch moves to Familiar.
    case familiar
    /// "Why this song": the existing sheet for the song that is playing.
    case why
    /// "More upbeat": `steer_session`, scope session, `energy_up`.
    case upbeat
    /// "Slower": `steer_session`, scope session, `energy_down`.
    case slower
    /// "Surprise me": `steer_session`, scope session, `more_new`.
    case surprise

    /// The novelty level a chip sets, or nil for a chip that does something else.
    public var noveltyLevel: Int? {
        switch self {
        case .new: Novelty.discover
        case .familiar: Novelty.familiar
        default: nil
        }
    }

    /// The `steer_session` change a chip asks for (scope session), or nil for a chip that does something else.
    public var steerChange: String? {
        switch self {
        case .upbeat: "energy_up"
        case .slower: "energy_down"
        case .surprise: "more_new"
        default: nil
        }
    }
}

/// What the host's "Something new" / "Back to familiar" chips do to the Familiar / Blend / Discover switch: they apply to this listening
/// only. The level the listener saved is remembered the first time a chip moves it, the chip's level is used without being saved, and the
/// saved one comes back when Endless Listening ends (or another station starts). A switch the listener moves themselves cancels the
/// put-back: their choice stands. The port of Android's `StationStore.setNoveltyForHost`; the state lives here so it is tested without a phone.
public struct HostNoveltyHold: Sendable, Equatable {
    /// The saved level while a chip holds another one; nil when no chip does.
    public private(set) var savedLevel: Int?

    public init(savedLevel: Int? = nil) { self.savedLevel = savedLevel }

    public var isHolding: Bool { savedLevel != nil }

    /// A chip asks for `level` while `current` is in force: remembers `current` the first time, and gives the level to use now.
    public mutating func hold(level: Int, current: Int) -> Int {
        if savedLevel == nil { savedLevel = current }
        return Novelty.clamp(level)
    }

    /// The level "Back to familiar" goes back to: the one saved before the chips, Blend when that was Discover or is not known (a harder
    /// Familiar they never chose is not what "back" means).
    public func levelBeforeHost(current: Int) -> Int {
        if let saved = savedLevel, saved != Novelty.discover { return saved }
        if current != Novelty.discover { return current }
        return Novelty.blend
    }

    /// The listening ended (or another station started): the level to put back, or nil when no chip held one. Forgets it.
    public mutating func release() -> Int? {
        defer { savedLevel = nil }
        return savedLevel
    }

    /// The listener moved the switch themselves: nothing is put back.
    public mutating func forget() { savedLevel = nil }
}

/// What the host says after a "More upbeat" / "Slower" / "Surprise me" chip: the number is what the steer really queued (a thin pool can
/// give fewer than five), never a count the host assumed.
public enum HostSteerReply: Sendable, Equatable {
    /// `count` songs (at least 1) were queued: the reply says that number.
    case queued(Int)
    /// Nothing was queued: the reply is `note` when the engine gave a reason, else the plain "could not change the queue".
    case nothing(note: String)

    public static func of(applied: Bool, tailChanged: Int, note: String) -> HostSteerReply {
        applied && tailChanged > 0 ? .queued(tailChanged) : .nothing(note: note)
    }
}
