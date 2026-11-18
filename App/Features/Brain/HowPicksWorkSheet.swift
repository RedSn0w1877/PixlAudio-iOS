import SwiftUI

/// "How picks work" (docs/brain-spec.md, 8.9; Android `HowPicksWorkSheet`): the promises the engine keeps, the
/// Autoplay switch and the way to Taste changes. Static text; the stage 1 version says only what is true of stage 1.
/// Reached from the (i) on the queue's Autoplay or Station line and from "Why this song".
struct HowPicksWorkSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(SettingsStore.self) private var settings
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(BrainStrings.howPicksWork)
                    .pixlFont(.headlineMedium, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                    .accessibilityAddTraits(.isHeader)
                Spacer().frame(height: 6)
                Text(BrainStrings.howIntro)
                    .pixlFont(.bodyLarge)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer().frame(height: 20)
                promises
                Spacer().frame(height: 16)
                controls
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("screen.howPicksWork")
    }

    /// The rows render together (4 pt apart, below the container's blend distance) inside one 24 pt clip.
    private var promises: some View {
        GlassEffectContainer(spacing: 0) {
            VStack(spacing: 4) {
                promise("checkmark.seal", BrainStrings.promisePaidTitle, nil)
                promise("repeat", BrainStrings.promiseRepeatTitle, BrainStrings.promiseRepeatBody)
                promise("eye", BrainStrings.promiseWhyTitle, BrainStrings.promiseWhyBody)
                promise("text.badge.plus", BrainStrings.promisePlaylistsTitle, BrainStrings.promisePlaylistsBody)
                promise("iphone", BrainStrings.promisePhoneTitle, BrainStrings.promisePhoneBody)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func promise(_ systemImage: String, _ title: String, _ detail: String?) -> some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.onSecondaryContainer)
                .frame(width: 40, height: 40)
                .background(Circle().fill(theme.secondaryContainer))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .pixlFont(.titleMedium)
                    .foregroundStyle(theme.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 6, style: .continuous),
                   tint: theme.surfaceContainerHigh.opacity(GlassTint.surface))
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        let ai = settings.ai
        let autoplayController = env.autoplayController
        return GlassEffectContainer(spacing: 0) {
            VStack(spacing: 4) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(BrainStrings.howAutoplayTitle)
                            .pixlFont(.titleMedium)
                            .foregroundStyle(theme.onSurface)
                        Text(BrainStrings.howAutoplayBody)
                            .pixlFont(.bodyMedium)
                            .foregroundStyle(theme.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle(BrainStrings.howAutoplayTitle, isOn: Binding(get: { ai.musicDiscoveryEnabled }, set: { isOn in
                        ai.musicDiscoveryEnabled = isOn
                        autoplayController?.settingChanged()
                    }))
                    .labelsHidden()
                    .tint(theme.primary)
                    .accessibilityIdentifier("howPicksWork.autoplay")
                }
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .padding(.vertical, 12)
                .pixlGlass(in: RoundedRectangle(cornerRadius: 6, style: .continuous),
                           tint: theme.surfaceContainerHigh.opacity(GlassTint.surface))

                Button(action: openTasteChanges) {
                    HStack(spacing: 16) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(theme.primary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(BrainStrings.howTasteChanges)
                                .pixlFont(.titleMedium)
                                .foregroundStyle(theme.onSurface)
                            Text(BrainStrings.howTasteChangesBody)
                                .pixlFont(.bodyMedium)
                                .foregroundStyle(theme.onSurfaceVariant)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.onSurfaceVariant)
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 12)
                    .padding(.vertical, 12)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .pixlGlass(in: RoundedRectangle(cornerRadius: 6, style: .continuous),
                           tint: theme.surfaceContainerHigh.opacity(GlassTint.surface), interactive: true)
                .accessibilityIdentifier("howPicksWork.tasteChanges")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// Closes the sheets in the way and opens Taste changes on the current tab, once the player has stepped aside
    /// (as the player's "Go to album" does).
    private func openTasteChanges() {
        let router = self.router
        dismiss()
        router.dismissSheet()
        env.playerSheet.collapse { router.push(.tasteChanges) }
    }
}
