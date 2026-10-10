import SwiftUI

/// Experimental › On-device models (iOS only: Android bundles both models in the APK). Same panel style as the other
/// Experimental rows (10 pt `surfaceContainer` glass): each model with its purpose, size and state — Download,
/// a progress bar with Cancel while it downloads, "Installing…", Remove once installed — and the rendered
/// instrumentals with their size and Delete. Jobs download a missing model by themselves; this is where the space
/// can be reclaimed.
struct OnDeviceModelsPanel: View {
    var tintStrength: Double = GlassTint.surface

    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme
    @State private var rendersBytes: Int64 = 0
    @State private var confirmsDeleteRenders = false

    var body: some View {
        let models = env.tais.models
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                SettingsIcon(systemImage: "cpu")
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: "On-device models").pixlFont(.titleMedium).foregroundStyle(theme.onSurface)
                    Text("Lyric Sync and Render Instrumental run on this iPhone. Their models download the first time you use them.")
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(ModelCatalog.tais) { model in
                Rectangle().fill(theme.outlineVariant).frame(height: 1)
                ModelRow(model: model, state: models.state(model.id),
                         onDownload: { models.download(model.id) },
                         onCancel: { models.cancel(model.id) },
                         onDelete: { models.delete(model.id) },
                         onReset: { models.reset(model.id) })
            }
            Rectangle().fill(theme.outlineVariant).frame(height: 1)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rendered instrumentals").pixlFont(.titleSmall).foregroundStyle(theme.onSurface)
                    Text(rendersBytes > 0 ? Self.format(rendersBytes) : "None yet")
                        .pixlFont(.bodySmall).foregroundStyle(theme.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SettingsFillButton(title: "Delete", style: .outlined, enabled: rendersBytes > 0, fullWidth: false) {
                    confirmsDeleteRenders = true
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                   tint: theme.surfaceContainer.opacity(tintStrength))
        .task(id: env.tais.studio.instrumentalRevision) {
            let bytes = await Task.detached(priority: .utility) { InstrumentalFiles.totalBytes }.value
            rendersBytes = LaunchConfiguration.current.isUITest ? 0 : bytes
        }
        .alert("Delete every rendered instrumental?", isPresented: $confirmsDeleteRenders) {
            Button("Delete", role: .destructive) {
                InstrumentalFiles.deleteAll()
                rendersBytes = 0
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They can be rendered again from the song sheet.")
        }
        .animation(PixlMotion.state, value: models.states)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tais.models")
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct ModelRow: View {
    let model: ModelDescriptor
    let state: ModelManager.State
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    let onReset: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title).pixlFont(.titleSmall).foregroundStyle(theme.onSurface)
                    Text(subtitle).pixlFont(.bodySmall).foregroundStyle(isFailed ? theme.error : theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("tais.model.\(model.id.rawValue).status")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                action
            }
            if case .downloading(let fraction) = state {
                TaisProgressBar(fraction: fraction ?? 0)
            }
            if isFailed {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    SettingsFillButton(title: "Delete download", systemImage: "trash", style: .outlined, fullWidth: false,
                                       action: onReset)
                        .accessibilityIdentifier("tais.model.\(model.id.rawValue).reset")
                    SettingsFillButton(title: "Try again", systemImage: "arrow.clockwise", style: .tonal, fullWidth: false,
                                       action: onDownload)
                        .accessibilityIdentifier("tais.model.\(model.id.rawValue).download")
                }
            }
        }
    }

    @ViewBuilder private var action: some View {
        switch state {
        case .notInstalled:
            SettingsFillButton(title: "Download", systemImage: "arrow.down", style: .tonal,
                               fullWidth: false, action: onDownload)
                .accessibilityIdentifier("tais.model.\(model.id.rawValue).download")
        case .failed:
            // "Try again" and "Delete download" sit under the reason.
            EmptyView()
        case .downloading, .installing:
            SettingsFillButton(title: "Cancel", style: .outlined, fullWidth: false, action: onCancel)
                .accessibilityIdentifier("tais.model.\(model.id.rawValue).cancel")
        case .installed:
            SettingsFillButton(title: "Remove", style: .outlined, fullWidth: false, action: onDelete)
                .accessibilityIdentifier("tais.model.\(model.id.rawValue).remove")
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private var subtitle: String {
        let size = OnDeviceModelsPanel.format(model.bytes)
        switch state {
        case .notInstalled: return "\(model.purpose) · \(size) download"
        case .downloading(let fraction):
            guard let fraction else { return "Downloading…" }
            return "Downloading — \(Int(fraction * 100))% of \(size)"
        case .installing: return "Checking and installing…"
        case .installed(let bytes): return "\(model.purpose) · installed, \(OnDeviceModelsPanel.format(bytes))"
        case .failed(let reason): return reason
        }
    }
}
