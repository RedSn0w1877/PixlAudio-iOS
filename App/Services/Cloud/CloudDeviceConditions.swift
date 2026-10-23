import Foundation
import Network
import PixlNet
import UIKit

/// What the phone is doing, for the cloud work that happens without a tap on a song (Settings › Sing › "Prepare songs
/// ahead in the cloud") and for Sing's "is this a connection the upload may use": the network (one path monitor), power
/// saving, heat, battery, free space, safe mode and the heavy lane. The rules that turn these facts into "wait" or "go"
/// are PixlNet's (`CloudAutoConditions`, tested there); this only gathers the facts.
///
/// The path monitor is passive and cheap, but it is still started on demand (`start()`, when the cloud is switched on and
/// PixlAudio is opened), never at launch.
@MainActor
final class CloudDeviceConditions {
    /// The latest network path (`.unknown` until the monitor has reported one).
    private(set) var network = StreamPrefetchPolicy.Conditions.unknown
    /// Called on the main actor when the network path changes (Prepare songs ahead looks again when Wi-Fi comes back).
    var onNetworkChange: (() -> Void)?

    private var monitor: NWPathMonitor?
    /// Free space is a file system call: asked at most every 30 s.
    private var freeBytesCache: (at: Date, bytes: Int64)?

    func start() {
        guard monitor == nil else { return }
        // The battery level and state are only reported while this is on.
        UIDevice.current.isBatteryMonitoringEnabled = true
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let conditions = NetworkConditionsMonitor.conditions(of: path)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update(conditions) } }
        }
        monitor.start(queue: DispatchQueue(label: "io.github.redsn0w1877.pixlaudio.cloud-conditions", qos: .utility))
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        network = .unknown
    }

    private func update(_ conditions: StreamPrefetchPolicy.Conditions) {
        // A report that was already on its way when `stop()` ran changes nothing.
        guard monitor != nil, conditions != network else { return }
        network = conditions
        onNetworkChange?()
    }

    /// The phone's state now, for `CloudAutoConditions.blockedReason`.
    func autoConditions() -> CloudAutoConditions {
        let device = UIDevice.current
        let level = device.batteryLevel
        let state = device.batteryState
        let gate = HeavyWorkGate.shared
        let process = ProcessInfo.processInfo
        return CloudAutoConditions(
            network: network.network, isExpensive: network.isExpensive, isConstrained: network.isConstrained,
            lowPowerMode: process.isLowPowerModeEnabled,
            isHot: process.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue,
            batteryPercent: level < 0 ? -1 : Int((level * 100).rounded()),
            isCharging: state == .charging || state == .full,
            freeBytes: freeBytes(),
            heavyLaneBusy: HeavyJobGovernor.shared.isBusy || gate.conditions.recentMemoryPressure,
            launchWorkAllowed: gate.allowsLaunchWork)
    }

    /// What the phone has free for "important" files; enough (`minFreeBytes`) when it doesn't say.
    private func freeBytes() -> Int64 {
        if let cached = freeBytesCache, Date().timeIntervalSince(cached.at) < 30 { return cached.bytes }
        let free = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? nil
        let bytes = free ?? CloudAutoConditions.minFreeBytes
        freeBytesCache = (Date(), bytes)
        return bytes
    }
}
