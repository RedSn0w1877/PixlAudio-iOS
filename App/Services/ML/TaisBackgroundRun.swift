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

    /// Called when the system or the person ends the run early.
    var onExpired: (() -> Void)?

    private var registered = false
    private var task: BGContinuedProcessingTask?
    private var isActive = false
    private var assertion: UIBackgroundTaskIdentifier = .invalid
    private var pendingTitle = ""
    private var pendingSubtitle = ""
    private var pendingFraction = 0.0

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
        let request = BGContinuedProcessingTaskRequest(identifier: Self.identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            beginAssertion()
        }
    }

    /// Progress for the system UI (0…1) and the line under the title.
    func update(subtitle: String, fraction: Double) {
        pendingSubtitle = subtitle
        pendingFraction = min(max(fraction, 0), 1)
        guard let task else { return }
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = Int64(pendingFraction * 1000)
        task.updateTitle(pendingTitle, subtitle: subtitle)
    }

    /// Ends the run.
    func end(success: Bool) {
        isActive = false
        if let task {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: success)
            self.task = nil
        }
        endAssertion()
    }

    private func register() {
        guard !registered else { return }
        registered = true
        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { [weak self] task in
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
        endAssertion()
        task.expirationHandler = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.task = nil
                    self.isActive = false
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
    }

    private func endAssertion() {
        guard assertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(assertion)
        assertion = .invalid
    }
}
