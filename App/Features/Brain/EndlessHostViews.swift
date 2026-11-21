import PixlLibrary
import SwiftUI

/// The host's chips above Ask Taizo's composer when the chat was opened from "Ask the host" (Android `HostChips`): one row that scrolls
/// sideways, each chip one glass capsule, all in one `GlassEffectContainer`. Each is answered on the phone with no model call.
struct HostChipsRow: View {
    let enabled: Bool
    let onChip: (HostChip) -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 8) {
                    ForEach(HostChip.allCases, id: \.rawValue) { chip in
                        Button { onChip(chip) } label: {
                            Text(verbatim: EndlessStrings.label(of: chip))
                                .pixlFont(.labelLarge)
                                .foregroundStyle(enabled ? theme.onSurface : theme.onSurface.opacity(0.38))
                                .padding(.horizontal, 16)
                                .frame(height: 40)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                        .pixlGlass(in: Capsule(), tint: theme.surfaceContainerHigh.opacity(GlassTint.container), interactive: enabled)
                        .accessibilityIdentifier("host.chip.\(chip.rawValue)")
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .scrollIndicators(.hidden)
        .padding(.top, 6)
    }
}

/// "Ask the host": one small glass capsule that opens Ask Taizo in host mode (queue header, player). It exists only while Endless Listening
/// is the queue's station; for any other queue the caller draws nothing.
struct AskHostButton: View {
    let action: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold))
                Text(verbatim: EndlessStrings.askHost).pixlFont(.labelLarge)
            }
            .foregroundStyle(theme.onSurface)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: Capsule(), tint: theme.surfaceContainerHigh.opacity(GlassTint.container), interactive: true)
        .accessibilityIdentifier("endless.askHost")
    }
}
