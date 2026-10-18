import PixlModel
import SwiftUI

/// The quick actions a long press on the full player's artwork or on the mini player offers (Settings › Behavior ›
/// Gestures): add to playlist, share, go to the artist. A context menu (the system's), so it needs no drag and cannot
/// fight scrolling or the sheet; the add-to-playlist sheet is presented from the view the menu is attached to.
struct SongQuickActionsModifier: ViewModifier {
    let song: Song
    var isEnabled: Bool

    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var showsAddToPlaylist = false

    func body(content: Content) -> some View {
        Group {
            if isEnabled && !voiceOver {
                content.contextMenu { menuItems }
            } else {
                content
            }
        }
        .sheet(isPresented: $showsAddToPlaylist) {
            AddToPlaylistSheet(songIds: [song.id])
                .pixlSheet(detents: [.large])
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Add to playlist", systemImage: "text.badge.plus") { showsAddToPlaylist = true }
        if let url = SongQuickActions.shareURL(song) {
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
        }
        ForEach(SongQuickActions.artists(of: song).prefix(3), id: \.id) { artist in
            Button("Go to \(artist.name)", systemImage: "music.mic") { openArtist(artist.id) }
        }
    }

    /// Collapse the player first when it is up, then push the artist (as the player's own artist line does).
    private func openArtist(_ artistId: Int64) {
        let router = self.router
        if env.playerSheet.isExpanded {
            env.playerSheet.collapse { router.push(.artistDetail(artistId: artistId)) }
        } else {
            router.push(.artistDetail(artistId: artistId))
        }
    }
}

enum SongQuickActions {
    /// What to share: the song's file when it is a local one, else its Spotify link.
    static func shareURL(_ song: Song) -> URL? {
        if let file = SongFiles.shareURL(song) { return file }
        guard let id = song.spotifyId, !id.isEmpty else { return nil }
        return URL(string: "https://open.spotify.com/track/\(id)")
    }

    static func artists(of song: Song) -> [ArtistRef] {
        song.artists.isEmpty ? [song.primaryArtist] : song.artists
    }
}

extension View {
    /// Long press for the quick actions menu (add to playlist, share, go to the artist).
    func songQuickActions(song: Song, isEnabled: Bool) -> some View {
        modifier(SongQuickActionsModifier(song: song, isEnabled: isEnabled))
    }
}

// MARK: - Heart burst

/// The double-tap-to-like effect: a heart (or a slashed one for unlike) that pops over the artwork and fades.
struct HeartBurst: View {
    /// Bumped for every burst; `isLike` says which heart to draw.
    let trigger: Int
    let isLike: Bool

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var shown = 0

    var body: some View {
        Image(systemName: isLike ? "heart.fill" : "heart.slash.fill")
            .font(.system(size: 96, weight: .bold))
            .foregroundStyle(isLike ? theme.primary : theme.onSurfaceVariant)
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            .scaleEffect(visible ? 1.0 : (reduceMotion ? 1.0 : 0.4))
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: trigger) { _, newValue in
                guard newValue != shown else { return }
                shown = newValue
                withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) { visible = true }
                Task {
                    try? await Task.sleep(for: .milliseconds(520))
                    withAnimation(.easeOut(duration: 0.28)) { visible = false }
                }
            }
    }
}

/// The small glass hint that names the swipe that just changed the song ("Next" / "Previous").
struct SwipeHint: View {
    let direction: SwipeDirection

    @Environment(\.playerTheme) private var theme

    var body: some View {
        Label(direction == .left ? "Next" : "Previous",
              systemImage: direction == .left ? "forward.end.fill" : "backward.end.fill")
            .pixlFont(.labelLarge, weight: .semibold)
            .foregroundStyle(theme.primary)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .glassEffect(Glass.clear.tint(theme.onPrimary.opacity(GlassTint.playerChrome)), in: Capsule())
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
