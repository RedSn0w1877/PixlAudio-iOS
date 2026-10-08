import SwiftUI

/// App entry point. Builds the `AppEnvironment` once and hands its stores to the view tree.
@main
struct PixlAudioApp: App {
    @State private var environment = AppEnvironment(launch: .current)
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        let spotify = environment.spotify
        let cloud = environment.cloud
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
                .onOpenURL { url in environment.open(url) }
                // Cloud Studio: catch up and poll while active; ask for a background refresh when leaving.
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active: cloud.resume()
                    case .background: cloud.didEnterBackground()
                    default: break
                    }
                }
        }
        // Stage 12: Spotify library refresh in the background (BGAppRefreshTask, scheduled after sign-in / each run).
        .backgroundTask(.appRefresh(SpotifyService.backgroundTaskIdentifier)) {
            await spotify.backgroundRefresh()
        }
        // Cloud Studio: results while jobs are in flight (BGAppRefresh, scheduled only then), and the wake iOS gives
        // when the background transfer session finishes uploads or downloads (design §7.4).
        .backgroundTask(.appRefresh(CloudBackground.refreshIdentifier)) {
            await cloud.backgroundRefresh()
        }
        .backgroundTask(.urlSession(CloudTransfers.sessionIdentifier)) {
            await cloud.transferSessionWake()
        }
    }
}
