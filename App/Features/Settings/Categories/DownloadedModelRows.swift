import SwiftUI

/// Settings › AI features › "Use downloaded AI model" (2026-10-07, local AI phase 2; iOS only — owner request,
/// docs/parity.md): a switch, off by default, that moves every on-device AI feature to a free model downloaded from
/// PixlAudio's releases (Qwen2.5 1.5B Instruct, Core ML), and the model's own row: its size and Download, the
/// progress with Cancel, "Checking and installing…", then its size on the phone with Delete. Turning the switch on
/// without the model offers the download; it never starts one by itself (it's a large download).
///
/// The row reads `ModelManager`'s state, which changes once per whole percent while downloading; nothing here ticks.
struct DownloadedModelRows: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme
    @State private var confirmsDelete = false
    @State private var stats: LocalModelRuntime.Stats?

    private static let model = ModelCatalog.llm

    var body: some View {
        @Bindable var ai = settings.ai
        let state = env.tais.models.state(.llm)
        let on = ai.useDownloadedModel
        SwitchSettingRow(title: "Use downloaded AI model",
                         subtitle: Self.switchSubtitle(on: on, state: state, cloud: ai.usesCloudAssistant),
                         isOn: Binding(get: { ai.useDownloadedModel }, set: { setOn($0) }),
                         systemImage: "arrow.down.circle", iconColor: on ? theme.primary : theme.tertiary)
        if on || state != .notInstalled {
            modelRow(state)
        }
    }

    private func modelRow(_ state: ModelManager.State) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SettingsIcon(systemImage: "cpu", color: isInstalled(state) ? theme.primary : nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Qwen2.5 1.5B Instruct").pixlFont(.bodyMedium, weight: .medium)
                        .foregroundStyle(theme.onSurface)
                    Text(Self.statusText(state))
                        .pixlFont(.bodySmall)
                        .foregroundStyle(isFailed(state) ? theme.error : theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.ai.localModel.status")
                    if isInstalled(state), let stats {
                        Text(Self.statsText(stats))
                            .pixlFont(.bodySmall)
                            .foregroundStyle(theme.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                action(state)
            }
            if case .downloading(let fraction) = state {
                TaisProgressBar(fraction: fraction ?? 0)
            }
        }
        .padding(16)
        .settingsRowGlass()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.ai.localModel")
        .task(id: isInstalled(state)) {
            stats = isInstalled(state) && !env.launch.isUITest ? LocalModelRuntime.shared.lastStats : nil
            // A finished install or a deletion changes what "With AI" and the AI sheets can do.
            await AIProviderStatus.refresh(env)
        }
        .alert("Delete the downloaded AI model?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It frees \(ModelCatalog.formattedSize(Self.model.bytes)) and turns off \"Use downloaded AI model\": AI features use the system's on-device model again.")
        }
    }

    @ViewBuilder
    private func action(_ state: ModelManager.State) -> some View {
        let models = env.tais.models
        switch state {
        case .notInstalled, .failed:
            SettingsFillButton(title: isFailed(state) ? "Retry" : "Download", systemImage: "arrow.down", style: .tonal,
                               fullWidth: false) { models.download(.llm) }
                .accessibilityIdentifier("settings.ai.localModel.download")
        case .downloading:
            SettingsFillButton(title: "Cancel", style: .outlined, fullWidth: false) { models.cancel(.llm) }
                .accessibilityIdentifier("settings.ai.localModel.cancel")
        case .installing:
            ProgressView().tint(theme.primary)
        case .installed:
            SettingsFillButton(title: "Delete", style: .outlined, fullWidth: false) { confirmsDelete = true }
                .accessibilityIdentifier("settings.ai.localModel.delete")
        }
    }

    private func setOn(_ on: Bool) {
        settings.ai.useDownloadedModel = on
        // Off: the model's memory goes back at once; the next request uses the system's model.
        if !on { LocalModelRuntime.shared.unload() }
        let env = self.env
        Task { await AIProviderStatus.refresh(env) }
    }

    /// Deleting also turns the switch off, so AI features go back to the system's model instead of failing for want
    /// of the file (what the confirmation promises).
    private func delete() {
        LocalModelRuntime.shared.unload()
        env.tais.models.delete(.llm)
        setOn(false)
    }

    private func isInstalled(_ state: ModelManager.State) -> Bool {
        if case .installed = state { return true }
        return false
    }

    private func isFailed(_ state: ModelManager.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    // MARK: Texts

    static func switchSubtitle(on: Bool, state: ModelManager.State, cloud: Bool = false) -> String {
        guard on else {
            return "Off: AI features use the system's on-device model. Turn on to run them on a free model you download instead."
        }
        // A cloud assistant answers while it's switched on (`AiProvider` isn't on-device): say so rather than claim
        // the downloaded model does.
        if cloud { return "On, but the cloud assistant answers while it's switched on." }
        if case .installed = state {
            return "On: playlists, Taizo, translation and Home's greeting run on the downloaded model, privately."
        }
        return "On: download the model below to use it. Until then, AI features can't answer."
    }

    static func statusText(_ state: ModelManager.State) -> String {
        let size = ModelCatalog.formattedSize(model.bytes)
        switch state {
        case .notInstalled: return "Not downloaded · \(size). Wi-Fi recommended."
        case .downloading(let fraction):
            guard let fraction else { return "Downloading…" }
            return "Downloading — \(Int(fraction * 100))% of \(size)"
        case .installing: return "Checking and installing…"
        case .installed(let bytes): return "Downloaded · \(ModelCatalog.formattedSize(bytes)) on this iPhone"
        case .failed(let reason): return reason
        }
    }

    /// The last answer's speed (what only the phone can measure).
    static func statsText(_ stats: LocalModelRuntime.Stats) -> String {
        var text = "Last answer: \(stats.promptTokens) prompt tokens"
        if stats.reusedTokens > 0 { text += " (\(stats.reusedTokens) reused)" }
        text += " in " + String(format: "%.1f s", stats.prefillSeconds)
        if stats.tokensPerSecond > 0 { text += ", then " + String(format: "%.1f", stats.tokensPerSecond) + " tokens/s" }
        text += stats.onCPU ? " on the CPU" : ""
        if let load = stats.loadSeconds { text += " · loaded in " + String(format: "%.1f s", load) }
        return text + "."
    }
}
