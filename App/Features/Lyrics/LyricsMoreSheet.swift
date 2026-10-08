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
/// (sync offset, romanisation, translations, show as plain text, immersive once) and the shuffle / repeat / favourite
/// row. The lyrics screen presents it at half height, where iOS draws the sheet as floating Liquid Glass (owner,
/// 2026-10-07: "0 liquid glass"); its rows stay soft fills on that glass (no glass on glass), while the alignment
/// picker (the liquid lens, `LiquidTabCapsule`) and the shuffle / repeat / favourite row (`PlayerToggleRow`) are
/// liquid. "Keep screen on" is gone: the lyrics screen always keeps it on.
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
    /// "Show as plain text" for this song (the lyrics screen's override of the automatic synced / plain choice); nil
    /// where the sheet isn't over the lyrics screen (`LyricsOptionsSheet`).
    var plainText: Binding<Bool>?

    @Environment(\.playerTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStore.self) private var library
    @State private var showResetDialog = false
    @State private var showDebugDialog = false

    /// The favourite as the library has it now, read in this sheet's own body (`observedSong`: the library's song
    /// lookup is not observed, so the presenter's `isFavorite` stayed stale after a tap); `isFavorite` when the song
    /// isn't in the library.
    private var liked: Bool { song.flatMap { library.observedSong(id: $0.id)?.isFavorite } ?? isFavorite }

    private var isUserSynced: Bool { lyrics?.document?.metadata.source == LyricsRepositoryLogic.userSource }
    private var hasWordTiming: Bool { lyrics?.synced?.contains { !($0.words ?? []).isEmpty } ?? false }
    private var hasSyncedLines: Bool { !(lyrics?.synced ?? []).isEmpty }
    private var itemFill: Color { theme.onSurface.opacity(0.08) }

    /// The lyrics alignment on the liquid lens (Android's three alignment buttons).
    private static let alignmentTabs: [LiquidTabCapsule<String>.Tab] = [
        .init(value: "left", title: "Left", systemImage: "text.alignleft", identifier: "lyrics.align.left"),
        .init(value: "center", title: "Center", systemImage: "text.aligncenter", identifier: "lyrics.align.center"),
        .init(value: "right", title: "Right", systemImage: "text.alignright", identifier: "lyrics.align.right"),
    ]

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
            rowGroup(bottomRadius: 18) {
                if let onSync = actions.onSyncYourself, song != nil {
                    // The lyrics screen opens the editor from this sheet's onDismiss, once the sheet has gone.
                    row(isUserSynced ? "Fix my word timing" : "Sync the words yourself",
                        subtitle: !isUserSynced && !hasWordTiming ? "Tap along so each word lights up" : nil,
                        systemImage: "hand.tap", accent: true, identifier: "lyricsMore.syncYourself") {
                        onSync()
                        dismiss()
                    }
                }
                if lyrics != nil, let onSave = actions.onSave {
                    row("Save Lyrics", systemImage: "square.and.arrow.down") {
                        dismiss()
                        onSave()
                    }
                }
                if lyrics != nil, let onTranslateViaAI = actions.onTranslateViaAI {
                    row("Translate via AI", systemImage: "translate") {
                        dismiss()
                        onTranslateViaAI()
                    }
                }
                if lyrics != nil, let onTranslate = actions.onTranslate {
                    row("Translate on device", systemImage: "character.bubble") {
                        dismiss()
                        onTranslate()
                    }
                }
                row("Reset imported lyrics", systemImage: "arrow.counterclockwise") {
                    showResetDialog = true
                }
                row("Lyrics debug info", systemImage: "ladybug") {
                    showDebugDialog = true
                }
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
                // The lens reads the app palette; this sheet is in the player's (album colours), also where the
                // route-level copy opens over the app.
                LiquidTabCapsule(tabs: Self.alignmentTabs, selection: $preferences.alignment)
                    .environment(\.appTheme, theme)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(itemFill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    @ViewBuilder private var controlsGroup: some View {
        let syncVisible = showSyncedLyrics && actions.onToggleSyncControls != nil
        let plainVisible = plainText != nil && hasSyncedLines
        let immersiveVisible = showSyncedLyrics && immersiveEnabled
        if syncVisible || hasRomanizedLyrics || hasTranslatedLyrics || plainVisible || immersiveVisible {
            VStack(alignment: .leading, spacing: 2) {
                caption("Controls")
                rowGroup(bottomRadius: 24) {
                    if syncVisible, let toggle = actions.onToggleSyncControls {
                        row(isSyncControlsVisible ? "Hide sync controls" : "Adjust sync",
                            systemImage: "slider.horizontal.3") {
                            dismiss()
                            toggle()
                        }
                    }
                    if hasRomanizedLyrics {
                        switchRow("Show romanization", systemImage: "character.textbox",
                                  isOn: $preferences.showRomanization)
                    }
                    if hasTranslatedLyrics {
                        switchRow("Show translations", systemImage: "translate", isOn: $preferences.showTranslation)
                    }
                    if plainVisible, let plainText {
                        switchRow("Show as plain text", systemImage: "text.justify.leading", isOn: plainText)
                    }
                    if immersiveVisible {
                        switchRow("Disable immersive (once)", systemImage: "eye.slash",
                                  isOn: $immersiveTemporarilyDisabled)
                    }
                }
            }
        }
    }

    /// Shuffle · Repeat · Favourite (Android `BottomToggleRow`, 74 pt): the full player's liquid segments, each its
    /// own interactive glass (owner, 2026-10-07: the row "becomes liquid").
    private var toggleRow: some View {
        PlayerToggleRow(isShuffleOn: isShuffleEnabled, repeatMode: repeatMode, isFavorite: liked,
                        onShuffle: actions.onShuffle, onRepeat: actions.onRepeat, onFavorite: actions.onFavorite)
            .padding(8)
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

    /// Rows 2 pt apart, each with 8 pt corners, the group clipped to 18 pt at the top and `bottomRadius` at the bottom
    /// (Android clips the column; as `SettingsGroup`), so the first and last rows get the outer corners whichever rows
    /// show.
    private func rowGroup<Content: View>(bottomRadius: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            content()
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: bottomRadius,
                                          bottomTrailingRadius: bottomRadius, topTrailingRadius: 18,
                                          style: .continuous))
    }

    private var rowShape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }

    /// `identifier` is an optional id for UI tests: the row's label joins its title and subtitle, so a label query is
    /// fragile.
    @ViewBuilder
    private func row(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, systemImage: String,
                     accent: Bool = false, identifier: String? = nil,
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
            .background(itemFill, in: rowShape)
            .contentShape(rowShape)
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.98))
        if let identifier {
            button.accessibilityIdentifier(identifier)
        } else {
            button
        }
    }

    private func switchRow(_ title: LocalizedStringKey, systemImage: String, isOn: Binding<Bool>) -> some View {
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
        .background(itemFill, in: rowShape)
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
