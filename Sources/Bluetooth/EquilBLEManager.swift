import CoreBluetooth
import Foundation

/// Low-level BLE transport for the Equil patch pump.
///
/// Byte-parity reference: AndroidAPS `pump/equil/ble/EquilBLE.kt` + `GattAttributes.kt`.
/// GATT: SERVICE_RADIO = 0000f000-..., single characteristic 0000f001-... used for
/// BOTH write (write-with-response) and notify. CCCD = 00002902-...
///
/// Transport contract mirrors EquilBLE.kt exactly:
///  - On CCCD-notification-enabled (`onReady`) the caller pushes the first command's
///    outgoing packet list and we send them one-by-one, gated by `didWriteValueFor`
///    (with a 20 ms inter-packet delay = EQUIL_BLE_WRITE_TIME_OUT).
///  - Incoming notifications are forwarded verbatim to `onNotify` (the command layer
///    reassembles them via decodeEquilPacket and returns the next packet list, which
///    the caller pushes back through `send(packets:)`).
final class EquilBLEManager: NSObject {

    // MARK: GATT constants (byte-parity: GattAttributes.kt)
    static let serviceRadio = CBUUID(string: "0000f000-0000-1000-8000-00805f9b34fb")
    static let charUART     = CBUUID(string: "0000f001-0000-1000-8000-00805f9b34fb")
    static let cccd         = CBUUID(string: "00002902-0000-1000-8000-00805f9b34fb")

    /// EQUIL_BLE_WRITE_TIME_OUT = 20 ms (EquilConst.kt)
    static let writeGapMs: UInt64 = 20

    // MARK: State
    private let queue = DispatchQueue(label: "equil.ble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    /// A jelenleg kapcsolódott/cél peripheral (watchdog megtartáshoz). nil ha nincs.
    var currentPeripheral: CBPeripheral? { peripheral }
    private var uartChar: CBCharacteristic?

    /// Optional name prefix filter. Equil advertises as "Equil ..." (CmdPair strips
    /// "Equil - " prefix to get the serial). nil = report every named peripheral.
    var nameFilterPrefix: String? = "Equil"

    /// Optional substring filter (AAPS EquilPairSerialNumberFragment uses
    /// `name.contains(serialNumber)` to find the right pump during pairing).
    /// When set, only peripherals whose advertised name contains this string
    /// (case-insensitive) are reported. nil = no substring filtering.
    var nameFilterContains: String?

    /// Outgoing packets pending sequential write; index of next to send.
    private var outgoing: [Data] = []
    private var outIndex = 0

    private(set) var isConnected = false

    // MARK: - BT Watchdog (állandó kapcsolat-tartás + auto force-reconnect)
    /// Ha igaz, a kapcsolat megszakadásakor azonnal újraépítjük (iOS reconnect, scan nélkül).
    var watchdogEnabled = false
    /// Ha igaz, a watchdog auto-reconnect FEL VAN FÜGGESZTVE (parancs-futtatás alatt),
    /// hogy ne versenyezzen a connect-per-command kapcsolatépítéssel (AAPS-modell).
    var watchdogPaused = false
    private var watchdogPeripheralID: UUID?
    private var watchdogTimer: DispatchSourceTimer?

    // MARK: Callbacks (main-thread dispatch is the caller's responsibility)
    var onLog: ((String) -> Void)?
    var onStateChange: ((CBManagerState) -> Void)?
    var onDiscover: ((CBPeripheral, String) -> Void)?      // peripheral, name
    var onConnected: (() -> Void)?
    var onDisconnected: ((Error?) -> Void)?
    /// Fired after CCCD write completes — the pump is ready to receive command packets.
    var onReady: (() -> Void)?
    /// One raw notification frame (16-byte or shorter last packet) from the pump.
    var onNotify: ((Data) -> Void)?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    // MARK: Public API
    func startScan() {
        guard central.state == .poweredOn else {
            log("startScan: BT not powered on (state=\(central.state.rawValue))")
            return
        }
        if central.isScanning { central.stopScan() }
        log("startScan")
        // Scan all services — Equil's advertised service list is unreliable across firmware.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        if central.isScanning {
            central.stopScan()
            log("stopScan")
        }
    }

    func connect(_ p: CBPeripheral) {
        stopScan()
        peripheral = p
        p.delegate = self
        log("connect -> \(p.name ?? "?")")
        central.connect(p, options: nil)
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        isConnected = false
        uartChar = nil
        outgoing = []
        outIndex = 0
    }

    /// Queue a command's framed packet list and begin sequential transmission.
    /// Mirrors EquilBLE.ready()/writeData(): send send[0], then send[i] after each
    /// onWrite callback. Reset index to 0 before pushing.
    func send(packets: [Data]) {
        guard !packets.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.outgoing = packets
            self.outIndex = 0
            self.writeNext()
        }
    }

    // MARK: Internal transmit pump
    private func writeNext() {
        guard let p = peripheral, let ch = uartChar else {
            log("writeNext: no peripheral/char — disconnect")
            disconnect()
            return
        }
        guard outIndex < outgoing.count else { return } // all sent
        let data = outgoing[outIndex]
        outIndex += 1
        log("write[\(outIndex)/\(outgoing.count)]: \(data.hexUpper)")
        p.writeValue(data, for: ch, type: .withResponse)
    }

    private func log(_ msg: String) {
        onLog?(msg)
    }
}

// MARK: - CBCentralManagerDelegate
extension EquilBLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        log("central state = \(c.state.rawValue)")
        onStateChange?(c.state)
    }

    func centralManager(_ c: CBCentralManager,
                        didDiscover p: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name
        guard let name = advName, !name.isEmpty else { return }
        if let prefix = nameFilterPrefix, !name.hasPrefix(prefix) { return }
        if let needle = nameFilterContains, !needle.isEmpty,
           !name.lowercased().contains(needle.lowercased()) { return }
        log("discover: \(name) rssi=\(RSSI)")
        onDiscover?(p, name)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        isConnected = true
        log("connected; discovering services")
        p.delegate = self
        p.discoverServices([EquilBLEManager.serviceRadio])
        onConnected?()
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("didFailToConnect: \(error?.localizedDescription ?? "?")")
        isConnected = false
        onDisconnected?(error)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("disconnected: \(error?.localizedDescription ?? "clean")")
        isConnected = false
        uartChar = nil
        outgoing = []
        outIndex = 0
        onDisconnected?(error)
        // AAPS connect-per-command modell: a disconnect NORMÁLIS (a pumpa ~11s inaktivitás
        // után magától bont). NINCS auto-reconnect — a következő parancs maga csatlakozik
        // a connectForCommand()-dal. Így nincs watchdog↔parancs kapcsolat-verseny, ami a
        // bólusz 2. üzenetét meghiúsította (a pumpa 10s-os időzítője a parancs kezdetekor indul).
    }
}

// MARK: - CBPeripheralDelegate
extension EquilBLEManager: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { log("didDiscoverServices error: \(error)"); return }
        guard let svc = p.services?.first(where: { $0.uuid == EquilBLEManager.serviceRadio }) else {
            log("SERVICE_RADIO not found"); return
        }
        p.discoverCharacteristics([EquilBLEManager.charUART], for: svc)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
        if let error { log("didDiscoverCharacteristics error: \(error)"); return }
        guard let ch = svc.characteristics?.first(where: { $0.uuid == EquilBLEManager.charUART }) else {
            log("UART char not found"); return
        }
        uartChar = ch
        log("UART char found; enabling notifications")
        p.setNotifyValue(true, for: ch) // CoreBluetooth writes the CCCD for us
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        if let error { log("didUpdateNotificationState error: \(error)"); return }
        guard ch.isNotifying else { return }
        log("notifications enabled -> ready")
        onReady?()
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        if let error { log("didWriteValueFor error: \(error)"); return }
        // EquilBLE.onCharacteristicWrite: sleep(EQUIL_BLE_WRITE_TIME_OUT) then writeData()
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(EquilBLEManager.writeGapMs))) { [weak self] in
            self?.writeNext()
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if let error { log("didUpdateValueFor error: \(error)"); return }
        guard let value = ch.value else { return }
        log("notify: \(value.hexUpper)")
        onNotify?(value)
    }
}

// MARK: - Data hex helper (transport logging only)
private extension Data {
    var hexUpper: String { map { String(format: "%02X", $0) }.joined() }
}

// MARK: - BT Watchdog implementáció (állandó kapcsolat + force-reconnect)
//
// iOS-specifikus megközelítés (erősebb mint az AAPS connect-per-command modell):
// a párosított CBPeripheral-t megtartjuk, és central.connect()-tel tartjuk/visszakötjük.
// A connect() timeout NÉLKÜL fut — iOS magától visszaköt, amint a pumpa hatótávba ér,
// új scan nélkül. Ez kiküszöböli a bondolás utáni "nem hirdet újra nevet" scan-race-t,
// ami a bólusz időtúllépést okozta.
extension EquilBLEManager {

    /// A sikeres párosítás után hívandó: eltárolja és "fogja" a peripheral-t a watchdoghoz.
    func holdPeripheral(_ p: CBPeripheral) {
        watchdogPeripheralID = p.identifier
        peripheral = p
        p.delegate = self
        watchdogEnabled = true
        log("watchdog: peripheral fogva (\(p.name ?? "?")) id=\(p.identifier.uuidString.prefix(8))")
    }

    /// Periodikus őr: ha be van kapcsolva és nincs kapcsolat, reconnect-et kísérel.
    func startWatchdog(intervalSeconds: Int = 3) {
        watchdogTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(intervalSeconds),
                       repeating: .seconds(intervalSeconds))
        timer.setEventHandler { /* watchdog kikapcsolva — AAPS connect-per-command */ }
        watchdogTimer = timer
        // NEM indítjuk el a timert: nincs periodikus reconnect (AAPS-modell).
        log("watchdog: periodikus reconnect KIKAPCSOLVA (connect-per-command)")
    }

    func stopWatchdog() {
        watchdogEnabled = false
        watchdogTimer?.cancel()
        watchdogTimer = nil
        log("watchdog: leállítva")
    }

    /// Azonnali reconnect a megtartott peripheral-hoz (timeout nélkül — iOS hatótáv-figyel).
    func reconnectNow() {
        guard central.state == .poweredOn else {
            log("watchdog: BT nincs poweredOn (\(central.state.rawValue)) — kihagyva")
            return
        }
        guard let p = peripheral else {
            // Talán app-újraindítás után vagyunk: próbáljuk visszakérni az ID alapján.
            if let id = watchdogPeripheralID, retrieveAndHold(identifier: id) {
                log("watchdog: peripheral visszakérve, reconnect…")
                if let pp = peripheral { central.connect(pp, options: nil) }
            } else {
                log("watchdog: nincs megtartott peripheral — reconnect kihagyva")
            }
            return
        }
        if isConnected { return }
        log("watchdog: reconnect kísérlet -> \(p.name ?? "?")")
        central.connect(p, options: [CBConnectPeripheralOptionNotifyOnConnectionKey: true])
    }

    /// App-újraindítás után: a bondolt peripheral visszakérése scan nélkül.
    @discardableResult
    func retrieveAndHold(identifier: UUID) -> Bool {
        guard let p = central.retrievePeripherals(withIdentifiers: [identifier]).first else {
            return false
        }
        holdPeripheral(p)
        return true
    }

    // MARK: - Connect-per-command (AAPS-modell)
    // A pumpa ~11s inaktivitás után magától bont, ezért NEM tartunk állandó kapcsolatot
    // parancs közben. A bólusz: pause watchdog → friss connect a megtartott peripheral-hoz
    // (scan nélkül) → parancs lefut → resume watchdog. Így nincs scan/reconnect verseny.

    /// Felfüggeszti a watchdog auto-reconnect-jét egy parancs idejére.
    func pauseWatchdog() {
        watchdogPaused = true
        log("watchdog: FELFÜGGESZTVE (parancs-futtatás alatt)")
    }

    /// Visszakapcsolja a watchdog auto-reconnect-jét a parancs után.
    func resumeWatchdog() {
        guard watchdogEnabled else { return }
        watchdogPaused = false
        log("watchdog: FOLYTATVA")
    }

    /// Friss kapcsolatot épít a megtartott peripheral-hoz scan NÉLKÜL (AAPS connectEquil).
    /// Ha már él a kapcsolat, az onConnected-et nem várjuk — a hívó ellenőrzi isConnected-et.
    /// Ha a peripheral elveszett (app-restart), ID alapján visszakéri.
    func connectForCommand() {
        guard central.state == .poweredOn else {
            log("connectForCommand: BT nincs poweredOn (\(central.state.rawValue))")
            return
        }
        // Tiszta induló állapot: minden korábbi kapcsolatot bontunk, hogy a pumpa friss
        // GATT-ot kapjon (a fél-állapotú kapcsolat okozta a néma 10s-os pumpa-bontást).
        if let p = peripheral {
            if isConnected {
                log("connectForCommand: bontás a friss kapcsolat előtt")
                central.cancelPeripheralConnection(p)
                isConnected = false
                uartChar = nil
            }
            stopScan()
            outgoing = []
            outIndex = 0
            peripheral = p
            p.delegate = self
            log("connectForCommand -> \(p.name ?? "?") (scan nélkül)")
            // 500 ms késleltetés a bontás után (AAPS EQUIL_BLE_NEXT_CMD-tanulság),
            // hogy a stack tisztuljon, mielőtt újracsatlakozunk.
            queue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                guard let self, let pp = self.peripheral else { return }
                self.central.connect(pp, options: nil)
            }
        } else if let id = watchdogPeripheralID, retrieveAndHold(identifier: id) {
            log("connectForCommand: peripheral visszakérve ID alapján")
            if let pp = peripheral {
                queue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                    self?.central.connect(pp, options: nil)
                }
            }
        } else {
            log("connectForCommand: nincs megtartott peripheral — scan-re esünk vissza")
            startScan()
        }
    }
}
