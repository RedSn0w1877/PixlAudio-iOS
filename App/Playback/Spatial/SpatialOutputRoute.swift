import AVFoundation
import Foundation
import PixlModel

/// Where the sound goes, as Spatial audio's route rule sees it (cloud audio spec 6.1; integration map section 6).
/// Headphones are wired, Bluetooth for music (A2DP, LE audio) and USB headsets; a Bluetooth speaker counts (the phone
/// cannot tell them apart). Line out (a dock, an amplifier) and the Bluetooth call route are not headphones here,
/// unlike `AudioRouteMonitor`'s grouping for the player's route button.
nonisolated enum SpatialOutputRoute {
    /// The output kind of the session's current port (nil: no output).
    static func kind(of port: AVAudioSession.Port?) -> SpatialOutputKind {
        guard let port else { return .phoneSpeaker }
        switch port {
        case .headphones: return .wiredHeadphones
        case .usbAudio: return .usbHeadset
        case .bluetoothA2DP, .bluetoothLE: return .bluetooth
        case .builtInSpeaker, .builtInReceiver: return .phoneSpeaker
        case .airPlay: return .airPlay
        case .carAudio: return .car
        default: return .other
        }
    }

    /// The output kind, with another device playing the music itself (Spotify Connect) winning over the port.
    static func kind(of port: AVAudioSession.Port?, remoteDevicePlays: Bool) -> SpatialOutputKind {
        remoteDevicePlays ? .remote : kind(of: port)
    }
}
