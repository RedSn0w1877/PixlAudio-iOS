import UIKit

/// The honest minimum for a local job that can't truly run in the background: iOS lets an app that was just
/// switched away from finish what it is doing for about 30 seconds (`beginBackgroundTask`), nothing more. A job
/// wrapped in `BackgroundGrace.run` finishes in that window if it can; if it can't, `onExpire` runs (checkpoint,
/// ask for a later background wake, whatever the job has) and the assertion is given back, after which iOS suspends
/// the app and the job carries on the next time PixlAudio is opened. Long jobs the person starts on purpose
/// (lyric sync, instrumentals) use the system's continued-processing task instead (`TaisBackgroundRun`).
///
/// Every path ends the assertion exactly once: normal return, a throw, or the expiry handler. Holding one in the
/// foreground costs nothing.
@MainActor
final class BackgroundGrace {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private let name: String
    private let onExpire: @MainActor () -> Void

    private init(name: String, onExpire: @escaping @MainActor () -> Void) {
        self.name = name
        self.onExpire = onExpire
    }

    /// Runs `body` with a background-task assertion held around it.
    static func run<T>(_ name: String, onExpire: @escaping @MainActor () -> Void = {},
                       _ body: () async throws -> T) async rethrows -> T {
        let grace = BackgroundGrace(name: name, onExpire: onExpire)
        grace.begin()
        defer { grace.end() }
        return try await body()
    }

    private func begin() {
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.expired() }
        }
    }

    private func expired() {
        onExpire()
        end()
    }

    private func end() {
        guard identifier != .invalid else { return }
        let finished = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(finished)
    }
}
