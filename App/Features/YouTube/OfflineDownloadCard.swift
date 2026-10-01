import PixlModel
import SwiftUI

/// Android `OfflineDownloadCard` (song sheet): a streamed song's offline state with its action — Download,
/// Downloading… (with a percentage bar when the size is known), Remove download, Try again. Hidden for local files,
/// which already play offline. Android: a 10 dp `surfaceContainer` surface, 16 dp padding, 12 dp spacing.
struct OfflineDownloadCard: View {
    let song: Song

    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme

    var body: some View {
        if YouTubeSongIdentity.videoId(for: song) != nil {
            card(env.youtube.downloads.state(for: song))
        }
    }

    private func card(_ state: DownloadManager.State?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: icon(state))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isFailed(state) ? theme.error : theme.secondary)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Offline")
                        .pixlFont(.titleMedium)
                        .foregroundStyle(theme.onSurface)
                    Text(description(state))
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(isFailed(state) ? theme.error : theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if case .downloading(let percent) = state {
                if let percent {
                    ProgressView(value: Double(percent), total: 100)
                        .tint(theme.primary)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(theme.primary)
                }
            }
            YouTubeWideButton(title: actionTitle(state), tint: theme.secondaryContainer,
                              foreground: theme.onSecondaryContainer, enabled: !isDownloading(state), onGlass: true) {
                if state == .downloaded {
                    env.youtube.downloads.remove(song)
                } else {
                    env.youtube.downloads.download(song)
                }
            }
            .accessibilityIdentifier("songInfo.download")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                   tint: theme.surfaceContainer.opacity(GlassTint.surface))
    }

    private func isFailed(_ state: DownloadManager.State?) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func isDownloading(_ state: DownloadManager.State?) -> Bool {
        if case .downloading = state { return true }
        return false
    }

    private func icon(_ state: DownloadManager.State?) -> String {
        switch state {
        case .downloaded: "checkmark.icloud"
        case .downloading: "icloud.and.arrow.down"
        case .failed: "exclamationmark.circle"
        case nil: "icloud.and.arrow.down"
        }
    }

    private func description(_ state: DownloadManager.State?) -> String {
        switch state {
        case .downloaded: "Saved on your phone. It plays with no connection."
        case .downloading(let percent?): "Saving this song to your phone — \(percent)%"
        case .downloading(nil): "Saving this song to your phone…"
        case .failed(let reason): reason
        case nil: "Keep this song on your phone so it plays without a connection."
        }
    }

    private func actionTitle(_ state: DownloadManager.State?) -> String {
        switch state {
        case .downloaded: "Remove download"
        case .downloading: "Downloading…"
        case .failed: "Try again"
        case nil: "Download"
        }
    }
}
