import BackgroundTasks
import Foundation
import PixlNet
import UIKit

/// Cloud Studio while PixlAudio isn't on screen (design §7.4; no push, no extensions). What iOS really gives:
/// - Transfers on the background URLSession continue in the system's daemon (suspended or terminated, not after a
///   force-quit); iOS wakes the app when they finish (`CloudStudio.transferSessionWake`).
/// - BGAppRefresh (`…refresh`): a short, opportunistic wake (about 30 s, maybe a few times a day, never in Low Power
///   Mode or with Background App Refresh off). One `CloudStudio.backgroundRefresh()` per wake.
/// - BGProcessing (`…cloud-processing`): a longer wake when iOS finds the phone idle (minutes, often overnight),
///   needing the network but not power. `CloudStudio.backgroundProcessing()` polls RunPod and imports results inside a
///   self-imposed window, and stops starting anything new in its last seconds.
/// - A background-task assertion (about 30 s) around submissions made during a wake.
/// - Continued processing (`…cloud-prepare`) for a person-started batch, so preparing songs keeps going after the
///   app is swiped to the background; the system shows its progress and lets the person stop it.
///
/// Which requests exist, and when they are asked for, is `CloudBackgroundPlanner`'s (tested in PixlNet); this class
/// only talks to BackgroundTasks.
@MainActor
final class CloudBackground {
    static let refreshIdentifier = "io.github.redsn0w1877.pixlaudio.refresh"
    /// The long pass. Listed in `BGTaskSchedulerPermittedIdentifiers` (project.yml); `UIBackgroundModes` has
    /// `processing`.
    static let processingIdentifier = "io.github.redsn0w1877.pixlaudio.cloud-processing"

    /// A held background-task assertion; `end()` gives it back.
    struct Assertion {
        let end: () -> Void
    }

    private var assertion: UIBackgroundTaskIdentifier = .invalid
    private let preparingRun = TaisBackgroundRun(identifier: TaisBackgroundRun.cloudPrepareIdentifier)
    private var preparingActive = false
    private var preparingTotal = 0
    private static var processingRegistered = false

    // MARK: Requests

    /// Puts the requests in place that `plan` asks for and takes back the others (a request replaces an earlier one
    /// with the same identifier).
    func apply(_ plan: CloudBackgroundPlan) {
        if let at = plan.refreshNotBeforeMs {
            let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
            request.earliestBeginDate = Date(timeIntervalSince1970: TimeInterval(at) / 1000)
            // Background App Refresh off, or the simulator: results come back at the next launch instead.
            try? BGTaskScheduler.shared.submit(request)
        } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshIdentifier)
        }
        if let at = plan.processingNotBeforeMs {
            let request = BGProcessingTaskRequest(identifier: Self.processingIdentifier)
            request.earliestBeginDate = Date(timeIntervalSince1970: TimeInterval(at) / 1000)
            request.requiresNetworkConnectivity = true
            request.requiresExternalPower = false
            try? BGTaskScheduler.shared.submit(request)
        } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingIdentifier)
        }
    }

    // MARK: The long pass

    /// Registers the BGProcessing handler. Must run before the app finishes launching (`CloudStudio.make`, called from
    /// `AppEnvironment.init`) and only once per launch (a second registration of an identifier is a fatal error).
    static func registerProcessing(for studio: CloudStudio) {
        guard !processingRegistered else { return }
        processingRegistered = true
        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: processingIdentifier, using: .main) { [weak studio] task in
            MainActor.assumeIsolated {
                guard let processing = task as? BGProcessingTask, let studio else {
                    task.setTaskCompleted(success: false)
                    return
                }
                ProcessingRun.start(processing, studio: studio)
            }
        }
    }

    /// One BGProcessingTask: the pass runs in a task; whichever of "done" and "iOS says time is up" comes first
    /// reports the completion, exactly once (`BackgroundCompletionGate`).
    @MainActor
    private final class ProcessingRun {
        private let task: BGProcessingTask
        private var gate = BackgroundCompletionGate()
        private var work: Task<Void, Never>?

        private init(task: BGProcessingTask) {
            self.task = task
        }

        static func start(_ task: BGProcessingTask, studio: CloudStudio) {
            let run = ProcessingRun(task: task)
            // The next request first: a crash or an expiry in the middle still leaves one in place.
            studio.scheduleBackground()
            task.expirationHandler = { [weak studio] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { run.expire(studio) }
                }
            }
            run.work = Task { @MainActor [weak studio] in
                await studio?.backgroundProcessing()
                run.finish(inTime: true)
            }
        }

        /// iOS is taking the time back: stop the pass, save what it knew, tell iOS.
        private func expire(_ studio: CloudStudio?) {
            work?.cancel()
            Task { @MainActor in
                await studio?.backgroundWillExpire()
                self.finish(inTime: false)
            }
        }

        private func finish(inTime: Bool) {
            guard gate.claim(finishedInTime: inTime) else { return }
            // The handler holds this run and this run holds the task: break the cycle once the task is reported.
            task.expirationHandler = nil
            work = nil
            task.setTaskCompleted(success: inTime)
        }
    }

    // MARK: Assertion

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

    // MARK: Preparing a person-started batch

    /// A person-started batch: keep preparing in the background (only from the foreground tap, as Apple requires).
    func beginPreparing(count: Int) {
        guard UIApplication.shared.applicationState == .active else { return }
        preparingTotal = preparingActive ? preparingTotal + count : count
        preparingActive = true
        preparingRun.begin(title: "Preparing songs for the cloud",
                           subtitle: count == 1 ? "1 song" : "\(count) songs")
    }

    /// The system's progress for the run: `remaining` songs still to prepare (each pass reports it, so the bar moves
    /// as songs go up instead of sitting at zero).
    func updatePreparing(remaining: Int) {
        guard preparingActive, preparingTotal > 0 else { return }
        let done = min(max(preparingTotal - remaining, 0), preparingTotal)
        preparingRun.update(subtitle: "\(done) of \(preparingTotal) prepared",
                            fraction: Double(done) / Double(preparingTotal))
    }

    /// Every song of the batch is prepared (or stopped, or waiting out a retry).
    func endPreparing() {
        guard preparingActive else { return }
        preparingActive = false
        preparingTotal = 0
        preparingRun.end(success: true)
    }
}
