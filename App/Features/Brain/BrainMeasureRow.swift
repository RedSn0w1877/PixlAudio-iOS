import Foundation
import PixlLibrary
import SwiftUI

/// Developer mode › Maintenance: what stage 5 measured from the song that is playing (docs/brain-spec.md 3.3; Android
/// `BrainMeasureRow`). One row; the subtitle is the tempo with its confidence, the integrated loudness, whether the tempo is the one
/// the flow ordering uses, and how long it took; or why there is nothing yet. Redrawn only when the measurer's status changes (a
/// few times per song).
struct BrainMeasureRow: View {
    let measurer: AudioMeasurer?
    @Environment(\.appTheme) private var theme

    var body: some View {
        SettingsItemRow(title: BrainMeasureStrings.title, subtitle: BrainMeasureStrings.describe(measurer?.status),
                        systemImage: "waveform", iconColor: theme.secondary,
                        identifier: "settings.developer.brainMeasure") {}
    }
}

/// The row's words (Android `strings_brain.xml`, `brain_measure_*`). Developer-facing; plain words.
enum BrainMeasureStrings {
    static var title: String { String(localized: "Tempo and loudness") }
    static var none: String { String(localized: "Play a song to see what the phone measures from it") }
    static var waiting: String { String(localized: "Waiting a few seconds into the song") }
    static var measuring: String { String(localized: "Listening to 40 seconds of it now") }
    static var measuringFile: String { String(localized: "Listening to 40 seconds of the downloaded file now") }
    static var wifi: String { String(localized: "Waits for Wi-Fi (only downloaded songs are measured on mobile data)") }
    static var off: String { String(localized: "Off while the new picks engine is off") }
    static var unknown: String { String(localized: "This song could not be matched to a recording") }
    static var failed: String { String(localized: "Could not decode this song; tries again tomorrow") }
    static var gaveUp: String { String(localized: "Gave up on this song after three tries") }
    static func tempo(_ bpm: String, _ percent: Int) -> String { String(localized: "\(bpm) bpm, \(percent)% sure") }
    static var tempoNone: String { String(localized: "No steady beat") }
    static func loudness(_ lufs: String) -> String { String(localized: "\(lufs) LUFS") }
    static var loudnessNone: String { String(localized: "loudness unknown") }
    static var used: String { String(localized: "used for flow") }
    static var notUsed: String { String(localized: "kept only when no other tempo is known") }
    static func took(_ seconds: String) -> String { String(localized: "\(seconds) s") }

    private static let posix = Locale(identifier: "en_US_POSIX")

    private static func oneDecimal(_ value: Double) -> String { String(format: "%.1f", locale: posix, value) }

    /// The subtitle for a status; plain text so the row stays one `Text`.
    static func describe(_ status: AudioMeasurer.Status?) -> String {
        guard let s = status else { return none }
        switch s.state {
        case .waiting: return waiting
        case .measuring: return s.fromFile ? measuringFile : measuring
        case .waitingForWifi: return wifi
        case .off: return off
        case .unknownTrack: return unknown
        case .failed: return failed
        case .gaveUp: return gaveUp
        case .done:
            guard let r = s.result else { return failed }
            var parts: [String] = []
            parts.reserveCapacity(4)
            parts.append(r.bpmX10 > 0 && r.tempoConf > 0 ? tempo(oneDecimal(Double(r.bpmX10) / 10.0), r.tempoConf / 10) : tempoNone)
            parts.append(r.loudnessKnown ? loudness(oneDecimal(Double(r.lufsX10) / 10.0)) : loudnessNone)
            parts.append(s.keptTempoSource == TrackDna.tempoOnDevice ? used : notUsed)
            if s.tookMs > 0 { parts.append(took(oneDecimal(Double(s.tookMs) / 1000.0))) }
            return parts.joined(separator: " · ")
        }
    }
}
