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

/// A host note as a small card (Endless Listening, Android `HostNoteCard`): the one line the host has about a song, a round surface with a voice
/// mark. It has no close button on purpose: a note is about the songs that come next, so skipping the song is what dismisses it (the note is
/// made again for every song, and a song with no note shows no card). `onAskHost` puts the "Ask the host" button beside the line; nil leaves
/// it out (the queue has the button in its header already).
///
/// The player's card is one glass shape (`glass`); the queue's is a flat tint, because rows scroll and are dragged and a glass layer per
/// row would be work for nothing. No blur of its own, no animation: it is drawn again only when its text changes.
struct HostNoteCard: View {
    let text: String
    var onAskHost: (() -> Void)?
    /// The text and mark colour; the theme's on-surface colour when nil.
    var color: Color?
    var glass = false

    @Environment(\.appTheme) private var theme

    var body: some View {
        let content = color ?? theme.onSecondaryContainer
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .semibold))
                .accessibilityHidden(true)
            Text(verbatim: text)
                .pixlFont(.labelLarge)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onAskHost {
                Button(action: onAskHost) {
                    Text(verbatim: EndlessStrings.askHost)
                        .pixlFont(.labelLarge)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .contentShape(.rect)
                }
                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.96))
                .accessibilityIdentifier("endless.askHost")
            }
        }
        .foregroundStyle(content)
        .padding(.leading, 14)
        .padding(.trailing, onAskHost == nil ? 14 : 4)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(HostCardSurface(glass: glass, tint: content.opacity(0.14), fill: theme.secondaryContainer, shape: shape))
        .accessibilityElement(children: onAskHost == nil ? .combine : .contain)
        .accessibilityIdentifier("endless.hostNote")
    }
}

/// The card's surface: one glass shape in the player, a flat fill in the queue.
private struct HostCardSurface: ViewModifier {
    let glass: Bool
    let tint: Color
    let fill: Color
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        if glass {
            content.pixlGlass(in: shape, tint: tint)
        } else {
            content.background(fill, in: shape)
        }
    }
}
