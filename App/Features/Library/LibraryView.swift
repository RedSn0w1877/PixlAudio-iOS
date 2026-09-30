import SwiftUI

/// Library (placeholder): the category list, then all songs.
struct LibraryView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        List {
            Section {
                ForEach(LibraryCategory.allCases) { category in
                    NavigationLink(value: Route.category(category)) {
                        Label(category.title, systemImage: category.systemImage)
                    }
                }
            }

            Section("Songs") {
                ForEach(environment.library.songs) { song in
                    SongRow(song: song)
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Title", systemImage: "textformat") {}
                    Button("Artist", systemImage: "music.mic") {}
                    Button("Recently Added", systemImage: "clock") {}
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .accessibilityIdentifier("screen.library")
    }
}

/// A category page (placeholder until stage 7a).
struct LibraryCategoryView: View {
    let category: LibraryCategory
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Group {
            if category == .songs {
                List(environment.library.songs) { song in
                    SongRow(song: song)
                }
            } else {
                ContentUnavailableView(
                    category.title,
                    systemImage: category.systemImage,
                    description: Text("Arrives with the library stage.")
                )
            }
        }
        .navigationTitle(category.title)
    }
}
