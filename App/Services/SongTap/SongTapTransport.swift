import PixlLibrary

/// One way of finding a peer and carrying an offer (the Android `SongTapTransport`). A transport does nothing until
/// `start`, and a radio transport only between `start` and `stop`, which the screen ties to being armed in the
/// foreground. It tells the engine what it sees as `SongTapTransportEvent`s, through `onEvent`.
///
/// Milestone 1 has the QR transport; the Bluetooth one (and Nearby Interaction, later) plug in here without the engine or
/// the screen changing.
@MainActor
protocol SongTapTransport: AnyObject {
    var id: String { get }
    var onEvent: ((SongTapTransportEvent) -> Void)? { get set }

    func start(role: SongTapRole)
    func stop()
    /// Sender: make `payload` available to `peer` (0 for the QR code).
    func publishOffer(peer: Int, payload: [UInt8])
    func withdrawOffer()
    /// Receiver: read the offer of `peer` now.
    func readOffer(peer: Int)
    func sendAck(peer: Int)
    func sendGo(peer: Int, startMs: Int64)
    func sendDecline(peer: Int)
    func abort(peer: Int)
}

/// The code route, which works between any two phones: the sender shows a QR code (the engine makes the text from the offer),
/// the receiver scans it. Nothing travels back, so there is no acknowledgement and no shared animation clock; each phone plays
/// its own part when it has what it needs. The camera is owned by the screen, which hands what it reads to
/// `SongTapEngine.scanned` (the engine decodes the link and keeps the same code from counting twice), so this transport has
/// nothing to carry: it is the stand-in that makes the QR route one more `SongTapTransport`, like the Bluetooth one later.
@MainActor
final class SongTapQrTransport: SongTapTransport {
    let id = "qr"
    var onEvent: ((SongTapTransportEvent) -> Void)?

    func start(role: SongTapRole) {}
    func stop() {}
    func publishOffer(peer: Int, payload: [UInt8]) {}
    func withdrawOffer() {}
    func readOffer(peer: Int) {}
    func sendAck(peer: Int) {}
    func sendGo(peer: Int, startMs: Int64) {}
    func sendDecline(peer: Int) {}
    func abort(peer: Int) {}
}
