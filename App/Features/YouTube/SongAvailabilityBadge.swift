import PixlModel
import SwiftUI

/// Android `EnhancedSongListItem.SongAvailabilityBadge`: a 16 pt icon after a streamed song's title block —
/// downloaded, downloading or failed (error colour). Local files show nothing. The Spotify "unmatched" state joins
/// in stage 12.
struct SongAvailabilityBadge: View {
    let kind: DownloadBadges.Kind
    let tint: Color

    @Environment(\.appTheme) private var theme

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(kind == .failed ? theme.error : tint.opacity(0.7))
            .frame(width: 16, height: 16)
            .padding(.leading, 8)
            .accessibilityLabel(label)
            .accessibilityIdentifier("songBadge.\(String(describing: kind))")
    }

    private var symbol: String {
        switch kind {
        case .downloaded: "arrow.down.circle.fill"
        case .downloading: "arrow.down.circle.dotted"
        case .failed: "exclamationmark.circle"
        }
    }

    private var label: String {
        switch kind {
        case .downloaded: "Downloaded — plays offline"
        case .downloading: "Downloading…"
        case .failed: "Download failed"
        }
    }
}
