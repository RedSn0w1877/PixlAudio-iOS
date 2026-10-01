import AVFoundation
import Observation
import SwiftUI

/// The current audio output (the iOS stand-in for Android's cast / Bluetooth state in the player's top bar and the
/// devices sheet): what `AVAudioSession.currentRoute` plays to, refreshed on every route change. Apps can't list or
/// pick AirPlay / Bluetooth devices themselves — the system route picker (`AVRoutePickerView`) does that.
@Observable
final class AudioRouteMonitor {
    static let shared = AudioRouteMonitor()

    nonisolated enum Kind: Sendable, Equatable {
        case phone
        case headphones
        case bluetooth
        case airPlay
        case carAudio
        case other
    }

    private(set) var kind: Kind = .phone
    /// The output's name ("iPhone", "AirPods Pro", "Living Room").
    private(set) var name: String = ""
    /// Whether more than one route is available (`AVRouteDetector.multipleRoutesDetected`).
    private(set) var hasOtherRoutes = false

    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    @ObservationIgnored private let detector = AVRouteDetector()
    @ObservationIgnored private var detectorObserver: (any NSObjectProtocol)?

    private init() {
        refresh()
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                          object: nil, queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        detectorObserver = NotificationCenter.default.addObserver(
            forName: .AVRouteDetectorMultipleRoutesDetectedDidChange, object: detector, queue: .main
        ) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRoutes() }
        }
    }

    /// Starts the (cheap) route detection while a picker is on screen.
    func setDetecting(_ detecting: Bool) {
        detector.isRouteDetectionEnabled = detecting
        refreshRoutes()
    }

    private func refreshRoutes() {
        let multiple = detector.multipleRoutesDetected
        if hasOtherRoutes != multiple { hasOtherRoutes = multiple }
    }

    private func refresh() {
        let output = AVAudioSession.sharedInstance().currentRoute.outputs.first
        let newKind: Kind
        switch output?.portType {
        case .builtInSpeaker?, .builtInReceiver?, nil: newKind = .phone
        case .headphones?, .usbAudio?, .lineOut?: newKind = .headphones
        case .bluetoothA2DP?, .bluetoothLE?, .bluetoothHFP?: newKind = .bluetooth
        case .airPlay?: newKind = .airPlay
        case .carAudio?: newKind = .carAudio
        default: newKind = .other
        }
        if kind != newKind { kind = newKind }
        let newName = output?.portName ?? ""
        if name != newName { name = newName }
    }

    /// SF Symbols for Android's `rounded_mobile_speaker_24` / `rounded_bluetooth_24` / `rounded_cast_24`.
    var systemImage: String {
        switch kind {
        case .phone: "iphone.gen3.radiowaves.left.and.right"
        case .headphones: "headphones"
        case .bluetooth: "headphones"
        case .airPlay: "airplayaudio"
        case .carAudio: "car"
        case .other: "hifispeaker"
        }
    }

    /// Android shows the route's name next to the icon while casting; AirPlay is the iOS counterpart.
    var isRemote: Bool { kind == .airPlay }
}
