import SwiftUI

/// Artists (Android `ArtistSettingsScreen`): the rescan banner when artist settings changed, "Multi-Artist
/// Parsing" (character delimiters, word delimiters, extract from title), "Library Organization" (group by album
/// artist), the info card and the examples card.
struct ArtistSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(LibraryStore.self) private var libraryStore
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme
    @State private var isResyncing = false

    var body: some View {
        let library = settings.library
        SettingsScaffold(title: L10n.settingsArtistsTitle, screenID: "artistSettings", horizontalPadding: 0) {
            if library.artistSettingsRescanRequired {
                rescanBanner
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            section(L10n.multiArtistParsingSection) {
                SettingsGroup {
                    SettingsItemRow(title: L10n.multiArtistCharDelimitersTitle,
                                    subtitle: L10n.multiArtistCharDelimitersSubtitle(library.artistDelimiters.joined(separator: ", ")),
                                    systemImage: "gearshape", showsChevron: true, identifier: "artist.delimiters") {
                        router.push(.delimiterConfig)
                    }
                    SettingsItemRow(title: L10n.multiArtistWordDelimitersTitle, subtitle: wordSubtitle(library.artistWordDelimiters),
                                    systemImage: "gearshape", showsChevron: true, identifier: "artist.wordDelimiters") {
                        router.push(.wordDelimiterConfig)
                    }
                    SwitchSettingRow(title: L10n.multiArtistExtractFromTitle, subtitle: L10n.multiArtistExtractFromSubtitle,
                                     isOn: Binding(get: { library.extractArtistsFromTitle }, set: {
                                         library.extractArtistsFromTitle = $0
                                         library.artistSettingsRescanRequired = true
                                     }), systemImage: "music.note.square.stack")
                }
            }
            section(L10n.libOrgSection) {
                SettingsGroup {
                    SwitchSettingRow(title: L10n.libOrgGroupByAlbumArtistTitle, subtitle: L10n.libOrgGroupByAlbumArtistSubtitle,
                                     isOn: Binding(get: { library.groupByAlbumArtist }, set: {
                                         library.groupByAlbumArtist = $0
                                         library.artistSettingsRescanRequired = true
                                     }), systemImage: "square.stack")
                }
            }
            infoCard
            examplesCard
        }
        .animation(PixlMotion.state, value: library.artistSettingsRescanRequired)
    }

    /// Android `SettingsSection`: a bold `labelMedium` caption 12 pt in, 16 / 8 pt padding.
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .pixlFont(.labelMedium, weight: .bold)
                .foregroundStyle(theme.primary)
                .padding(.leading, 12)
                .padding(.vertical, 8)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func wordSubtitle(_ words: [String]) -> String {
        guard !words.isEmpty else { return L10n.multiArtistWordDelimitersSubtitleNone }
        let preview = words.prefix(5).joined(separator: ", ") + (words.count > 5 ? "..." : "")
        return L10n.multiArtistWordDelimitersSubtitleCurrent(preview)
    }

    /// Android `RescanRequiredBanner`: `tertiaryContainer`, 16 pt corners, the rescan button in `tertiary`.
    private var rescanBanner: some View {
        HStack(spacing: 0) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(theme.onTertiaryContainer)
                .accessibilityHidden(true)
            Spacer().frame(width: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.multiArtistRescanBannerTitle).pixlFont(.titleSmall, weight: .bold)
                    .foregroundStyle(theme.onTertiaryContainer)
                Text(L10n.multiArtistRescanBannerBody).pixlFont(.bodySmall)
                    .foregroundStyle(theme.onTertiaryContainer.opacity(0.8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: 8)
            Button {
                Task {
                    isResyncing = true
                    try? await libraryStore.refresh(mode: .full)
                    settings.library.artistSettingsRescanRequired = false
                    isResyncing = false
                }
            } label: {
                HStack(spacing: 8) {
                    if isResyncing {
                        ProgressView().controlSize(.mini).tint(theme.onTertiary)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                    }
                    Text(isResyncing ? L10n.multiArtistStatusScanning : L10n.multiArtistActionRescan)
                        .pixlFont(.labelMedium)
                }
                .foregroundStyle(theme.onTertiary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(theme.tertiary, in: Capsule())
            }
            .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))
            .disabled(isResyncing)
            .accessibilityIdentifier("artist.rescan")
        }
        .padding(16)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                   tint: theme.tertiaryContainer.opacity(GlassTint.container))
    }

    /// Android `InfoCard`.
    private var infoCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle").font(.system(size: 20, weight: .medium)).foregroundStyle(theme.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.multiArtistInfoTitle).pixlFont(.titleSmall, weight: .bold)
                    .foregroundStyle(theme.onSecondaryContainer)
                Text(L10n.multiArtistInfoBody).pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSecondaryContainer.opacity(0.8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                   tint: theme.secondaryContainer.opacity(GlassTint.surface + 0.2))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Android `ExamplesCard`.
    private var examplesCard: some View {
        let examples = [(L10n.multiArtistEx1In, L10n.multiArtistEx1Out), (L10n.multiArtistEx2In, L10n.multiArtistEx2Out),
                        (L10n.multiArtistEx3In, L10n.multiArtistEx3Out), (L10n.multiArtistEx4In, L10n.multiArtistEx4Out),
                        (L10n.multiArtistEx5In, L10n.multiArtistEx5Out)]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "lightbulb").font(.system(size: 20, weight: .medium)).foregroundStyle(theme.tertiary)
                    .accessibilityHidden(true)
                Text(L10n.multiArtistExamplesTitle).pixlFont(.titleSmall, weight: .bold).foregroundStyle(theme.onSurface)
            }
            Spacer().frame(height: 12)
            ForEach(examples.indices, id: \.self) { i in
                HStack(spacing: 0) {
                    Text(L10n.multiArtistExampleBullet).pixlFont(.bodyMedium).foregroundStyle(theme.tertiary)
                        .padding(.trailing, 8)
                    Text(examples[i].0).pixlFont(.bodyMedium, weight: .medium).foregroundStyle(theme.onSurface)
                    Text(L10n.multiArtistExampleArrow).pixlFont(.bodyMedium).foregroundStyle(theme.onSurfaceVariant)
                    Text(examples[i].1).pixlFont(.bodyMedium).foregroundStyle(theme.primary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                   tint: theme.tertiaryContainer.opacity(GlassTint.surface))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
