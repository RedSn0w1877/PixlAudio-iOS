import PixlModel
import SwiftUI

/// Redesign 2 (Android `LibraryToolsRow`, mockup AndroidLibrary): the row under the tab chips, 48 pt tall inside the
/// 16 pt gutter. On the left the sort as a text button (40 pt, 20 pt corners, 8 / 12 pt padding, 20 dp sort icon,
/// 6 pt gap, the current sort's name 14/20 medium) that opens Sort by as a small system menu; on the right a connected
/// group of 44 × 40 pt buttons (20 / 6 pt corners, 2 pt apart): Locate (when the current song is off screen),
/// Instrumental-only (Songs), List | Grid (Albums). Each group button is tinted glass; the selected one is `primary`.
struct LibraryToolsRow: View {
    let tab: LibraryTab
    let showsLocate: Bool
    let isInstrumentalizedOnly: Bool
    let onLocate: () -> Void
    let onInstrumentalFilter: () -> Void
    /// The tab's sort preferences, for the Sort by menu and its label.
    let prefs: LibraryPreferences

    @Environment(\.appTheme) private var theme
    @Environment(SettingsStore.self) private var settings

    private enum Kind: Hashable { case locate, instrumental, list, grid }

    var body: some View {
        HStack(spacing: 0) {
            sortButton
                .frame(maxWidth: .infinity, alignment: .leading)
            let kinds = buttonKinds
            if !kinds.isEmpty {
                Spacer().frame(width: 8)
                GlassEffectContainer(spacing: 1) {
                    HStack(spacing: Redesign.groupGap) {
                        ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                            groupButton(kind, position: .of(index, count: kinds.count))
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
            }
        }
        .frame(height: 48)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showsLocate)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: tab)
    }

    private var buttonKinds: [Kind] {
        var kinds: [Kind] = []
        if showsLocate { kinds.append(.locate) }
        if tab == .songs { kinds.append(.instrumental) }
        if tab == .albums { kinds += [.list, .grid] }
        return kinds
    }

    /// The sort as a text button; Sort by is a small system menu that morphs out of it (owner change 2026-10-02).
    private var sortButton: some View {
        let current = prefs.sort(for: tab)
        return Menu {
            LibrarySortMenuContent(tab: tab, prefs: prefs)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 20, height: 20)
                Text(current.displayName)
                    .pixlFont(.redesignLabel)
                    .lineLimit(1)
                    .frame(maxWidth: 200, alignment: .leading)
            }
            .foregroundStyle(theme.onSurface)
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(height: 40)
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort options, \(current.displayName)")
        .accessibilityIdentifier("library.sort")
    }

    private func groupButton(_ kind: Kind, position: GroupPosition) -> some View {
        let isListView = settings.library.isAlbumsListView
        let selected: Bool = switch kind {
        case .locate: false
        case .instrumental: isInstrumentalizedOnly
        case .list: isListView
        case .grid: !isListView
        }
        return RedesignGroupButton(position: position, isSelected: selected, height: 40, inner: 6,
                                   horizontalPadding: 0, action: {
            switch kind {
            case .locate: onLocate()
            case .instrumental: onInstrumentalFilter()
            case .list: withAnimation(PixlMotion.state) { settings.library.isAlbumsListView = true }
            case .grid: withAnimation(PixlMotion.state) { settings.library.isAlbumsListView = false }
            }
        }) { tint in
            Image(systemName: symbol(kind))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: 44)
        .accessibilityLabel(label(kind))
        .accessibilityIdentifier(identifier(kind))
    }

    private func symbol(_ kind: Kind) -> String {
        switch kind {
        case .locate: "scope"
        case .instrumental: "mic.slash"
        case .list: "list.bullet"
        case .grid: "square.grid.2x2"
        }
    }

    private func label(_ kind: Kind) -> LocalizedStringKey {
        switch kind {
        case .locate: "Locate current song"
        case .instrumental: isInstrumentalizedOnly ? "Showing instrumentals only" : "Show instrumentals only"
        case .list: "List view"
        case .grid: "Grid view"
        }
    }

    private func identifier(_ kind: Kind) -> String {
        switch kind {
        case .locate: "library.locate"
        case .instrumental: "library.instrumentalFilter"
        case .list: "library.view.list"
        case .grid: "library.view.grid"
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

/// Redesign 2 (Android `LibraryTabChips`): one filter chip per library tab in the user's order, 8 pt apart, 16 pt
/// content padding, then an outlined Edit chip (the reorder sheet). The selected chip scrolls into view.
struct LibraryTabChips: View {
    let tabs: [LibraryTab]
    let selected: LibraryTab
    let onSelect: (LibraryTab) -> Void
    let onEdit: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 4) {
                    HStack(spacing: 8) {
                        ForEach(tabs, id: \.self) { tab in
                            RedesignFilterChip(label: tab.tabTitle, isSelected: tab == selected) { onSelect(tab) }
                                .id(tab)
                                .accessibilityIdentifier("library.tab.\(tab.tabTitle)")
                        }
                        RedesignFilterChip(label: "", isSelected: false, leadingSystemImage: "pencil", action: onEdit)
                            .accessibilityLabel("Reorder tabs")
                            .accessibilityIdentifier("library.tab.accessory")
                    }
                    .padding(.horizontal, Redesign.gutter)
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .onChange(of: selected) { _, tab in
                withAnimation(PixlMotion.selection) { proxy.scrollTo(tab) }
            }
        }
    }
}
