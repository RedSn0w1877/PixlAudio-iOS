import SwiftUI

/// The search field a list page reveals above its header when it is pulled down past the top (iOS-first, 2026-10-18):
/// a glass capsule with a magnifier, the text field and Cancel. Typing filters the page live (`ListFindModel`); Cancel
/// clears and hides it. One glass layer, no glass on glass: the clear button is a plain symbol.
struct ListFindField: View {
    let model: ListFindModel
    /// "Find in playlist": the VoiceOver label and the placeholder.
    var prompt: LocalizedStringKey = "Find in playlist"
    var accessibilityPrompt = "Find in playlist"

    @Environment(\.appTheme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .accessibilityHidden(true)
                TextField(prompt, text: $model.query)
                    .pixlFont(.bodyLarge)
                    .foregroundStyle(theme.onSurface)
                    .focused($focused)
                    .submitLabel(.search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel(accessibilityPrompt)
                    .accessibilityIdentifier("find.field")
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(theme.onSurfaceVariant)
                            .frame(width: 28, height: 28)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search text")
                    .accessibilityIdentifier("find.clear")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .pixlGlass(in: Capsule(), tint: theme.surfaceContainerHigh.opacity(GlassTint.container), interactive: true)
            Button("Cancel") {
                focused = false
                withAnimation(PixlMotion.state) { model.close() }
            }
            .pixlFont(.labelLarge)
            .foregroundStyle(theme.primary)
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .accessibilityIdentifier("find.cancel")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .onAppear {
            // A fresh reveal takes the keyboard; a reveal restored with a query (UI tests) does not.
            if model.query.isEmpty { focused = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("find.bar")
    }
}

/// The "No matches" state under the field.
struct ListFindNoMatches: View {
    let query: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(theme.onSurfaceVariant)
                .accessibilityHidden(true)
            Text("No matches")
                .pixlFont(.titleMedium)
                .foregroundStyle(theme.onSurface)
            Text("Nothing here matches \"\(query)\".")
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("find.noMatches")
    }
}
