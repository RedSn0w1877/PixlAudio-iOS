import PixlBackup
import SwiftUI
import UniformTypeIdentifiers

/// The restore flow in one full-screen cover (Android: `ImportFileSelectionDialog` → `BackupModuleSelectionDialog`
/// → `BackupTransferProgressDialog` → result): pick a file (or start from one already inspected, as the setup does),
/// choose the modules, restore with the progress dialog on top, then the report.
struct BackupImportFlowView: View {
    nonisolated enum Start: Sendable {
        case pick
        case inspected(InspectedBackup)
        /// Straight to a report (UI tests).
        case report(BackupRestoreReport)
    }

    let start: Start
    /// Called when the flow ends: with the report when a restore ran, nil when the user backed out.
    let onFinish: (BackupRestoreReport?) -> Void

    @Environment(AppEnvironment.self) private var env
    @State private var step: Step = .pick
    @State private var selection: Set<BackupSection> = []
    @State private var isInspecting = false
    @State private var isRestoring = false
    @State private var toast: String?
    @State private var started = false

    private enum Step {
        case pick
        case plan(InspectedBackup)
        case report(BackupRestoreReport)
    }

    var body: some View {
        Group {
            switch step {
            case .pick:
                BackupImportPicker { url in inspect(url) }
                    .overlay(alignment: .bottom) {
                        if isInspecting { BackupBusyCapsule(text: L10n.settingsBackupInspecting).padding(.bottom, 72) }
                    }
            case .plan(let backup):
                BackupRestorePlanView(backup: backup, selection: $selection, inProgress: isRestoring,
                                      onBack: back, onConfirm: { restore(backup) })
            case .report(let report):
                BackupImportReportView(report: report) { onFinish(report) }
            }
        }
        .backupProgressOverlay(env.backup.progress)
        .settingsToast($toast)
        .onAppear(perform: begin)
    }

    private func begin() {
        guard !started else { return }
        started = true
        switch start {
        case .pick: step = .pick
        case .inspected(let backup): show(backup)
        case .report(let report): step = .report(report)
        }
    }

    private func show(_ backup: InspectedBackup) {
        selection = Set(backup.plan.selectedModules)
        withAnimation(PixlMotion.state) { step = .plan(backup) }
    }

    private func back() {
        if case .pick = start {
            withAnimation(PixlMotion.state) { step = .pick }
        } else {
            onFinish(nil)
        }
    }

    private func inspect(_ url: URL) {
        guard !isInspecting else { return }
        isInspecting = true
        Task {
            defer { isInspecting = false }
            do {
                show(try await env.backup.inspect(url: url))
            } catch {
                toast = L10n.settingsBackupInvalidFormat(BackupService.message(of: error))
            }
        }
    }

    private func restore(_ backup: InspectedBackup) {
        guard !isRestoring, !selection.isEmpty else { return }
        isRestoring = true
        Task {
            let report = await env.backup.restore(backup, sections: selection)
            isRestoring = false
            withAnimation(PixlMotion.state) { step = .report(report) }
        }
    }
}

/// The export flow in one cover (Android `BackupSectionSelectionDialog` → `CreateDocument` → progress → toast):
/// choose the sections, build the `.pxpl` under the progress dialog, then save it with the system file exporter.
struct BackupExportFlowView: View {
    @Binding var selection: Set<BackupSection>
    /// Called when the flow ends, with the message to toast (nil when there is nothing to say).
    let onFinish: (String?) -> Void

    @Environment(AppEnvironment.self) private var env
    @State private var document: BackupFileDocument?
    @State private var showsExporter = false
    @State private var fileName = BackupService.defaultFileName()

    var body: some View {
        BackupSectionPicker(selection: $selection, onConfirm: export)
            .backupProgressOverlay(env.backup.progress)
            .fileExporter(isPresented: $showsExporter, document: document, contentType: .pixlBackup,
                          defaultFilename: fileName) { result in
                document = nil
                switch result {
                case .success:
                    onFinish(L10n.settingsDataExportedSuccessfully)
                case .failure(let error):
                    if (error as? CocoaError)?.code == .userCancelled { return }
                    onFinish(L10n.settingsExportFailedFormat(error.localizedDescription))
                }
            }
    }

    private func export() {
        guard !selection.isEmpty, !env.backup.isBusy else { return }
        let sections = selection
        Task {
            do {
                fileName = BackupService.defaultFileName()
                document = try await env.backup.export(sections: sections)
                showsExporter = true
            } catch {
                onFinish(L10n.settingsExportFailedFormat(BackupService.message(of: error)))
            }
        }
    }
}

/// `AppCover.backupImport`: the restore flow presented from the root (a cover attached inside Settings' lazy list did
/// not present reliably). UI tests open it on the module step or the report (`-screen backupRestorePlan|…Report`).
struct BackupImportCover: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router

    var body: some View {
        BackupImportFlowView(start: start) { _ in
            env.backup.importStart = .pick
            router.dismissCover()
        }
    }

    private var start: BackupImportFlowView.Start {
        switch env.launch.screen {
        case .backupRestorePlan?: .inspected(.demo)
        case .backupImportReport?: .report(.demo)
        default: env.backup.importStart
        }
    }
}

/// `AppCover.backupExport`: the export flow presented from the root; its message is toasted by the settings screen.
struct BackupExportCover: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var backup = env.backup
        BackupExportFlowView(selection: $backup.exportSelection) { message in
            backup.exportMessage = message
            router.dismissCover()
        }
    }
}

/// A small busy capsule (Android's "Inspecting…" state of the browse button).
struct BackupBusyCapsule: View {
    let text: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().tint(theme.primary)
            Text(text).pixlFont(.labelLarge).foregroundStyle(theme.onSurface)
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .pixlGlass(in: Capsule(), tint: theme.surfaceContainerHigh.opacity(GlassTint.container))
        .transition(.opacity)
    }
}

extension InspectedBackup {
    /// An Android v3 backup for screenshots: the restore plan as the module dialog shows it (no payloads).
    static let demo: InspectedBackup = {
        let manifest = BackupManifest(schemaVersion: 3, appVersion: "0.7.7-beta2", appVersionCode: 14,
                                      createdAt: 1_759_300_000_000,
                                      deviceInfo: DeviceInfo(manufacturer: "Google", model: "Pixel 9 Pro", androidVersion: 36))
        let counts: [(BackupSection, Int32)] = [(.playlists, 6), (.globalSettings, 52), (.favorites, 149), (.lyrics, 22),
                                                (.searchHistory, 31), (.transitions, 3), (.engagementStats, 325),
                                                (.playbackHistory, 2_242), (.quickFill, 2), (.equalizer, 2)]
        let modules = counts.map(\.0)
        var details: [BackupSection: ModuleRestoreDetail] = [:]
        for (section, count) in counts { details[section] = ModuleRestoreDetail(entryCount: count, sizeBytes: Int64(count) * 120) }
        let plan = RestorePlan(manifest: manifest, backupUri: "PixelPlayer_Backup_1759300000000.pxpl",
                               availableModules: modules, selectedModules: modules, moduleDetails: details)
        return InspectedBackup(bytes: [], fileName: "PixelPlayer_Backup_1759300000000.pxpl", plan: plan)
    }()
}
