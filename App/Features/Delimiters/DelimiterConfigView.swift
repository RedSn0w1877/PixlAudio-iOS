import PixlLibrary
import SwiftUI

/// Artist character delimiters (Android `DelimiterConfigScreen`): the collapsing "Delimiters" header with the reset
/// capsule (52 × 36, `errorContainer`), "Current Delimiters" (chips; tap removes, at least one stays), "Add New
/// Delimiter" (text field + 48 pt add circle) and "Default Delimiters". Panels are 16 pt glass, 16 pt apart.
struct DelimiterConfigView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let library = settings.library
        DelimiterEditor(
            screenID: "delimiterConfig",
            texts: .init(title: L10n.delimitersScreenTitle, currentTitle: L10n.delimiterCurrentTitle,
                         currentSubtitle: L10n.delimiterCurrentSubtitle, empty: nil,
                         addTitle: L10n.delimiterAddTitle, addHint: L10n.delimiterAddHint, addLabel: L10n.delimiterCdAdd,
                         added: L10n.delimiterToastAdded, invalid: L10n.delimiterToastInvalid,
                         resetTitle: L10n.delimiterResetTitle, resetMessage: L10n.delimiterResetMessage,
                         resetDone: L10n.delimiterToastReset, footerTitle: L10n.delimiterDefaultsTitle,
                         footerBody: ArtistParsing.defaultArtistDelimiters.map { "\"\($0)\"" }.joined(separator: "  •  ")),
            items: library.artistDelimiters,
            label: { $0 == " " ? L10n.delimiterLabelSpace : "\"\($0)\"" },
            canRemove: library.artistDelimiters.count > 1,
            onAdd: { text in
                // Android `addDelimiter`: trimmed, non-empty, not already present.
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !library.artistDelimiters.contains(trimmed) else { return false }
                library.artistDelimiters.append(trimmed)
                library.artistSettingsRescanRequired = true
                return true
            },
            onRemove: { delimiter in
                guard library.artistDelimiters.count > 1 else { return L10n.delimiterToastAtLeastOne }
                library.artistDelimiters.removeAll { $0 == delimiter }
                library.artistSettingsRescanRequired = true
                return nil
            },
            onReset: {
                library.artistDelimiters = ArtistParsing.defaultArtistDelimiters
                library.artistSettingsRescanRequired = true
            })
    }
}

/// The shared layout of the two delimiter screens.
struct DelimiterEditor: View {
    struct Texts {
        let title: String
        let currentTitle: String
        let currentSubtitle: String
        let empty: String?
        let addTitle: String
        let addHint: String
        let addLabel: String
        let added: String
        let invalid: String
        let resetTitle: String
        let resetMessage: String
        let resetDone: String
        let footerTitle: String
        let footerBody: String
    }

    let screenID: String
    let texts: Texts
    let items: [String]
    let label: (String) -> String
    let canRemove: Bool
    /// Returns whether the delimiter was added.
    let onAdd: (String) -> Bool
    /// Returns a message to show when the delimiter can't be removed.
    let onRemove: (String) -> String?
    let onReset: () -> Void

    @State private var draft = ""
    @State private var toast: String?
    @State private var showsReset = false
    @FocusState private var fieldFocused: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        SettingsScaffold(title: texts.title, screenID: screenID, spacing: 16) {
            Button { showsReset = true } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.onErrorContainer)
                    .frame(width: 52, height: 36)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pixlGlass(in: Capsule(), tint: theme.errorContainer.opacity(GlassTint.prominent), interactive: true)
            .accessibilityLabel(L10n.commonResetDefaults)
            .accessibilityIdentifier("delimiters.reset")
            .padding(.trailing, 16)
            .padding(.top, 2)
        } content: {
            panel {
                Text(texts.currentTitle).pixlFont(.titleMedium, weight: .bold).foregroundStyle(theme.onSurface)
                Spacer().frame(height: 8)
                Text(texts.currentSubtitle).pixlFont(.bodySmall).foregroundStyle(theme.onSurfaceVariant)
                Spacer().frame(height: 12)
                if items.isEmpty, let empty = texts.empty {
                    Text(empty).pixlFont(.bodyMedium).foregroundStyle(theme.onSurfaceVariant.opacity(0.6))
                } else {
                    FlowChips(spacing: 8) {
                        ForEach(items, id: \.self) { item in chip(item) }
                    }
                }
            }
            panel {
                Text(texts.addTitle).pixlFont(.titleMedium, weight: .bold).foregroundStyle(theme.onSurface)
                Spacer().frame(height: 12)
                HStack(spacing: 12) {
                    TextField(texts.addHint, text: $draft)
                        .pixlFont(.bodyLarge)
                        .foregroundStyle(theme.onSurface)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($fieldFocused)
                        .submitLabel(.done)
                        .onSubmit(add)
                        .padding(.horizontal, 16)
                        .frame(height: 56)
                        .background(theme.surfaceContainerLowest.opacity(0.6),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(fieldFocused ? theme.primary : theme.outline, lineWidth: fieldFocused ? 2 : 1))
                        .accessibilityIdentifier("delimiters.field")
                    Button(action: add) {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(theme.onPrimary)
                            .frame(width: 48, height: 48)
                            .background(theme.primary, in: Circle())
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    .accessibilityLabel(texts.addLabel)
                    .accessibilityIdentifier("delimiters.add")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(texts.footerTitle).pixlFont(.titleSmall, weight: .bold).foregroundStyle(theme.onSurface)
                Text(texts.footerBody).pixlFont(.bodyMedium).foregroundStyle(theme.onSurfaceVariant)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                       tint: theme.secondaryContainer.opacity(GlassTint.surface))
        }
        .settingsToast($toast)
        .alert(texts.resetTitle, isPresented: $showsReset) {
            Button(L10n.commonCancel, role: .cancel) {}
            Button(L10n.commonReset, role: .destructive) {
                onReset()
                toast = texts.resetDone
            }
        } message: {
            Text(texts.resetMessage)
        }
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                       tint: theme.surfaceVariant.opacity(GlassTint.surface))
    }

    /// Android `InputChip` (selected, `primaryContainer`): the label and a close icon when removable.
    private func chip(_ item: String) -> some View {
        Button {
            if let message = onRemove(item) { toast = message }
        } label: {
            HStack(spacing: 8) {
                Text(label(item)).pixlFont(.bodyMedium, weight: .medium)
                if canRemove {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                        .accessibilityLabel(L10n.commonRemove)
                }
            }
            .foregroundStyle(theme.onPrimaryContainer)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(theme.primaryContainer, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.vertical, 4)
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.94))
        .accessibilityIdentifier("delimiters.chip.\(item)")
    }

    private func add() {
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if onAdd(draft) {
            draft = ""
            fieldFocused = false
            toast = texts.added
        } else {
            toast = texts.invalid
        }
    }
}
