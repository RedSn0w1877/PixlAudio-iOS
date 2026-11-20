import Foundation
import PixlLibrary

/// The remote half of the refresh's off switch (docs/brain-spec.md, 3.7 "Switches"). The app already fetches the repo's
/// `remote/config.json` (`RemoteClientConfigStore`, at most every six hours) and keeps the copy it got; this reads that
/// saved copy and never touches the network, so the refresh asks it for free and an offline phone is not held up. The
/// key is `brain.refresh.enabled`; a missing file or key means "on" (`BrainRemoteConfig.refreshAllowed`).
nonisolated enum BrainRemoteFlags {
    private static let maxBytes = 64 * 1024

    static func refreshAllowed() -> Bool {
        BrainRemoteConfig.refreshAllowed(configText: savedText())
    }

    /// False only when the saved remote config switches the open-data source `key` off (`brain.sources.<key>.enabled`).
    /// The owner can do that for every phone before charging anyone (docs/brain-spec.md, 15, question 2).
    static func sourceAllowed(_ key: String) -> Bool {
        BrainRemoteConfig.sourceAllowed(configText: savedText(), key: key)
    }

    /// False only when the saved remote config switches the optional assistant jobs off (`brain.assist.enabled`).
    static func assistAllowed() -> Bool {
        BrainRemoteConfig.assistAllowed(configText: savedText())
    }

    private static func savedText() -> String? {
        let file = YouTubeNetwork.supportDirectory().appendingPathComponent("remote-config.json")
        guard let data = try? Data(contentsOf: file), data.count < maxBytes else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
