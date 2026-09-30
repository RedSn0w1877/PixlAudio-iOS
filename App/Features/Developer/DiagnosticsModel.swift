import AVFoundation
import FoundationModels
import MediaPlayer
import Observation
import UIKit

/// Backs the Diagnostics screen: platform checks the owner can run on the phone once, before the big
/// build (architecture §7, stage 1). Each check is independent and reports a plain-text result.
@Observable
final class DiagnosticsModel {
    // MARK: Test tone (background audio + Now Playing + remote commands)

    private(set) var isTonePlaying = false
    private(set) var toneStatus = "Not started"

    // MARK: Keychain

    private(set) var keychainStatus = "Not run"

    // MARK: Folder bookmark

    var isFolderImporterPresented = false
    private(set) var folderStatus: String

    // MARK: Device

    private(set) var maxRefreshRate: Int?
    let proMotionKeyPresent: Bool
    let onDeviceModelStatus: String
    let systemVersion: String

    @ObservationIgnored private var player: AVQueuePlayer?
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var commandTargets: [(command: MPRemoteCommand, token: Any)] = []

    private static let bookmarkKey = "diagnostics.folderBookmark"
    private static let keychainAccount = "diagnostics.roundtrip"

    init() {
        folderStatus = UserDefaults.standard.data(forKey: Self.bookmarkKey) == nil
            ? "No folder saved"
            : "A folder bookmark is saved — tap Resolve"
        proMotionKeyPresent = Bundle.main.object(forInfoDictionaryKey: "CADisableMinimumFrameDurationOnPhone") as? Bool == true
        onDeviceModelStatus = Self.describeOnDeviceModel()
        systemVersion = UIDevice.current.systemVersion
    }

    // MARK: - Display

    /// Reads the maximum refresh rate of the screen hosting the app (120 on ProMotion iPhones).
    func refreshDisplayInfo() {
        let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first
        maxRefreshRate = scene?.screen.maximumFramesPerSecond
    }

    // MARK: - On-device model

    private static func describeOnDeviceModel() -> String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "Available"
        case .unavailable(.deviceNotEligible):
            return "Not supported on this device"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turned off in Settings"
        case .unavailable(.modelNotReady):
            return "Not ready yet (downloading)"
        case .unavailable:
            return "Unavailable"
        @unknown default:
            return "Unknown"
        }
    }

    // MARK: - Test tone

    func toggleTone() async {
        if isTonePlaying {
            stopTone()
        } else {
            await startTone()
        }
    }

    private func startTone() async {
        toneStatus = "Starting…"
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pixlaudio-test-tone.wav")
            if !FileManager.default.fileExists(atPath: url.path) {
                try await Task.detached(priority: .userInitiated) {
                    try TestToneWriter.write(to: url)
                }.value
            }

            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            try session.setActive(true)

            let queuePlayer = AVQueuePlayer()
            looper = AVPlayerLooper(player: queuePlayer, templateItem: AVPlayerItem(url: url))
            queuePlayer.play()
            player = queuePlayer

            isTonePlaying = true
            toneStatus = "Playing — lock the phone: it should keep playing and show Now Playing controls"
            installRemoteCommands()
            publishNowPlaying()
        } catch {
            toneStatus = "Failed: \(error.localizedDescription)"
        }
    }

    private func stopTone() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
        isTonePlaying = false
        removeRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        toneStatus = "Stopped"
    }

    private func pauseTone() {
        player?.pause()
        toneStatus = "Paused from remote command"
        publishNowPlaying()
    }

    private func resumeTone() {
        player?.play()
        toneStatus = "Playing (resumed from remote command)"
        publishNowPlaying()
    }

    private func toggleFromRemote() {
        if (player?.rate ?? 0) > 0 { pauseTone() } else { resumeTone() }
    }

    private func publishNowPlaying() {
        let isPlaying = (player?.rate ?? 0) > 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Test Tone",
            MPMediaItemPropertyArtist: "PixlAudio Diagnostics",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
    }

    private func installRemoteCommands() {
        removeRemoteCommands()
        let center = MPRemoteCommandCenter.shared()
        // Handlers arrive on the main queue; assumeIsolated keeps this correct whether or not the SDK
        // marks the handler closure @Sendable.
        let play = center.playCommand.addTarget { [weak self] (_: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus in
            MainActor.assumeIsolated { self?.resumeTone() }
            return .success
        }
        let pause = center.pauseCommand.addTarget { [weak self] (_: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus in
            MainActor.assumeIsolated { self?.pauseTone() }
            return .success
        }
        let toggle = center.togglePlayPauseCommand.addTarget { [weak self] (_: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus in
            MainActor.assumeIsolated { self?.toggleFromRemote() }
            return .success
        }
        commandTargets = [
            (center.playCommand, play),
            (center.pauseCommand, pause),
            (center.togglePlayPauseCommand, toggle),
        ]
    }

    private func removeRemoteCommands() {
        for target in commandTargets {
            target.command.removeTarget(target.token)
        }
        commandTargets = []
    }

    // MARK: - Keychain

    func runKeychainRoundTrip() {
        let payload = Data("pixlaudio-\(UUID().uuidString)".utf8)
        do {
            try KeychainStore.set(payload, for: Self.keychainAccount)
            let readBack = try KeychainStore.data(for: Self.keychainAccount)
            try KeychainStore.delete(account: Self.keychainAccount)
            let gone = try KeychainStore.data(for: Self.keychainAccount) == nil
            keychainStatus = (readBack == payload && gone)
                ? "Passed — wrote, read back, deleted"
                : "Failed — read back \(readBack?.count ?? 0) bytes, deleted: \(gone)"
        } catch {
            keychainStatus = "Failed: \(error)"
        }
    }

    // MARK: - Folder bookmark

    func handleFolderImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .failure(let error):
            folderStatus = "Picker failed: \(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else {
                folderStatus = "No folder chosen"
                return
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
                folderStatus = "Saved “\(url.lastPathComponent)” — relaunch the app, then tap Resolve"
            } catch {
                folderStatus = "Bookmark failed: \(error.localizedDescription)"
            }
        }
    }

    func resolveSavedFolder() {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
            folderStatus = "No folder saved"
            return
        }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if isStale {
                let refreshed = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(refreshed, forKey: Self.bookmarkKey)
            }
            let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            folderStatus = "Resolved “\(url.lastPathComponent)”: \(items.count) items"
                + (isStale ? " (bookmark was stale, refreshed)" : "")
                + (scoped ? "" : " — security scope not granted")
        } catch {
            folderStatus = "Resolve failed: \(error.localizedDescription)"
        }
    }

    func forgetSavedFolder() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        folderStatus = "No folder saved"
    }
}
