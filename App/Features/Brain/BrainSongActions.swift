import PixlLibrary
import PixlModel
import SwiftUI

/// "Start station" and "Not for me" for one song (docs/brain-spec.md, 8.3, 8.5; Android `BrainSongActions`): two
/// rows joined like a grouped list, in the song sheet that every song row's ⋮ opens. The rows render together in
/// one container (4 pt apart, below its blend distance) inside a 24 pt clip, as the sheet's Info rows do.
struct BrainSongActions: View {
    let song: Song
    /// Called after either row did its work (the sheet closes).
    let onDone: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            VStack(spacing: 4) {
                row(BrainStrings.startStation, BrainStrings.startStationSongSupporting,
                    systemImage: "dot.radiowaves.left.and.right", identifier: "songInfo.startStation") {
                    env.brainActions.startSongStation(song)
                    onDone()
                }
                if !StationRules.primaryArtist(of: song).isEmpty {
                    row(BrainStrings.startArtistStation, BrainStrings.startStationArtistSupporting,
                        systemImage: "person.wave.2", identifier: "songInfo.startArtistStation") {
                        env.brainActions.startArtistStation(name: StationRules.primaryArtist(of: song))
                        onDone()
                    }
                }
                row(BrainStrings.moreLikeThis, BrainStrings.moreLikeThisSupporting, systemImage: "hand.thumbsup",
                    identifier: "songInfo.moreLikeThis") {
                    env.brainActions.moreLike(song)
                    onDone()
                }
                row(BrainStrings.notForMe, BrainStrings.notForMeSupporting, systemImage: "hand.thumbsdown",
                    identifier: "songInfo.notForMe") {
                    env.brainActions.notForMe(song)
                    onDone()
                }
                row(BrainStrings.dontCount, BrainStrings.dontCountSupporting, systemImage: "eye.slash",
                    identifier: "songInfo.dontCount") {
                    env.brainActions.dontCount(song)
                    onDone()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func row(_ title: String, _ supporting: String, systemImage: String, identifier: String,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.onSecondaryContainer)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(theme.secondaryContainer))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .pixlFont(.titleMedium)
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                    Text(supporting)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 66)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 6, style: .continuous),
                   tint: theme.surfaceContainerHigh.opacity(GlassTint.surface), interactive: true)
        .accessibilityIdentifier(identifier)
    }
}
