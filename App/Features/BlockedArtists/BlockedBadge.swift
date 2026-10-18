import SwiftUI

/// The small "Blocked" tag a blocked artist's song carries in playlists and albums (the row is dimmed as well).
/// A fill, not glass: it sits on a row that is already one glass layer.
struct BlockedBadge: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        Text("Blocked")
            .pixlFont(.custom(size: 11, weight: .bold))
            .foregroundStyle(theme.onErrorContainer)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.errorContainer))
            .accessibilityLabel("Blocked artist")
    }
}

/// How dim a blocked song's art and text are.
enum BlockedRowStyle {
    static let dimmedOpacity: Double = 0.5
}
