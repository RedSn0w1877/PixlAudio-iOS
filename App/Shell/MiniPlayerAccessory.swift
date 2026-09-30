import SwiftUI

/// Mini player shown in the tab view's bottom accessory.
///
/// `.expanded` (above the tab bar): artwork, title + artist, play/pause, next.
/// `.inline` (beside the minimized tab bar): smaller artwork, title, play/pause.
/// No custom glass here — the accessory is already glass. Nothing in it updates per second.
struct MiniPlayerAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(PlaybackStore.self) private var playback

    var body: some View {
        let isInline = placement == .inline
        if let song = playback.current {
            HStack(spacing: isInline ? 10 : 12) {
                ArtworkView(hue: song.hue, cornerRadius: isInline ? 6 : 8)
                    .frame(width: isInline ? 28 : 40, height: isInline ? 28 : 40)

                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title)
                        .font(isInline ? .footnote.weight(.semibold) : .subheadline.weight(.semibold))
                        .lineLimit(1)
                    if !isInline {
                        Text(song.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("miniPlayer.title")

                Button {
                    playback.togglePlayPause()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 36, height: 36)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

                if !isInline {
                    Button {
                        playback.skipToNext()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title3)
                            .frame(width: 36, height: 36)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Next")
                }
            }
            .padding(.leading, isInline ? 8 : 10)
            .padding(.trailing, 8)
            .accessibilityIdentifier("miniPlayer")
        }
    }
}
