import BackgroundTasks
import Foundation
import PixlNet
import UIKit

/// Cloud Studio while PixlAudio isn't on screen (design §7.4; no push, no extensions):
/// - BGAppRefresh (`io.github.redsn0w1877.pixlaudio.refresh`), asked for about 15 minutes out and only while jobs are
///   in flight. iOS decides when (maybe a few times a day, never in Low Power Mode or with Background App Refresh
///   off); each wake runs one `CloudStudio.backgroundRefresh()`.
/// - A background-task assertion (about 30 s) around submissions made during a transfer-session wake.
/// - Continued processing (`…cloud-prepare`) for a person-started batch, so preparing songs keeps going after the
///   app is swiped to the background; the system shows its progress and lets the person stop it.
@MainActor
final class CloudBackground {
    static let refreshIdentifier = "io.github.redsn0w1877.pixlaudio.refresh"
    /// iOS is asked for no sooner than this.
    static let refreshDelay: TimeInterval = TimeInterval(CloudTiming.refreshEarliestMs) / 1000

    /// A held background-task assertion; `end()` gives it back.
    struct Assertion {
        let end: () -> Void
    }

    private var assertion: UIBackgroundTaskIdentifier = .invalid
    private let preparingRun = TaisBackgroundRun(identifier: TaisBackgroundRun.cloudPrepareIdentifier)
    private var preparingActive = false

    /// Asks iOS for a refresh about 15 minutes out (replacing an earlier request).
    func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.refreshDelay)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Background App Refresh is off, or the simulator: results come back at the next launch instead.
        }
    }

    func cancelRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshIdentifier)
    }

    /// About 30 extra seconds for a submission burst after a background wake.
    func beginAssertion() -> Assertion {
        if assertion == .invalid {
            assertion = UIApplication.shared.beginBackgroundTask(withName: "Cloud processing") { [weak self] in
                MainActor.assumeIsolated { self?.endAssertion() }
            }
        }
        return Assertion(end: { [weak self] in self?.endAssertion() })
    }

    private func endAssertion() {
        guard assertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(assertion)
        assertion = .invalid
    }

    /// A person-started batch: keep preparing in the background (only from the foreground tap, as Apple requires).
    func beginPreparing(count: Int) {
        guard UIApplication.shared.applicationState == .active else { return }
        preparingActive = true
        preparingRun.begin(title: "Preparing songs for the cloud",
                           subtitle: count == 1 ? "1 song" : "\(count) songs")
    }

    /// Every song of the batch is prepared (or stopped).
    func endPreparing() {
        guard preparingActive else { return }
        preparingActive = false
        preparingRun.end(success: true)
    }
}
