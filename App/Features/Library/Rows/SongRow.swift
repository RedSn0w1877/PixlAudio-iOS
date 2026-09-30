import SwiftUI

/// A song row. Content layer: plain row, no glass (CI forbids `glassEffect` in row files).
struct SongRow: View {
    let song: DemoSong
    @Environment(PlaybackStore.self) private var playback

    var body: some View {
        let isCurrent = playback.current?.id == song.id
        Button {
            playback.play(song)
        } label: {
            HStack(spacing: Tokens.Spacing.m) {
                ArtworkView(hue: song.hue)
                    .frame(width: Tokens.Artwork.rowSize, height: Tokens.Artwork.rowSize)

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.body)
                        .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                    Text(song.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isCurrent {
                    Image(systemName: "waveform")
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.variableColor.iterative, isActive: playback.isPlaying)
                        .accessibilityLabel("Now playing")
                } else {
                    Text(song.durationText)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {}
                .tint(.indigo)
        }
        .swipeActions(edge: .trailing) {
            Button("Add to Queue", systemImage: "text.badge.plus") {}
                .tint(.orange)
        }
        .contextMenu {
            Button("Play", systemImage: "play") { playback.play(song) }
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {}
            Button("Add to Queue", systemImage: "text.badge.plus") {}
            Button("Like", systemImage: "heart") {}
        }
    }
}
