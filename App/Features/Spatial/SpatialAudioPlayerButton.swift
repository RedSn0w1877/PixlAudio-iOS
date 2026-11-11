import PixlModel
import SwiftUI

/// The full player's Spatial audio button (cloud audio spec 6.5: "a Spatial audio entry in the full player"), the third
/// circle after Lyrics and Ask Taizo in the song row, where the Android player has it (`SpatialAudioPlayerButton.kt`,
/// branch `audio-ui`). It reads its own two facts (the selected profile and what holds it back), so a pick redraws this
/// button only, never the player around it. A tap opens the Spatial audio sheet over the player.
struct SpatialAudioPlayerButton: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router

    var body: some View {
        let spatial = env.spatial
        SpatialAudioButtonContent(ui: SpatialButtonUI.of(selection: spatial.selection,
                                                         blockedBy: spatial.snapshot.blockedBy)) {
            router.present(AppSheet.spatialAudio(fromPlayer: true))
        }
    }
}

/// The button itself (Android `SpatialAudioButtonContent`), drawn from `ui` alone.
///
/// Off: a 48 pt clear-glass circle in the player's chrome tint, like its neighbours, with "Off" under the icon. On: the
/// glass fills with `primary` and the content turns `onPrimary` (Android's selected look), the corners tighten (24 → 16
/// pt) and the profile's name takes the place of "Off", the button widening for it, at most 104 pt ("Concert Hall"
/// fits; a longer name truncates rather than squeeze the song title). Held back: the name stays, the fill goes. One
/// interruptible spring moves fill, corners and width; nothing is computed per frame.
struct SpatialAudioButtonContent: View {
    let ui: SpatialButtonUI
    let action: () -> Void

    @Environment(\.playerTheme) private var theme

    /// Android: 48 dp tall, at most 104 dp wide with 6 dp of padding each side, a 20 dp icon over `labelSmall`.
    private static let size: CGFloat = 48
    private static let labelMaxWidth: CGFloat = 92

    var body: some View {
        let emphasized = ui.isEmphasized
        let shape = RoundedRectangle(cornerRadius: emphasized ? 16 : 24, style: .continuous)
        Button(action: action) {
            VStack(spacing: 0) {
                Image(systemName: SpatialAudioUI.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(height: 22)
                Text(ui.label)
                    .pixlFont(.labelSmall)
                    .lineLimit(1)
                    .frame(maxWidth: Self.labelMaxWidth)
            }
            .foregroundStyle(emphasized ? theme.onPrimary : theme.primary)
            .padding(.horizontal, 6)
            .frame(minWidth: Self.size, minHeight: Self.size, maxHeight: Self.size)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        // Hugs its label: the song title keeps every point the button doesn't need.
        .fixedSize(horizontal: true, vertical: false)
        .playerGlass(in: shape, tint: emphasized ? theme.primary.opacity(GlassTint.prominent)
                                                 : theme.onPrimary.opacity(GlassTint.playerChrome))
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: ui)
        .accessibilityLabel(L10n.spatialAudio)
        .accessibilityValue(ui.accessibilityValue)
        .accessibilityIdentifier("player.spatialAudio")
    }
}
