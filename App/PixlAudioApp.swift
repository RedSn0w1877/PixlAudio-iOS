import SwiftUI

/// App entry point. Builds the `AppEnvironment` once and hands its stores to the view tree.
@main
struct PixlAudioApp: App {
    @State private var environment = AppEnvironment(launch: .current)

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(environment)
                .environment(environment.playback)
                .environment(environment.router)
                .preferredColorScheme(environment.launch.colorScheme)
        }
    }
}
