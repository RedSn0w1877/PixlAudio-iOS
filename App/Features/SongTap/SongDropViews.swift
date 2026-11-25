import PixlLibrary
import SwiftUI

// The Song Drop pieces shared by the Song Tap screen and its diagnostics screen (Android `NearbyList`, `ArmedCard` and `SongDropAsk`
// in `SongTapScreen.kt`): the phones nearby, the armed card after a yes, and the "Song drop to X?" question. A sender only beams to
// a phone it said yes to, and a tap with no yes is ignored, so the question has to be reachable wherever taps happen.

/// The phones that advertise as receivers inside the list gate, strongest first. A row is "Close" inside the near gate, "Nearby"
/// otherwise; a tap on it asks "Song drop to X?".
struct SongDropNearbyList: View {
    let entries: [SongTapNearbyEntry]
    let onPick: (SongTapNearbyEntry) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SongTapStrings.dropNearbyTitle)
                .pixlFont(.titleSmall)
                .foregroundStyle(theme.primary)
            if entries.isEmpty {
                Text(SongTapStrings.dropNearbyEmpty)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            ForEach(entries, id: \.id) { entry in
                Button { onPick(entry) } label: {
                    GlassCard(cornerRadius: 24, tint: theme.surfaceContainerHigh) {
                        HStack(spacing: 14) {
                            Image(systemName: "iphone.gen3")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(theme.primary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .pixlFont(.titleMedium)
                                    .foregroundStyle(theme.onSurface)
                                    .lineLimit(1)
                                Text(entry.near ? SongTapStrings.dropSignalClose : SongTapStrings.dropSignalNearby)
                                    .pixlFont(.bodySmall)
                                    .foregroundStyle(theme.onSurfaceVariant)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .contentShape(.rect)
                    }
                }
                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.97))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("songTap.nearby.\(entry.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(PixlMotion.state, value: entries.map(\.id))
    }
}

/// After a yes: the sender waits for the touch, armed to that one phone.
struct SongDropArmedCard: View {
    let peerName: String?
    let onCancel: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        GlassCard(cornerRadius: 28, tint: theme.primaryContainer) {
            VStack(spacing: 8) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(theme.onPrimaryContainer)
                    .accessibilityHidden(true)
                Text(SongTapStrings.dropArmedTitle)
                    .pixlFont(.headlineSmall)
                    .foregroundStyle(theme.onPrimaryContainer)
                    .multilineTextAlignment(.center)
                Text(SongTapStrings.dropArmedTo(peerName ?? SongTapStrings.dropOtherPhone))
                    .pixlFont(.titleMedium)
                    .foregroundStyle(theme.onPrimaryContainer)
                    .multilineTextAlignment(.center)
                Button(action: onCancel) {
                    Text(SongTapStrings.dropArmedCancel)
                        .pixlFont(.titleMedium, weight: .semibold)
                        .foregroundStyle(theme.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(.capsule)
                }
                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.94))
                .accessibilityIdentifier("songTap.cancelDrop")
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("songTap.armed")
    }
}

/// The "Song drop to X?" question: for the phone picked from the list (`picked`) or the one the route asks about (`ui.prompt`), while a
/// sender is waiting and the song can be sent. Yes arms the beam to that phone, No silences it. `answered` is the phone just answered,
/// so the question is not asked again while the offer is being made.
struct SongDropAsk: ViewModifier {
    let ui: SongTapUiState
    let enabled: Bool
    @Binding var picked: SongTapNearbyEntry?
    @Binding var answered: Int?
    let controller: SongTapController

    func body(content: Content) -> some View {
        let asking = Self.asking(ui, enabled: enabled, picked: picked, answered: answered)
        content
            .alert(SongTapStrings.dropConfirmTitle(asking?.name ?? ""),
                   isPresented: Binding(get: { asking != nil }, set: { if !$0 { picked = nil } }),
                   presenting: asking) { entry in
                Button(SongTapStrings.dropYes) {
                    answered = entry.id
                    picked = nil
                    controller.approve(peer: entry.id, name: entry.name)
                }
                Button(SongTapStrings.dropNo, role: .cancel) {
                    answered = entry.id
                    picked = nil
                    controller.decideNo(peer: entry.id)
                }
            } message: { _ in
                Text(SongTapStrings.dropConfirmBody(ui.nowPlaying?.title ?? ""))
            }
            .onChange(of: ui.prompt?.id) { _, new in if new != answered { answered = nil } }
    }

    /// The phone to ask about: the one picked from the list, else the one the route says is inside the near gate. Only while `enabled`
    /// (sending over Bluetooth, no code on screen), waiting, with a song that can be sent.
    static func asking(_ ui: SongTapUiState, enabled: Bool, picked: SongTapNearbyEntry?, answered: Int?) -> SongTapNearbyEntry? {
        let waiting = ui.phase == .armed || ui.phase == .found || ui.phase == .near
        guard ui.allowed, enabled, waiting, ui.nowPlaying?.canSend == true else { return nil }
        if let picked { return picked }
        if let prompt = ui.prompt, prompt.id != answered { return prompt }
        return nil
    }
}

extension View {
    func songDropAsk(ui: SongTapUiState, enabled: Bool, picked: Binding<SongTapNearbyEntry?>, answered: Binding<Int?>,
                     controller: SongTapController) -> some View {
        modifier(SongDropAsk(ui: ui, enabled: enabled, picked: picked, answered: answered, controller: controller))
    }
}
