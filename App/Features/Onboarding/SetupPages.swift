import SwiftUI

// The setup pages, ported from Android `SetupScreen.kt` (same order of elements, sizes and text styles).

/// Android `WelcomePage`: "Welcome to" (42 pt) over "PixlAudio" (46 pt, `primary`), the β Beta chip, the 240 pt
/// welcome art with its two sine waves, and the intro line.
struct SetupWelcomePage: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.setupWelcomePrefix.trimmingCharacters(in: .whitespaces))
                    .pixlFont(.custom(size: 42, weight: .bold, lineHeight: 46))
                    .foregroundStyle(theme.onSurface)
                Text(L10n.appName)
                    .pixlFont(.custom(size: 46, weight: .bold, lineHeight: 51))
                    .foregroundStyle(theme.primary)
            }
            .padding(.horizontal, 8)
            .padding(.top, 12)
            Spacer(minLength: 10)
            HStack(spacing: 6) {
                Text(L10n.setupBetaSymbol).pixlFont(.labelLarge, weight: .black)
                Text(L10n.setupBetaLabel).pixlFont(.labelLarge, weight: .semibold)
            }
            .foregroundStyle(theme.onSurface)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .pixlGlass(in: Capsule(), tint: theme.surface.opacity(GlassTint.surface))
            Spacer(minLength: 16)
            ZStack(alignment: .bottom) {
                WelcomeArt()
                HomeSineWaveLine(color: theme.surface.opacity(0.95), amplitude: 4, lineWidth: 16)
                    .frame(height: 32)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                theme.surface
                    .frame(height: 22)
                    .padding(.bottom, 0)
                HomeSineWaveLine(color: theme.primary.opacity(0.95), amplitude: 4, lineWidth: 4)
                    .frame(height: 32)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            Spacer(minLength: 16)
            Text(L10n.setupIntroBody)
                .pixlFont(.bodyLarge)
                .foregroundStyle(theme.onSurface)
                .multilineTextAlignment(.center)
        }
        .frame(maxHeight: .infinity)
        .padding(16)
    }
}

/// Android `MediaPermissionPage` → the music library (`MPMediaLibrary`). Not a gate on iOS: the library holds only
/// downloaded DRM-free songs, and folders work without it.
struct SetupMediaPermissionPage: View {
    let status: SetupView.MediaStatus
    let onGrant: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        SetupPermissionPage(title: L10n.setupPermissionMediaTitle, granted: status == .granted,
                            description: L10n.setupPermissionMediaDescription,
                            buttonText: status == .granted ? L10n.setupPermissionGranted : L10n.setupGrantMediaPermission,
                            icons: ["music.note", "opticaldisc", "music.note.house", "music.mic", "play.square.stack"],
                            buttonEnabled: status != .granted, onGrant: onGrant) {
            if status == .denied {
                Text(L10n.setupPermissionDeniedHint)
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// Android `DirectorySelectionPage` → picking music folders (`LibraryImporting` bookmarks). Android scans all of
/// storage and lets you exclude folders; iOS sees only the app's own folder plus the folders you add.
struct SetupMusicFoldersPage: View {
    let folders: [String]
    let onChoose: () -> Void
    let onSkip: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        SetupPermissionPage(title: L10n.setupMusicFoldersTitle, description: L10n.setupMusicFoldersDescription,
                            buttonText: L10n.setupChooseFolders,
                            icons: ["folder", "music.note", "folder.badge.plus", "folder.fill", "waveform"],
                            onGrant: onChoose) {
            if !folders.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.setupFoldersAdded(folders.count))
                        .pixlFont(.titleSmall, weight: .semibold)
                        .foregroundStyle(theme.primary)
                    ForEach(folders, id: \.self) { name in
                        Label(name, systemImage: "folder.fill")
                            .pixlFont(.bodyMedium)
                            .foregroundStyle(theme.onSurface)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .pixlGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                           tint: theme.surfaceContainerHigh.opacity(GlassTint.container))
                .padding(.bottom, 8)
            }
            SetupTextButton(title: L10n.setupSkipForNow, action: onSkip)
        }
    }
}

/// Android `BackupRestorePage`: import a backup, with the "checking" / progress card above "Skip / Not now". iOS
/// reads the library first (the backup's songs are matched against it), showing the scan in the same card.
struct SetupBackupPage: View {
    let isInspecting: Bool
    let isRestoring: Bool
    let isScanning: Bool
    let onImport: () -> Void
    let onSkip: () -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(\.appTheme) private var theme

    var body: some View {
        // The scan's progress is read here, not by SetupView: each tick re-runs this page only, not the pager.
        let scanProgress = library.lastImportProgress
        let isBusy = isInspecting || isRestoring || isScanning
        SetupPermissionPage(title: L10n.setupBackupHaveTitle, description: L10n.setupBackupHaveDescription,
                            buttonText: isInspecting ? L10n.setupInspectingBackup
                                : isRestoring ? L10n.setupRestoringBackup : L10n.setupImportBackup,
                            icons: ["doc.badge.arrow.up", "music.note.list", "gearshape", "quote.bubble",
                                    "chart.line.uptrend.xyaxis"],
                            buttonEnabled: !isBusy, onGrant: onImport) {
            if isInspecting || isScanning {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        ProgressView().tint(theme.primary)
                        Text(isInspecting ? L10n.setupCheckingBackup : L10n.setupScanningLibrary)
                            .pixlFont(.bodyMedium)
                            .foregroundStyle(theme.onSurfaceVariant)
                    }
                    if isScanning, let scanProgress, scanProgress.total > 0 {
                        Text(scanProgress.phase)
                            .pixlFont(.titleSmall, weight: .semibold)
                            .foregroundStyle(theme.onSurface)
                        ProgressView(value: scanProgress.fraction)
                            .tint(theme.primary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .pixlGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                           tint: theme.surfaceContainerHigh.opacity(GlassTint.container))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            SetupTextButton(title: L10n.setupSkipForNow, isEnabled: !isRestoring, action: onSkip)
        }
        .animation(PixlMotion.state, value: isBusy)
    }
}

/// Android `ThemeSelectionPage`: title and subtitle, the three option cards (Dark — recommended —, Light, Follow
/// system) and the footer.
struct SetupThemePage: View {
    let selected: AppThemeMode
    let onSelect: (AppThemeMode) -> Void
    @Environment(\.appTheme) private var theme

    private struct Option: Identifiable {
        let mode: AppThemeMode
        let title: String
        let description: String
        let symbol: String
        var recommended = false
        var id: String { mode.rawValue }
    }

    private var options: [Option] {
        [Option(mode: .dark, title: L10n.setupThemeDarkTitle, description: L10n.setupThemeDarkDescription,
                symbol: "moon.fill", recommended: true),
         Option(mode: .light, title: L10n.setupThemeLightTitle, description: L10n.setupThemeLightDescription,
                symbol: "sun.max"),
         Option(mode: .followSystem, title: L10n.setupThemeFollowTitle, description: L10n.setupThemeFollowDescription,
                symbol: "iphone")]
    }

    var body: some View {
        VStack(spacing: 0) {
            SetupPageHeader(title: L10n.setupThemeTitle, subtitle: L10n.setupThemeSubtitle, topSpacing: 12)
            Spacer(minLength: 16)
            VStack(spacing: 10) {
                ForEach(options) { option in
                    SetupThemeOptionCard(title: option.title, description: option.description, symbol: option.symbol,
                                         recommended: option.recommended, isSelected: selected == option.mode) {
                        onSelect(option.mode)
                    }
                }
                Text(L10n.setupThemeFooter)
                    .pixlFont(.labelMedium)
                    .foregroundStyle(theme.onSurfaceVariant.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
        .padding(24)
    }
}

/// Android `ThemeModeOptionCard`: 24 pt corners (`primaryContainer` 70 % when selected, else `surfaceContainer`),
/// the 46 pt icon tile (16 pt corners), title, the "Recommended" pill, description, and the 28 pt selection dot.
private struct SetupThemeOptionCard: View {
    let title: String
    let description: String
    let symbol: String
    let recommended: Bool
    let isSelected: Bool
    let onTap: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(isSelected ? theme.onPrimary : theme.onSecondaryContainer)
                    .frame(width: 46, height: 46)
                    .background(isSelected ? theme.primary : theme.secondaryContainer,
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).pixlFont(.titleMedium, weight: .bold).foregroundStyle(theme.onSurface)
                    if recommended {
                        Text(L10n.setupRecommended)
                            .pixlFont(.labelSmall, weight: .semibold)
                            .foregroundStyle(isSelected ? theme.onPrimary : theme.onPrimaryContainer)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(isSelected ? theme.primary : theme.primaryContainer, in: Capsule())
                    }
                    Text(description)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ZStack {
                    Circle().fill(isSelected ? theme.primary : theme.surfaceContainerHighest)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(theme.onPrimary)
                    } else {
                        Circle().fill(theme.onSurfaceVariant.opacity(0.35)).frame(width: 8, height: 8)
                    }
                }
                .frame(width: 28, height: 28)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous),
                   tint: isSelected ? theme.primaryContainer.opacity(GlassTint.container)
                       : theme.surfaceContainer.opacity(SettingsTint.row),
                   interactive: true)
        .animation(PixlMotion.state, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Android `LibraryLayoutPage`: title and subtitle, the library-header preview (standard tab row or the compact
/// pill), the "Compact Mode" card with its switch, and the footer.
struct SetupLibraryLayoutPage: View {
    let isCompact: Bool
    let onChange: (Bool) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            SetupPageHeader(title: L10n.setupLibraryLayoutTitle, subtitle: L10n.setupLibraryLayoutSubtitle)
            SetupLibraryHeaderPreview(isCompact: isCompact)
                .frame(maxHeight: .infinity)
            VStack(spacing: 0) {
                Button { onChange(!isCompact) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(L10n.setupCompactMode)
                                .pixlFont(.titleMedium, weight: .bold)
                                .foregroundStyle(theme.onSurface)
                            Text(isCompact ? L10n.setupCompactModePillHint : L10n.setupCompactModeTabHint)
                                .pixlFont(.bodyMedium)
                                .foregroundStyle(theme.onSurfaceVariant)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Toggle(L10n.setupCompactMode, isOn: Binding(get: { isCompact }, set: onChange))
                            .labelsHidden()
                            .tint(theme.primary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                .buttonStyle(.plain)
                .pixlGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous),
                           tint: theme.surfaceContainer.opacity(SettingsTint.row), interactive: true)
                Spacer().frame(height: 16)
                Text(L10n.setupLibraryLayoutFooter)
                    .pixlFont(.labelMedium)
                    .foregroundStyle(theme.onSurfaceVariant.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                Spacer().frame(height: 24)
            }
        }
        .padding(24)
    }
}

/// Android `LibraryHeaderPreview`: a card with 24 pt top corners, 180 pt tall, a `primaryContainer` gradient
/// (50 % → 25 % → clear), showing either the "Library" title over three tab chips or the compact pill.
private struct SetupLibraryHeaderPreview: View {
    let isCompact: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                                           topTrailingRadius: 24, style: .continuous)
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [theme.primaryContainer.opacity(0.5), theme.primaryContainer.opacity(0.25), .clear],
                           startPoint: .top, endPoint: .bottom)
            if isCompact {
                compactPill
                    .padding(.top, 24)
                    .padding(.leading, 16)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else {
                standard
                    .padding(.top, 24)
                    .padding(.horizontal, 20)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
        .clipShape(shape)
        .glassEffect(Glass.regular.tint(theme.surface.opacity(GlassTint.surface)), in: shape)
        .animation(PixlMotion.state, value: isCompact)
    }

    private var standard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.settingsDefaultTabLibrary)
                .pixlFont(.custom(size: 40, weight: .heavy, tracking: 1))
                .foregroundStyle(theme.primary)
            HStack(spacing: 6) {
                tab(L10n.setupTabSongs, selected: true)
                tab(L10n.setupTabAlbums, selected: false)
                tab(L10n.setupTabArtists, selected: false)
            }
        }
    }

    private func tab(_ title: String, selected: Bool) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .pixlFont(.custom(size: 13, weight: selected ? .bold : .medium))
                .foregroundStyle(selected ? theme.primary : theme.onSurfaceVariant)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(theme.surfaceContainerLowest, in: Capsule())
            Capsule()
                .fill(selected ? theme.primary : .clear)
                .frame(width: 20, height: 3)
        }
    }

    /// Android `LibraryNavigationPillSetupShow`: the title half (26 pt left corners, 4 pt right) and the arrow half
    /// (4 pt left corners, 26 pt right), both `primaryContainer`, 4 pt apart.
    private var compactPill: some View {
        HStack(spacing: 4) {
            HStack(spacing: 12) {
                Image(systemName: "music.note").font(.system(size: 20, weight: .medium))
                Text(L10n.setupPreviewSongsLabel).pixlFont(.custom(size: 26, weight: .semibold))
            }
            .foregroundStyle(theme.onPrimaryContainer)
            .padding(.vertical, 10)
            .padding(.leading, 18)
            .padding(.trailing, 14)
            .frame(maxHeight: .infinity)
            .background(theme.primaryContainer,
                        in: UnevenRoundedRectangle(topLeadingRadius: 26, bottomLeadingRadius: 26, bottomTrailingRadius: 4,
                                                   topTrailingRadius: 4, style: .continuous))
            Image(systemName: "chevron.down")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.onPrimaryContainer)
                .frame(width: 36)
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity)
                .background(theme.primaryContainer,
                            in: UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4, bottomTrailingRadius: 26,
                                                       topTrailingRadius: 26, style: .continuous))
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 4)
    }
}

/// Android `SpotifyLinkPage`: title and description, the collage, the "reach out" card, the bouncing arrow with
/// "Tap the button below" (until signed in), the Spotify-green sign-in button and "Skip / Not now".
struct SetupSpotifyPage: View {
    let isLoggedIn: Bool
    let onSignIn: () -> Void
    let onSkip: () -> Void
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @State private var arrowDown = false

    /// Android `SpotifyBrandGreen`.
    static let spotifyGreen = Color(argb: 0xFF1DB954)
    /// The hint's green under Increase Contrast in light mode: Spotify green is about 2.5:1 on the light background.
    static let spotifyGreenHighContrast = Color(argb: 0xFF117A3D)

    private var hintGreen: Color {
        contrast == .increased && colorScheme == .light ? Self.spotifyGreenHighContrast : Self.spotifyGreen
    }

    var body: some View {
        VStack(spacing: 0) {
            SetupPageHeader(title: L10n.setupSpotifyTitle, subtitle: L10n.setupSpotifyDescription)
            SetupIconCollage(icons: ["music.note", "heart.fill", "music.note.list", "music.note.house", "opticaldisc"])
                .frame(maxHeight: 200)
                .frame(maxHeight: .infinity)
            VStack(spacing: 0) {
                Text(L10n.setupSpotifyReachOut)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSecondaryContainer)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .pixlGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                               tint: theme.secondaryContainer.opacity(GlassTint.container))
                Spacer().frame(height: 14)
                if !isLoggedIn {
                    Text(L10n.setupSpotifyArrowHint)
                        .pixlFont(.labelLarge)
                        .foregroundStyle(hintGreen)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Self.spotifyGreen)
                        .frame(width: 42, height: 42)
                        .offset(y: arrowDown ? 14 : 0)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.75).repeatForever(autoreverses: true),
                                   value: arrowDown)
                        .onAppear { arrowDown = true }
                        .accessibilityLabel(L10n.setupSpotifyCdArrow)
                }
                Spacer().frame(height: 4)
                SetupFilledButton(title: isLoggedIn ? L10n.setupSpotifyConnected : L10n.setupSpotifyButton,
                                  systemImage: isLoggedIn ? "checkmark" : "music.note", isEnabled: !isLoggedIn,
                                  tint: Self.spotifyGreen, foreground: .black, action: onSignIn)
                    .accessibilityIdentifier("setup.spotify")
                SetupTextButton(title: L10n.setupSkipForNow, action: onSkip)
                Spacer().frame(height: 8)
            }
        }
        .padding(24)
    }
}

/// Android `FinishPage`: "All Set!" (`headlineLarge`), the 230 pt collage and the closing line, centred.
struct SetupFinishPage: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 16) {
            Text(L10n.setupAllSetTitle)
                .pixlFont(.headlineLarge)
                .foregroundStyle(theme.onSurface)
            SetupIconCollage(icons: ["checkmark.circle", "heart.fill", "party.popper", "heart.fill", "sparkles"])
                .frame(height: 230)
            Text(L10n.setupAllSetBody)
                .pixlFont(.bodyLarge)
                .foregroundStyle(theme.onSurface)
                .multilineTextAlignment(.center)
        }
        .frame(maxHeight: .infinity)
        .padding(16)
    }
}
