// The seams of the Bluetooth route (Song Tap): everything the platform does sits behind these small protocols, so the
// whole route (`SongTapBleRoute`) is decided and tested here without a radio. The Android twins are `BleRadio`,
// `BleRadioListener`, `SongTapClock` and `ImpulseSource`.
//
// All of it runs on the main actor: the app makes its CoreBluetooth managers on the main queue.

/// Whether the phone's Bluetooth can be used for Song Tap right now, and if not why.
public enum SongTapBleStatus: String, Sendable, CaseIterable {
    /// Not started (Song Tap is not armed on screen).
    case idle
    /// Advertising and scanning.
    case active
    /// This phone cannot advertise or scan.
    case unsupported
    /// Bluetooth has not been allowed for PixlAudio (the system asks when Song Tap is turned on).
    case noPermission
    /// Bluetooth is switched off.
    case bluetoothOff
}

/// What the radio tells the route. A phone's address changes every few minutes (random, private), which is what makes a
/// peer unlinkable from one session to the next, and why nothing here treats it as an identity: `address` is only the
/// handle of the radio's own object for the length of one session.
@MainActor
public protocol SongTapBleRadioListener: AnyObject {
    /// A scan result: a phone advertising `role`'s service, with its signal strength in dBm and the short name it advertised
    /// (`name`, already clean through `SongTapWire.advertisedName`, nil when it advertised none). On iOS the signal is the reference
    /// scale as it is: there is no offset to add.
    func onSeen(address: String, role: SongTapRole, rssi: Int, name: String?)
    /// Our connection to a sender's server is ready (service found, notifications on), or failed.
    func onConnected(address: String, ok: Bool)
    func onDisconnected(address: String)
    /// The answer to `SongTapBleRadio.readInfo`; nil when the read failed.
    func onInfoRead(address: String, value: [UInt8]?)
    /// The answer to `SongTapBleRadio.readName`; nil when the read failed.
    func onNameRead(address: String, value: [UInt8]?)
    /// The answer to `SongTapBleRadio.readOffer`; nil when the read failed or the sender had nothing to give yet.
    func onOfferRead(address: String, value: [UInt8]?)
    /// The answer to `SongTapBleRadio.writeControl`, in the order the writes were asked for.
    func onControlWritten(address: String, ok: Bool)
    /// The sender notified us (the Event characteristic).
    func onNotified(address: String, value: [UInt8])
    func onStatus(_ status: SongTapBleStatus)

    // The sender's own GATT server.

    /// A client read Info.
    func serverInfo() -> [UInt8]
    /// A client read Name: the value of `SongTapWire.encodeName` for this phone's name.
    func serverName() -> [UInt8]
    /// A client read Offer. Nil answers with the "not ready" error (`SongTapWire.errorNotReady`).
    func serverOffer(client: String) -> [UInt8]?
    /// A client wrote Control; false answers the write with an error.
    func serverControl(client: String, value: [UInt8]) -> Bool
    func serverClientGone(client: String)
}

/// The thin layer over the platform's Bluetooth LE. Calls return at once; results come back through the listener.
@MainActor
public protocol SongTapBleRadio: AnyObject {
    /// Starts advertising `role`'s service (the sender also opens its GATT server) with `name` as the short name (the local name in
    /// the advertisement; an iPhone cannot choose its advertising power, which is why the near gate is the only thing that keeps a
    /// far phone from being connected to) and scanning for both services. Returns `.active`, or the reason it could not start (then nothing is running). A radio that learns its state
    /// later (iOS asks for permission, and tells the state a moment after it is made) answers `.active` now and reports
    /// the truth through `onStatus`.
    func start(role: SongTapRole, listener: any SongTapBleRadioListener, name: String) -> SongTapBleStatus
    /// Stops advertising, scanning, the server and every connection.
    func stop()
    /// Client: connect to the sender seen at `address`, find the service and subscribe to Event.
    func connect(address: String)
    func disconnect(address: String)
    func readInfo(address: String)
    func readName(address: String)
    func readOffer(address: String)
    func writeControl(address: String, value: [UInt8])
    /// Server: send `value` as a notification of the Event characteristic to the connected `client`.
    func notify(client: String, value: [UInt8])
    /// Server: drop a client.
    func dropClient(client: String)
    /// The route no longer tracks the phone at `address`: let go of whatever the radio keeps for it (a scan result is an
    /// object per address, and a flood of made-up addresses must not pile up).
    func forget(address: String)
}

public extension SongTapBleRadio {
    func forget(address: String) {}
}

/// The two clocks Song Tap uses: a monotonic one for signal and motion timing, the wall clock for signed offers.
@MainActor
public protocol SongTapClock: AnyObject {
    func elapsedMs() -> Int64
    func wallMs() -> Int64
}

/// The accelerometer, as "the phone was jerked at this time" (milliseconds on the monotonic clock).
@MainActor
public protocol SongTapImpulseSource: AnyObject {
    func start(onImpulse: @escaping @MainActor (Int64) -> Void)
    func stop()
    /// The sensitivity profile whose jerk threshold decides what counts as a jerk (spec 6); may change while running.
    func setSensitivity(_ profile: SongTapSensitivity)
}

public extension SongTapImpulseSource {
    func setSensitivity(_ profile: SongTapSensitivity) {}
}

/// Timers for the route. The app implements them with tasks; a test moves them by hand.
@MainActor
public protocol SongTapBleScheduler: AnyObject {
    /// Calls `tick` every `everyMs` until `stopTicking`, replacing an earlier one.
    func startTicking(everyMs: Int64, _ tick: @escaping @MainActor () -> Void)
    func stopTicking()
    /// Calls `action` once, `ms` from now.
    func after(ms: Int64, _ action: @escaping @MainActor () -> Void)
}

/// A per-session signing key (CryptoKit on iOS, java.security on Android): the uncompressed point and r||s signatures.
public protocol SongTapSignerPort {
    /// 65 bytes.
    var publicKey: [UInt8] { get }
    /// 64 bytes, r then s; nil only when the platform refuses to sign.
    func sign(_ message: [UInt8]) -> [UInt8]?
}
