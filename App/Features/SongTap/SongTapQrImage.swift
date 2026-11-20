import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Draws a Song Tap link as a QR code (Android `QrCode.kt`, zxing): black on white whatever the theme (scanners want the
/// contrast), error correction L (the link is about 400 characters, and a lower level keeps the modules big enough to read
/// across a table), once per text.
nonisolated enum SongTapQrImage {
    /// A square image of `text`, `modulePixels` pixels per module with a one module quiet zone added by the filter.
    static func cgImage(for text: String, modulePixels: Int = 8) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "L"
        guard let output = filter.outputImage else { return nil }
        // Scale by whole pixels so the modules stay sharp; the picture is drawn with `.interpolation(.none)`.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: CGFloat(modulePixels), y: CGFloat(modulePixels)))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}

/// The code in a white rounded square (the quiet zone is part of the white).
struct SongTapQrView: View {
    let text: String
    let accessibilityText: String

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.white)
            if let image {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: text) { image = SongTapQrImage.cgImage(for: text) }
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("songTap.code")
    }
}
