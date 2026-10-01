import Foundation

// Strings of the backup flows (stage 15). Android keys where Android has the string (the String Catalog carries its
// translations); `backup_report_*` and `backup_progress_*` are iOS additions (the restore report).
extension L10n {
    static let settingsBackupProgressPreparingBackup = String(localized: "settings_backup_progress_preparing_backup", defaultValue: "Preparing backup")
    static let settingsBackupProgressStartingBackupTask = String(localized: "settings_backup_progress_starting_backup_task", defaultValue: "Starting backup task.")
    static let settingsBackupProgressPreparingRestore = String(localized: "settings_backup_progress_preparing_restore", defaultValue: "Preparing restore")
    static let settingsBackupProgressStartingTask = String(localized: "settings_backup_progress_starting_task", defaultValue: "Starting restore task.")
    static let backupProgressPreparingBackup = settingsBackupProgressPreparingBackup
    static let backupProgressStartingBackupTask = settingsBackupProgressStartingBackupTask
    static let backupProgressPreparingRestore = settingsBackupProgressPreparingRestore
    static let backupProgressStartingTask = settingsBackupProgressStartingTask
    static func backupProgressRestoring(_ a1: String) -> String {
        String(format: String(localized: "backup_progress_restoring", defaultValue: "Restoring %1$@"), a1)
    }
    static let backupProgressFinishing = String(localized: "backup_progress_finishing", defaultValue: "Finishing up")
    static let backupProgressFinishingDetail = String(localized: "backup_progress_finishing_detail", defaultValue: "Updating your library.")

    static let settingsDataExportedSuccessfully = String(localized: "settings_data_exported_successfully", defaultValue: "Data exported successfully")
    static func settingsExportFailedFormat(_ a1: String) -> String {
        String(format: String(localized: "settings_export_failed_format", defaultValue: "Export failed: %1$@"), a1)
    }
    static let settingsDataRestoredSuccessfully = String(localized: "settings_data_restored_successfully", defaultValue: "Data restored successfully")
    static func settingsRestoreFailedFormat(_ a1: String) -> String {
        String(format: String(localized: "settings_restore_failed_format", defaultValue: "Restore failed: %1$@"), a1)
    }
    static func settingsRestorePartialUnresolvedFormat(_ a1: String) -> String {
        String(format: String(localized: "settings_restore_partial_unresolved_format", defaultValue: "Restore completed with unresolved issues. Failed: %1$@"), a1)
    }
    static func settingsBackupInvalidFormat(_ a1: String) -> String {
        String(format: String(localized: "settings_backup_invalid_format", defaultValue: "Invalid backup: %1$@"), a1)
    }
    static let commonErrorUnknown = String(localized: "common_error_unknown", defaultValue: "Unknown error")

    // MARK: Restore report (iOS)

    static let backupReportTitle = String(localized: "backup_report_title", defaultValue: "Restore report")
    static let backupReportSuccess = String(localized: "backup_report_success", defaultValue: "Backup restored")
    static let backupReportPartial = String(localized: "backup_report_partial", defaultValue: "Restored with some issues")
    static let backupReportFailed = String(localized: "backup_report_failed", defaultValue: "Restore failed")
    static let backupReportFromAndroid = String(localized: "backup_report_from_android", defaultValue: "Backup from the Android app")
    static let backupReportFromPixlAudio = String(localized: "backup_report_from_pixlaudio", defaultValue: "PixlAudio backup")
    static func backupReportCreated(_ a1: String) -> String {
        String(format: String(localized: "backup_report_created", defaultValue: "Created %1$@"), a1)
    }
    static let backupReportRestoredSection = String(localized: "backup_report_restored_section", defaultValue: "Restored")
    static func backupReportCountRestored(_ a1: Int) -> String {
        String(format: String(localized: "backup_report_count_restored", defaultValue: "%1$lld restored"), a1)
    }
    static func backupReportCountUnmatched(_ a1: Int) -> String {
        String(format: String(localized: "backup_report_count_unmatched", defaultValue: "%1$lld not matched"), a1)
    }
    static let backupReportUnmatchedTitle = String(localized: "backup_report_unmatched_title", defaultValue: "Some songs couldn't be matched")
    static func backupReportUnmatchedBody(_ a1: Int) -> String {
        String(format: String(localized: "backup_report_unmatched_body", defaultValue: "%1$lld entries were skipped. An Android backup describes songs only inside its playlists, so favorites, play counts, listening history, lyrics and transition rules of songs that aren't in any backed-up playlist can't be matched — nor can songs that aren't in your library on this device."), a1)
    }
    static func backupReportPending(_ a1: Int) -> String {
        String(format: String(localized: "backup_report_pending", defaultValue: "%1$lld playlist songs aren't in your library yet. PixlAudio adds them to their playlists after the next library scan."), a1)
    }
    static let backupReportFailedSection = String(localized: "backup_report_failed_section", defaultValue: "Couldn't restore")
    static let backupReportSkippedSettingsTitle = String(localized: "backup_report_skipped_settings_title", defaultValue: "Settings not restored")
    static func backupReportSkippedSettingsBody(_ a1: Int) -> String {
        String(format: String(localized: "backup_report_skipped_settings_body", defaultValue: "%1$lld Android-only or device-specific settings were skipped."), a1)
    }
    static let backupReportSettingsRestart = String(localized: "backup_report_settings_restart", defaultValue: "Some restored settings apply the next time PixlAudio starts.")
    static let backupReportWarningsTitle = String(localized: "backup_report_warnings_title", defaultValue: "Warnings")
    static let backupReportNothingRestored = String(localized: "backup_report_nothing_restored", defaultValue: "Nothing was restored.")
}
