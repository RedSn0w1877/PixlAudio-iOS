import Foundation
import PixlNet
import UIKit
import UserNotifications

/// Cloud Studio's local notifications: "Your instrumentals are ready" when a batch finishes while PixlAudio is not on
/// screen. Local only (no push, no extension: product rule 5), so a free Apple ID and Sideloadly are enough. What
/// counts as a finished batch, and the words, are PixlNet's (`CloudBatchNotifier`, `CloudNotificationCopy`); this is
/// only the UserNotifications side.
///
/// Permission is asked once, in context (when the person sends a batch), never at launch.
nonisolated protocol CloudNotifying: Sendable {
    /// Asks for permission the first time (the system shows its prompt once); does nothing afterwards.
    func requestAuthorizationIfNeeded() async
    /// Shows the notification, unless PixlAudio is on screen (the person is looking at the queue) or notifications
    /// are off in iOS Settings.
    func notifyBatchFinished(_ outcome: CloudBatchOutcome) async
    /// What a tap on a notification does (opens the Cloud queue). Set once at launch.
    func install(onOpen: @escaping @MainActor @Sendable () -> Void)
}

nonisolated final class LiveCloudNotifier: CloudNotifying, @unchecked Sendable {
    private let delegate = CloudNotificationDelegate()

    func install(onOpen: @escaping @MainActor @Sendable () -> Void) {
        delegate.onOpen = onOpen
        // The delegate must be in place before the app finishes launching to receive a tap that launched it.
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// Only the status crosses out of the callback (the settings object itself stays inside it).
    private func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { (continuation: CheckedContinuation<UNAuthorizationStatus, Never>) in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func requestAuthorizationIfNeeded() async {
        guard await authorizationStatus() == .notDetermined else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                continuation.resume()
            }
        }
    }

    func notifyBatchFinished(_ outcome: CloudBatchOutcome) async {
        guard await MainActor.run(body: { UIApplication.shared.applicationState != .active }) else { return }
        switch await authorizationStatus() {
        case .authorized, .provisional, .ephemeral: break
        default: return
        }
        let content = UNMutableNotificationContent()
        content.title = CloudNotificationCopy.title(outcome)
        content.body = CloudNotificationCopy.body(outcome)
        content.sound = .default
        content.threadIdentifier = "cloud-studio"
        content.userInfo = [CloudNotificationDelegate.routeKey: CloudNotificationDelegate.cloudQueueRoute]
        // One request per batch: a second delivery of the same batch replaces the first instead of stacking.
        let request = UNNotificationRequest(identifier: "cloud.batch.\(outcome.batchId)", content: content, trigger: nil)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            UNUserNotificationCenter.current().add(request) { _ in continuation.resume() }
        }
    }
}

/// Receives the notification centre's callbacks (any thread).
nonisolated final class CloudNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let routeKey = "pixl.route"
    static let cloudQueueRoute = "cloudQueue"

    /// Set once, before the delegate is installed.
    var onOpen: (@MainActor @Sendable () -> Void)?

    /// A notification that arrives while PixlAudio is on screen is not shown (none is posted then anyway).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let route = response.notification.request.content.userInfo[Self.routeKey] as? String
        guard route == Self.cloudQueueRoute, let open = onOpen else { return }
        await MainActor.run { open() }
    }
}

extension Router {
    /// A tap on "Your instrumentals are ready": the Cloud queue on Home's stack, over whatever was open (the first-run
    /// setup keeps the screen until it is done).
    func openCloudQueue() {
        if case .setup? = cover { return }
        sheet = nil
        if cover != nil { cover = nil }
        selection = .home
        if homePath.last != .cloudQueue { homePath.append(.cloudQueue) }
    }
}
