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
