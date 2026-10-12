import Foundation
import MediaPlayer
import UIKit

/// When the library rescans by itself (architecture §2: "incremental rescans on foreground/pull/manual"): once after
/// launch, whenever the app returns to the foreground, and when the device music library changes. Requests are
/// debounced and coalesce into one incremental scan (`LibraryStore.refresh`); manual refreshes call the store
/// directly.
final class LibraryAutoRefresh {
    private let library: LibraryStore
    private var observers: [any NSObjectProtocol] = []
    private var isObservingMediaLibrary = false
    private var pending: Task<Void, Never>?
    /// Called after each automatic rescan finished (the artist pictures look for new artists).
    var onRefreshed: (() -> Void)?

    init(library: LibraryStore) {
        self.library = library
    }

    func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(after: .seconds(1)) }
        })
        observeMediaLibraryIfAuthorized()
        schedule(after: .milliseconds(300))
    }

    /// Starts the music-library change notifications (call again after access was granted).
    func observeMediaLibraryIfAuthorized() {
        guard !isObservingMediaLibrary, MediaLibraryImporter.isAuthorized else { return }
        isObservingMediaLibrary = true
        MPMediaLibrary.default().beginGeneratingLibraryChangeNotifications()
        observers.append(NotificationCenter.default.addObserver(
            forName: .MPMediaLibraryDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(after: .seconds(2)) }
        })
    }

    func schedule(after delay: Duration) {
        pending?.cancel()
        // Utility priority: a rescan nobody asked for must not compete with scrolling and animations.
        pending = Task(priority: .utility) { [library, weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            // Safe mode (the app closed unexpectedly) and Emergency stop: no rescan by itself; Library's own refresh does it.
            guard HeavyWorkGate.shared.allowsLaunchWork else {
                DiagnosticsLog.shared.log("safemode", "automatic library rescan held back")
                return
            }
            try? await library.refresh(mode: .incremental)
            self?.onRefreshed?()
        }
    }
}
