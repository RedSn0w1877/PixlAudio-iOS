import AVFoundation
import Foundation
import SwiftUI
import UIKit

/// The camera the Receive side reads a code with (Android `QrScanner`, CameraX + zxing; here AVFoundation's own QR
/// detector). It runs only between `start` and `stop`, which the screen ties to being armed in the foreground on the
/// Receive side, and never touches the main thread for more than the preview layer: the session is started and stopped on
/// its own queue, and what it reads is handed over at most six times a second.
///
/// Permission is asked for lazily, the first time the listener picks Receive (`SongTapCameraAccess`).
nonisolated final class SongTapCamera: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "io.github.redsn0w1877.pixlaudio.songtap.camera")
    private let onText: @Sendable (String) -> Void
    private var configured = false
    private var lastDeliveredAt: TimeInterval = 0

    /// 6 frames a second is plenty for a code held still in front of the lens.
    private static let minGap: TimeInterval = 1.0 / 6.0

    init(onText: @escaping @Sendable (String) -> Void) {
        self.onText = onText
        super.init()
    }

    func start() {
        queue.async { [self] in
            configureIfNeeded()
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: queue)
            if output.availableMetadataObjectTypes.contains(.qr) { output.metadataObjectTypes = [.qr] }
        }
        session.commitConfiguration()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDeliveredAt >= Self.minGap else { return }
        for object in metadataObjects {
            if let code = object as? AVMetadataMachineReadableCodeObject, let text = code.stringValue {
                lastDeliveredAt = now
                onText(text)
                return
            }
        }
    }
}

/// Where the camera permission stands, and the one place that asks for it.
nonisolated enum SongTapCameraAccess {
    enum Status { case notAsked, allowed, blocked }

    static func current() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .blocked
        }
    }

    /// Asks (the system prompt shows once); true when the camera may be used.
    static func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }
}

/// The camera's picture, behind the Receive card.
struct SongTapCameraPreview: UIViewRepresentable {
    let camera: SongTapCamera

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = camera.session
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
