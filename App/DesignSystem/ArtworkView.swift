import PixlModel
import SwiftUI

/// Album art at a fixed size: decoded off the main thread at display resolution by `ArtworkPipeline`, shown from
/// the memory cache on the first frame when it's there, a tonal placeholder otherwise (Android `SmartImage`).
struct ArtworkView: View {
    let source: ArtworkSource?
    let size: CGFloat
    var cornerRadius: CGFloat = Tokens.Artwork.rowCornerRadius
    var pipeline: ArtworkPipeline = .shared

    @State private var image: ArtworkImage?
    @Environment(\.appTheme) private var theme

    init(source: ArtworkSource?, size: CGFloat, cornerRadius: CGFloat = Tokens.Artwork.rowCornerRadius,
         pipeline: ArtworkPipeline = .shared) {
        self.source = source
        self.size = size
        self.cornerRadius = cornerRadius
        self.pipeline = pipeline
        let pixels = ArtworkPipeline.pixelSize(forPoints: size)
        _image = State(initialValue: source.flatMap { pipeline.cachedImage($0, pixelSize: pixels) })
    }

    init(song: Song?, size: CGFloat, cornerRadius: CGFloat = Tokens.Artwork.rowCornerRadius) {
        self.init(source: song.flatMap(ArtworkSource.init(song:)), size: size, cornerRadius: cornerRadius)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(theme.surfaceVariant)
            if let image {
                Image(decorative: image.cgImage, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(theme.onSurfaceVariant.opacity(0.6))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .task(id: source) {
            guard let source else { image = nil; return }
            let pixels = ArtworkPipeline.pixelSize(forPoints: size)
            if let hit = pipeline.cachedImage(source, pixelSize: pixels) {
                image = hit
                return
            }
            let loaded = await pipeline.image(source, pixelSize: pixels)
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.18)) { image = loaded }
            }
        }
        .accessibilityHidden(true)
    }
}
