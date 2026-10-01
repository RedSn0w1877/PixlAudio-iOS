import PixlBackup
import SwiftUI

/// Android `BackupModuleSelectionDialog` (restore, step 2 — also the setup's restore dialog): the top bar with a back
/// circle and the centred "Restore Modules" title, the backup details card (created, app version, schema, device,
/// "n of m modules selected"), one warning card per inspection warning, one selectable card per module with its
/// entry count, and the bottom bar (select all, clear, "Restore Selected").
struct BackupRestorePlanView: View {
    let backup: InspectedBackup
    @Binding var selection: Set<BackupSection>
    var inProgress = false
    let onBack: () -> Void
    let onConfirm: () -> Void

    @Environment(\.appTheme) private var theme

    private var plan: RestorePlan { backup.plan }

    var body: some View {
        VStack(spacing: 0) {
            BackupFlowTopBar(title: L10n.settingsRestoreModulesTitle, systemImage: "chevron.left",
                             accessibilityLabel: L10n.commonBack, action: onBack)
            ScrollView {
                LazyVStack(spacing: 10) {
                    detailsCard
                        .padding(.top, 12)
                    ForEach(plan.warnings, id: \.self) { warning in
                        BackupWarningCard(text: warning)
                    }
                    ForEach(plan.availableModules, id: \.self) { section in
                        BackupModuleCard(section: section, detail: plan.moduleDetails[section],
                                         isSelected: selection.contains(section), isEnabled: !inProgress) {
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
        .accessibilityIdentifier("screen.backupRestorePlan")
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.settingsBackupDetailsTitle)
                .pixlFont(.titleSmall, weight: .semibold)
                .foregroundStyle(theme.onSurface)
            detail(L10n.settingsBackupCreatedLabel, BackupDates.created(plan.manifest.createdAt))
            HStack(alignment: .top, spacing: 16) {
                detail(L10n.settingsBackupAppVersionLabel,
                       (plan.manifest.appVersion ?? "").isEmpty ? L10n.settingsBackupUnknown : plan.manifest.appVersion ?? "")
                detail(L10n.settingsBackupSchemaLabel, L10n.settingsBackupManifestSchemaV(Int(plan.manifest.schemaVersion)))
                if let device = plan.manifest.deviceInfo, let model = device.model, !model.isEmpty {
                    detail(L10n.settingsBackupDeviceLabel,
                           L10n.settingsBackupManifestDeviceLine(device.manufacturer ?? "", model)
                               .trimmingCharacters(in: .whitespaces))
                }
            }
            Text(L10n.settingsRestoreModulesSelected(selection.count, plan.availableModules.count))
                .pixlFont(.titleSmall, weight: .semibold)
                .foregroundStyle(theme.primary)
            if inProgress {
                HStack(spacing: 10) {
                    ProgressView().tint(theme.primary)
                    Text(L10n.settingsBackupTransferInProgress)
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                   tint: theme.surfaceContainerHighest.opacity(GlassTint.container))
    }

    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).pixlFont(.labelSmall).foregroundStyle(theme.onSurfaceVariant)
            Text(value).pixlFont(.bodySmall).foregroundStyle(theme.onSurface).lineLimit(1)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            GlassCircleButton(systemImage: "checklist", accessibilityLabel: LocalizedStringKey(L10n.settingsCdSelectAll),
                              tint: theme.secondaryContainer.opacity(GlassTint.container),
                              foreground: theme.onSecondaryContainer) {
                selection = Set(plan.availableModules)
            }
            .disabled(inProgress)
            GlassCircleButton(systemImage: "minus.square",
                              accessibilityLabel: LocalizedStringKey(L10n.settingsCdClearSelection)) { selection = [] }
                .disabled(inProgress)
            Spacer()
            BackupPrimaryButton(title: inProgress ? L10n.settingsBackupRestoring : L10n.settingsActionRestoreSelected,
                                systemImage: "clock.arrow.circlepath", isBusy: inProgress,
                                isEnabled: !selection.isEmpty && !inProgress, action: onConfirm)
                .accessibilityIdentifier("backup.restoreSelected")
        }
        .padding(.leading, 22)
        .padding(.trailing, 18)
        .padding(.vertical, 8)
    }
}

/// Android `BackupSectionSelectableCardShared`: 22 pt corners, 48 pt icon tile (14 pt corners), label, description,
/// "n entries · Will replace current data" in `tertiary`, and a switch; selected = primary border.
struct BackupModuleCard: View {
    let section: BackupSection
    let detail: ModuleRestoreDetail?
    let isSelected: Bool
    var isEnabled = true
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
                if let detail, detail.entryCount > 0 {
                    Text(L10n.settingsImportBackupEntries(Int(detail.entryCount)))
                        .pixlFont(.labelSmall)
                        .foregroundStyle(theme.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(section.label, isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                .labelsHidden()
                .tint(theme.primary)
                .disabled(!isEnabled)
        }
        .padding(14)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture { if isEnabled { onToggle() } }
        .pixlGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous),
                   tint: theme.surfaceContainerLow.opacity(SettingsTint.row), interactive: isEnabled)
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(isSelected ? theme.primary.opacity(0.8) : .clear, lineWidth: isSelected ? 2.5 : 1))
        .animation(PixlMotion.state, value: isSelected)
        .accessibilityIdentifier("backup.module.\(section.key)")
    }
}

/// An inspection warning (Android: `errorContainer` 50 %, 14 pt corners, warning icon in `error`).
struct BackupWarningCard: View {
    let text: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 15))
                .foregroundStyle(theme.error)
                .frame(width: 18, height: 18)
            Text(text)
                .pixlFont(.bodySmall)
                .foregroundStyle(theme.onErrorContainer)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                   tint: theme.errorContainer.opacity(GlassTint.container))
    }
}

/// The top bar of the backup dialogs (Android `CenterAlignedTopAppBar` with a `FilledIconButton`): a glass circle on
/// the left and the title centred, 24 pt bold.
struct BackupFlowTopBar: View {
    let title: String
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack {
            Text(title)
                .pixlFont(.custom(size: 24, weight: .bold))
                .foregroundStyle(theme.onSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 60)
            HStack {
                GlassCircleButton(systemImage: systemImage, accessibilityLabel: LocalizedStringKey(accessibilityLabel),
                                  action: action)
                Spacer()
            }
            .padding(.leading, 10)
        }
        .frame(height: 64)
    }
}

/// The extended primary action of the backup dialogs (Android `ExtendedFloatingActionButton`, 48 pt, 16 pt corners,
/// `primaryContainer`) as tinted glass.
struct BackupPrimaryButton: View {
    let title: String
    let systemImage: String
    var isBusy = false
    var isEnabled = true
    let action: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView().tint(theme.onPrimaryContainer).controlSize(.small)
                } else {
                    Image(systemName: systemImage).font(.system(size: 17, weight: .semibold))
                }
                Text(title).pixlFont(.labelLarge, weight: .semibold).lineLimit(1)
            }
            .foregroundStyle(isEnabled || isBusy ? theme.onPrimaryContainer : theme.onSurface.opacity(0.38))
            .padding(.horizontal, 20)
            .frame(height: 48)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                   tint: (isEnabled || isBusy ? theme.primaryContainer : theme.surfaceContainerHighest).opacity(GlassTint.prominent),
                   interactive: isEnabled)
    }
}

/// Android's backup date format (`"MMM d, yyyy 'at' h:mm a"`, device locale), formatter cached.
enum BackupDates {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMdyyyyhmma")
        return formatter
    }()

    static func created(_ millis: Int64) -> String {
        formatter.string(from: Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
    }
}
