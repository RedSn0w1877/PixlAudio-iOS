import SwiftUI

/// The AI DJ (Android `TaisChatSheet`, "Ask Taizo"), opened from the player's sparkles circle — placeholder until
/// stage 13 builds it (stage 8 only adds the entry point and this route).
struct AIDJSheet: View {
    var body: some View {
        SheetScaffold("AI DJ") {
            Text("The AI DJ arrives in stage 13")
                .pixlFont(.bodyMedium)
                .padding(.horizontal, Tokens.Spacing.xxl)
        }
        .accessibilityIdentifier("screen.aiDJ")
    }
}
