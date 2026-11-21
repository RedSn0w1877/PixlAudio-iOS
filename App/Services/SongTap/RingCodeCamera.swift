import AVFoundation
import CoreMedia
import Foundation
import PixlLibrary

/// The camera that reads Pixl ring codes (Android `RingCodeCamera`, CameraX analysis): an `AVCaptureVideoDataOutput` delivering
/// 4:2:0 biplanar frames at 1280 x 720 on one background queue, "discard late frames" so a slow scan never queues pictures up, and
/// `RingScanPacer` (PixlCore) deciding how often the scanner may look at all. The luma and chroma planes go through `RingFrameBuilder`
/// (PixlCore: a row copy and a table lookup per chroma sample) and `RingScanner`; this class only owns the session and the handing over.
///
/// It runs only between `start` and `stop`, which the screen ties to the Receive side being open in the foreground, and the diagnostics
/// screen to being open. Nothing here touches the main thread: the session starts and stops on its own queue, and results are
/// reported on the camera's queue (`Sink`).
nonisolated final class RingCodeCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Where the camera's queue reports to. Each call is on that queue: keep it short and never block.
    nonisolated struct Sink: Sendable {
        /// A frame arrived (scanned or skipped), for the frame rate.
        var onFrame: @Sendable (_ nowMs: Int64) -> Void = { _ in }
        /// One frame was scanned. The frame's buffers are reused by the next one: copy what is needed before returning.
        var onScan: @Sendable (_ frame: RingFrame, _ result: RingScanResult, _ diagnostics: RingScanDiagnostics,
                               _ rotationDegrees: Int, _ nowMs: Int64) -> Void = { _, _, _, _, _ in }
        /// The scanner cannot keep up on this phone.
        var onSlow: @Sendable () -> Void = {}
        /// The camera would not start, or stopped by itself.
        var onFailed: @Sendable () -> Void = {}
    }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "io.github.redsn0w1877.pixlaudio.songtap.ringscan", qos: .userInitiated)
    private let sink: Sink
    // Everything below belongs to `queue`.
    private var configured = false
    private var failed = false
    private var observer: (any NSObjectProtocol)?
    private var scanner: RingScanner?
    private let builder = RingFrameBuilder()
    private var pacer = RingScanPacer()
    private var running = false

    /// The back camera in portrait hands over landscape buffers: the picture is upright after a quarter turn clockwise.
    private static let bufferRotationDegrees = 90

    init(sink: Sink) {
        self.sink = sink
        super.init()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// True when the phone has a camera at all.
    static var exists: Bool { AVCaptureDevice.default(for: .video) != nil }

    func start() {
        queue.async { [self] in
            running = true
            pacer.reset()
            if !configure() {
                sink.onFailed()
                return
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() -> Bool {
        if configured { return !failed }
        configured = true
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device) else {
            failed = true
            return false
        }
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        if session.canAddInput(input) { session.addInput(input) } else { failed = true }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setSampleBufferDelegate(self, queue: queue)
        } else {
            failed = true
        }
        session.commitConfiguration()
        if failed { return false }
        // A code is read from arm's length: focus that settles on something near, and keeps settling.
        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
            device.unlockForConfiguration()
        }
        observer = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session,
                                                          queue: nil) { [sink] _ in sink.onFailed() }
        return true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard running else { return }
        let now = Int64(ProcessInfo.processInfo.systemUptime * 1000)
        sink.onFrame(now)
        guard pacer.shouldScan(nowMs: now), let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pixels) >= 2, let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return }
        let width = CVPixelBufferGetWidthOfPlane(pixels, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let luma = UnsafeRawBufferPointer(start: lumaBase, count: lumaStride * height)
        var chroma: UnsafeRawBufferPointer?
        var chromaStride = 0
        if let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixels, 1) {
            chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1)
            chroma = UnsafeRawBufferPointer(start: chromaBase, count: chromaStride * CVPixelBufferGetHeightOfPlane(pixels, 1))
        }
        let frame = builder.buildBiplanar(width: width, height: height, luma: luma, lumaRowStride: lumaStride, chroma: chroma,
                                          chromaRowStride: chromaStride)
        let scanner = self.scanner ?? RingScanner()
        self.scanner = scanner
        let result = scanner.scan(frame, clockNanos: { Int64(clamping: DispatchTime.now().uptimeNanoseconds) })
        let done = Int64(ProcessInfo.processInfo.systemUptime * 1000)
        pacer.recordScan(micros: scanner.diagnostics.scanMicros, nowMs: done)
        sink.onScan(frame, result, scanner.diagnostics, Self.bufferRotationDegrees, done)
        if pacer.tooSlow() { sink.onSlow() }
    }
}
