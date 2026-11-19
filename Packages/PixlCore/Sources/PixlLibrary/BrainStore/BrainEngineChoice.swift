import Foundation
// `BrainSwitch.engine` (docs/brain-spec.md, 2.1, 14 stage 2): which engine ranks Daily Mix and Your Mix. `brain` is the
// default; `legacy` is the old scorer, byte for byte what it was. The listener never sees the choice: the owner flips
// it under Developer mode to compare. A port of Android's `BrainEngineChoice.kt`.

/// Which engine ranks the mixes.
public enum BrainEngineChoice {
    public static let legacy = 0
    public static let brain = 1

    public static func clamp(_ value: Int) -> Int { value == legacy ? legacy : brain }

    /// The brain has something to rank by once the listener has played a few different tracks. With none it would
    /// serve the library in the order of a coin toss, and the legacy mixes (which read the library's own engagement
    /// counters) are the better start: "falling back to legacy when no state exists at all" (14, stage 2; 5.14).
    public static let minHeardTracks = 10

    public static func hasState(heardTracks: Int) -> Bool { heardTracks >= minHeardTracks }

    /// True when the brain scorer builds the mixes: it is switched on and has state to rank by.
    public static func useBrain(engine: Int, hasState: Bool) -> Bool { clamp(engine) == brain && hasState }
}

/// The remote half of the refresh's off switch (docs/brain-spec.md, 3.7 "Switches"). The app already fetches the
/// repo's `remote/config.json` (one switch file for both apps) and keeps the copy it got; this reads that saved copy
/// and never touches the network. The key is `brain.refresh.enabled`; a missing file, a missing key or text that is
/// not JSON all mean "on", because a switch that is off by accident would silently disable the feature.
///
///     {"brain": {"refresh": {"enabled": false}}}
public enum BrainRemoteConfig {
    /// False only when `configText` says the refresh is off.
    public static func refreshAllowed(configText: String?) -> Bool {
        guard let configText, !configText.isEmpty,
              let root = (try? JSONSerialization.jsonObject(with: Data(configText.utf8))) as? [String: Any],
              let brain = root["brain"] as? [String: Any],
              let refresh = brain["refresh"] as? [String: Any],
              let enabled = refresh["enabled"] as? Bool else { return true }
        return enabled
    }

    /// False only when `configText` says `{"brain": {"sources": {"<key>": {"enabled": false}}}}` for that source. The
    /// owner can switch a knowledge source off for every phone before charging anyone (docs/brain-spec.md, 15, question 2).
    /// A missing file, a missing key or text that is not JSON means "on".
    public static func sourceAllowed(configText: String?, key: String) -> Bool {
        guard let configText, !configText.isEmpty,
              let root = (try? JSONSerialization.jsonObject(with: Data(configText.utf8))) as? [String: Any],
              let brain = root["brain"] as? [String: Any],
              let sources = brain["sources"] as? [String: Any],
              let source = sources[key] as? [String: Any],
              let enabled = source["enabled"] as? Bool else { return true }
        return enabled
    }
}
