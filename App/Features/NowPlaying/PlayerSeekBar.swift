import PixlModel
import SwiftUI

/// The full player's progress section (Android `PlayerProgressBarSection` + `EfficientSlider` +
/// `EfficientTimeLabels`; the same seek-hold rules as `PlayerSeekBar`): the track, then position · audio-format
/// chip · duration. Position is never observable state: a `TimelineView` samples `PlaybackStore.clock` at most four
/// times a second while playing (paused: no ticks) and only the `Canvas` and the labels redraw.
///
/// The track is Android's glass-mode scrubber shape (`MediaScrubber`) in the wavy slider's geometry: a 5 pt rounded
/// line, the played part in `onPrimaryContainer`, the rest at 20 %, a 16 pt thumb with a 6 pt gap and a 3 pt stop dot
/// at the end. Drag to scrub (haptic every 5 %), release to seek; tap seeks. After a seek the thumb holds the target
/// until playback catches up (within 4 %) or 5 s pass.
struct PlayerSeekBar: View {
    let song: Song
    let isPlaying: Bool
    /// Whether the section is on screen (the sheet's full player is visible): no ticks otherwise.
    var isActive = true
    let clock: PlaybackClock
    let onSeek: (Int64) -> Void
    var onScrubbingChange: (Bool) -> Void = { _ in }

    @Environment(\.playerTheme) private var theme
    @Environment(SettingsStore.self) private var settings

    @State private var scrubFraction: Double?
    @State private var heldTarget: Double?
    @State private var heldAt = Date.distantPast
    @State private var hapticStep = -1

    var body: some View {
        let textColor = theme.onPrimaryContainer
        TimelineView(.animation(minimumInterval: 0.25, paused: !(isPlaying && isActive) || scrubFraction != nil)) { context in
            let duration = PlayerFormat.displayDuration(reportedMs: clock.durationMs, hintMs: song.duration)
            let progress = displayedFraction(durationMs: duration, now: context.date)
            VStack(spacing: 0) {
                track(progress: progress, color: textColor)
                    .padding(.vertical, 8)
                labels(positionMs: Int64((progress * Double(max(duration, 1))).rounded()), durationMs: duration,
                       color: textColor)
            }
            .frame(minHeight: 70, alignment: .top)
        }
        .onChange(of: song.id) { _, _ in
            scrubFraction = nil
            heldTarget = nil
        }
        .sensoryFeedback(.selection, trigger: hapticStep)
    }

    private func displayedFraction(durationMs: Int64, now: Date) -> Double {
        if let scrubFraction { return scrubFraction }
        let actual = durationMs > 0 ? min(max(Double(clock.positionMs) / Double(durationMs), 0), 1) : 0
        if let heldTarget, now.timeIntervalSince(heldAt) < 5, abs(actual - heldTarget) >= 0.04 {
            return heldTarget
        }
        return actual
    }

    // MARK: Track

    private func track(progress: Double, color: Color) -> some View {
        Canvas { context, size in
            let stroke: CGFloat = 5
            let thumbRadius: CGFloat = scrubFraction == nil ? 8 : 9
            let gap: CGFloat = 6
            let midY = size.height / 2
            let usable = max(size.width - thumbRadius * 2, 1)
            let thumbX = thumbRadius + usable * progress
            let start = thumbRadius - stroke / 2
            let end = size.width - thumbRadius + stroke / 2
            if thumbX - thumbRadius - gap > start {
                var played = Path()
                played.move(to: CGPoint(x: start, y: midY))
                played.addLine(to: CGPoint(x: thumbX - thumbRadius - gap, y: midY))
                context.stroke(played, with: .color(color), style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            }
            if thumbX + thumbRadius + gap < end {
                var rest = Path()
                rest.move(to: CGPoint(x: thumbX + thumbRadius + gap, y: midY))
                rest.addLine(to: CGPoint(x: end, y: midY))
                context.stroke(rest, with: .color(color.opacity(0.2)),
                               style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            }
            // Stop indicator (3 pt dot at the end of the track).
            let stop = CGRect(x: end - stroke / 2 - 1.5, y: midY - 1.5, width: 3, height: 3)
            context.fill(Path(ellipseIn: stop), with: .color(color))
            let thumb = CGRect(x: thumbX - thumbRadius, y: midY - thumbRadius, width: thumbRadius * 2,
                               height: thumbRadius * 2)
            context.fill(Path(ellipseIn: thumb), with: .color(color))
        }
        .frame(height: 24)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trackWidth = $0 }
        .contentShape(.rect)
        .gesture(scrubGesture)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(PlayerFormat.duration(Int64(progress * Double(max(song.duration, 1)))))
        .accessibilityAdjustableAction { direction in
            let step: Int64 = 10_000
            let position = clock.positionMs
            onSeek(direction == .increment ? position + step : max(position - step, 0))
        }
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if scrubFraction == nil { onScrubbingChange(true) }
                let scrubbed = fraction(atX: value.location.x)
                scrubFraction = scrubbed
                let step = Int(scrubbed * 20)
                if step != hapticStep { hapticStep = step }
            }
            .onEnded { value in
                let target = fraction(atX: value.location.x)
                let duration = PlayerFormat.displayDuration(reportedMs: clock.durationMs, hintMs: song.duration)
                heldTarget = target
                heldAt = Date()
                scrubFraction = nil
                onScrubbingChange(false)
                onSeek(Int64((target * Double(max(duration, 1))).rounded()))
            }
    }

    @State private var trackWidth: CGFloat = 1

    /// The thumb's centre travels between the two thumb radii.
    private func fraction(atX x: CGFloat) -> Double {
        let usable = max(trackWidth - 16, 1)
        return Double(min(max((x - 8) / usable, 0), 1))
    }

    // MARK: Labels

    private func labels(positionMs: Int64, durationMs: Int64, color: Color) -> some View {
        ZStack {
            HStack {
                Text(PlayerFormat.duration(positionMs / 1000 * 1000))
                Spacer()
                Text(PlayerFormat.duration(durationMs))
            }
            .pixlFont(.custom(size: 12, weight: .semibold, lineHeight: 16, tracking: 0.4))
            .monospacedDigit()
            .foregroundStyle(color)
            if settings.appearance.fullPlayerShowFileInfo, let label = PlayerFormat.audioMetaLabel(song: song) {
                Text(label)
                    .pixlFont(.custom(size: 11, weight: .medium, lineHeight: 16, tracking: 0.5))
                    .lineLimit(1)
                    .foregroundStyle(color.opacity(0.96))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.14), in: Capsule())
                    .padding(.horizontal, 58)
            }
        }
    }
}

/// Number and label formatting shared by the player screens (Android `formatDuration`, `AudioMetaUtils`).
nonisolated enum PlayerFormat {
    /// Android `formatDuration`: "mm:ss", or "hh:mm:ss" from an hour.
    static func duration(_ milliseconds: Int64) -> String {
        guard milliseconds > 0 else { return "00:00" }
        let total = Int(milliseconds / 1000)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02ld:%02ld:%02ld", hours, minutes, seconds)
        }
        return String(format: "%02ld:%02ld", minutes, seconds)
    }

    /// The duration the progress section shows: the player's when it agrees with the library's (±1.5 s), else the
    /// shorter of the two (Android `displayDurationValue`).
    static func displayDuration(reportedMs: Int64, hintMs: Int64) -> Int64 {
        let reported = max(reportedMs, 0)
        let hint = max(hintMs, 0)
        if reported <= 0 && hint <= 0 { return 0 }
        if reported <= 0 { return hint }
        if hint <= 0 { return reported }
        if abs(reported - hint) <= 1500 { return reported }
        return min(reported, hint)
    }

    /// Android `bitrateToQualityTierLabel`.
    static func qualityTier(bitrateKbps: Int) -> String {
        switch bitrateKbps {
        case ...96: "Low"
        case ...160: "Standard"
        case ...256: "High"
        default: "Ultrasound"
        }
    }

    /// Android `AudioMetaUtils.mimeTypeToFormat` ("-" when unknown).
    static func format(mimeType: String?) -> String {
        guard let raw = mimeType?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return "-" }
        let mime = raw.split(separator: ";").first.map(String.init) ?? raw
        switch mime {
        case "audio/mpeg", "audio/mp3", "audio/x-mp3", "audio/mpeg3": return "mp3"
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave": return "wav"
        case "audio/ogg", "application/ogg", "audio/vorbis", "audio/x-vorbis": return "ogg"
        case "audio/opus", "audio/x-opus": return "opus"
        case "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/mp4a-latm": return "m4a"
        case "audio/aac", "audio/aacp": return "aac"
        case "audio/amr", "audio/amr-wb", "audio/3gpp": return "amr"
        case "audio/alac", "audio/x-alac": return "alac"
        case "audio/aiff", "audio/x-aiff", "audio/aif", "audio/x-aifc": return "aiff"
        case "audio/x-ms-wma", "audio/wma": return "wma"
        default:
            return mime.hasPrefix("audio/") ? String(mime.dropFirst("audio/".count)) : "-"
        }
    }

    /// Android `formatAudioMetaLabel`: "48.0 kHz • Standard • OPUS" (the configured quality tier when the bitrate is
    /// unknown).
    static func audioMetaLabel(song: Song, fallbackTier: String = "Ultrasound") -> String? {
        var parts: [String] = []
        if let rate = song.sampleRate, rate > 0 {
            parts.append(String(format: "%.1f kHz", locale: Locale(identifier: "en_US"), Double(rate) / 1000))
        }
        let tier = song.bitrate.flatMap { $0 > 0 ? qualityTier(bitrateKbps: $0 / 1000) : nil } ?? fallbackTier
        let format = format(mimeType: song.mimeType)
        parts.append(format == "-" ? tier : "\(tier) \u{2022} \(format.uppercased())")
        return parts.joined(separator: " \u{2022} ")
    }
}
