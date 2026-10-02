import PixlLibrary
import PixlModel
import SwiftUI

// Sort and filter as small system menus (Hoa, 2026-10-02: the liquid menus belong on "small menus, filter songs,
// etc"). These hold the same choices as Android's sort bottom sheets, which stay in the app for UI-test launch states.

/// Sort by (the sort methods, the current one checked) and Order (ascending / descending when the current method
/// can flip), as menu sections. `options` is a screen's full option list; methods are deduplicated as in the sheets.
struct SortMenuSections: View {
    let options: [SortOption]
    let selected: SortOption
    let onSelect: (SortOption) -> Void

    var body: some View {
        let methods = options.map { $0.methodOption() }.reduce(into: [SortOption]()) { result, option in
            if !result.contains(where: { $0.methodKey == option.methodKey }) { result.append(option) }
        }
        Section("Sort by") {
            Picker("Sort by", selection: Binding(get: { selected.methodKey }, set: { key in
                guard let method = methods.first(where: { $0.methodKey == key }) else { return }
                onSelect(method.resolveForDirection(selected.direction))
            })) {
                ForEach(methods, id: \.methodKey) { method in
                    Text(method.methodLabel).tag(method.methodKey)
                }
            }
            .pickerStyle(.inline)
        }
        if selected.canFlipDirection, let direction = selected.direction {
            Section("Order") {
                Picker("Order", selection: Binding(get: { direction }, set: { newDirection in
                    guard newDirection != direction else { return }
                    onSelect(selected.flipDirection())
                })) {
                    Label("Ascending", systemImage: "arrow.up").tag(SortDirection.ascending)
                    Label("Descending", systemImage: "arrow.down").tag(SortDirection.descending)
                }
                .pickerStyle(.inline)
            }
        }
    }
}

/// Library › Sort by as a menu (Android `LibrarySortBottomSheet`): sort methods, order, then per tab Albums › View
/// (Grid / List), Folders › Playlist View, others › Cloud Only.
struct LibrarySortMenuContent: View {
    let tab: LibraryTab
    let prefs: LibraryPreferences

    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let options = tab.menuSortOptions
        let selected = options.first { $0 == prefs.sort(for: tab) } ?? tab.defaultSort
        SortMenuSections(options: options, selected: selected) { prefs.setSort($0, for: tab) }
        if tab == .albums {
            Section("View") {
                Picker("View", selection: Binding(get: { settings.library.isAlbumsListView },
                                                  set: { settings.library.isAlbumsListView = $0 })) {
                    Label("Grid", systemImage: "square.grid.2x2").tag(false)
                    Label("List", systemImage: "list.bullet").tag(true)
                }
                .pickerStyle(.inline)
            }
        }
        if tab == .folders {
            Section("View") {
                Toggle("Playlist View", isOn: Binding(get: { prefs.isFoldersPlaylistView },
                                                      set: { prefs.isFoldersPlaylistView = $0 }))
            }
        } else {
            Section("Cloud") {
                Toggle("Cloud Only", isOn: Binding(get: { settings.library.hideLocalMedia },
                                                   set: { settings.library.hideLocalMedia = $0 }))
            }
        }
    }
}
