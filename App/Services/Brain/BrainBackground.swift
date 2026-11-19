import BackgroundTasks
import Foundation
import PixlLibrary

/// The music brain's one background job (docs/brain-spec.md, 3.7, stage 2a): once a day, when iOS finds the phone idle,
/// the refresh asks YouTube Music for the radios of the listener's own tracks and the artist pages of their top artists,
/// so Daily Mix and Your Mix have new music to pick from. Android's twin is `BrainRefreshWorker`.
///
/// iOS decides when (and whether) a `BGProcessingTask` ever runs, so the same work also runs in the foreground when the
/// app has been in front for a while (`BrainService.sceneBecameActive`). Both go through `BrainService.runRefresh`, which
/// keeps the conditions of 3.7: an unmetered network, no Low Power Mode, never while music plays, the off switches.
///
/// It is requested after the brain is first used (a mix was built), never at launch. Registering the handler is all that
/// happens at launch: no brain code runs until a task is granted.
@MainActor
final class BrainBackground {
    static let identifier = "io.github.redsn0w1877.pixlaudio.brain-refresh"
    private static var registered = false

    /// Registers the BGProcessing handler. Must run before the app finishes launching (`AppEnvironment.init`) and only
    /// once per launch (a second registration of an identifier is a fatal error).
    static func register(for service: BrainService) {
        guard !registered else { return }
        registered = true
        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak service] task in
            MainActor.assumeIsolated {
                guard let processing = task as? BGProcessingTask, let service else {
                    task.setTaskCompleted(success: false)
                    return
                }
                Run.start(processing, service: service)
            }
        }
    }

    /// Asks the system for the next run: a day after the last one, plus up to an hour (a million phones should not ask
    /// at one minute), on a network, without needing the charger. A request replaces an earlier one.
    static func schedule(lastRunMs: Int64?) {
        let now = currentTimeMillis()
        let unit = Double.random(in: 0..<1)
        let at = RefreshSchedule.earliestBegin(lastRunMs: lastRunMs, nowMs: now, unit: unit)
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSince1970: TimeInterval(at) / 1000)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        // Background App Refresh off, or the simulator: the foreground fallback runs it instead.
        try? BGTaskScheduler.shared.submit(request)
    }

    /// One BGProcessingTask: the refresh runs in a task; whichever of "done" and "iOS says time is up" comes first
    /// reports the completion, exactly once.
    @MainActor
    private final class Run {
        private let task: BGProcessingTask
        private var finished = false
        private var work: Task<Void, Never>?

        private init(task: BGProcessingTask) {
            self.task = task
        }

        static func start(_ task: BGProcessingTask, service: BrainService) {
            let run = Run(task: task)
            task.expirationHandler = {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { run.finish(success: false) }
                }
            }
            run.work = Task { @MainActor [weak service] in
                // The next request first: a crash or an expiry in the middle still leaves one in place.
                await service?.scheduleFromLastRun()
                await service?.runRefresh()
                await service?.scheduleFromLastRun()
                run.finish(success: true)
            }
        }

        private func finish(success: Bool) {
            guard !finished else { return }
            finished = true
            if !success { work?.cancel() }
            // The handler holds this run and this run holds the task: break the cycle once the task is reported.
            task.expirationHandler = nil
            work = nil
            task.setTaskCompleted(success: success)
        }
    }
}
