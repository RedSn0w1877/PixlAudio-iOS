import Foundation
import Observation
import SwiftUI

/// Notify-only update check (Android `AppUpdateCheckWorker` + `AppUpdateNotifications`): at most every 12 hours,
/// on launch and when the app comes back to the foreground, ask GitHub for the latest release of
/// `RedSn0w1877/PixlAudio-iOS`; when it is newer than the installed version, show a banner once per release with a
/// link to the release page. iOS can't install a sideloaded app itself, so there is no download — the owner installs
/// the new `.ipa` with Sideloadly. Failures are silent; the next window retries (as on Android).
@Observable
final class UpdateNotifier {
    /// The release to announce; nil when there is nothing to show.
    private(set) var available: AppUpdateChecker.Release?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isEnabled: Bool
    @ObservationIgnored private var isChecking = false

    /// Android checks twice a day (`PeriodicWorkRequest` every 12 h).
    static let interval: TimeInterval = 12 * 60 * 60
    static let lastCheckKey = "ios_update_last_check_ms"
    static let lastNotifiedKey = "ios_update_last_notified_release"

    init(defaults: UserDefaults = .standard, isEnabled: Bool) {
        self.defaults = defaults
        self.isEnabled = isEnabled
    }

    /// Runs a check when the last one is older than `interval`.
    func checkIfDue(now: Date = Date()) async {
        guard isEnabled, !isChecking else { return }
        let last = defaults.double(forKey: Self.lastCheckKey) / 1000
        guard now.timeIntervalSince1970 - last >= Self.interval else { return }
        isChecking = true
        defer { isChecking = false }
        let checker = AppUpdateChecker()
        await checker.check()
        switch checker.state {
        case .available(let release):
            defaults.set(now.timeIntervalSince1970 * 1000, forKey: Self.lastCheckKey)
            // Once per release (Android `notifyOnce`).
            guard defaults.string(forKey: Self.lastNotifiedKey) != release.releaseURL else { return }
            withAnimation(PixlMotion.bars) { available = release }
        case .upToDate:
            defaults.set(now.timeIntervalSince1970 * 1000, forKey: Self.lastCheckKey)
        default:
            break
        }
    }

    /// The banner was closed or followed: don't show this release again.
    func dismiss() {
        if let available { defaults.set(available.releaseURL, forKey: Self.lastNotifiedKey) }
        withAnimation(PixlMotion.bars) { available = nil }
    }
}

/// The update banner: a glass card at the top of the shell (Android posts a notification), with "What's new" and a
/// close button.
private struct UpdateBannerModifier: ViewModifier {
    let notifier: UpdateNotifier
    @Environment(\.appTheme) private var theme
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let release = notifier.available {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "arrow.down.app")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(theme.onPrimaryContainer)
                        .frame(width: 40, height: 40)
                        .background(theme.primaryContainer, in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(release.version)
                            .pixlFont(.titleSmall, weight: .semibold)
                            .foregroundStyle(theme.onSurface)
                        Text(L10n.appUpdateSideloadNote)
                            .pixlFont(.bodySmall)
                            .foregroundStyle(theme.onSurfaceVariant)
                        if let url = URL(string: release.releaseURL) {
                            Button {
                                notifier.dismiss()
                                openURL(url)
                            } label: {
                                Text(L10n.appUpdateActionReleasePage)
                                    .pixlFont(.labelLarge)
                                    .foregroundStyle(theme.primary)
                            }
                            .buttonStyle(PressScaleButtonStyle())
                            .padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: notifier.dismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(theme.onSurfaceVariant)
                            .frame(width: 32, height: 32)
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    .accessibilityLabel(L10n.commonClose)
                }
                .padding(14)
                .pixlGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous),
                           tint: theme.surfaceContainerHigh.opacity(GlassTint.bar))
                .padding(.horizontal, Tokens.Shell.horizontalInset)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("updateBanner")
            }
        }
    }
}

extension View {
    /// Shows the update banner of `notifier` over the view.
    func updateBanner(_ notifier: UpdateNotifier) -> some View {
        modifier(UpdateBannerModifier(notifier: notifier))
    }
}

extension L10n {
    static let appUpdateSideloadNote = String(localized: "app_update_sideload_note",
                                              defaultValue: "Install the new version with Sideloadly from the release page.")
}
