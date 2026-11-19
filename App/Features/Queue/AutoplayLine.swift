import PixlLibrary
import SwiftUI

/// The Autoplay line of the queue (docs/brain-spec.md, 8.3, 8.4; Android `AutoplayDivider`): everything under it was
/// picked by the engine. For plain autoplay it is "Autoplay" with its off switch; when the queue is a station it is
/// "Station · X", which has no switch (the listener asked for it by hand). Under it sits the Familiar / Blend /
/// Discover switch, and beside the title the way to "How picks work". Shown above the first pick that is still to
/// come, or at the end of the queue while there is none.
///
/// Plain text on the sheet's own glass, with the system switch: no glass of its own (the rows around it are glass).
struct AutoplayLine: View {
    let isOn: Bool
    /// The queue ended and picks are being looked for.
    let finding: Bool
    /// The picks come from the library alone.
    let fromLibrary: Bool
    /// The queue plays on a Spotify Connect device.
    var onConnect = false
    /// Three skips in a row: Autoplay just turned to something else (shown for a few seconds).
    var changedDirection = false
    /// The queue is a station: what it is named after (a song's title, an artist's name). Nil for plain autoplay.
    var stationTitle: String?
    var stationIsArtist = false
    /// What the station was started from (`Station.sourceSong`, `.sourceArtist`, `.sourceAlbum`, `.sourcePlaylist`).
    var stationSource = Station.sourceSong
    /// `Novelty.familiar`, `.blend` or `.discover`.
    var novelty = Novelty.blend
    let onToggle: (Bool) -> Void
    var onNovelty: ((Int) -> Void)?
    /// "Refresh picks" (8.4): the upcoming picks are replaced by the next best ones.
    var onRefresh: (() -> Void)?
    var onHowPicksWork: (() -> Void)?

    @Environment(\.appTheme) private var theme

    var body: some View {
        let isStation = stationTitle != nil
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        if isStation {
                            Text(title).pixlFont(.titleMedium, weight: .semibold)
                        } else {
                            Text(title).pixlFont(.titleSmall)
                        }
                    }
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
                    Text(subtitle)
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let onHowPicksWork {
                    Button(action: onHowPicksWork) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(theme.onSurfaceVariant)
                            .frame(width: 40, height: 40)
                            .contentShape(.circle)
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    .accessibilityLabel(BrainStrings.howPicksWork)
                    .accessibilityIdentifier("queue.howPicksWork")
                }
                if !isStation {
                    Toggle("Autoplay", isOn: Binding(get: { isOn }, set: { onToggle($0) }))
                        .labelsHidden()
                        .tint(theme.primary)
                        .accessibilityIdentifier("queue.autoplay")
                }
            }
            if let onNovelty, isStation || isOn, !fromLibrary {
                NoveltySwitch(level: novelty, onChange: onNovelty)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
            if let onRefresh, isStation || isOn, !fromLibrary, !finding, !onConnect {
                Button(action: onRefresh) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 14, weight: .semibold))
                        Text(BrainStrings.refreshPicks).pixlFont(.labelLarge)
                    }
                    .foregroundStyle(theme.primary)
                    .padding(.horizontal, 4)
                    .frame(minHeight: 40)
                    .contentShape(.rect)
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityIdentifier("queue.refreshPicks")
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var title: String {
        if let stationTitle { return BrainStrings.stationTitle(stationTitle) }
        return String(localized: "Autoplay")
    }

    private var subtitle: String {
        let isStation = stationTitle != nil
        if !isStation, !isOn { return String(localized: "Off. The queue ends after the last song") }
        if finding { return String(localized: "Finding more like this") }
        if changedDirection { return String(localized: "Skipped three. Changing direction.") }
        if fromLibrary { return String(localized: "From your library") }
        if onConnect { return BrainStrings.connectLine }
        if isStation {
            switch stationSource {
            case Station.sourceAlbum: return BrainStrings.stationSubtitleAlbum
            case Station.sourcePlaylist: return BrainStrings.stationSubtitlePlaylist
            default: return stationIsArtist ? BrainStrings.stationSubtitleArtist : BrainStrings.stationSubtitleSong
            }
        }
        return String(localized: "Taizo picks more after this")
    }
}
