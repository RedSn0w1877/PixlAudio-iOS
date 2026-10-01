import AVKit
import SwiftUI
import UIKit

/// The system output picker (AirPlay, Bluetooth, the phone's speaker) — the iOS stand-in for Android's cast button.
/// Stage 8 places it in the player; it draws the system route icon, tinted with the player's palette.
struct AirPlayRoutePicker: UIViewRepresentable {
    var tint: Color = .primary
    var activeTint: Color = .accentColor

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.backgroundColor = .clear
        apply(to: view)
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: AVRoutePickerView) {
        view.tintColor = UIColor(tint)
        view.activeTintColor = UIColor(activeTint)
    }
}
