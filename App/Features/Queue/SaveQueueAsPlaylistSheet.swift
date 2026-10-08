import PixlModel
import SwiftUI

/// "Save as playlist" (Android `SaveQueueAsPlaylistSheet`), full screen: the close circle, the title
/// (`headlineMedium` semibold) and Select all / Deselect all (rounding into a `tertiary` pill when everything is
/// selected); the playlist name field (focused, the default name selected) and the song search capsule; the queue's
/// songs as capsules with a check box and round art; and the bottom bar: the summary capsule ("N songs selected" ·
/// "Save as: …") beside the Save pill. Saves the checked songs in queue order as a new playlist.
///
/// Android puts the Save pill on the summary capsule. Hoa (2026-10-07) asked for the primary buttons on floating
/// bars to be their own glass pills, so the two are separate glass shapes in one container (no glass on glass).
struct SaveQueueAsPlaylistSheet: View {
    let songs: [Song]
    let defaultName: String

    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var query = ""
    @State private var selected: Set<String> = []
    /// Every song id of the queue (built once; `selected` is always a subset of it).
    @State private var allIds: Set<String> = []
    /// Every row, and the rows the search shows — built once and on query changes, never in `body` (the queue
    /// can be the whole library: a Set of it was built seven times per pass, the filter ran twice).
    @State private var allRows: [QueueSaveRow] = []
    @State private var rows: [QueueSaveRow]?
    @State private var filterTask: Task<Void, Never>?
    @FocusState private var nameFocused: Bool

    var body: some View {
        // Until onAppear has built the rows (the first frame), every song shows, as before.
        let visible = rows ?? QueueSaveRow.rows(songs)
        let allSelected = !allIds.isEmpty && selected.count == allIds.count
        VStack(spacing: 0) {
            topBar(allSelected: allSelected)
            // The name field and the search capsule render together (12 pt apart, above the 6 pt spacing).
            GlassEffectContainer(spacing: 6) {
                VStack(spacing: 12) {
                    fieldBox {
                        TextField("Playlist name", text: $name)
                            .pixlFont(.bodyLarge)
                            .foregroundStyle(theme.onSurface)
                            .focused($nameFocused)
                            .submitLabel(.done)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(theme.onSurfaceVariant)
                        TextField("Search songs to include…", text: $query)
                            .pixlFont(.bodyLarge)
                            .foregroundStyle(theme.onSurface)
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(theme.onSurfaceVariant)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                        }
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 56)
                    .pixlGlass(in: Capsule(), tint: theme.surfaceContainerHigh.opacity(GlassTint.surface))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Rectangle().fill(theme.outlineVariant.opacity(0.4)).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if visible.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 40, weight: .semibold))
                                .foregroundStyle(theme.primary.opacity(0.6))
                            Text("No songs match \"\(query)\"")
                                .pixlFont(.bodyLarge)
                                .foregroundStyle(theme.onSurfaceVariant)
                        }
                        .padding(.vertical, 48)
                    } else {
                        ForEach(visible) { item in
                            row(item.song)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            bottomBar
                .padding(16)
        }
        .background(theme.surface.ignoresSafeArea())
        .onAppear {
            name = defaultName
            allRows = QueueSaveRow.rows(songs)
            rows = allRows
            allIds = Set(songs.map(\.id))
            selected = allIds
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                nameFocused = true
            }
        }
        .onChange(of: songs.count) { _, _ in
            allRows = QueueSaveRow.rows(songs)
            allIds = Set(songs.map(\.id))
            selected.formIntersection(allIds)
            applyQuery()
        }
        .onChange(of: query) { _, _ in applyQuery() }
        .accessibilityIdentifier("sheet.saveQueue")
    }

    /// Shows the rows matching the search: at once for short queues, off the main actor for long ones (the result
    /// lands only if the query is still current; the previous rows stay until then).
    private func applyQuery() {
        filterTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let all = allRows
        guard !trimmed.isEmpty else {
            rows = all
            return
        }
        guard all.count > 300 else {
            rows = QueueSaveRow.filter(all, query: trimmed)
            return
        }
        filterTask = Task {
            let result = await Task.detached(priority: .userInitiated) { QueueSaveRow.filter(all, query: trimmed) }.value
            guard !Task.isCancelled, trimmed == query.trimmingCharacters(in: .whitespaces) else { return }
            rows = result
        }
    }

    private func topBar(allSelected: Bool) -> some View {
        HStack(spacing: 12) {
            GlassCircleButton(systemImage: "xmark", accessibilityLabel: "Close",
                              tint: theme.surfaceContainerHigh.opacity(GlassTint.container)) { dismiss() }
                .padding(.leading, 8)
            // The pill keeps its one-line size and the title steps down a text style until it fits (on a 402 pt
            // iPhone the full-size title truncated to "Save as pl…" and "Deselect all" wrapped inside its 40 pt pill;
            // `minimumScaleFactor` doesn't shrink `pixlFont` text, which carries tracking).
            ViewThatFits(in: .horizontal) {
                title(.headlineMedium)
                title(.headlineSmall)
                title(.titleLarge)
            }
            Spacer(minLength: 8)
            Button {
                selected = allSelected ? [] : allIds
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: allSelected ? "checklist.unchecked" : "checklist.checked")
                        .font(.system(size: 15, weight: .semibold))
                    Text(allSelected ? "Deselect all" : "Select all")
                        .pixlFont(.labelLarge, weight: .bold)
                        .lineLimit(1)
                }
                .fixedSize()
                .foregroundStyle(allSelected ? theme.onTertiary : theme.onSurface)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .pixlGlass(in: RoundedRectangle(cornerRadius: allSelected ? 20 : 6, style: .continuous),
                       tint: (allSelected ? theme.tertiary : theme.surfaceContainerHigh)
                           .opacity(allSelected ? GlassTint.prominent : GlassTint.container), interactive: true)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: allSelected)
            .padding(.trailing, 12)
        }
        .frame(height: 64)
    }

    private func title(_ style: PixlTextStyle) -> some View {
        Text("Save as playlist")
            .pixlFont(style, weight: .semibold)
            .foregroundStyle(theme.onSurface)
            .lineLimit(1)
    }

    private func fieldBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .frame(height: 56)
            .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                       tint: theme.surfaceContainerLow.opacity(GlassTint.surface))
    }

    private func row(_ song: Song) -> some View {
        let isOn = selected.contains(song.id)
        return Button {
            if isOn { selected.remove(song.id) } else { selected.insert(song.id) }
        } label: {
            HStack(spacing: 0) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isOn ? theme.primary : theme.onSurfaceVariant)
                    .frame(width: 40, height: 40)
                ArtworkView(song: song, size: 36, cornerRadius: 18)
                Spacer().frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(song.title).pixlFont(.bodyLarge).foregroundStyle(theme.onSurface).lineLimit(1)
                    Text(song.displayArtist).pixlFont(.bodySmall).foregroundStyle(theme.onSurfaceVariant).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: Capsule(), tint: theme.surfaceContainerLowest.opacity(GlassTint.surface), interactive: true)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// The summary capsule (`secondaryContainer`) and the Save pill (`primary`), each its own glass, 12 pt apart in one
    /// container (spacing below the gap: they never blend at rest).
    private var bottomBar: some View {
        let count = selected.count
        let canSave = !selected.isEmpty
        return GlassEffectContainer(spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(count == 1 ? String(localized: "1 song selected")
                                    : String(localized: "\(count) songs selected"))
                        .pixlFont(.labelLarge)
                        .foregroundStyle(theme.onSecondaryContainer)
                    Text(name.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "Enter a playlist name")
                         : String(localized: "Save as: \(name)"))
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSecondaryContainer.opacity(0.8))
                        .lineLimit(1)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .pixlGlass(in: Capsule(), tint: theme.secondaryContainer.opacity(GlassTint.prominent))
                Button(action: save) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark").font(.system(size: 15, weight: .bold))
                        Text("Save").pixlFont(.labelLarge)
                    }
                    .foregroundStyle(theme.onPrimary)
                    .padding(.horizontal, 22)
                    .frame(height: 56)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                .pixlGlass(in: Capsule(), tint: theme.primary.opacity(GlassTint.prominent), interactive: canSave)
                .opacity(canSave ? 1 : 0.38)
                .accessibilityIdentifier("saveQueue.save")
            }
        }
    }

    private func save() {
        guard !selected.isEmpty else { return }
        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty ? defaultName : name
        var seen = Set<String>()
        let ordered = songs.map(\.id).filter { selected.contains($0) && seen.insert($0).inserted }
        env.libraryEditor.createPlaylist(name: finalName, songIds: ordered)
        LibraryToast.shared.show(String(localized: "Playlist created"))
        dismiss()
    }
}

/// A queue entry in the save sheet. The queue can hold a song twice, so the id is the song id plus its occurrence.
nonisolated struct QueueSaveRow: Identifiable, Sendable {
    let id: String
    let song: Song

    static func rows(_ songs: [Song]) -> [QueueSaveRow] {
        var seen: [String: Int] = [:]
        return songs.map { song in
            let occurrence = seen[song.id, default: 0]
            seen[song.id] = occurrence + 1
            return QueueSaveRow(id: "\(song.id)#\(occurrence)", song: song)
        }
    }

    static func filter(_ rows: [QueueSaveRow], query: String) -> [QueueSaveRow] {
        rows.filter {
            $0.song.title.localizedCaseInsensitiveContains(query) || $0.song.artist.localizedCaseInsensitiveContains(query)
        }
    }
}
