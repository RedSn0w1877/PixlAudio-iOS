import PixlModel
import SwiftUI

/// Android `LibraryActionRow` (42 pt high): the main action — Shuffle (its icon spins when coming from Playlists),
/// or on Playlists the New button — and on the trailing side the connected run of
/// [locate] [instrumental filter] [sort] (26 pt outer corners, 8 pt inner, 4 pt gaps). Colours: main
/// `tertiaryContainer`, the icon buttons `secondaryContainer` (the active instrumental filter `primary`) — all as
/// tinted glass. (The storage filter, the M3U Import button and the Folders breadcrumbs went with the local songs.)
struct LibraryActionRow: View {
    let tab: LibraryTab
    let showsLocate: Bool
    let isInstrumentalizedOnly: Bool
    let onMainAction: () -> Void
    let onLocate: () -> Void
    let onInstrumentalFilter: () -> Void
    /// The tab's sort preferences, for the Sort by menu.
    let prefs: LibraryPreferences

    @Environment(\.appTheme) private var theme
    @State private var iconRotation: Double = 360

    private static let height: CGFloat = 42
    private static let outer: CGFloat = 26
    private static let inner: CGFloat = 8

    var body: some View {
        HStack(spacing: 0) {
            mainActions
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: Tokens.Spacing.s)
            trailingButtons
        }
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .onChange(of: tab, initial: true) { _, newTab in
            withAnimation(.easeInOut(duration: 0.3)) { iconRotation = newTab == .playlists ? 0 : 360 }
        }
    }

    private var mainActions: some View {
        let isPlaylists = tab == .playlists
        return GlassEffectContainer(spacing: 2) {
            HStack(spacing: Tokens.Spacing.s) {
                SegmentedGlassButton(title: isPlaylists ? "New" : "Shuffle",
                                     systemImage: isPlaylists ? "text.badge.plus" : "shuffle",
                                     accessibilityLabel: isPlaylists ? "Create new playlist" : "Shuffle Play",
                                     leading: Self.outer, trailing: Self.outer,
                                     height: Self.height, tint: theme.tertiaryContainer.opacity(GlassTint.prominent),
                                     foreground: theme.onTertiaryContainer,
                                     iconRotation: isPlaylists ? 0 : iconRotation, action: onMainAction)
                    .accessibilityIdentifier("library.mainAction")
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isPlaylists)
        }
    }

    private var showsInstrumentalFilter: Bool { tab == .songs }

    private var trailingButtons: some View {
        let tonal = theme.secondaryContainer.opacity(GlassTint.prominent)
        let onTonal = theme.onSecondaryContainer
        return GlassEffectContainer(spacing: 2) {
            HStack(spacing: 0) {
                if showsLocate {
                    SegmentedGlassButton(systemImage: "scope", accessibilityLabel: "Locate current song",
                                         leading: Self.outer, trailing: Self.inner, height: Self.height,
                                         tint: tonal, foreground: onTonal, action: onLocate)
                        .padding(.trailing, 4)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                if showsInstrumentalFilter {
                    SegmentedGlassButton(systemImage: "mic.slash",
                                         accessibilityLabel: isInstrumentalizedOnly ? "Showing instrumentals only"
                                                                                   : "Show instrumentals only",
                                         leading: showsLocate ? Self.inner : Self.outer,
                                         trailing: Self.inner, height: Self.height,
                                         tint: isInstrumentalizedOnly ? theme.primary.opacity(GlassTint.prominent) : tonal,
                                         foreground: isInstrumentalizedOnly ? theme.onPrimary : onTonal,
                                         action: onInstrumentalFilter)
                        .padding(.trailing, 4)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                // Sort by is a small system menu that morphs out of this segment (owner change 2026-10-02).
                let sortLeading = (showsLocate || showsInstrumentalFilter) ? Self.inner : Self.outer
                ShapedGlassMenu(systemImage: "line.3.horizontal.decrease", accessibilityLabel: "Sort options",
                                shape: UnevenRoundedRectangle(topLeadingRadius: sortLeading, bottomLeadingRadius: sortLeading,
                                                              bottomTrailingRadius: Self.outer, topTrailingRadius: Self.outer,
                                                              style: .continuous),
                                width: Self.height, height: Self.height, tint: tonal, foreground: onTonal) {
                    LibrarySortMenuContent(tab: tab, prefs: prefs)
                }
                .accessibilityIdentifier("library.sort")
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showsLocate)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: tab)
        }
    }
}

/// Android `SelectionActionRow` (44 pt): the connected All (`secondaryContainer`) + Deselect (`secondary`) pair,
/// 3 pt apart, and the ⋮ options pill (`primaryContainer`, 36 pt wide) on the trailing side.
struct LibrarySelectionActionRow: View {
    let onSelectAll: () -> Void
    let onDeselect: () -> Void
    let onOptions: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack {
            GlassEffectContainer(spacing: 1) {
                HStack(spacing: 3) {
                    SegmentedGlassButton(title: "All", systemImage: "checklist", accessibilityLabel: "Select all",
                                         leading: 26, trailing: 8, height: 44, horizontalPadding: 14, iconSize: 18,
                                         tint: theme.secondaryContainer.opacity(GlassTint.prominent),
                                         foreground: theme.onSecondaryContainer, action: onSelectAll)
                        .accessibilityIdentifier("selection.all")
                    SegmentedGlassButton(title: "Deselect", systemImage: "checklist.unchecked",
                                         accessibilityLabel: "Deselect", leading: 8, trailing: 26, height: 44,
                                         horizontalPadding: 14, iconSize: 18,
                                         tint: theme.secondary.opacity(GlassTint.prominent),
                                         foreground: theme.onSecondary, action: onDeselect)
                        .accessibilityIdentifier("selection.deselect")
                }
            }
            Spacer()
            SegmentedGlassButton(systemImage: "ellipsis", accessibilityLabel: "More options", leading: 26, trailing: 26,
                                 height: 44, minWidth: 36, tint: theme.primaryContainer.opacity(GlassTint.prominent),
                                 foreground: theme.onPrimaryContainer, iconRotation: 90, action: onOptions)
                .frame(width: 36)
                .accessibilityIdentifier("selection.options")
        }
        .padding(.horizontal, 4)
    }
}
