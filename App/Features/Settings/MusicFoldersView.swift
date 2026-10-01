import SwiftUI
import UniformTypeIdentifiers

/// Settings › Music Management › Excluded Directories (Android `FileExplorerDialog`, full screen): close circle,
/// title, refresh circle; one tab per storage root; the hint; the breadcrumb header; the folder list where each row
/// shows the folder, its path, a song-count badge, a chevron to open it and a checkbox to exclude it (excluded rows
/// turn `errorContainer`); "Done" bottom-right.
///
/// iOS has no device-wide file system, so the roots are the app's Documents folder ("On My iPhone") plus the
/// folders the user adds with the system folder picker (stored as security-scoped bookmarks in
/// `FolderSourceRecord`; stage 6's scanner reads them). Exclusions are written to Android's `blocked_directories`
/// as library paths `/<root>/<sub folder>`.
struct MusicFoldersView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var model = MusicFoldersModel()
    @State private var showsPicker = false
    @State private var blockedAtOpen: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            topBar
            if model.roots.count > 1 {
                GlassPillRow(items: model.roots.map { GlassPillRow<String>.Item(id: $0.id, title: $0.displayName) },
                             selection: Binding(get: { model.selectedRootID }, set: { model.select(rootID: $0) }),
                             uppercase: false, accessibilityIdentifierPrefix: "folders.root")
            }
            Text(L10n.fileExplorerHint)
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurfaceVariant)
                .padding(.top, 10)
                .padding(.horizontal, 18)
            breadcrumbs
                .padding(.horizontal, 18)
            list
        }
        .background(theme.surfaceContainerLow.ignoresSafeArea())
        .overlay(alignment: .bottomTrailing) { doneButton }
        .task {
            blockedAtOpen = settings.library.blockedDirectories
            await model.load(persistence: environment.persistence)
        }
        .fileImporter(isPresented: $showsPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task { await model.addFolder(url, importer: environment.libraryImporter, persistence: environment.persistence) }
        }
        .accessibilityIdentifier("screen.musicFolders")
    }

    private var topBar: some View {
        ZStack {
            Text(L10n.settingsExcludedDirectoriesTitle)
                .pixlFont(.custom(size: 22, weight: .medium))
                .foregroundStyle(theme.onSurface)
                .lineLimit(1)
                .padding(.horizontal, 64)
            HStack {
                GlassCircleButton(systemImage: "xmark", accessibilityLabel: LocalizedStringKey(L10n.commonClose)) {
                    finish()
                }
                Spacer()
                GlassCircleButton(systemImage: "plus", accessibilityLabel: "Add folder",
                                  tint: theme.primaryContainer.opacity(GlassTint.container),
                                  foreground: theme.onPrimaryContainer) { showsPicker = true }
                    .accessibilityIdentifier("folders.add")
                GlassCircleButton(systemImage: "arrow.clockwise",
                                  accessibilityLabel: LocalizedStringKey(L10n.fileExplorerCdRefresh),
                                  tint: theme.secondaryContainer.opacity(GlassTint.container),
                                  foreground: theme.onSecondaryContainer) {
                    Task { await model.reload() }
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 64)
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button { model.goToRoot() } label: {
                    Image(systemName: "house.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.onSecondaryContainer)
                        .frame(width: 36, height: 36)
                        .background(theme.secondaryContainer.opacity(0.45), in: Circle())
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityLabel(L10n.fileExplorerCdGoRoot)
                ForEach(Array(model.crumbs.enumerated()), id: \.offset) { index, crumb in
                    let isLast = index == model.crumbs.count - 1
                    Button { model.goToCrumb(index) } label: {
                        Text(crumb)
                            .pixlFont(.bodyMedium, weight: isLast ? .semibold : .regular)
                            .foregroundStyle(isLast ? theme.onPrimaryContainer : theme.onSurfaceVariant)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(isLast ? theme.primaryContainer : theme.surfaceContainerHigh,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    if !isLast {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.onSurfaceVariant)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if model.isLoading {
                    ProgressView().padding(.vertical, 36)
                } else if model.children.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "folder")
                            .font(.system(size: 52, weight: .regular))
                            .foregroundStyle(theme.onSurfaceVariant.opacity(0.6))
                        Text(L10n.fileExplorerEmptyFolders)
                            .pixlFont(.bodyLarge)
                            .foregroundStyle(theme.onSurfaceVariant)
                    }
                    .padding(.vertical, 36)
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(model.children) { folder in
                        let path = model.libraryPath(of: folder)
                        MusicFolderRow(folder: folder, path: path,
                                       isBlocked: settings.library.blockedDirectories.contains(path),
                                       onOpen: { model.open(folder) },
                                       onToggle: { toggle(path) })
                    }
                }
                if let root = model.selectedRoot, root.isRemovable, model.crumbs.count <= 1 {
                    SettingsFillButton(title: L10n.commonRemove, systemImage: "minus.circle", style: .destructive) {
                        Task { await model.removeRoot(root, importer: environment.libraryImporter,
                                                    persistence: environment.persistence) }
                    }
                    .padding(.top, 12)
                }
                Spacer().frame(height: 88)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 18)
    }

    private var doneButton: some View {
        Button(action: finish) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark").font(.system(size: 18, weight: .semibold))
                Text(L10n.commonDone).pixlFont(.labelLarge, weight: .semibold)
            }
            .foregroundStyle(theme.onTertiaryContainer)
            .padding(.horizontal, 22)
            .frame(height: 56)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pixlGlass(in: Capsule(), tint: theme.tertiaryContainer.opacity(GlassTint.prominent), interactive: true)
        .padding(.trailing, 24)
        .padding(.bottom, 12)
        .accessibilityIdentifier("folders.done")
    }

    private func toggle(_ path: String) {
        var blocked = settings.library.blockedDirectories
        if let index = blocked.firstIndex(of: path) { blocked.remove(at: index) } else { blocked.append(path) }
        settings.library.blockedDirectories = blocked
    }

    /// Android `applyPendingDirectoryRuleChanges`: a changed rule set (or a new folder) triggers a full rescan.
    private func finish() {
        if Set(blockedAtOpen) != Set(settings.library.blockedDirectories) || model.didChangeRoots {
            Task { try? await library.refresh(mode: .full) }
        }
        dismiss()
    }
}

/// Android `FileExplorerItem`.
struct MusicFolderRow: View {
    let folder: MusicFolderEntry
    let path: String
    let isBlocked: Bool
    let onOpen: () -> Void
    let onToggle: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let content = isBlocked ? theme.onErrorContainer : theme.onSurface
        let badge = isBlocked ? theme.onErrorContainer : theme.secondary
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 20))
                .foregroundStyle(content)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 0) {
                Text(folder.name)
                    .pixlFont(.titleMedium)
                    .foregroundStyle(content)
                    .lineLimit(1)
                Text(path)
                    .pixlFont(.bodySmall)
                    .foregroundStyle(content.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer().frame(height: 6)
                Text(countLabel)
                    .pixlFont(.labelMedium)
                    .foregroundStyle(badge)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(badge.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if folder.hasSubfolders {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(content)
                    .frame(width: 32, height: 32)
                    .background(content.opacity(0.08), in: Circle())
            } else {
                Spacer().frame(width: 8)
            }
            Button(action: onToggle) {
                Image(systemName: isBlocked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isBlocked ? theme.onErrorContainer : theme.onSurfaceVariant)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityLabel(isBlocked ? "Excluded" : "Included")
            .accessibilityAddTraits(isBlocked ? .isSelected : [])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { if folder.hasSubfolders { onOpen() } }
        .pixlGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                   tint: (isBlocked ? theme.errorContainer : theme.surfaceContainerHigh)
                       .opacity(isBlocked ? GlassTint.prominent : SettingsTint.row),
                   interactive: true)
        .animation(PixlMotion.state, value: isBlocked)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("folders.row.\(folder.name)")
    }

    private var countLabel: String {
        switch folder.audioCount {
        case ..<0: "Scanning..."
        case 1: "1 song"
        case 100...: "99+ songs"
        default: "\(folder.audioCount) songs"
        }
    }
}

/// A storage root: the Documents folder or a picked folder.
nonisolated struct MusicFolderRoot: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    /// The first component of library paths under this root.
    let pathKey: String
    let bookmark: Data?
    let isRemovable: Bool
}

/// A sub-folder in the list.
nonisolated struct MusicFolderEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let relativePath: String
    let audioCount: Int
    let hasSubfolders: Bool
    var id: String { relativePath }
}

/// Folder browsing for `MusicFoldersView` (Android `SettingsViewModel` explorer state). Directory reads run off the
/// main thread; security-scoped roots are opened only while listed.
@Observable
final class MusicFoldersModel {
    private(set) var roots: [MusicFolderRoot] = []
    private(set) var selectedRootID = "documents"
    private(set) var relativeStack: [String] = []
    private(set) var children: [MusicFolderEntry] = []
    private(set) var isLoading = true
    private(set) var didChangeRoots = false

    @ObservationIgnored private var scopedURL: URL?

    var selectedRoot: MusicFolderRoot? { roots.first { $0.id == selectedRootID } }

    /// Breadcrumb labels: the root, then each opened folder.
    var crumbs: [String] {
        [selectedRoot?.displayName ?? ""] + relativeStack.map { ($0 as NSString).lastPathComponent }
    }

    func libraryPath(of folder: MusicFolderEntry) -> String {
        "/" + (selectedRoot?.pathKey ?? "") + "/" + folder.relativePath
    }

    func load(persistence: PersistenceActor?) async {
        let sources = (try? await persistence?.settingsFolderSources()) ?? []
        roots = [MusicFolderRoot(id: FolderRoot.documentsID, displayName: "On My iPhone",
                                 pathKey: FolderRoot.documentsDisplayName, bookmark: nil,
                                 isRemovable: false)]
            + sources.map { MusicFolderRoot(id: $0.id, displayName: $0.displayName, pathKey: $0.displayName,
                                            bookmark: $0.bookmark, isRemovable: true) }
        if !roots.contains(where: { $0.id == selectedRootID }) { selectedRootID = "documents" }
        await reload()
    }

    func select(rootID: String) {
        guard rootID != selectedRootID else { return }
        selectedRootID = rootID
        relativeStack = []
        Task { await reload() }
    }

    func open(_ folder: MusicFolderEntry) {
        relativeStack.append(folder.relativePath)
        Task { await reload() }
    }

    func goToRoot() {
        relativeStack = []
        Task { await reload() }
    }

    func goToCrumb(_ index: Int) {
        let keep = max(index, 0)
        guard keep < relativeStack.count + 1 else { return }
        relativeStack = Array(relativeStack.prefix(keep))
        Task { await reload() }
    }

    /// Adds a picked folder through the stage-6 importer (unique display name, security scope kept open), or straight
    /// into the store when there is no importer (UI-test launches).
    func addFolder(_ url: URL, importer: LocalLibraryImporter?, persistence: PersistenceActor?) async {
        if let importer {
            guard (try? await importer.addFolder(url)) != nil else { return }
        } else {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil,
                                                       relativeTo: nil) else { return }
            try? await persistence?.settingsAddFolderSource(displayName: url.lastPathComponent, bookmark: bookmark,
                                                            addedAt: Int64(Date().timeIntervalSince1970 * 1000))
        }
        didChangeRoots = true
        await load(persistence: persistence)
    }

    func removeRoot(_ root: MusicFolderRoot, importer: LocalLibraryImporter?, persistence: PersistenceActor?) async {
        if let importer {
            try? await importer.removeFolder(id: root.id)
        } else {
            try? await persistence?.settingsRemoveFolderSource(id: root.id)
        }
        didChangeRoots = true
        selectedRootID = "documents"
        relativeStack = []
        await load(persistence: persistence)
    }

    func reload() async {
        isLoading = true
        closeScope()
        guard let root = selectedRoot, let base = resolve(root) else {
            children = []
            isLoading = false
            return
        }
        let relative = relativeStack.last ?? ""
        let listing = await Task.detached(priority: .userInitiated) {
            Self.list(base: base, relative: relative)
        }.value
        children = listing
        isLoading = false
    }

    private func resolve(_ root: MusicFolderRoot) -> URL? {
        guard let bookmark = root.bookmark else {
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        return url
    }

    private func closeScope() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    nonisolated private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "alac",
                                                       "caf", "opus", "ogg", "mp4"]

    nonisolated private static func list(base: URL, relative: String) -> [MusicFolderEntry] {
        let fm = FileManager.default
        let directory = relative.isEmpty ? base : base.appendingPathComponent(relative, isDirectory: true)
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        return items.compactMap { url -> MusicFolderEntry? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let rel = relative.isEmpty ? url.lastPathComponent : relative + "/" + url.lastPathComponent
            let (count, hasSub) = scan(url)
            return MusicFolderEntry(url: url, name: url.lastPathComponent, relativePath: rel, audioCount: count,
                                    hasSubfolders: hasSub)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Audio files below `url` (stops counting at 100, the badge shows "99+") and whether it has sub-folders.
    nonisolated private static func scan(_ url: URL) -> (Int, Bool) {
        let fm = FileManager.default
        var hasSub = false
        if let direct = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) {
            hasSub = direct.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        }
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil,
                                             options: [.skipsHiddenFiles]) else { return (0, hasSub) }
        var count = 0
        for case let file as URL in enumerator where audioExtensions.contains(file.pathExtension.lowercased()) {
            count += 1
            if count >= 100 { break }
        }
        return (count, hasSub)
    }
}
