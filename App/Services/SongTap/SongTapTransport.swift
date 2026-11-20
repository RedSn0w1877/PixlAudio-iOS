import PixlLibrary

/// The code route, which works between any two phones: the sender shows a QR code (the engine makes the text from the offer),
/// the receiver scans it. Nothing travels back, so there is no acknowledgement and no shared animation clock; each phone plays
/// its own part when it has what it needs. The camera is owned by the screen, which hands what it reads to
/// `SongTapEngine.scanned` (the engine decodes the link and keeps the same code from counting twice), so this transport has
/// nothing to carry: it is the stand-in that makes the QR route one more `SongTapTransport`, next to the Bluetooth one
/// (`SongTapBleRoute`, in PixlCore).
///
/// The `SongTapTransport` interface itself lives in PixlCore now (the Bluetooth route is decided and tested there).
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
