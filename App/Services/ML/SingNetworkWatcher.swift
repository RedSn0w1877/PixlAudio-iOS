import Foundation
import Network
import PixlNet

/// Whether the phone is on Wi-Fi or Ethernet that is not metered or in Low Data Mode, which is what a cloud Sing waits
/// for while cellular data is off (the button says "Waiting for Wi-Fi"). It watches the network only while such a Sing
/// is under way: `start()` when one begins, `stop()` when it ends, so nothing runs while idle.
@MainActor
final class SingNetworkWatcher {
    /// Optimistic until the first path report arrives.
    private(set) var isUnmetered = true
    /// Called on the main actor when `isUnmetered` changes.
    var onChange: (() -> Void)?

    private var monitor: NWPathMonitor?

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let conditions = NetworkConditionsMonitor.conditions(of: path)
            let unmetered = (conditions.network == .wifi || conditions.network == .wired)
                && !conditions.isExpensive && !conditions.isConstrained
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update(unmetered) } }
        }
        monitor.start(queue: DispatchQueue(label: "io.github.redsn0w1877.pixlaudio.sing-network", qos: .utility))
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        isUnmetered = true
    }

    private func update(_ unmetered: Bool) {
        // A report that was already on its way when `stop()` ran changes nothing.
        guard monitor != nil, unmetered != isUnmetered else { return }
        isUnmetered = unmetered
        onChange?()
    }
}
