import CoreBluetooth
import Foundation
import PixlLibrary

/// Bluetooth LE on this iPhone, for Song Tap (Android `AndroidBleRadio`): advertise one service UUID, scan for both, run the
/// sender's GATT server, and be a client of somebody else's. Every decision is in `SongTapBleRoute` (PixlCore); this class only
/// turns CoreBluetooth callbacks into `SongTapBleRadioListener` calls and back, and keeps the GATT client's one-operation-at-a-time
/// rule. The wire (the UUIDs, the characteristics and what they hold) is `SongTapWire`, the same on a Pixel.
///
/// Nothing is created until `start`: no manager, no permission prompt, no scan. The advertisement is the service UUID alone (an
/// iPhone can advertise nothing else while PixlAudio is in the foreground): no local name, no data, and the address iOS gives an
/// advertiser is a private one that changes every few minutes. Both managers run on the main queue, so every callback arrives on
/// the main thread and is handed to the main actor from there.
///
/// iOS cannot do two things Android does, both harmless here: it has no API to disconnect a central from the server side
/// (`dropClient` does nothing; the receiver closes its own connection when the session ends), and an iOS peripheral cannot
/// answer a read with an ATT application error code of our choosing, so "not ready" is the closest standard error (`unlikelyError`)
/// instead of 0x80 (the receiver treats any read error the same way: ask again).
@MainActor
final class SongTapBluetoothRadio: SongTapBleRadio {
    private weak var listener: (any SongTapBleRadioListener)?
    private var role = SongTapRole.send
    private var running = false
    private var proxy: SongTapBluetoothProxy?
    private var central: CBCentralManager?
    private var advertiser: CBPeripheralManager?
    private var scanning = false
    private var advertising = false
    private var reportedActive = false

    // The scanning side: what was seen, and the connections to senders.
    private var seen: [String: CBPeripheral] = [:]
    private var clients: [String: Client] = [:]

    // The serving side: the service, its characteristics, who is connected.
    private var infoCharacteristic: CBMutableCharacteristic?
    private var offerCharacteristic: CBMutableCharacteristic?
    private var controlCharacteristic: CBMutableCharacteristic?
    private var eventCharacteristic: CBMutableCharacteristic?
    private var serverClients: [String: CBCentral] = [:]
    private var offerCache: [String: [UInt8]] = [:]
    private var pendingGo: [String] = []

    private static let sendService = CBUUID(string: SongTapWire.serviceSend)
    private static let receiveService = CBUUID(string: SongTapWire.serviceReceive)
    private static let info = CBUUID(string: SongTapWire.charInfo)
    private static let offer = CBUUID(string: SongTapWire.charOffer)
    private static let control = CBUUID(string: SongTapWire.charControl)
    private static let event = CBUUID(string: SongTapWire.charEvent)

    private enum Op {
        case readInfo
        case readOffer
        case write([UInt8])
    }

    private final class Client {
        let peripheral: CBPeripheral
        var ready = false
        var busy = false
        var info: CBCharacteristic?
        var offer: CBCharacteristic?
        var control: CBCharacteristic?
        var event: CBCharacteristic?
        var queue: [Op] = []

        init(_ peripheral: CBPeripheral) { self.peripheral = peripheral }
    }

    // MARK: Start and stop

    func start(role: SongTapRole, listener: any SongTapBleRadioListener) -> SongTapBleStatus {
        stopRadios()
        self.listener = listener
        self.role = role
        switch CBManager.authorization {
        case .denied, .restricted: return .noPermission
        default: break
        }
        running = true
        reportedActive = false
        let proxy = SongTapBluetoothProxy(radio: self)
        self.proxy = proxy
        // Making the managers is what shows the system's Bluetooth question, the first time. Their state arrives a moment later.
        central = CBCentralManager(delegate: proxy, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        advertiser = CBPeripheralManager(delegate: proxy, queue: nil, options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
        return .active
    }

    func stop() {
        stopRadios()
        listener = nil
    }

    private func stopRadios() {
        running = false
        if scanning { central?.stopScan() }
        for client in clients.values { central?.cancelPeripheralConnection(client.peripheral) }
        clients.removeAll()
        if advertising { advertiser?.stopAdvertising() }
        advertiser?.removeAllServices()
        central = nil
        advertiser = nil
        proxy = nil
        scanning = false
        advertising = false
        reportedActive = false
        seen.removeAll()
        serverClients.removeAll()
        offerCache.removeAll()
        pendingGo.removeAll()
        infoCharacteristic = nil
        offerCharacteristic = nil
        controlCharacteristic = nil
        eventCharacteristic = nil
    }

    // MARK: Manager state

    fileprivate func centralStateChanged(_ state: CBManagerState) {
        guard running else { return }
        switch state {
        case .poweredOn:
            startScanning()
            reportActiveIfReady()
        case .poweredOff:
            teardownForStatus(.bluetoothOff)
        case .unauthorized:
            teardownForStatus(.noPermission)
        case .unsupported:
            teardownForStatus(.unsupported)
        default:
            break
        }
    }

    fileprivate func advertiserStateChanged(_ state: CBManagerState) {
        guard running else { return }
        switch state {
        case .poweredOn:
            if role == .send { openServer() } else { startAdvertising(Self.receiveService) }
        case .poweredOff, .unauthorized, .unsupported:
            // The scanner's state reports the same thing; the advertiser only needs to stop trying.
            advertising = false
        default:
            break
        }
    }

    /// The radio is usable once it can scan; a sender also has to have its service up (it advertises from `didAdd`).
    private func reportActiveIfReady() {
        if reportedActive { return }
        reportedActive = true
        listener?.onStatus(.active)
    }

    /// Bluetooth went away (or was never allowed): whatever was in flight is lost, and the route is told why.
    private func teardownForStatus(_ status: SongTapBleStatus) {
        scanning = false
        advertising = false
        reportedActive = false
        for client in clients.values { central?.cancelPeripheralConnection(client.peripheral) }
        clients.removeAll()
        seen.removeAll()
        serverClients.removeAll()
        offerCache.removeAll()
        pendingGo.removeAll()
        infoCharacteristic = nil
        offerCharacteristic = nil
        controlCharacteristic = nil
        eventCharacteristic = nil
        listener?.onStatus(status)
    }

    // MARK: Advertising and scanning

    private func startScanning() {
        guard let central, !scanning else { return }
        scanning = true
        central.scanForPeripherals(withServices: [Self.sendService, Self.receiveService],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private func startAdvertising(_ service: CBUUID) {
        guard let advertiser, !advertising else { return }
        advertising = true
        advertiser.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [service]])
    }

    fileprivate func discovered(_ peripheral: CBPeripheral, advertisement: [String: Any], rssi: Int) {
        guard running, rssi != 127 else { return }
        var uuids = advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        uuids += advertisement[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        var peerRole: SongTapRole?
        for uuid in uuids {
            if let r = SongTapWire.roleOfService(uuid.uuidString.lowercased()) { peerRole = r; break }
        }
        guard let peerRole else { return }
        let address = peripheral.identifier.uuidString
        seen[address] = peripheral
        listener?.onSeen(address: address, role: peerRole, rssi: rssi)
    }

    // MARK: The sender's GATT server

    private func openServer() {
        guard let advertiser, infoCharacteristic == nil else { return }
        let info = CBMutableCharacteristic(type: Self.info, properties: [.read], value: nil, permissions: [.readable])
        let offer = CBMutableCharacteristic(type: Self.offer, properties: [.read], value: nil, permissions: [.readable])
        let control = CBMutableCharacteristic(type: Self.control, properties: [.write], value: nil, permissions: [.writeable])
        let event = CBMutableCharacteristic(type: Self.event, properties: [.notify], value: nil, permissions: [.readable])
        infoCharacteristic = info
        offerCharacteristic = offer
        controlCharacteristic = control
        eventCharacteristic = event
        let service = CBMutableService(type: Self.sendService, primary: true)
        service.characteristics = [info, offer, control, event]
        advertiser.add(service)
    }

    fileprivate func serviceAdded(error: Bool) {
        guard running, role == .send else { return }
        if error {
            listener?.onStatus(.unsupported)
            return
        }
        startAdvertising(Self.sendService)
        reportActiveIfReady()
    }

    fileprivate func advertisingStarted(error: Bool) {
        guard running, error else { return }
        advertising = false
        listener?.onStatus(.unsupported)
    }

    private static let notReady: CBATTError.Code = CBATTError.Code(rawValue: SongTapWire.errorNotReady) ?? .unlikelyError

    fileprivate func readRequested(_ request: CBATTRequest) {
        guard let advertiser, running else { return }
        let address = request.central.identifier.uuidString
        serverClients[address] = request.central
        let full: [UInt8]?
        switch request.characteristic.uuid {
        case Self.info:
            full = listener?.serverInfo()
        case Self.offer:
            // A long read comes as several requests with growing offsets: sign once, on the first.
            if request.offset == 0 {
                let frame = listener?.serverOffer(client: address)
                offerCache[address] = frame
                full = frame
            } else {
                full = offerCache[address]
            }
        default:
            full = nil
        }
        guard let full else {
            advertiser.respond(to: request, withResult: Self.notReady)
            return
        }
        if request.offset > full.count {
            advertiser.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = Data(full[request.offset...])
        advertiser.respond(to: request, withResult: .success)
    }

    fileprivate func writesRequested(_ requests: [CBATTRequest]) {
        guard let advertiser, running, let first = requests.first else { return }
        var ok = true
        for request in requests {
            let address = request.central.identifier.uuidString
            serverClients[address] = request.central
            let accepted = request.characteristic.uuid == Self.control && request.offset == 0 && request.value != nil
                && (listener?.serverControl(client: address, value: Array(request.value ?? Data())) ?? false)
            if !accepted { ok = false }
        }
        advertiser.respond(to: first, withResult: ok ? .success : Self.notReady)
    }

    fileprivate func subscribed(_ central: CBCentral, to characteristic: CBCharacteristic) {
        serverClients[central.identifier.uuidString] = central
    }

    fileprivate func unsubscribed(_ central: CBCentral) {
        let address = central.identifier.uuidString
        serverClients[address] = nil
        offerCache[address] = nil
        pendingGo.removeAll { $0 == address }
        listener?.serverClientGone(client: address)
    }

    fileprivate func readyToNotify() {
        let waiting = pendingGo
        pendingGo.removeAll()
        for address in waiting { notifyGo(client: address) }
    }

    func notifyGo(client: String) {
        guard let advertiser, let event = eventCharacteristic, let target = serverClients[client] else { return }
        let sent = advertiser.updateValue(Data(SongTapWire.encodeGo()), for: event, onSubscribedCentrals: [target])
        if !sent { pendingGo.append(client) }
    }

    func dropClient(client: String) {
        // iOS has no way to disconnect a central from the server side; the receiver ends its own connection.
    }

    // MARK: The receiver's client side

    func connect(address: String) {
        guard running, let central else { failLater(address) { $0.onConnected(address: address, ok: false) }; return }
        guard let peripheral = seen[address] else { failLater(address) { $0.onConnected(address: address, ok: false) }; return }
        if clients[address] != nil { return }
        clients[address] = Client(peripheral)
        peripheral.delegate = proxy
        central.connect(peripheral, options: nil)
    }

    func disconnect(address: String) {
        guard let client = clients.removeValue(forKey: address) else { return }
        central?.cancelPeripheralConnection(client.peripheral)
    }

    func readInfo(address: String) { enqueue(address, .readInfo) }
    func readOffer(address: String) { enqueue(address, .readOffer) }
    func writeControl(address: String, value: [UInt8]) { enqueue(address, .write(value)) }

    private func enqueue(_ address: String, _ op: Op) {
        guard let client = clients[address] else {
            failLater(address) { listener in
                switch op {
                case .readInfo: listener.onInfoRead(address: address, value: nil)
                case .readOffer: listener.onOfferRead(address: address, value: nil)
                case .write: listener.onControlWritten(address: address, ok: false)
                }
            }
            return
        }
        client.queue.append(op)
        pump(address, client)
    }

    /// Runs the next queued operation if none is in flight.
    private func pump(_ address: String, _ client: Client) {
        guard client.ready, !client.busy, !client.queue.isEmpty else { return }
        let op = client.queue.removeFirst()
        let peripheral = client.peripheral
        switch op {
        case .readInfo:
            guard let c = client.info else { return failLater(address) { $0.onInfoRead(address: address, value: nil) } }
            client.busy = true
            peripheral.readValue(for: c)
        case .readOffer:
            guard let c = client.offer else { return failLater(address) { $0.onOfferRead(address: address, value: nil) } }
            client.busy = true
            peripheral.readValue(for: c)
        case .write(let bytes):
            guard let c = client.control else { return failLater(address) { $0.onControlWritten(address: address, ok: false) } }
            client.busy = true
            peripheral.writeValue(Data(bytes), for: c, type: .withResponse)
        }
    }

    /// A failure that could not even start is reported after the current call returns: the route may be in the middle of one.
    private func failLater(_ address: String, _ report: @escaping @MainActor (any SongTapBleRadioListener) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                if let listener = self?.listener { report(listener) }
            }
        }
    }

    private func key(of peripheral: CBPeripheral) -> String { peripheral.identifier.uuidString }

    fileprivate func didConnect(_ peripheral: CBPeripheral) {
        guard clients[key(of: peripheral)] != nil else { return }
        peripheral.discoverServices([Self.sendService])
    }

    fileprivate func connectionEnded(_ peripheral: CBPeripheral) {
        let address = key(of: peripheral)
        guard let client = clients.removeValue(forKey: address) else { return }
        central?.cancelPeripheralConnection(peripheral)
        if client.ready { listener?.onDisconnected(address: address) } else { listener?.onConnected(address: address, ok: false) }
    }

    fileprivate func didDiscoverServices(_ peripheral: CBPeripheral, failed: Bool) {
        guard clients[key(of: peripheral)] != nil else { return }
        guard !failed, let service = peripheral.services?.first(where: { $0.uuid == Self.sendService }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.info, Self.offer, Self.control, Self.event], for: service)
    }

    fileprivate func didDiscoverCharacteristics(_ peripheral: CBPeripheral, failed: Bool) {
        guard let client = clients[key(of: peripheral)] else { return }
        let characteristics = peripheral.services?.first(where: { $0.uuid == Self.sendService })?.characteristics ?? []
        client.info = characteristics.first { $0.uuid == Self.info }
        client.offer = characteristics.first { $0.uuid == Self.offer }
        client.control = characteristics.first { $0.uuid == Self.control }
        client.event = characteristics.first { $0.uuid == Self.event }
        guard !failed, client.info != nil, client.offer != nil, client.control != nil, let event = client.event else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.setNotifyValue(true, for: event)
    }

    fileprivate func notificationStateChanged(_ peripheral: CBPeripheral, characteristic: CBUUID, on: Bool, failed: Bool) {
        let address = key(of: peripheral)
        guard let client = clients[address], characteristic == Self.event else { return }
        if failed || !on {
            if !client.ready { central?.cancelPeripheralConnection(peripheral) }
            return
        }
        if client.ready { return }
        client.ready = true
        client.busy = false
        listener?.onConnected(address: address, ok: true)
        // The route may have queued operations in answer; the next ones run as each completes.
        if let still = clients[address] { pump(address, still) }
    }

    fileprivate func valueUpdated(_ peripheral: CBPeripheral, characteristic: CBUUID, value: [UInt8]?, failed: Bool) {
        let address = key(of: peripheral)
        guard let client = clients[address] else { return }
        switch characteristic {
        case Self.event:
            if let value, !failed { listener?.onNotified(address: address, value: value) }
        case Self.info:
            client.busy = false
            listener?.onInfoRead(address: address, value: failed ? nil : value)
            if let still = clients[address] { pump(address, still) }
        case Self.offer:
            client.busy = false
            listener?.onOfferRead(address: address, value: failed ? nil : value)
            if let still = clients[address] { pump(address, still) }
        default:
            break
        }
    }

    fileprivate func valueWritten(_ peripheral: CBPeripheral, failed: Bool) {
        let address = key(of: peripheral)
        guard let client = clients[address] else { return }
        client.busy = false
        listener?.onControlWritten(address: address, ok: !failed)
        if let still = clients[address] { pump(address, still) }
    }
}

/// CoreBluetooth's delegate, which Objective-C calls on the main queue (the managers are made with no queue). It only forwards,
/// to the main actor, plain values plus the CoreBluetooth objects the radio has to hold on to.
nonisolated final class SongTapBluetoothProxy: NSObject, CBCentralManagerDelegate, CBPeripheralManagerDelegate, CBPeripheralDelegate,
    @unchecked Sendable {
    private unowned let radio: SongTapBluetoothRadio

    @MainActor init(radio: SongTapBluetoothRadio) {
        self.radio = radio
        super.init()
    }

    // Central

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        MainActor.assumeIsolated { radio.centralStateChanged(state) }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        nonisolated(unsafe) let p = peripheral
        nonisolated(unsafe) let advertisement = advertisementData
        let rssi = RSSI.intValue
        MainActor.assumeIsolated { radio.discovered(p, advertisement: advertisement, rssi: rssi) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        nonisolated(unsafe) let p = peripheral
        MainActor.assumeIsolated { radio.didConnect(p) }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        nonisolated(unsafe) let p = peripheral
        MainActor.assumeIsolated { radio.connectionEnded(p) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        nonisolated(unsafe) let p = peripheral
        MainActor.assumeIsolated { radio.connectionEnded(p) }
    }

    // Peripheral (the sender we are connected to)

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        nonisolated(unsafe) let p = peripheral
        let failed = error != nil
        MainActor.assumeIsolated { radio.didDiscoverServices(p, failed: failed) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        nonisolated(unsafe) let p = peripheral
        let failed = error != nil
        MainActor.assumeIsolated { radio.didDiscoverCharacteristics(p, failed: failed) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        nonisolated(unsafe) let p = peripheral
        nonisolated(unsafe) let uuid = characteristic.uuid
        let on = characteristic.isNotifying
        let failed = error != nil
        MainActor.assumeIsolated { radio.notificationStateChanged(p, characteristic: uuid, on: on, failed: failed) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        nonisolated(unsafe) let p = peripheral
        nonisolated(unsafe) let uuid = characteristic.uuid
        let value = characteristic.value.map { Array($0) }
        let failed = error != nil
        MainActor.assumeIsolated { radio.valueUpdated(p, characteristic: uuid, value: value, failed: failed) }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        nonisolated(unsafe) let p = peripheral
        let failed = error != nil
        MainActor.assumeIsolated { radio.valueWritten(p, failed: failed) }
    }

    // Peripheral manager (the sender's server)

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let state = peripheral.state
        MainActor.assumeIsolated { radio.advertiserStateChanged(state) }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        let failed = error != nil
        MainActor.assumeIsolated { radio.serviceAdded(error: failed) }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        let failed = error != nil
        MainActor.assumeIsolated { radio.advertisingStarted(error: failed) }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        nonisolated(unsafe) let r = request
        MainActor.assumeIsolated { radio.readRequested(r) }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        nonisolated(unsafe) let r = requests
        MainActor.assumeIsolated { radio.writesRequested(r) }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        nonisolated(unsafe) let c = central
        nonisolated(unsafe) let ch = characteristic
        MainActor.assumeIsolated { radio.subscribed(c, to: ch) }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        nonisolated(unsafe) let c = central
        MainActor.assumeIsolated { radio.unsubscribed(c) }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated { radio.readyToNotify() }
    }
}
