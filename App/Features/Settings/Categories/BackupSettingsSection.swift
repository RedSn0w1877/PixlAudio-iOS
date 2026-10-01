import PixlBackup
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Backup & Restore (Android `SettingsCategoryScreen` BACKUP_RESTORE): the "How backup works" notice, the
/// export row (opens the section picker) and the restore row (opens the file step). UI only for now — stage 15 wires
/// PixlBackup's `.pxpl` writer and reader behind `BackupFlow`.
struct BackupSettingsSection: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.appTheme) private var theme

    @State private var exportSections: Set<BackupSection> = BackupSection.defaultSelection
    @State private var showsExport = false
    @State private var showsImport = false
    @State private var toast: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !settings.experimental.backupInfoDismissed {
                BackupInfoNotice { withAnimation(PixlMotion.state) { settings.experimental.backupInfoDismissed = true } }
                Spacer().frame(height: 10)
            }
            SettingsSubsection(title: L10n.settingsCreateBackupSection) {
                ActionSettingRow(title: L10n.settingsExportBackupTitle,
                                 subtitle: L10n.settingsExportBackupSubtitle(selectionSummary),
                                 systemImage: "square.and.arrow.down",
                                 primaryLabel: L10n.settingsActionSelectExport) { showsExport = true }
            }
            SettingsSubsection(title: L10n.settingsRestoreBackupSection, addBottomSpace: false) {
                ActionSettingRow(title: L10n.settingsImportBackupTitle, subtitle: L10n.settingsImportBackupSubtitle,
                                 systemImage: "clock.arrow.circlepath",
                                 primaryLabel: L10n.settingsActionSelectRestore) { showsImport = true }
            }
        }
        .fullScreenCover(isPresented: $showsExport) {
            BackupSectionPicker(selection: $exportSections) {
                showsExport = false
                toast = BackupFlow.unavailableMessage
            }
            .environment(\.appTheme, theme)
        }
        .fullScreenCover(isPresented: $showsImport) {
            BackupImportPicker { _ in
                showsImport = false
                toast = BackupFlow.unavailableMessage
            }
            .environment(\.appTheme, theme)
        }
        .settingsToast($toast)
    }

    private var selectionSummary: String {
        if exportSections.isEmpty { return L10n.settingsExportBackupNone }
        let total = BackupSection.allCases.count
        return exportSections.count == total ? L10n.settingsExportBackupAll
            : L10n.settingsExportBackupPartial(exportSections.count, total)
    }
}

/// Where stage 15 plugs in the `.pxpl` export / inspect / restore (PixlBackup).
nonisolated enum BackupFlow {
    static let unavailableMessage = "Backups aren't available in this build yet."
}

/// Android `BackupInfoNoticeCard`: `primaryContainer` 55 % panel, 20 pt corners, upload icon, title, body, close.
struct BackupInfoNotice: View {
    let onDismiss: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Image(systemName: "doc.badge.arrow.up")
                .font(.system(size: 17))
                .foregroundStyle(theme.onPrimaryContainer)
                .frame(width: 20, height: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.settingsBackupHowDialogTitle)
                    .pixlFont(.titleSmall, weight: .semibold)
                    .foregroundStyle(theme.onPrimaryContainer)
                Text(L10n.settingsBackupHowDialogBody)
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onPrimaryContainer.opacity(0.9))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.onPrimaryContainer)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityLabel(L10n.settingsCdCloseNotice)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                   tint: theme.primaryContainer.opacity(GlassTint.container))
        .accessibilityIdentifier("settings.backup.notice")
    }
}

/// The full-screen top bar of Android's backup dialogs: a close circle and a centred title (24 pt bold).
struct BackupDialogTopBar: View {
    let title: String
    let onClose: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack {
            Text(title)
                .pixlFont(.custom(size: 24, weight: .bold))
                .foregroundStyle(theme.onSurface)
                .lineLimit(1)
                .padding(.horizontal, 60)
            HStack {
                GlassCircleButton(systemImage: "xmark", accessibilityLabel: LocalizedStringKey(L10n.commonClose),
                                  action: onClose)
                Spacer()
            }
            .padding(.leading, 10)
        }
        .frame(height: 64)
    }
}

/// Android `BackupSectionSelectionDialog` (export): the hint card with "n of m selected", one card per section with
/// a switch, and the bottom bar (select all, clear, "Export Backup").
struct BackupSectionPicker: View {
    @Binding var selection: Set<BackupSection>
    let onConfirm: () -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            BackupDialogTopBar(title: L10n.settingsExportBackupTitle) { dismiss() }
            ScrollView {
                VStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.settingsExportBackupHint)
                            .pixlFont(.bodyLarge)
                            .foregroundStyle(theme.onSurfaceVariant)
                        Text(L10n.settingsBackupSectionsSelected(selection.count, BackupSection.allCases.count))
                            .pixlFont(.titleSmall, weight: .semibold)
                            .foregroundStyle(theme.primary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pixlGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                               tint: theme.surfaceContainerHighest.opacity(GlassTint.container))
                    .padding(.top, 12)
                    ForEach(BackupSection.allCases, id: \.self) { section in
                        BackupSectionCard(section: section, isSelected: selection.contains(section)) {
                            if selection.contains(section) { selection.remove(section) } else { selection.insert(section) }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
            bottomBar
        }
        .background(theme.surfaceContainerLowest.ignoresSafeArea())
        .accessibilityIdentifier("screen.backupExport")
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            GlassCircleButton(systemImage: "checklist", accessibilityLabel: LocalizedStringKey(L10n.settingsCdSelectAll),
                              tint: theme.secondaryContainer.opacity(GlassTint.container),
                              foreground: theme.onSecondaryContainer) { selection = Set(BackupSection.allCases) }
            GlassCircleButton(systemImage: "minus.square",
                              accessibilityLabel: LocalizedStringKey(L10n.settingsCdClearSelection)) { selection = [] }
            Spacer()
            Button(action: onConfirm) {
                Label(L10n.settingsExportBackupTitle, systemImage: "square.and.arrow.down")
                    .pixlFont(.labelLarge, weight: .semibold)
                    .foregroundStyle(theme.onTertiaryContainer)
                    .padding(.horizontal, 20)
                    .frame(height: 48)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pixlGlass(in: Capsule(), tint: theme.tertiaryContainer.opacity(GlassTint.prominent), interactive: true)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
    }
}

/// Android `BackupSectionSelectableCard`: 22 pt corners, a 48 pt icon tile (14 pt corners), label, description,
/// switch; selected = primary border and `secondaryContainer` tile.
struct BackupSectionCard: View {
    let section: BackupSection
    let isSelected: Bool
    let onToggle: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: section.systemImage)
                .font(.system(size: 19))
                .foregroundStyle(isSelected ? theme.primary : theme.onSurfaceVariant)
                .frame(width: 48, height: 48)
                .background(isSelected ? theme.secondaryContainer : theme.surfaceContainerHighest,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(section.label).pixlFont(.titleMedium, weight: .bold).foregroundStyle(theme.onSurface)
                Text(section.description).pixlFont(.bodyMedium).foregroundStyle(theme.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(section.label, isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                .labelsHidden()
                .tint(theme.primary)
        }
        .padding(14)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture(perform: onToggle)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous),
                   tint: theme.surfaceContainerLow.opacity(SettingsTint.row), interactive: true)
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(isSelected ? theme.primary.opacity(0.8) : .clear, lineWidth: isSelected ? 2.5 : 1))
        .animation(PixlMotion.state, value: isSelected)
    }
}

/// Android `ImportFileSelectionDialog` (restore, step 1): the hint card, recent backups (empty state), and
/// "Browse for file".
struct BackupImportPicker: View {
    let onPicked: (URL) -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var showsPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BackupDialogTopBar(title: L10n.settingsImportBackupTitle) { dismiss() }
            Text(L10n.settingsImportBackupHint)
                .pixlFont(.bodyLarge)
                .foregroundStyle(theme.onSurfaceVariant)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .pixlGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                           tint: theme.surfaceContainerHighest.opacity(GlassTint.container))
                .padding(.top, 12)
                .padding(.horizontal, 18)
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 32))
                    .foregroundStyle(theme.onSurfaceVariant.opacity(0.5))
                Text(L10n.settingsImportNoRecentTitle).pixlFont(.bodyMedium).foregroundStyle(theme.onSurfaceVariant)
                Text(L10n.settingsImportNoRecentSubtitle)
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant.opacity(0.7))
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .pixlGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                       tint: theme.surfaceContainerLow.opacity(SettingsTint.row))
            .padding(.horizontal, 18)
            Spacer()
            HStack {
                Spacer()
                Button { showsPicker = true } label: {
                    Label(L10n.settingsBackupBrowseFile, systemImage: "doc.badge.arrow.up")
                        .pixlFont(.labelLarge, weight: .semibold)
                        .foregroundStyle(theme.onPrimaryContainer)
                        .padding(.horizontal, 20)
                        .frame(height: 48)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pixlGlass(in: Capsule(), tint: theme.primaryContainer.opacity(GlassTint.prominent), interactive: true)
                Spacer()
            }
            .padding(.vertical, 8)
        }
        .background(theme.surfaceContainerLowest.ignoresSafeArea())
        .fileImporter(isPresented: $showsPicker, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { onPicked(url) }
        }
        .accessibilityIdentifier("screen.backupImport")
    }
}
