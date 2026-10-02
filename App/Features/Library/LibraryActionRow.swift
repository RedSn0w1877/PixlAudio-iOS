import PixlModel
import SwiftUI

/// Android `LibraryActionRow` (42 pt high): the main action — Shuffle (its icon spins when coming from Playlists),
/// or on Playlists the connected New + Import pair — and on the trailing side the connected run of
/// [locate] [storage filter] [instrumental filter] [sort] (26 pt outer corners, 8 pt inner, 4 pt gaps). On Folders
/// the main action becomes the breadcrumbs. Colours: main `tertiaryContainer`, Import `secondaryContainer`, the icon
/// buttons `secondaryContainer` (the active instrumental filter `primary`) — all as tinted glass.
struct LibraryActionRow: View {
    let tab: LibraryTab
    let isFoldersBreadcrumbs: Bool
    let folderPath: String?
    let folderRoots: [String]
    let showsLocate: Bool
    let storageFilter: StorageFilter
    let isInstrumentalizedOnly: Bool
    let onMainAction: () -> Void
    let onImport: () -> Void
    let onLocate: () -> Void
    let onStorageFilter: () -> Void
    let onInstrumentalFilter: () -> Void
    /// The tab's sort preferences, for the Sort by menu.
    let prefs: LibraryPreferences
    let onFolder: (String?) -> Void
    let onFolderBack: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var iconRotation: Double = 360

    private static let height: CGFloat = 42
    private static let outer: CGFloat = 26
    private static let inner: CGFloat = 8

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                if isFoldersBreadcrumbs {
                    FolderBreadcrumbs(folderPath: folderPath, roots: folderRoots, onFolder: onFolder, onBack: onFolderBack)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    mainActions
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(PixlMotion.state, value: isFoldersBreadcrumbs)
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
                                     leading: Self.outer, trailing: isPlaylists ? Self.inner : Self.outer,
                                     height: Self.height, tint: theme.tertiaryContainer.opacity(GlassTint.prominent),
                                     foreground: theme.onTertiaryContainer,
                                     iconRotation: isPlaylists ? 0 : iconRotation, action: onMainAction)
                    .accessibilityIdentifier("library.mainAction")
                if isPlaylists {
                    SegmentedGlassButton(title: "Import", systemImage: "doc.badge.arrow.up",
                                         accessibilityLabel: "Import M3U playlist", leading: Self.inner,
                                         trailing: Self.outer, height: Self.height, horizontalPadding: 14,
                                         tint: theme.secondaryContainer.opacity(GlassTint.prominent),
                                         foreground: theme.onSecondaryContainer, action: onImport)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .accessibilityIdentifier("library.import")
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isPlaylists)
        }
    }

    private var showsStorageFilter: Bool { [.songs, .albums, .artists, .liked].contains(tab) }
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
                if showsStorageFilter {
                    SegmentedGlassButton(systemImage: storageIcon, accessibilityLabel: storageLabel,
                                         leading: showsLocate ? Self.inner : Self.outer, trailing: Self.inner,
                                         height: Self.height, tint: tonal, foreground: onTonal, action: onStorageFilter)
                        .contentTransition(.symbolEffect(.replace))
                        .padding(.trailing, 4)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .accessibilityIdentifier("library.storageFilter")
                }
                if showsInstrumentalFilter {
                    SegmentedGlassButton(systemImage: "mic.slash",
                                         accessibilityLabel: isInstrumentalizedOnly ? "Showing instrumentals only"
                                                                                   : "Show instrumentals only",
                                         leading: (showsLocate || showsStorageFilter) ? Self.inner : Self.outer,
                                         trailing: Self.inner, height: Self.height,
                                         tint: isInstrumentalizedOnly ? theme.primary.opacity(GlassTint.prominent) : tonal,
                                         foreground: isInstrumentalizedOnly ? theme.onPrimary : onTonal,
                                         action: onInstrumentalFilter)
                        .padding(.trailing, 4)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                // Sort by is a small system menu that morphs out of this segment (owner change 2026-10-02).
                let sortLeading = (showsLocate || showsStorageFilter || showsInstrumentalFilter) ? Self.inner : Self.outer
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

    /// Android: Dataset (all), Cloud (online), PhoneAndroid (offline).
    private var storageIcon: String {
        switch storageFilter {
        case .all: "square.grid.2x2.fill"
        case .online: "cloud.fill"
        case .offline: "iphone"
        }
    }

    private var storageLabel: String {
        switch storageFilter {
        case .all: "All songs"
        case .online: "CLOUD"
        case .offline: "LOCAL"
        }
    }
}

/// Android `Breadcrumbs`: a 36 pt back (home at the root) circle, then the path segments (`titleSmall`; the last one
/// bold `primary`, the others `onSurfaceVariant`, chevrons between) in a row that fades 24 pt at scrolled edges.
struct FolderBreadcrumbs: View {
    let folderPath: String?
    let roots: [String]
    let onFolder: (String?) -> Void
    let onBack: () -> Void

    @Environment(\.appTheme) private var theme

    private var segments: [(name: String, path: String?)] {
        var result: [(name: String, path: String?)] = [("Folders", nil)]
        guard let folderPath, let root = roots.first(where: { folderPath == $0 || folderPath.hasPrefix($0 + "/") }) else {
            return result
        }
        result.append(((root as NSString).lastPathComponent, root))
        var current = root
        let rest = folderPath.dropFirst(root.count).split(separator: "/")
        for component in rest {
            current += "/" + component
            result.append((String(component), current))
        }
        return result
    }

    var body: some View {
        let items = segments
        HStack(spacing: 0) {
            Button(action: onBack) {
                Image(systemName: folderPath == nil ? "house.fill" : "arrow.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.onSecondaryContainer)
                    .frame(width: 36, height: 36)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(folderPath == nil)
            .pixlGlass(in: Circle(), tint: theme.secondaryContainer.opacity(GlassTint.prominent), interactive: true)
            .accessibilityLabel(folderPath == nil ? "Home" : "Back")
            Spacer().frame(width: 8)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        Spacer().frame(width: 12)
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            let isLast = index == items.count - 1
                            Button { onFolder(item.path) } label: {
                                Text(item.name)
                                    .pixlFont(.titleSmall, weight: isLast ? .bold : .regular)
                                    .foregroundStyle(isLast ? theme.primary : theme.onSurfaceVariant)
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .disabled(isLast)
                            .id(index)
                            if !isLast {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(theme.onSurfaceVariant.opacity(0.6))
                            }
                        }
                        Spacer().frame(width: 12)
                    }
                }
                .mask(LinearGradient(stops: [.init(color: .black.opacity(0), location: 0), .init(color: .black, location: 0.08),
                                             .init(color: .black, location: 0.92), .init(color: .black.opacity(0), location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                .onChange(of: folderPath, initial: true) { _, _ in
                    withAnimation(PixlMotion.state) { proxy.scrollTo(items.count - 1, anchor: .trailing) }
                }
            }
        }
        .padding(.leading, 2)
        .accessibilityIdentifier("library.breadcrumbs")
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
