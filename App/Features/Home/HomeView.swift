import SwiftUI

/// Home (placeholder): greeting title, quick actions, recently played/added. Settings from the toolbar.
struct HomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(PlaybackStore.self) private var playback
    @State private var greeting = HomeView.makeGreeting(for: Date())

    var body: some View {
        List {
            Section {
                HStack(spacing: Tokens.Spacing.m) {
                    quickAction("Shuffle", systemImage: "shuffle") {
                        if let song = environment.library.songs.randomElement() { playback.play(song) }
                    }
                    quickAction("Liked", systemImage: "heart.fill") {}
                    quickAction("Recent", systemImage: "clock.fill") {}
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            }

            Section("Recently Played") {
                ForEach(environment.library.recentlyPlayed) { song in
                    SongRow(song: song)
                }
            }

            Section("Recently Added") {
                ForEach(environment.library.recentlyAdded) { song in
                    SongRow(song: song)
                }
            }
        }
        .navigationTitle(greeting)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.settings) {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("home.settings")
            }
        }
        .accessibilityIdentifier("screen.home")
    }

    private func quickAction(
        _ title: LocalizedStringKey,
        systemImage: String,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.footnote.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(.fill.tertiary, in: .rect(cornerRadius: Tokens.Artwork.tileCornerRadius, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }

    private static func makeGreeting(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }
}
