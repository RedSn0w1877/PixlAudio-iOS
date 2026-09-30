import SwiftUI

/// Placeholder artwork: a generated gradient with a music-note glyph. Content layer — never glass.
/// Stage 8 replaces the inside with ImageIO-decoded, cached thumbnails; the call sites stay.
struct ArtworkView: View {
    let hue: Double
    var cornerRadius: CGFloat = Tokens.Artwork.rowCornerRadius

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.55, brightness: 0.95),
                        Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.6),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .imageScale(.medium)
            }
            .accessibilityHidden(true)
    }
}
