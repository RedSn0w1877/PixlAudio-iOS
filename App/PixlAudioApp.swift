import SwiftUI

/// App entry point. Builds the `AppEnvironment` once and hands its stores to the view tree.
@main
struct PixlAudioApp: App {
    @State private var environment = AppEnvironment(launch: .current)

    var body: some Scene {
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
                .preferredColorScheme(environment.preferredColorScheme)
                .task { await environment.start() }
        }
    }
}
