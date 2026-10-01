import SwiftUI

/// App entry point. Builds the `AppEnvironment` once and hands its stores to the view tree.
@main
struct PixlAudioApp: App {
    @State private var environment = AppEnvironment(launch: .current)

    var body: some Scene {
        let spotify = environment.spotify
        WindowGroup {
            RootView()
                .environment(environment)
                .environment(environment.router)
                .environment(environment.library)
                .environment(environment.playback)
                .environment(environment.settings)
                .environment(environment.accounts)
                .environment(environment.lyrics)
                .environment(environment.theme)
                .environment(environment.youtube.downloads.badges)
                .preferredColorScheme(environment.preferredColorScheme)
                .task { await environment.start() }
        }
        // Stage 12: Spotify library refresh in the background (BGAppRefreshTask, scheduled after sign-in / each run).
        .backgroundTask(.appRefresh(SpotifyService.backgroundTaskIdentifier)) {
            await spotify.backgroundRefresh()
        }
    }
}
