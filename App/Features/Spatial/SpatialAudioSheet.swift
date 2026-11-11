import PixlModel
import SwiftUI

/// Spatial audio's sheet (cloud audio spec 6.5), Android's `SpatialAudioSheet` in the same layout and order: the header
/// ("Spatial audio" / "For headphones."), "This song" (Spatial audio on or off for the playing song, while a profile is
/// selected; Hoa, 2026-11-11), the status line for the current song, Off and the six profiles with their
/// one-liners, and under the list the quiet line about level. Picking a row applies at once (`env.spatial.select`; the
/// player and the cloud side follow the stored value) and the sheet stays open, so profiles can be compared by ear.
///
/// Opened from the full player it takes the album's colours, as Android's does (`LocalMaterialTheme` there); from
/// Settings the app's. The sheet wraps its content like Android's `skipPartiallyExpanded` sheet (`fittedSheetDetent`).
/// Liquid Glass: each row is one glass shape in one container (Android's grouped list: 24 pt outer corners, 6 pt inner,
/// the selected row rounds fully and takes `secondaryContainer`), the status line a tinted glass card.
struct SpatialAudioSheet: View {
    /// Opened from the full player (album colours) rather than from Settings (the app's).
    var fromPlayer: Bool

    @Environment(\.appTheme) private var appTheme
    @Environment(\.playerTheme) private var playerTheme

    var body: some View {
        SpatialAudioSheetContent()
            .environment(\.appTheme, fromPlayer ? playerTheme : appTheme)
    }
}

private struct SpatialAudioSheetContent: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The natural height of the content (nil until the first layout pass): the sheet's detent.
    @State private var contentHeight: CGFloat?

    var body: some View {
        // A height measured on an earlier open (same text size, with or without a status line and the "This song"
        // card) opens the sheet at its final size instead of re-targeting the detent mid-presentation.
        let hasLine = env.spatial.statusLine != SpatialStatusLine.none
        let showsSong = env.spatial.showsThisSong
        let key = "spatial.sheet|\(dynamicTypeSize)|\(hasLine)|\(showsSong)"
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SpatialSheetHeader()
                    .padding(.horizontal, 8)
                    .padding(.bottom, 16)
                SpatialThisSongSlot()
                SpatialStatusCard()
                SpatialChoiceList()
                Text(L10n.spatialQuieterNote)
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.top, 14)
                    .accessibilityIdentifier("spatialAudio.levelNote")
            }
            .padding(.horizontal, 16)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .measuringHeight($contentHeight, rememberedAs: key)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: .infinity, alignment: .top)
        .fittedSheetDetent(contentHeight ?? FittedSheetHeights.values[key])
        .accessibilityIdentifier("screen.spatialAudio")
    }
}

/// The feature's icon in a filled circle, the title and "For headphones." (Android `SpatialSheetHeader`).
private struct SpatialSheetHeader: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: SpatialAudioUI.symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(theme.onPrimaryContainer)
                .frame(width: 44, height: 44)
                .pixlGlass(in: Circle(), tint: theme.primaryContainer.opacity(GlassTint.prominent))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.spatialAudio)
                    .pixlFont(.headlineSmall, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.spatialForHeadphones)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Where "This song" goes: the card while a profile is selected and a song with a Spotify id plays, else nothing (with
/// Spatial audio off every song plays its original anyway). It fades in and out and the sheet's height follows.
private struct SpatialThisSongSlot: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let shows = env.spatial.showsThisSong
        ZStack(alignment: .top) {
            if shows {
                SpatialThisSongCard()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(PixlMotion.state, value: shows)
    }
}

/// "This song" (Hoa, 2026-11-11; Android's `SpatialThisSongCard`, same words and layout): Spatial audio on or off for
/// the song that plays, remembered for every later play of it (`spatial.songsOff`). Off, the song plays its original at
/// full quality: no on-device stage, no cloud render, nothing asked of the cloud for it.
///
/// The whole card is the switch (one glass shape, interactive, like the rows below it); the `Toggle` inside only shows
/// the state. On, the icon fills with `primary` and the glass takes `primaryContainer`; off, both go neutral. The line
/// under the title crossfades. Nothing here is per frame: it redraws when the switch or the song changes.
private struct SpatialThisSongCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme

    private static let corner: CGFloat = 24

    var body: some View {
        let spatial = env.spatial
        let isOn = spatial.isOnForCurrentSong
        let line = isOn ? L10n.spatialThisSongOn : L10n.spatialThisSongOff
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        Button {
            withAnimation(PixlMotion.state) { spatial.setOnForCurrentSong(!isOn) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: SpatialAudioUI.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isOn ? theme.onPrimary : theme.onSurfaceVariant)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(isOn ? theme.primary : theme.surfaceContainerHighest))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.spatialThisSong)
                        .pixlFont(.titleMedium, weight: .semibold)
                        .foregroundStyle(isOn ? theme.onPrimaryContainer : theme.onSurface)
                    ZStack(alignment: .topLeading) {
                        Text(line)
                            .pixlFont(.bodyMedium)
                            .foregroundStyle(isOn ? theme.onPrimaryContainer.opacity(0.8) : theme.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                            .id(isOn)
                            .transition(.opacity)
                    }
                    .animation(.easeInOut(duration: 0.22), value: isOn)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Shows the state only: the card is what is tapped.
                Toggle(L10n.spatialThisSong, isOn: .constant(isOn))
                    .labelsHidden()
                    .tint(theme.primary)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .padding(.leading, 16)
            .padding(.trailing, 16)
            .padding(.vertical, 14)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: shape,
                   tint: isOn ? theme.primaryContainer.opacity(GlassTint.container)
                              : theme.surfaceContainerHigh.opacity(SettingsTint.row),
                   interactive: true)
        .pixlHaptic(.selection, trigger: isOn)
        // One element, the button: "This song", the line as its value, a switch that is on or off.
        .accessibilityLabel(L10n.spatialThisSong)
        .accessibilityValue(line)
        .accessibilityAddTraits(.isToggle)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("spatialAudio.thisSong")
        .padding(.bottom, 12)
    }
}

/// The status line for the current song (spec 6.5), or nothing for `none`. A change crossfades and the card's height
/// follows; VoiceOver reads the new line (Android: a polite live region).
private struct SpatialStatusCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme

    var body: some View {
        let line = env.spatial.statusLine
        ZStack(alignment: .top) {
            if let text = SpatialAudioUI.statusText(line) {
                card(line: line, text: text)
                    .id(line)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.22), value: line)
        .onChange(of: line) { _, new in
            if let text = SpatialAudioUI.statusText(new) { PixlAccessibility.announce(text) }
        }
    }

    private func card(line: SpatialStatusLine, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: SpatialAudioUI.statusSymbol(line))
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            Text(text)
                .pixlFont(.bodyMedium)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(theme.onSecondaryContainer)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                   tint: theme.secondaryContainer.opacity(GlassTint.prominent))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("spatialAudio.status")
        .padding(.bottom, 12)
    }
}

/// Off and the six profiles (Android: one selectable group of seven rows, 2 pt apart).
private struct SpatialChoiceList: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let selected = env.spatial.selection
        let choices = SpatialAudioUI.choices(selected: selected)
        let last = choices.count - 1
        // The rows' glass shapes render together; spacing 0 is below the 2 pt gap, so they never blend at rest.
        GlassEffectContainer(spacing: 0) {
            VStack(spacing: 2) {
                ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                    SpatialChoiceRow(choice: choice, isFirst: index == 0, isLast: index == last) {
                        select(choice)
                    }
                }
            }
        }
        .animation(PixlMotion.selection, value: selected)
        .pixlHaptic(.selection, trigger: selected)
    }

    private func select(_ choice: SpatialChoice) {
        guard !choice.isSelected else { return }
        env.spatial.select(choice.selection)
    }
}

/// One row: the name over its one-liner, and a check that scales in on the selected row. The selected row takes
/// `secondaryContainer` and full corners; the others keep the tight inner corners of a grouped list.
private struct SpatialChoiceRow: View {
    let choice: SpatialChoice
    let isFirst: Bool
    let isLast: Bool
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let outerCorner: CGFloat = 24
    private static let innerCorner: CGFloat = 6

    var body: some View {
        let selected = choice.isSelected
        let top = selected || isFirst ? Self.outerCorner : Self.innerCorner
        let bottom = selected || isLast ? Self.outerCorner : Self.innerCorner
        let shape = UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                           bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous)
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.name)
                        .pixlFont(.titleMedium)
                        .foregroundStyle(theme.onSurface)
                    Text(choice.line)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "checkmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.onSecondaryContainer)
                    .frame(width: 24, height: 24)
                    // Reduce Motion: the check fades in place instead of growing.
                    .scaleEffect(selected || reduceMotion ? 1 : 0.4)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.leading, 20)
            .padding(.trailing, 16)
            .padding(.vertical, 14)
            .frame(minHeight: 72)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: shape,
                   tint: selected ? theme.secondaryContainer.opacity(GlassTint.prominent)
                                  : theme.surfaceContainerHigh.opacity(SettingsTint.row),
                   interactive: true)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("spatialAudio.choice.\(choice.id)")
    }
}
