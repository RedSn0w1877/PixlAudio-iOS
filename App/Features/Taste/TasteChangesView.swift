import PixlLibrary
import SwiftUI

/// Settings › Library & storage › Listening history › Ask Taizo's taste changes: every boost, reduction, mute and block
/// Taizo (or you) made to what PixlAudio recommends, with the reason, who set it and how old it is. Each row has
/// Remove (a long press or VoiceOver's actions do the same); Clear all removes them all. Nothing here touches your songs
/// or your history.
struct TasteChangesView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme
    @State private var confirmsClear = false

    var body: some View {
        let store = env.tasteAdjustments
        SettingsScaffold(title: "Taste changes", screenID: "tasteChanges") {
            if store.items.isEmpty {
                emptyCard
                    .padding(.vertical, 8)
            } else {
                SettingsSubsection(title: store.items.count == 1 ? "1 change" : "\(store.items.count) changes") {
                    SettingsGroup {
                        ForEach(store.items) { item in
                            row(item, store: store)
                        }
                    }
                }
                SettingsFillButton(title: "Clear all", systemImage: "arrow.uturn.backward", style: .destructive) {
                    confirmsClear = true
                }
                .padding(.vertical, 8)
                .accessibilityIdentifier("tasteChanges.clearAll")
            }
            Text("Boosts and reductions nudge your mixes, shelves and recommendations. Muted music stays out of automatic mixes but you can still play it yourself. Blocked music is never recommended or queued by Taizo. Your songs and your listening history are never touched.")
                .pixlFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceVariant)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .confirmationDialog("Clear all taste changes?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear all", role: .destructive) {
                withAnimation(PixlMotion.state) { _ = store.removeAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your mixes go back to following only what you listen to.")
        }
        .animation(PixlMotion.state, value: store.revision)
        .task { await store.ensureLoaded() }
    }

    private func row(_ item: TasteAdjustment, store: TasteAdjustmentStore) -> some View {
        HStack(spacing: 12) {
            SettingsIcon(systemImage: TasteChangeText.icon(item.kind))
            VStack(alignment: .leading, spacing: 2) {
                Text(TasteChangeText.title(item))
                    .pixlFont(.titleMedium)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(2)
                Text(TasteChangeText.detail(item, nowMs: env.home.history.clock.nowMs()))
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SettingsFillButton(title: "Remove", style: .tonal, fullWidth: false) {
                withAnimation(PixlMotion.state) { _ = store.remove(id: item.id) }
            }
            .accessibilityLabel("Remove \(TasteChangeText.title(item))")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .settingsRowGlass()
        .accessibilityElement(children: .contain)
        .contextMenu {
            Button(role: .destructive) {
                withAnimation(PixlMotion.state) { _ = store.remove(id: item.id) }
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .accessibilityAction(named: "Remove") {
            withAnimation(PixlMotion.state) { _ = store.remove(id: item.id) }
        }
        .accessibilityIdentifier("tasteChanges.row.\(item.id)")
    }

    private var emptyCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(theme.onSurfaceVariant)
                .accessibilityHidden(true)
            Text("No taste changes")
                .pixlFont(.titleMedium)
                .foregroundStyle(theme.onSurface)
            Text("Ask Taizo for more of an artist, less of a genre, or to keep a song out of your mixes. The changes show up here, and you can undo any of them.")
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .settingsRowGlass()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tasteChanges.empty")
    }
}

/// The wording of a taste change, shared by the screen and the Settings row.
enum TasteChangeText {
    static func icon(_ kind: TasteAdjustmentKind) -> String {
        switch kind {
        case .boost: "arrow.up.circle"
        case .reduce: "arrow.down.circle"
        case .mute: "speaker.slash"
        case .block: "nosign"
        }
    }

    /// "More of Daft Punk", "Much less of Jazz", "Keep Late Night Drive out of mixes", "Block Hollow Pines".
    static func title(_ item: TasteAdjustment) -> String {
        switch item.kind {
        case .boost: return amount(item.strength, strong: "Much more of ", slight: "A bit more of ", normal: "More of ") + item.label
        case .reduce: return amount(item.strength, strong: "Much less of ", slight: "A bit less of ", normal: "Less of ") + item.label
        case .mute: return "Keep \(item.label) out of mixes"
        case .block: return "Block \(item.label)"
        }
    }

    private static func amount(_ strength: Int, strong: String, slight: String, normal: String) -> String {
        if strength >= 3 { return strong }
        if strength <= 1 { return slight }
        return normal
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// "Artist · Taizo · 2 d ago · ends in 28 d — Too much of it lately".
    static func detail(_ item: TasteAdjustment, nowMs: Int64) -> String {
        let kind = item.targetType.rawValue.capitalized
        let who = item.source == .user ? "You" : "Taizo"
        let now = Date(timeIntervalSince1970: Double(nowMs) / 1000)
        let made = Date(timeIntervalSince1970: Double(item.createdMs) / 1000)
        var parts = [kind, who, relative.localizedString(for: made, relativeTo: now)]
        if let expires = item.expiresMs {
            let end = Date(timeIntervalSince1970: Double(expires) / 1000)
            parts.append("ends " + relative.localizedString(for: end, relativeTo: now))
        }
        let line = parts.joined(separator: " · ")
        return item.reason.isEmpty ? line : line + " — " + item.reason
    }

    /// The Settings row's subtitle.
    static func summary(count: Int) -> String {
        switch count {
        case 0: "Nothing changed yet. Ask Taizo to boost, reduce or mute music."
        case 1: "1 change in force"
        default: "\(count) changes in force"
        }
    }
}
