import PixlModel
import SwiftUI

/// Android `GenreSortBottomSheet`: "Sort & Play" (`headlineMedium` bold), the Shuffle button (`primary`, 16 pt
/// corners, 56 pt), Quick Fill Genre for the unknown genre (`secondaryContainer`), then "Sort By" (`titleSmall` bold,
/// `onSurfaceVariant`) and the Artist / Album / Title cards (64 pt, 16 pt corners; selected `secondaryContainer`
/// with a check).
struct GenreSortSheet: View {
    let sort: GenreSort
    let showsQuickFill: Bool
    let onSort: (GenreSort) -> Void
    let onShuffle: () -> Void
    let onQuickFill: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Sort & Play")
                    .pixlFont(.headlineMedium, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                    .padding(.bottom, 24)
                wideButton("Shuffle", systemImage: "shuffle", fill: theme.primary, content: theme.onPrimary, action: onShuffle)
                if showsQuickFill {
                    Spacer().frame(height: 16)
                    wideButton("Quick Fill Genre", systemImage: "wand.and.stars", fill: theme.secondaryContainer,
                               content: theme.onSecondaryContainer, action: onQuickFill)
                        .accessibilityIdentifier("genre.quickFill")
                }
                Spacer().frame(height: 32)
                Text("Sort By")
                    .pixlFont(.titleSmall, weight: .bold)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .padding(.bottom, 12)
                VStack(spacing: 12) {
                    option(.artist, "Artist", systemImage: "person.fill")
                    option(.album, "Album", systemImage: "opticaldisc")
                    option(.title, "Title", systemImage: "textformat.abc")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 48)
        }
        .accessibilityIdentifier("sheet.genreSort")
    }

    private func wideButton(_ title: String, systemImage: String, fill: Color, content: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 18, weight: .semibold))
                Text(title).pixlFont(.titleMedium, weight: .bold)
            }
            .foregroundStyle(content)
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), tint: fill.opacity(GlassTint.prominent),
                   interactive: true)
    }

    private func option(_ value: GenreSort, _ title: String, systemImage: String) -> some View {
        let selected = value == sort
        let content = selected ? theme.onSecondaryContainer : theme.onSurface
        return Button { onSort(value) } label: {
            HStack(spacing: 16) {
                Image(systemName: systemImage).font(.system(size: 20, weight: .semibold)).frame(width: 24)
                Text(title).pixlFont(.titleMedium, weight: .semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if selected { Image(systemName: "checkmark").font(.system(size: 18, weight: .semibold)) }
            }
            .foregroundStyle(content)
            .padding(.horizontal, 20)
            .frame(height: 64)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                   tint: (selected ? theme.secondaryContainer : theme.surfaceContainerHigh)
                       .opacity(selected ? GlassTint.prominent : GlassTint.surface),
                   interactive: true)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Android `QuickFillDialog` (full screen): step 1 "Select Songs" (search field, songs with check boxes), step 2
/// "Choose Genre" (a grid of genre cards, 80 pt, 16 pt corners — selected `primary` — plus "New Genre"); the docked
/// toolbar (64 pt, 32 pt corners, `surfaceContainerHighest`) holds Select all | Clear, the chosen genre and
/// Next / Quick Fill.
struct QuickFillSheet: View {
    let songs: [Song]
    let onApply: ([String], String) -> Void

    @Environment(LibraryStore.self) private var library
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0
    @State private var query = ""
    @State private var selected: Set<String> = []
    @State private var genre: String?
    @State private var customGenres: [String] = QuickFillSheet.loadCustomGenres()
    @State private var showsNewGenre = false
    @State private var newGenre = ""

    private var filtered: [Song] {
        guard !query.isEmpty else { return songs }
        return songs.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.displayArtist.localizedCaseInsensitiveContains(query) }
    }

    private var allGenres: [String] {
        let fromLibrary = library.songs.compactMap { $0.genre?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Array(Set(fromLibrary + customGenres)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                GlassCircleButton(systemImage: step > 0 ? "arrow.left" : "xmark", accessibilityLabel: "Back",
                                  tint: theme.surfaceContainerHighest.opacity(GlassTint.container),
                                  foreground: theme.onSurface) {
                    if step > 0 { withAnimation(PixlMotion.state) { step -= 1 } } else { dismiss() }
                }
                Text(step == 0 ? "Select Songs" : "Choose Genre")
                    .pixlFont(.titleLarge, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 64)
            ZStack {
                if step == 0 { songStep.transition(.move(edge: .leading).combined(with: .opacity)) }
                else { genreStep.transition(.move(edge: .trailing).combined(with: .opacity)) }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.86), value: step)
        }
        .background(theme.surface.ignoresSafeArea())
        .overlay(alignment: .bottom) { toolbar }
        .alert("Add Custom Genre", isPresented: $showsNewGenre) {
            TextField("Genre Name", text: $newGenre)
            Button("Add") {
                let name = newGenre.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                if !customGenres.contains(name) {
                    customGenres.append(name)
                    QuickFillSheet.saveCustomGenres(customGenres)
                }
                genre = name
                newGenre = ""
            }
            Button("Cancel", role: .cancel) { newGenre = "" }
        }
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .accessibilityIdentifier("screen.quickFill.genre")
    }

    private var songStep: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.onSurfaceVariant)
                TextField("Search songs", text: $query).pixlFont(.bodyLarge)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                       tint: theme.surfaceContainerHigh.opacity(GlassTint.surface))
            .padding(16)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filtered) { song in
                        SongCheckRow(song: song, isChecked: selected.contains(song.id)) {
                            if selected.contains(song.id) { selected.remove(song.id) } else { selected.insert(song.id) }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 100)
            }
        }
    }

    private var genreStep: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                Button { showsNewGenre = true } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 20, weight: .semibold))
                        Text("New Genre").pixlFont(.labelMedium)
                    }
                    .foregroundStyle(theme.primary)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                           tint: theme.primaryContainer.opacity(0.5), interactive: true)
                ForEach(allGenres, id: \.self) { name in
                    let isSelected = genre == name
                    Button { genre = name } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "music.note")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(isSelected ? theme.onPrimaryContainer : theme.onSurface)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(isSelected ? theme.primaryContainer : theme.surface))
                            Text(name)
                                .pixlFont(.labelLarge, weight: .semibold)
                                .foregroundStyle(isSelected ? theme.onPrimary : theme.onSurface)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 80)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                               tint: (isSelected ? theme.primary : theme.surfaceContainerHigh)
                                   .opacity(isSelected ? GlassTint.prominent : GlassTint.surface),
                               interactive: true)
                }
            }
            .padding(16)
            .padding(.bottom, 100)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                SegmentedGlassButton(title: "Select all", systemImage: "checklist", accessibilityLabel: "Select all",
                                     leading: 50, trailing: 4, height: 44, horizontalPadding: 16, iconSize: 0,
                                     tint: theme.surfaceContainerHigh.opacity(GlassTint.prominent),
                                     foreground: theme.onSurface) { selected = Set(filtered.map(\.id)) }
                SegmentedGlassButton(title: "Clear", systemImage: "xmark", accessibilityLabel: "Clear",
                                     leading: 4, trailing: 50, height: 44, horizontalPadding: 16, iconSize: 0,
                                     tint: theme.surfaceContainerHigh.opacity(GlassTint.prominent),
                                     foreground: theme.onSurface) { selected.removeAll() }
            }
            .opacity(step == 0 ? 1 : 0)
            .disabled(step != 0)
            Spacer().frame(width: 16)
            Text(step == 0 ? "\(selected.count) selected" : (genre.map { "Genre: \($0)" } ?? "Select a genre"))
                .pixlFont(.labelMedium)
                .foregroundStyle(theme.onSurfaceVariant)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: 16)
            Button {
                if step == 0 {
                    guard !selected.isEmpty else { return }
                    withAnimation(PixlMotion.state) { step = 1 }
                } else if let genre {
                    onApply(Array(selected), genre)
                    dismiss()
                }
            } label: {
                HStack(spacing: 8) {
                    Text(step == 0 ? "Next" : "Quick Fill").pixlFont(.labelLarge)
                    Image(systemName: step == 0 ? "arrow.right" : "checkmark").font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(theme.onPrimary)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(Capsule().fill(theme.primary))
                .contentShape(.capsule)
            }
            .buttonStyle(PressScaleButtonStyle())
            .opacity((step == 0 && selected.isEmpty) || (step == 1 && genre == nil) ? 0.5 : 1)
        }
        .padding(.horizontal, 10)
        .frame(height: 64)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 32, style: .continuous),
                   tint: theme.surfaceContainerHighest.opacity(GlassTint.container))
        .padding(16)
    }

    // Custom genres (`custom_genres`, a string set on Android) — a string array here.
    private static func loadCustomGenres() -> [String] {
        UserDefaults.standard.stringArray(forKey: PreferenceKeys.customGenres) ?? []
    }

    private static func saveCustomGenres(_ genres: [String]) {
        UserDefaults.standard.set(genres, forKey: PreferenceKeys.customGenres)
    }
}

/// Android `SongPickerRow`: a capsule (`surfaceContainerLowest`), check box, 36 pt round art, title and artist.
struct SongCheckRow: View {
    let song: Song
    let isChecked: Bool
    let onToggle: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 0) {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22))
                    .foregroundStyle(isChecked ? theme.primary : theme.onSurfaceVariant)
                    .frame(width: 40, height: 40)
                ArtworkView(song: song, size: 36, cornerRadius: 18)
                Spacer().frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(song.title).pixlFont(.bodyLarge).foregroundStyle(theme.onSurface).lineLimit(1)
                    Text(song.displayArtist).pixlFont(.bodyMedium).foregroundStyle(theme.onSurfaceVariant).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: Capsule(), tint: theme.surfaceContainerLowest.opacity(GlassTint.surface), interactive: true)
        .accessibilityAddTraits(isChecked ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("songCheck.\(song.id)")
    }
}
