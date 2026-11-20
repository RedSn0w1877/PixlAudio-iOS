// One way of finding a peer and carrying an offer (the Android `SongTapTransport`): the code route (QR) and the Bluetooth
// route, and Nearby Interaction later. A transport does nothing until `start`, and a radio transport only between `start`
// and `stop`, which the screen ties to being armed in the foreground. It tells the engine what it sees as
// `SongTapTransportEvent`s through `onEvent`; it knows nothing about the session's rules.

@MainActor
public protocol SongTapTransport: AnyObject {
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
