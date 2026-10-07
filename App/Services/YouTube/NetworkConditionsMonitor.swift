import Foundation
import Network
import PixlNet
import Synchronization

/// The network the prefetcher plans for (streaming speed R3): Wi-Fi, Ethernet or cellular, Low Data Mode and
/// metered paths. One `NWPathMonitor`, started the first time music plays (never at launch); path updates arrive on
/// a utility queue and are kept behind a `Mutex`, so reading them is a lock and a copy.
nonisolated final class NetworkConditionsMonitor: @unchecked Sendable {
    private nonisolated struct State: Sendable {
        var started = false
        var conditions = StreamPrefetchPolicy.Conditions.unknown
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "io.github.redsn0w1877.pixlaudio.network-path", qos: .utility)
    private let state = Mutex(State())

    /// The latest path (`.unknown` until the monitor has reported one).
    var conditions: StreamPrefetchPolicy.Conditions { state.withLock { $0.conditions } }

    /// Starts the monitor once.
    func startIfNeeded() {
        let shouldStart = state.withLock { s in
            guard !s.started else { return false }
            s.started = true
            return true
        }
        guard shouldStart else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            let conditions = NetworkConditionsMonitor.conditions(of: path)
            self?.state.withLock { $0.conditions = conditions }
        }
        monitor.start(queue: queue)
    }

    static func conditions(of path: NWPath) -> StreamPrefetchPolicy.Conditions {
        guard path.status == .satisfied else { return StreamPrefetchPolicy.Conditions(network: .offline) }
        let network: StreamPrefetchPolicy.Network
        if path.usesInterfaceType(.wifi) {
            network = .wifi
        } else if path.usesInterfaceType(.wiredEthernet) {
            network = .wired
        } else if path.usesInterfaceType(.cellular) {
            network = .cellular
        } else {
            network = .other
        }
        return StreamPrefetchPolicy.Conditions(network: network, isConstrained: path.isConstrained,
                                               isExpensive: path.isExpensive)
    }

    deinit {
        monitor.cancel()
    }
}
