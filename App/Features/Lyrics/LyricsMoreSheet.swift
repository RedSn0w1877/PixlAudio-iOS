import PixlLyrics
import PixlModel
import SwiftUI

/// What the More sheet can do (the lyrics screen supplies these; the route-level `LyricsOptionsSheet` a subset).
struct LyricsMoreActions {
    var onSyncYourself: (() -> Void)?
    var onSave: (() -> Void)?
    var onTranslate: (() -> Void)?
    /// Android's "Translate via AI" (stage 13's provider); `onTranslate` is the on-device translation.
    var onTranslateViaAI: (() -> Void)?
    var onReset: () -> Void
    var onToggleSyncControls: (() -> Void)?
    var onShuffle: () -> Void
    var onRepeat: () -> Void
    var onFavorite: () -> Void
}

/// The lyrics More sheet (Android `LyricsMoreBottomSheet`): Lyrics actions, Appearance (alignment), Controls
/// (sync offset, romanisation, translations, immersive once, keep screen on) and the shuffle / repeat / favourite row.
/// In the system sheet (glass), so its rows are fills — no glass on glass.
struct LyricsMoreSheet: View {
    let song: Song?
    let lyrics: Lyrics?
    let source: String?
    let showSyncedLyrics: Bool
    let isSyncControlsVisible: Bool
    let hasTranslatedLyrics: Bool
    let hasRomanizedLyrics: Bool
    let immersiveEnabled: Bool
    @Binding var immersiveTemporarilyDisabled: Bool
    @Bindable var preferences: LyricsViewPreferences
    let isShuffleEnabled: Bool
    let repeatMode: RepeatMode
    let isFavorite: Bool
    let actions: LyricsMoreActions

    @Environment(\.playerTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var showResetDialog = false
    @State private var showDebugDialog = false

    private var isUserSynced: Bool { lyrics?.document?.metadata.source == LyricsRepositoryLogic.userSource }
    private var hasWordTiming: Bool { lyrics?.synced?.contains { !($0.words ?? []).isEmpty } ?? false }
    private var itemFill: Color { theme.onSurface.opacity(0.08) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                lyricsGroup
                appearanceGroup
                controlsGroup
                Spacer().frame(height: 8)
                toggleRow
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("screen.lyricsOptions")
        .alert("Reset lyrics?", isPresented: $showResetDialog) {
            Button("Reset", role: .destructive) {
                dismiss()
                actions.onReset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(isUserSynced
                 ? "Are you sure you want to reset the lyrics for this song?\n\nThis also deletes the word timing you made."
                 : "Are you sure you want to reset the lyrics for this song?")
        }
        .alert("Where these lyrics came from", isPresented: $showDebugDialog) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: debugMessage)
        }
    }

    // MARK: Groups

    private var lyricsGroup: some View {
        VStack(alignment: .leading, spacing: 2) {
            caption("Lyrics")
            if let onSync = actions.onSyncYourself, song != nil {
                // The lyrics screen opens the editor from this sheet's onDismiss, once the sheet has gone.
                row(isUserSynced ? "Fix my word timing" : "Sync the words yourself",
                    subtitle: !isUserSynced && !hasWordTiming ? "Tap along so each word lights up" : nil,
                    systemImage: "hand.tap", accent: true, corners: (18, 8), identifier: "lyricsMore.syncYourself") {
                    onSync()
                    dismiss()
                }
            }
            if lyrics != nil, let onSave = actions.onSave {
                row("Save Lyrics", systemImage: "square.and.arrow.down",
                    corners: actions.onSyncYourself != nil && song != nil ? (8, 8) : (18, 8)) {
                    dismiss()
                    onSave()
                }
            }
            if lyrics != nil, let onTranslateViaAI = actions.onTranslateViaAI {
                row("Translate via AI", systemImage: "translate", corners: (8, 8)) {
                    dismiss()
                    onTranslateViaAI()
                }
            }
            if lyrics != nil, let onTranslate = actions.onTranslate {
                row("Translate on device", systemImage: "character.bubble", corners: (8, 8)) {
                    dismiss()
                    onTranslate()
                }
            }
            row("Reset imported lyrics", systemImage: "arrow.counterclockwise", corners: (8, 8)) {
                showResetDialog = true
            }
            row("Lyrics debug info", systemImage: "ladybug", corners: (8, 18)) {
                showDebugDialog = true
            }
        }
    }

    private var appearanceGroup: some View {
        VStack(alignment: .leading, spacing: 2) {
            caption("Appearance")
            VStack(alignment: .leading, spacing: 12) {
                Text("Alignment")
                    .pixlFont(.bodyLarge, weight: .medium)
                    .foregroundStyle(theme.onSurface)
                HStack(spacing: 8) {
                    alignmentButton("left", systemImage: "text.alignleft", label: "Align lyrics left")
                    alignmentButton("center", systemImage: "text.aligncenter", label: "Align lyrics center")
                    alignmentButton("right", systemImage: "text.alignright", label: "Align lyrics right")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(itemFill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    @ViewBuilder private var controlsGroup: some View {
        let syncVisible = showSyncedLyrics && actions.onToggleSyncControls != nil
        let immersiveVisible = showSyncedLyrics && immersiveEnabled
        VStack(alignment: .leading, spacing: 2) {
            caption("Controls")
            if syncVisible, let toggle = actions.onToggleSyncControls {
                row(isSyncControlsVisible ? "Hide sync controls" : "Adjust sync", systemImage: "slider.horizontal.3",
                    corners: (18, 8)) {
                    dismiss()
                    toggle()
                }
            }
            if hasRomanizedLyrics {
                switchRow("Show romanization", systemImage: "character.textbox", isOn: $preferences.showRomanization,
                          corners: (syncVisible ? 8 : 18, 8))
            }
            if hasTranslatedLyrics {
                switchRow("Show translations", systemImage: "translate", isOn: $preferences.showTranslation,
                          corners: (syncVisible || hasRomanizedLyrics ? 8 : 18, 8))
            }
            if immersiveVisible {
                switchRow("Disable immersive (once)", systemImage: "eye.slash", isOn: $immersiveTemporarilyDisabled,
                          corners: (8, 8))
            }
            switchRow("Keep screen on", systemImage: "sun.max", isOn: $preferences.keepScreenOn,
                      corners: (syncVisible || hasRomanizedLyrics || hasTranslatedLyrics || immersiveVisible ? 8 : 18, 24))
        }
    }

    /// Shuffle · Repeat · Favourite (Android `BottomToggleRow`, 74 pt, 60 pt corners).
    private var toggleRow: some View {
        HStack(spacing: 8) {
            toggle(active: isShuffleEnabled, systemImage: "shuffle", label: "Shuffle", color: theme.primary,
                   onColor: theme.onPrimary, action: actions.onShuffle)
            toggle(active: repeatMode != .off, systemImage: repeatMode == .one ? "repeat.1" : "repeat", label: "Repeat",
                   color: theme.secondary, onColor: theme.onSecondary, action: actions.onRepeat)
            toggle(active: isFavorite, systemImage: isFavorite ? "heart.fill" : "heart", label: "Favorite",
                   color: theme.tertiary, onColor: theme.onTertiary, action: actions.onFavorite)
        }
        .padding(8)
        .frame(height: 74)
        .background(theme.surfaceContainer.opacity(0.6), in: RoundedRectangle(cornerRadius: 60, style: .continuous))
        .padding(.horizontal, 20)
    }

    // MARK: Pieces

    private func caption(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .pixlFont(.bodyLarge, weight: .semibold)
            .foregroundStyle(theme.primary)
            .padding(.leading, 6)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private func shape(_ corners: (CGFloat, CGFloat)) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: corners.0, bottomLeadingRadius: corners.1,
                               bottomTrailingRadius: corners.1, topTrailingRadius: corners.0, style: .continuous)
    }

    /// `identifier` is an optional id for UI tests: the row's label joins its title and subtitle, so a label query is
    /// fragile.
    @ViewBuilder
    private func row(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, systemImage: String,
                     accent: Bool = false, corners: (CGFloat, CGFloat), identifier: String? = nil,
                     action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(accent ? theme.primary : theme.onSurface)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .pixlFont(.bodyLarge)
                        .foregroundStyle(theme.onSurface)
                    if let subtitle {
                        Text(subtitle)
                            .pixlFont(.bodyMedium)
                            .foregroundStyle(theme.onSurface.opacity(0.7))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(itemFill, in: shape(corners))
            .contentShape(shape(corners))
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.98))
        if let identifier {
            button.accessibilityIdentifier(identifier)
        } else {
            button
        }
    }

    private func switchRow(_ title: LocalizedStringKey, systemImage: String, isOn: Binding<Bool>,
                           corners: (CGFloat, CGFloat)) -> some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(theme.onSurface)
                .frame(width: 24)
            Toggle(isOn: isOn) {
                Text(title)
                    .pixlFont(.bodyLarge)
                    .foregroundStyle(theme.onSurface)
            }
            .tint(theme.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(itemFill, in: shape(corners))
    }

    private func alignmentButton(_ value: String, systemImage: String, label: LocalizedStringKey) -> some View {
        let active = preferences.alignment == value
        let shape = RoundedRectangle(cornerRadius: active ? 24 : 8, style: .continuous)
        return Button {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { preferences.alignment = value }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(active ? theme.onPrimary : theme.onSurface.opacity(0.78))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(active ? theme.primary : theme.surfaceContainerLow, in: shape)
                .contentShape(shape)
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func toggle(active: Bool, systemImage: String, label: LocalizedStringKey, color: Color, onColor: Color,
                        action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: active ? 60 : 8, style: .continuous)
        return Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(active ? onColor : theme.onSurfaceVariant)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(active ? color : theme.surfaceContainerHighest, in: shape)
                .contentShape(shape)
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: active)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var debugMessage: String {
        guard let lyrics else { return "No lyrics loaded for this song." }
        let synced = lyrics.synced ?? []
        let sourceLine = lyrics.document?.metadata.source ?? source
            ?? (lyrics.areFromRemote ? "Remote catalog" : "Local file / embedded / cache")
        if synced.isEmpty {
            if (lyrics.plain ?? []).isEmpty { return "Source: \(sourceLine)\nNo lyrics content at all." }
            return "Source: \(sourceLine)\nPlain text only — no timestamps, so no highlighting is possible."
        }
        let wordSynced = synced.filter { !($0.words ?? []).isEmpty }.count
        var text = "Source: \(sourceLine)\nSynced lines: \(synced.count)\nWord-synced lines: \(wordSynced) of \(synced.count)"
        if wordSynced == 0 {
            text += "\n\nNo word-level timing in this file."
            text += lyrics.areFromRemote
                ? " This catalog record has line timing only. Other recordings may include real word timing; resync checks available catalogs again."
                : " This file doesn't include per-word tags."
        }
        return text
    }
}
