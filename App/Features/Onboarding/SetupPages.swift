import SwiftUI

// The setup's pages. Each one is a `SetupPageScroll` (so it scrolls on small phones and at big text sizes) of a hero,
// a title, glass content and staggered reveals. The bottom button and the progress live in `SetupView`.

// MARK: - Welcome

/// The first page: the logo, "Welcome to PixlAudio", the welcome illustration in a glass-rimmed frame with three
/// floating chips, and one line of intro.
struct SetupWelcomePage: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        SetupPageScroll { compact in
            VStack(spacing: compact ? 12 : 20) {
                SetupLogo(size: compact ? 64 : 92)
                    .setupReveal(0)
                titles(compact: compact)
                    .setupReveal(1)
                SetupWelcomeArtCard(maxHeight: compact ? 150 : 260)
                    .setupReveal(2)
                Text(L10n.setupIntroBody)
                    .pixlFont(.bodyLarge)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .setupReveal(3)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
    }

    private func titles(compact: Bool) -> some View {
        VStack(spacing: 2) {
            Text(L10n.setupWelcomePrefix.trimmingCharacters(in: .whitespaces))
                .pixlFont(.custom(size: compact ? 22 : 26, weight: .semibold, lineHeight: 32))
                .foregroundStyle(theme.onSurfaceVariant)
            Text(L10n.appName)
                .pixlFont(.custom(size: compact ? 42 : 52, weight: .heavy, lineHeight: compact ? 48 : 58))
                .foregroundStyle(theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            HStack(spacing: 6) {
                Text(L10n.setupBetaSymbol).pixlFont(.labelLarge, weight: .black)
                Text(L10n.setupBetaLabel).pixlFont(.labelLarge, weight: .semibold)
            }
            .foregroundStyle(theme.onSurface)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .pixlGlass(in: Capsule(), tint: theme.surface.opacity(GlassTint.surface))
            .padding(.top, 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The app icon, breathing slowly over a soft coloured glow.
private struct SetupLogo: View {
    let size: CGFloat
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let still = SetupMotion.isStill(reduceMotion: reduceMotion)
        logo
            .phaseAnimator(still ? [false] : [false, true]) { view, big in
                view.scaleEffect(big ? 1.04 : 1)
            } animation: { _ in
                Animation.easeInOut(duration: 2.6)
            }
    }

    private var logo: some View {
        BrandMark()
            .frame(width: size, height: size)
            .shadow(color: theme.primary.opacity(0.35), radius: 22, y: 10)
    }
}

/// The welcome illustration (the 16-path vector in the palette's colours) with its two sine waves, framed by a
/// hairline rim, and three glass chips floating over its corners.
private struct SetupWelcomeArtCard: View {
    let maxHeight: CGFloat
    @Environment(\.appTheme) private var theme

    var body: some View {
        art
            .aspectRatio(1536.0 / 1024.0, contentMode: .fit)
            .frame(maxWidth: maxHeight * 1536.0 / 1024.0)
            .overlay(alignment: .topLeading) {
                SetupFloatingChip(symbol: "music.note", color: theme.primary, period: 2.4)
                    .offset(x: -8, y: -14)
            }
            .overlay(alignment: .topTrailing) {
                SetupFloatingChip(symbol: "heart.fill", color: theme.tertiary, period: 2.9)
                    .offset(x: 8, y: 18)
            }
            .overlay(alignment: .bottomTrailing) {
                SetupFloatingChip(symbol: "waveform", color: theme.secondary, period: 3.3)
                    .offset(x: 6, y: 16)
            }
            .accessibilityHidden(true)
    }

    private var art: some View {
        ZStack(alignment: .bottom) {
            WelcomeArt()
            HomeSineWaveLine(color: theme.surface.opacity(0.95), amplitude: 4, lineWidth: 16)
                .frame(height: 32)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            theme.surface
                .frame(height: 22)
            HomeSineWaveLine(color: theme.primary.opacity(0.95), amplitude: 4, lineWidth: 4)
                .frame(height: 32)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.05), .white.opacity(0.25)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        }
    }
}

/// A glass circle with one symbol that bobs gently up and down.
private struct SetupFloatingChip: View {
    let symbol: String
    let color: Color
    let period: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let still = SetupMotion.isStill(reduceMotion: reduceMotion)
        chip
            .phaseAnimator(still ? [false] : [false, true]) { view, up in
                view.offset(y: up ? -7 : 7)
            } animation: { _ in
                Animation.easeInOut(duration: period)
            }
    }

    private var chip: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(color)
            .symbolEffect(.variableColor.iterative, isActive: symbol == "waveform" && !SetupMotion.isStill(reduceMotion: reduceMotion))
            .frame(width: 46, height: 46)
            .pixlGlass(in: Circle(), tint: color.opacity(0.18))
    }
}

// MARK: - Spotify

/// Connect Spotify: what you get, the green sign-in button (it turns into "Spotify connected").
struct SetupSpotifyPage: View {
    let isLoggedIn: Bool
    let onSignIn: () -> Void
    @Environment(\.appTheme) private var theme

    /// The Spotify brand green.
    static let spotifyGreen = Color(argb: 0xFF1DB954)

    var body: some View {
        SetupPageScroll { compact in
            VStack(spacing: compact ? 14 : 20) {
                SetupHero(symbol: isLoggedIn ? "checkmark" : "music.note.house.fill", size: compact ? 52 : 88)
                    .setupReveal(0)
                SetupPageHeader(title: L10n.setupSpotifyTitle, subtitle: L10n.setupSpotifyDescription)
                    .setupReveal(1)
                perks
                    .setupReveal(2)
                    .setupScrollFade()
                VStack(spacing: 10) {
                    SetupFilledButton(title: isLoggedIn ? L10n.setupSpotifyConnected : L10n.setupSpotifyButton,
                                      systemImage: isLoggedIn ? "checkmark" : "music.note", kind: .spotify,
                                      action: signInTapped)
                        .allowsHitTesting(!isLoggedIn)
                        .accessibilityIdentifier("setup.spotify")
                    if !isLoggedIn {
                        SetupFootnote(text: L10n.setupSpotifyLater)
                    }
                }
                .setupReveal(3)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .animation(PixlMotion.state, value: isLoggedIn)
        }
    }

    private func signInTapped() {
        if !isLoggedIn { onSignIn() }
    }

    private var perks: some View {
        VStack(alignment: .leading, spacing: 14) {
            perk("heart.fill", L10n.setupSpotifyPerkLiked)
            perk("music.note.list", L10n.setupSpotifyPerkPlaylists)
            perk("sparkles", L10n.setupSpotifyPerkMixes)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .setupGlassCard()
        .accessibilityElement(children: .combine)
    }

    private func perk(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.onSecondaryContainer)
                .frame(width: 36, height: 36)
                .background(theme.secondaryContainer, in: Circle())
            Text(text)
                .pixlFont(.bodyLarge, weight: .medium)
                .foregroundStyle(theme.onSurface)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Backup

/// Restore a backup: what a backup holds, the import button and a card while the file is being checked.
struct SetupBackupPage: View {
    let isInspecting: Bool
    let isRestoring: Bool
    let onImport: () -> Void
    @Environment(\.appTheme) private var theme

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 10)]

    var body: some View {
        let isBusy = isInspecting || isRestoring
        SetupPageScroll { compact in
            VStack(spacing: compact ? 14 : 20) {
                SetupHero(symbol: "arrow.down.doc.fill", size: compact ? 52 : 88)
                    .setupReveal(0)
                SetupPageHeader(title: L10n.setupBackupHaveTitle, subtitle: L10n.setupBackupHaveDescription)
                    .setupReveal(1)
                LazyVGrid(columns: columns, spacing: 10) {
                    chip("music.note.list", L10n.setupBackupChipPlaylists)
                    chip("gearshape.fill", L10n.setupBackupChipSettings)
                    chip("quote.bubble.fill", L10n.setupBackupChipLyrics)
                    chip("chart.line.uptrend.xyaxis", L10n.setupBackupChipStats)
                }
                .setupReveal(2)
                .setupScrollFade()
                if isInspecting {
                    HStack(spacing: 12) {
                        ProgressView().tint(theme.primary)
                        Text(L10n.setupCheckingBackup)
                            .pixlFont(.bodyMedium)
                            .foregroundStyle(theme.onSurfaceVariant)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .setupGlassCard(cornerRadius: 20, tint: theme.surfaceContainerHigh.opacity(GlassTint.container))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                SetupFilledButton(title: buttonTitle, systemImage: "square.and.arrow.down", isEnabled: !isBusy,
                                  action: onImport)
                    .accessibilityIdentifier("setup.import")
                    .setupReveal(3)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .animation(PixlMotion.state, value: isBusy)
        }
    }

    private var buttonTitle: String {
        if isInspecting { return L10n.setupInspectingBackup }
        if isRestoring { return L10n.setupRestoringBackup }
        return L10n.setupImportBackup
    }

    private func chip(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.primary)
                .frame(width: 24)
            Text(title)
                .pixlFont(.labelLarge)
                .foregroundStyle(theme.onSurface)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .setupGlassCard(cornerRadius: 20)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Theme

/// Pick the look: three glass cards with a little preview of each, and a ring that slides to the one you tap.
struct SetupThemePage: View {
    let selected: AppThemeMode
    let onSelect: (AppThemeMode) -> Void
    @Environment(\.appTheme) private var theme
    @Namespace private var ring

    private struct Option: Identifiable {
        let mode: AppThemeMode
        let title: String
        let description: String
        var recommended = false
        var id: String { mode.rawValue }
    }

    private var options: [Option] {
        [Option(mode: .dark, title: L10n.setupThemeDarkTitle, description: L10n.setupThemeDarkDescription,
                recommended: true),
         Option(mode: .light, title: L10n.setupThemeLightTitle, description: L10n.setupThemeLightDescription),
         Option(mode: .followSystem, title: L10n.setupThemeFollowTitle, description: L10n.setupThemeFollowDescription)]
    }

    var body: some View {
        SetupPageScroll { compact in
            VStack(spacing: compact ? 14 : 20) {
                SetupPageHeader(title: L10n.setupThemeTitle, subtitle: L10n.setupThemeSubtitle)
                    .setupReveal(0)
                VStack(spacing: 12) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                        card(option)
                            .setupReveal(index + 1)
                            .setupScrollFade()
                    }
                }
                SetupFootnote(text: L10n.setupThemeFooter)
                    .setupReveal(4)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .pixlHaptic(.selection, trigger: selected)
        }
    }

    private func traits(_ isSelected: Bool) -> AccessibilityTraits {
        if isSelected { return [.isButton, .isSelected] }
        return .isButton
    }

    private func card(_ option: Option) -> some View {
        let isSelected = selected == option.mode
        return Button { onSelect(option.mode) } label: {
            HStack(spacing: 16) {
                SetupThemeSwatch(mode: option.mode)
                VStack(alignment: .leading, spacing: 6) {
                    Text(option.title)
                        .pixlFont(.titleMedium, weight: .bold)
                        .foregroundStyle(theme.onSurface)
                    if option.recommended {
                        Text(L10n.setupRecommended)
                            .pixlFont(.labelSmall, weight: .semibold)
                            .foregroundStyle(isSelected ? theme.onPrimary : theme.onPrimaryContainer)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(isSelected ? theme.primary : theme.primaryContainer, in: Capsule())
                    }
                    Text(option.description)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(isSelected ? theme.primary : theme.onSurfaceVariant.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
        .setupGlassCard(cornerRadius: 26,
                        tint: isSelected ? theme.primaryContainer.opacity(GlassTint.container)
                            : theme.surfaceContainer.opacity(SettingsTint.row),
                        interactive: true)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(theme.primary, lineWidth: 2.5)
                    .matchedGeometryEffect(id: "ring", in: ring)
                    .allowsHitTesting(false)
            }
        }
        .animation(PixlMotion.selection, value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(traits(isSelected))
        .accessibilityIdentifier("setup.theme.\(option.mode.rawValue)")
    }
}

/// A tiny phone screen in the mode's colours: two text lines and a mini player bar. "Match my phone" is split in two.
private struct SetupThemeSwatch: View {
    let mode: AppThemeMode
    @Environment(\.appTheme) private var theme

    var body: some View {
        Group {
            switch mode {
            case .dark:
                scene(dark: true)
            case .light:
                scene(dark: false)
            default:
                scene(dark: false)
                    .overlay {
                        scene(dark: true)
                            .mask { HStack(spacing: 0) { Color.clear; Color.black } }
                    }
            }
        }
        .frame(width: 56, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(theme.onSurface.opacity(0.2), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private func scene(dark: Bool) -> some View {
        let ink = dark ? Color.white : Color.black
        return ZStack(alignment: .topLeading) {
            Color(argb: dark ? 0xFF14121A : 0xFFFBF8FF)
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(ink.opacity(0.7)).frame(width: 28, height: 5)
                Capsule().fill(ink.opacity(0.25)).frame(width: 40, height: 4)
                Capsule().fill(ink.opacity(0.25)).frame(width: 34, height: 4)
            }
            .padding(.leading, 8)
            .padding(.top, 10)
            Capsule()
                .fill(theme.primary)
                .frame(height: 12)
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 6)
        }
    }
}

// MARK: - Library layout

/// Choose the library header: a live preview that switches between the tab row and the compact pill, and a glass
/// two-way picker whose highlight slides.
struct SetupLibraryLayoutPage: View {
    let isCompact: Bool
    let onChange: (Bool) -> Void
    @Environment(\.appTheme) private var theme
    @Namespace private var pick

    var body: some View {
        SetupPageScroll { compact in
            VStack(spacing: compact ? 14 : 20) {
                SetupPageHeader(title: L10n.setupLibraryLayoutTitle, subtitle: L10n.setupLibraryLayoutSubtitle)
                    .setupReveal(0)
                SetupLibraryHeaderPreview(isCompact: isCompact, height: compact ? 140 : 180)
                    .setupReveal(1)
                    .accessibilityHidden(true)
                picker
                    .setupReveal(2)
                Text(isCompact ? L10n.setupCompactModePillHint : L10n.setupCompactModeTabHint)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .animation(PixlMotion.state, value: isCompact)
                    .setupReveal(3)
                SetupFootnote(text: L10n.setupLibraryLayoutFooter)
                    .setupReveal(4)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .pixlHaptic(.selection, trigger: isCompact)
        }
    }

    private var picker: some View {
        HStack(spacing: 4) {
            option(L10n.setupLayoutTabs, symbol: "rectangle.split.3x1.fill", compactValue: false)
            option(L10n.setupLayoutPill, symbol: "capsule.fill", compactValue: true)
        }
        .padding(4)
        .pixlGlass(in: Capsule(), tint: theme.surfaceContainer.opacity(SettingsTint.row))
    }

    private func option(_ title: String, symbol: String, compactValue: Bool) -> some View {
        let isSelected = isCompact == compactValue
        return Button { onChange(compactValue) } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                Text(title).pixlFont(.labelLarge).lineLimit(1)
            }
            .foregroundStyle(isSelected ? theme.onPrimary : theme.onSurface)
            .frame(maxWidth: .infinity, minHeight: 46)
            .contentShape(Capsule())
            .background {
                if isSelected {
                    Capsule().fill(theme.primary).matchedGeometryEffect(id: "selection", in: pick)
                }
            }
        }
        .buttonStyle(.plain)
        .animation(PixlMotion.selection, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(compactValue ? "setup.layout.pill" : "setup.layout.tabs")
    }
}

/// The library header as a glass card: either the "Library" title over three tab chips, or the compact pill.
private struct SetupLibraryHeaderPreview: View {
    let isCompact: Bool
    let height: CGFloat
    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [theme.primaryContainer.opacity(0.5), theme.primaryContainer.opacity(0.2), .clear],
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
        .frame(height: height, alignment: .topLeading)
        .clipShape(shape)
        .glassEffect(Glass.regular.tint(theme.surface.opacity(GlassTint.surface)), in: shape)
        .animation(PixlMotion.state, value: isCompact)
    }

    private var standard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.settingsDefaultTabLibrary)
                .pixlFont(.custom(size: 38, weight: .heavy, tracking: 1))
                .foregroundStyle(theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
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
                .lineLimit(1)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(theme.surfaceContainerLowest, in: Capsule())
            Capsule()
                .fill(selected ? theme.primary : .clear)
                .frame(width: 20, height: 3)
        }
    }

    /// The compact pill: the title half (rounded left, tight right) and the arrow half, 4 pt apart.
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

// MARK: - Finish

/// The last page: a ring that draws itself around a check, and a recap of what was picked.
struct SetupFinishPage: View {
    let isSpotifyLinked: Bool
    let themeTitle: String
    let layoutTitle: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        SetupPageScroll { compact in
            VStack(spacing: compact ? 14 : 22) {
                SetupSuccessMark(size: compact ? 112 : 148)
                    .setupReveal(0)
                SetupPageHeader(title: L10n.setupAllSetTitle, subtitle: L10n.setupAllSetBody)
                    .setupReveal(1)
                VStack(spacing: 0) {
                    row(L10n.setupRecapSpotify, isSpotifyLinked ? L10n.setupRecapConnected : L10n.setupRecapNotYet)
                    divider
                    row(L10n.setupRecapLook, themeTitle)
                    divider
                    row(L10n.setupRecapLibrary, layoutTitle)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .setupGlassCard()
                .setupReveal(2)
                .setupScrollFade()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
    }

    private var divider: some View {
        Rectangle().fill(theme.onSurface.opacity(0.1)).frame(height: 1)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .pixlFont(.bodyLarge)
                .foregroundStyle(theme.onSurfaceVariant)
            Spacer(minLength: 8)
            Text(value)
                .pixlFont(.bodyLarge, weight: .semibold)
                .foregroundStyle(theme.onSurface)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}

/// A glass disc with a ring that draws around a check, which hops once when the ring closes.
private struct SetupSuccessMark: View {
    let size: CGFloat
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        ZStack {
            Circle().stroke(theme.primary.opacity(0.18), lineWidth: 8)
            Circle()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(theme.primary, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(theme.primary)
                .symbolEffect(.bounce, options: .nonRepeating, value: drawn)
        }
        .padding(18)
        .frame(width: size, height: size)
        .pixlGlass(in: Circle(), tint: theme.primaryContainer.opacity(GlassTint.container))
        .accessibilityHidden(true)
        .task {
            if reduceMotion || LaunchConfiguration.current.isUITest {
                drawn = true
            } else {
                try? await Task.sleep(for: .milliseconds(250))
                withAnimation(.easeInOut(duration: 0.9)) { drawn = true }
            }
        }
    }
}
