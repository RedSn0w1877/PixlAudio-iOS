import BackgroundTasks
import Foundation
import UIKit

/// Keeps TAIS Studio jobs running when the app goes to the background — iOS's counterpart of Android's foreground
/// service with its progress notification (`TaisForegroundNotifications`). Each user-started run submits a
/// `BGContinuedProcessingTaskRequest` (iOS 26): the system shows its title, subtitle and progress in a Live Activity,
/// where the person can also cancel it (the expiration handler cancels the jobs). If the request can't be submitted,
/// a plain background-task assertion buys the usual extra seconds instead.
@MainActor
final class TaisBackgroundRun {
    static let identifier = "io.github.redsn0w1877.pixlaudio.tais-studio"
    /// Cloud Studio's "Send N songs" preparation (its own identifier, so the two runs never share a task).
    static let cloudPrepareIdentifier = "io.github.redsn0w1877.pixlaudio.cloud-prepare"

    /// The `BGTaskSchedulerPermittedIdentifiers` entry this run submits.
    let identifier: String

    /// Called when the system or the person ends the run early.
    var onExpired: (() -> Void)?

    private var registered = false
    private var task: BGContinuedProcessingTask?
    private var isActive = false
    private var assertion: UIBackgroundTaskIdentifier = .invalid
    /// Whether this run has told `HeavyWorkGate` that iOS granted it background time (the continued-processing task, or
    /// the assertion that covers the gap before it): heavy work may carry on out of the foreground only inside one.
    private var windowOpen = false
    private var pendingTitle = ""
    private var pendingSubtitle = ""
    private var pendingFraction = 0.0
    /// The last time the system was told (every update is an IPC round trip to the system's Live Activity).
    private var lastSent: ContinuousClock.Instant?
    private static let minUpdateGap: Duration = .milliseconds(500)

    init(identifier: String = TaisBackgroundRun.identifier) {
        self.identifier = identifier
    }

    /// Starts a run (from a button tap). Safe to call while one is active.
    func begin(title: String, subtitle: String) {
        pendingTitle = title
        pendingSubtitle = subtitle
        guard !isActive else {
            update(subtitle: subtitle, fraction: pendingFraction)
            return
        }
        isActive = true
        pendingFraction = 0
        register()
        // The ordinary ~30 s of background time covers the gap until the system hands over the continued-processing
        // task (`attach` gives this back), and all of the run when the request is refused.
        beginAssertion()
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Refused (not allowed now, or the simulator): the assertion above is all there is.
        }
    }

    /// Progress for the system UI (0…1) and the line under the title.
    func update(subtitle: String, fraction: Double) {
        pendingSubtitle = subtitle
        pendingFraction = min(max(fraction, 0), 1)
        guard let task else { return }
        // Progress arrives many times a second; the system shows it twice a second at most.
        let now = ContinuousClock.now
        if let lastSent, now - lastSent < Self.minUpdateGap, pendingFraction < 1 { return }
        lastSent = now
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = Int64(pendingFraction * 1000)
        task.updateTitle(pendingTitle, subtitle: subtitle)
    }

    /// Ends the run.
    func end(success: Bool) {
        isActive = false
        lastSent = nil
        if let task {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: success)
            self.task = nil
        }
        endAssertion()
        updateWindow()
    }

    private func register() {
        guard !registered else { return }
        registered = true
        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let continued = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                guard let self, self.isActive else {
                    continued.setTaskCompleted(success: true)
                    return
                }
                self.attach(continued)
            }
        }
    }

    private func attach(_ task: BGContinuedProcessingTask) {
        self.task = task
        updateWindow()
        lastSent = nil
        endAssertion()
        task.expirationHandler = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.task = nil
                    self.isActive = false
                    self.updateWindow()
                    self.onExpired?()
                }
            }
        }
        update(subtitle: pendingSubtitle, fraction: pendingFraction)
    }

    private func beginAssertion() {
        guard assertion == .invalid else { return }
        assertion = UIApplication.shared.beginBackgroundTask(withName: "TAIS Studio") { [weak self] in
            MainActor.assumeIsolated { self?.endAssertion() }
        }
        updateWindow()
    }

    private func endAssertion() {
        guard assertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(assertion)
        assertion = .invalid
        updateWindow()
    }

    private func updateWindow() {
        let wanted = task != nil || assertion != .invalid
        guard wanted != windowOpen else { return }
        windowOpen = wanted
        if wanted { HeavyWorkGate.shared.windowOpened() } else { HeavyWorkGate.shared.windowClosed() }
        DiagnosticsLog.shared.log("background", "\(identifier.hasSuffix("cloud-prepare") ? "cloud prepare" : "studio") window \(wanted ? "open" : "closed")")
    }
}
