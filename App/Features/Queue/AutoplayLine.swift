import SwiftUI

/// The Autoplay line of the queue (docs/brain-spec.md, 8.4; Android `AutoplayDivider`): everything under it was
/// picked by Autoplay, and the switch turns the picking off. Shown above the first pick that is still to come, or at
/// the end of the queue while there is none.
///
/// Plain text on the sheet's own glass, with the system switch: no glass of its own (the rows around it are glass).
struct AutoplayLine: View {
    let isOn: Bool
    /// The queue ended and picks are being looked for.
    let finding: Bool
    /// The picks come from the library alone.
    let fromLibrary: Bool
    let onToggle: (Bool) -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Autoplay")
                    .pixlFont(.titleSmall)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
                Text(subtitle)
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Autoplay", isOn: Binding(get: { isOn }, set: { onToggle($0) }))
                .labelsHidden()
                .tint(theme.primary)
                .accessibilityIdentifier("queue.autoplay")
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var subtitle: LocalizedStringKey {
        if !isOn { return "Off. The queue ends after the last song" }
        if finding { return "Finding more like this" }
        if fromLibrary { return "From your library" }
        return "Taizo picks more after this"
    }
}
