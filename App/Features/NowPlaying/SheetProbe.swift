import SwiftUI

/// EXPERIMENT ONLY: the full player's last evaluated play state against the store's.
enum SheetProbe {
    static var evaluated: (isPlaying: Bool, count: Int) = (false, 0)
    static func markNowPlaying(_ playing: Bool) { evaluated = (playing, evaluated.count + 1) }
}

/// EXPERIMENT ONLY: refreshed twice a second; "STALE" when the full player last rendered another play state.
struct SheetProbeLabel: View {
    @Environment(PlaybackStore.self) private var playback

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let stale = SheetProbe.evaluated.count > 0 && SheetProbe.evaluated.isPlaying != playback.isPlaying
            Text("probe")
                .font(.system(size: 2))
                .opacity(0.01)
                .accessibilityIdentifier("debug.sheet")
                .accessibilityLabel((stale ? "STALE" : "OK") + " store=\(playback.isPlaying) "
                                    + "evaluated=\(SheetProbe.evaluated.isPlaying) n=\(SheetProbe.evaluated.count)")
        }
        .allowsHitTesting(false)
    }
}
