import Foundation
import PixlLibrary

/// The remote half of the refresh's off switch (docs/brain-spec.md, 3.7 "Switches"). The app already fetches the repo's
/// `remote/config.json` (`RemoteClientConfigStore`, at most every six hours) and keeps the copy it got; this reads that
/// saved copy and never touches the network, so the refresh asks it for free and an offline phone is not held up. The
/// key is `brain.refresh.enabled`; a missing file or key means "on" (`BrainRemoteConfig.refreshAllowed`).
nonisolated enum BrainRemoteFlags {
    private static let maxBytes = 64 * 1024

    static func refreshAllowed() -> Bool {
        let file = YouTubeNetwork.supportDirectory().appendingPathComponent("remote-config.json")
        guard let data = try? Data(contentsOf: file), data.count < maxBytes else { return true }
        return BrainRemoteConfig.refreshAllowed(configText: String(decoding: data, as: UTF8.self))
    }
}
