import Foundation
import Combine
import CoreBluetooth
import os

/// View model wiring EquilBLEManager + EquilCommandRunner to the SwiftUI controller.
/// Streams every log line to the UI and to os_log (so `log stream` on the Mac sees it too).
@MainActor
final class EquilControllerModel: ObservableObject {

    // MARK: UI state
    @Published var logLines: [String] = []
    @Published var btState: String = "ismeretlen"
    @Published var serialNumber: String = "A09F2A"    // 6 hex (a pumpa SN-je / neve) — fix alapértelmezett
    @Published var pairPassword: String = "0000"      // 4 hex (a pumpa jelszava)
    @Published var maxBolus: String = "25"            // max bólusz (E) — küszöbhöz
    @Published var maxBasal: String = "15"            // max basal (E/h) — küszöbhöz
    @Published var bolusUnits: String = "0.05"
    @Published var tempRate: String = "0.5"           // temp basal ráta (E/h)
    @Published var tempDuration: String = "30"        // temp basal időtartam (perc)
    @Published var busy: Bool = false
    @Published var statusLine: String = "Készenlét"

    // MARK: Beviteli validáció (AAPS regex: 6 / 4 hex karakter)
    var serialNumberValid: Bool {
        serialNumber.range(of: "^[0-9A-Fa-f]{6}$", options: .regularExpression) != nil
    }
    var pairPasswordValid: Bool {
        pairPassword.range(of: "^[0-9A-Fa-f]{4}$", options: .regularExpression) != nil
    }

    // MARK: Stored pairing result (device/password negotiated during pairing)
    @Published var pairedDevice: String = ""
    @Published var pairedPassword: String = ""

    // MARK: Scanner (diagnosztika) — közeli BLE-eszközök szűrő nélkül
    struct DiscoveredDevice: Identifiable {
        let id: String      // peripheral identifier (uuid)
        let name: String
        var rssi: Int
        var matchesSerial: Bool
    }
    @Published var scanning: Bool = false
    @Published var discovered: [DiscoveredDevice] = []

    private let ble = EquilBLEManager()
    private lazy var runner = EquilCommandRunner(ble: ble)
    private let oslog = Logger(subsystem: "app.equil.controller", category: "Equil")

    // MARK: Beágyazott HTTP log-szerver (curl http://<iphone-ip>:8080 a Macen)
    let logServer = LogServer()
    @Published var logURL: String = "log-szerver indul…"

    init() {
        ble.onStateChange = { [weak self] state in
            Task { @MainActor in self?.btState = Self.describe(state) }
        }
        runner.onLog = { [weak self] line in
            Task { @MainActor in self?.append(line) }
        }
        ble.onLog = { [weak self] line in
            Task { @MainActor in self?.append("[BLE] \(line)") }
        }
        // Diagnosztikai protokoll-log bekötése (decode() lépés, runPwd/runCode/payload).
        EquilBaseCmd.debugLog = { [weak self] line in
            Task { @MainActor in self?.append(line) }
        }
        // Beágyazott log-szerver indítása — a Macen: curl http://<iphone-ip>:8080
        logServer.start(port: 8080)
        if let ip = logServer.ipAddress {
            logURL = "http://\(ip):8080"
        } else {
            logURL = "Wi-Fi IP nem elérhető (port 8080)"
        }
        append("📡 Log-szerver: \(logURL)")
    }

    // MARK: Actions
    /// Teljes 4-lépéses AAPS-hű párosítás: SN-szűrt scan → CmdDevicesOldGet →
    /// CmdPair → CmdSettingSet. A SN-t és jelszót a felhasználó adja meg.
    func startPairing() {
        guard !busy else { return }
        guard serialNumberValid else {
            append("⚠️ Érvénytelen sorozatszám (6 hex karakter kell, pl. A1B2C3)")
            statusLine = "Hibás SN"
            return
        }
        guard pairPasswordValid else {
            append("⚠️ Érvénytelen jelszó (4 hex karakter kell, pl. 0000)")
            statusLine = "Hibás jelszó"
            return
        }
        let mb = Double(maxBolus) ?? 25
        let mbas = Double(maxBasal) ?? 15
        busy = true
        statusLine = "Párosítás folyamatban…"
        append("=== PÁROSÍTÁS START (SN=\(serialNumber), jelszó=\(pairPassword)) ===")
        runner.runPairing(serialNumber: serialNumber,
                          password: pairPassword,
                          maxBolus: mb,
                          maxBasal: mbas,
                          timeout: 90) { [weak self] outcome in
            self?.handle(outcome, kind: "Párosítás")
            if case .success = outcome {
                self?.pairedDevice = self?.runner.pairedDevice ?? ""
                self?.pairedPassword = self?.runner.pairedPassword ?? ""
                self?.append("Tárolt device=\(self?.runner.pairedDevice ?? "?")")
                self?.append("Tárolt password=\(self?.runner.pairedPassword ?? "?")")
                // BT WATCHDOG aktiválása: megtartjuk a párosított peripheral-t és tartjuk a kapcsolatot.
                self?.activateWatchdogAfterPairing()
            }
        }
    }

    func sendBolus() {
        guard !busy else { return }
        guard !pairedDevice.isEmpty, !pairedPassword.isEmpty else {
            append("⚠️ Előbb párosíts (nincs tárolt device/password)")
            return
        }
        guard let units = Double(bolusUnits), units > 0 else {
            append("⚠️ Érvénytelen bólusz mennyiség")
            return
        }
        busy = true
        statusLine = "Bólusz \(units) E a levegőbe…"
        append("=== BÓLUSZ START: \(units) E (a levegőbe) ===")
        let cmd = CmdLargeBasalSet(insulin: units,
                                   createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                   equilDevice: pairedDevice,
                                   equilPassword: pairedPassword)
        // CONNECT-PER-COMMAND (AAPS-modell): a pumpa ~11s után magától bont, ezért
        // NEM az állandó watchdog-kapcsolatra építünk. Felfüggesztjük a watchdogot,
        // friss kapcsolatot építünk a megtartott peripheral-hoz (scan nélkül), és csak
        // amikor a kapcsolat READY (onConnected), AKKOR futtatjuk a parancsot.
        runCommandPerConnection(cmd, kind: "Bólusz")
    }

    // MARK: - PRIME / FELTÖLTÉS (AAPS EquilPairFillFragment-hű)
    //
    //  A dugattyút (pin) lépésenként (EQUIL_STEP_FILL=160) előretoljuk (CmdStepSet),
    //  majd ellenállást mérünk (CmdResistanceGet). Ha az ellenállás eléri a küszöböt
    //  (A09F2A → A → régi pumpa → 500), a pin elérte a pisztont → delivery-ready.
    //  Egyesével, külön kapcsolatokon (connect-per-command), max 32000 lépésig.
    private let primeStepFill = 160
    private let primeStepMax = 32000
    private var primeStepTotal = 0

    /// SN első karaktere ∈ {0,1,3,A,D} → 500 (régi), különben 220 (AAPS getResistanceThreshold).
    private var resistanceThreshold: Int {
        let first = serialNumber.uppercased().first
        let old: Set<Character> = ["0","1","3","A","D"]
        if let c = first, old.contains(c) { return 500 }
        return 220
    }

    func startPrime() {
        guard !busy else { return }
        guard !pairedDevice.isEmpty, !pairedPassword.isEmpty else {
            append("⚠️ Előbb párosíts (nincs tárolt device/password)")
            return
        }
        busy = true
        primeStepTotal = 0
        statusLine = "Feltöltés (prime) indul…"
        append("=== PRIME START (küszöb=\(resistanceThreshold)) ===")
        primeMoveStep()
    }

    /// 1. lépés: pin-mozgatás (CmdStepSet 160).
    private func primeMoveStep() {
        let cmd = CmdStepSet(sendConfig: false, step: primeStepFill,
                             createTime: Int64(Date().timeIntervalSince1970 * 1000),
                             equilDevice: pairedDevice, equilPassword: pairedPassword)
        runCommandPerConnection(cmd, kind: "Prime-lépés") { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success:
                self.primeStepTotal += self.primeStepFill
                self.append("➡️ Pin mozgatva, össz lépés=\(self.primeStepTotal)")
                self.primeReadResistance()
            case .failure(let msg):
                self.append("❌ Prime-lépés HIBA: \(msg)")
                self.statusLine = "Prime: HIBA (lépés) — \(msg)"
                self.busy = false
                self.ble.onReady = nil; self.ble.onConnected = nil
            }
        }
    }

    /// 2. lépés: ellenállás-mérés (CmdResistanceGet). enacted=true → pin a pisztonnál.
    private func primeReadResistance() {
        let cmd = CmdResistanceGet(threshold: resistanceThreshold,
                                   createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                   equilDevice: pairedDevice, equilPassword: pairedPassword)
        runCommandPerConnection(cmd, kind: "Ellenállás") { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success(let enacted):
                if enacted {
                    self.append("✅ PIN ELÉRTE A PISZTONT — feltöltés kész (lépés=\(self.primeStepTotal)). Most jöhet a bólusz.")
                    self.statusLine = "Prime KÉSZ — delivery-ready"
                    self.busy = false
                    self.ble.onReady = nil; self.ble.onConnected = nil
                } else if self.primeStepTotal > self.primeStepMax {
                    self.append("⚠️ MAX LÉPÉS túllépve (\(self.primeStepTotal)) — cseréld a rezervoárt")
                    self.statusLine = "Prime: max lépés túllépve"
                    self.busy = false
                    self.ble.onReady = nil; self.ble.onConnected = nil
                } else {
                    self.append("↻ Pin még nincs a pisztonnál — folytatás…")
                    self.primeMoveStep()
                }
            case .failure(let msg):
                self.append("❌ Ellenállás HIBA: \(msg)")
                self.statusLine = "Prime: HIBA (ellenállás) — \(msg)"
                self.busy = false
                self.ble.onReady = nil; self.ble.onConnected = nil
            }
        }
    }

    // MARK: - FUTÁSI MÓD (AAPS EquilPairConfirmFragment záró lépése)
    //
    //  A párosítás UTOLSÓ lépése az AAPS-ben CmdModelSet(RUN=1) — ez teszi a pumpát
    //  bólusz-fogadó állapotba. NÉLKÜLE a pumpa némán eldobja a bólusz Msg2-t.
    //  Külön gombbal kézzel kiváltható (a párosítás után).

    /// RUN módba állítja a pumpát (CmdModelSet mode=1).
    func setRunMode() {
        guard !busy else { return }
        guard !pairedDevice.isEmpty, !pairedPassword.isEmpty else {
            append("⚠️ Előbb párosíts (nincs tárolt device/password)")
            return
        }
        busy = true
        statusLine = "Futási mód → RUN…"
        append("=== FUTÁSI MÓD → RUN (CmdModelSet mode=1) ===")
        let cmd = CmdModelSet(mode: 1,
                              createTime: Int64(Date().timeIntervalSince1970 * 1000),
                              equilDevice: pairedDevice, equilPassword: pairedPassword)
        runCommandPerConnection(cmd, kind: "Futási mód RUN")
    }

    /// Lekérdezi a pumpa aktuális futási módját (diagnózis).
    func queryRunningMode() {
        guard !busy else { return }
        guard !pairedDevice.isEmpty, !pairedPassword.isEmpty else {
            append("⚠️ Előbb párosíts (nincs tárolt device/password)")
            return
        }
        busy = true
        statusLine = "Futási mód lekérdezése…"
        append("=== FUTÁSI MÓD LEKÉRDEZÉS ===")
        let cmd = CmdRunningModeGet(createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                    equilDevice: pairedDevice, equilPassword: pairedPassword)
        runCommandPerConnection(cmd, kind: "Futási mód lekérdezés")
    }

    // MARK: - SUSPEND / STOP (CmdModelSet mode=0 / mode=2)

    /// Felfüggeszti a pumpát (CmdModelSet mode=0 = SUSPEND).
    func suspendPump() {
        runModelSet(mode: 0, label: "SUSPEND (felfüggesztés)")
    }

    /// Leállítja a pumpát (CmdModelSet mode=2 = STOP).
    func stopPump() {
        runModelSet(mode: 2, label: "STOP (leállítás)")
    }

    private func runModelSet(mode: Int, label: String) {
        guard !busy else { return }
        guard !pairedDevice.isEmpty, !pairedPassword.isEmpty else {
            append("⚠️ Előbb párosíts (nincs tárolt device/password)")
            return
        }
        busy = true
        statusLine = "Futási mód → \(label)…"
        append("=== FUTÁSI MÓD → \(label) (CmdModelSet mode=\(mode)) ===")
        let cmd = CmdModelSet(mode: mode,
                              createTime: Int64(Date().timeIntervalSince1970 * 1000),
                              equilDevice: pairedDevice, equilPassword: pairedPassword)
        runCommandPerConnection(cmd, kind: label)
    }

    // MARK: - TARTÁLY-ÁLLAPOT (CmdInsulinGet)

    /// Lekérdezi a tartályban maradt inzulint (E).
    func queryInsulin() {
        guard !busy else { return }
        guard !pairedDevice.isEmpty, !pairedPassword.isEmpty else {
            append("⚠️ Előbb párosíts (nincs tárolt device/password)")
            return
        }
        busy = true
        statusLine = "Tartály-állapot lekérdezése…"
        append("=== TARTÁLY-ÁLLAPOT LEKÉRDEZÉS (CmdInsulinGet) ===")
        let cmd = CmdInsulinGet(createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                equilDevice: pairedDevice, equilPassword: pairedPassword)
        runCommandPerConnection(cmd, kind: "Tartály-állapot") { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success:
                self.append("💧 Maradék inzulin a tartályban: \(cmd.insulin) E")
                self.statusLine = "Tartály: \(cmd.insulin) E"
            case .failure(let msg):
                self.append("❌ Tartály-állapot HIBA: \(msg)")
                self.statusLine = "Tartály: HIBA — \(msg)"
            }
            self.busy = false
            self.ble.onReady = nil; self.ble.onConnected = nil
        }
    }

    // MARK: - ELŐZMÉNYEK / ÁLLAPOT (CmdHistoryGet)

    /// Lekérdezi a pumpa aktuális állapotát (akku, tartály, idő, utolsó dózis).
    func queryHistory() {
        guard !busy else { return }
        guard !pairedDevice.isEmpty, !pairedPassword.isEmpty else {
            append("⚠️ Előbb párosíts (nincs tárolt device/password)")
            return
        }
        busy = true
        statusLine = "Állapot/előzmény lekérdezése…"
        append("=== ELŐZMÉNYEK/ÁLLAPOT LEKÉRDEZÉS (CmdHistoryGet) ===")
        let cmd = CmdHistoryGet(currentIndex: 0,
                                createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                equilDevice: pairedDevice, equilPassword: pairedPassword)
        runCommandPerConnection(cmd, kind: "Állapot") { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success:
                self.append("🔋 Akku=\(cmd.battery)%  💧tartály=\(cmd.medicine)  ráta=\(cmd.rate)  idő=\(cmd.ts)  idx=\(cmd.recordIndex)")
                self.statusLine = "Akku \(cmd.battery)% · tartály \(cmd.medicine)"
            case .failure(let msg):
                self.append("❌ Állapot HIBA: \(msg)")
                self.statusLine = "Állapot: HIBA — \(msg)"
            }
            self.busy = false
            self.ble.onReady = nil; self.ble.onConnected = nil
        }
    }

    // MARK: - IDEIGLENES BAZÁL (CmdTempBasalSet / CmdTempBasalGet)

    /// Beállít egy ideiglenes bazált (ráta E/h + időtartam perc).
    func setTempBasal() {
        guard !busy else { return }
        guard !pairedDevice.isEmpty, !pairedPassword.isEmpty else {
            append("⚠️ Előbb párosíts (nincs tárolt device/password)")
            return
        }
        guard let rate = Double(tempRate), rate >= 0,
              let dur = Int(tempDuration), dur > 0 else {
            append("⚠️ Érvénytelen temp basal (ráta E/h vagy időtartam perc)")
            return
        }
        busy = true
        statusLine = "Temp basal \(rate) E/h \(dur) perc…"
        append("=== TEMP BASAL START: \(rate) E/h, \(dur) perc ===")
        let cmd = CmdTempBasalSet(insulin: rate, duration: dur,
                                  createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                  equilDevice: pairedDevice, equilPassword: pairedPassword)
        runCommandPerConnection(cmd, kind: "Temp basal")
    }

    /// Törli az aktuális ideiglenes bazált (insulin=0 → cancel).
    func cancelTempBasal() {
        guard !busy else { return }
        guard !pairedDevice.isEmpty, !pairedPassword.isEmpty else {
            append("⚠️ Előbb párosíts (nincs tárolt device/password)")
            return
        }
        busy = true
        statusLine = "Temp basal törlése…"
        append("=== TEMP BASAL TÖRLÉS (cancel) ===")
        let cmd = CmdTempBasalSet(insulin: 0, duration: 0,
                                  createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                  equilDevice: pairedDevice, equilPassword: pairedPassword)
        runCommandPerConnection(cmd, kind: "Temp basal törlés")
    }

    /// Lekérdezi az aktuális ideiglenes bazált.
    func queryTempBasal() {
        guard !busy else { return }
        guard !pairedDevice.isEmpty, !pairedPassword.isEmpty else {
            append("⚠️ Előbb párosíts (nincs tárolt device/password)")
            return
        }
        busy = true
        statusLine = "Temp basal lekérdezése…"
        append("=== TEMP BASAL LEKÉRDEZÉS (CmdTempBasalGet) ===")
        let cmd = CmdTempBasalGet(createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                  equilDevice: pairedDevice, equilPassword: pairedPassword)
        runCommandPerConnection(cmd, kind: "Temp basal lekérdezés") { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success:
                if cmd.step == 0 {
                    self.append("⏱️ Nincs aktív temp basal (step=0)")
                    self.statusLine = "Temp basal: nincs aktív"
                } else {
                    self.append("⏱️ Aktív temp basal: ≈\(String(format: "%.2f", cmd.rate)) E/h, hátralévő \(cmd.durationMinutes) perc")
                    self.statusLine = "Temp: \(String(format: "%.2f", cmd.rate)) E/h · \(cmd.durationMinutes)p"
                }
            case .failure(let msg):
                self.append("❌ Temp basal lekérdezés HIBA: \(msg)")
                self.statusLine = "Temp basal: HIBA — \(msg)"
            }
            self.busy = false
            self.ble.onReady = nil; self.ble.onConnected = nil
        }
    }

    /// Connect-per-command futtató: pause watchdog → friss connect → onReady-re run() → resume.
    /// Ez szünteti meg a bólusz időtúllépést (scan/watchdog verseny + fél-állapotú kapcsolat).
    private func runCommandPerConnection(_ cmd: EquilCommandDriving, kind: String,
                                         completion: ((EquilCommandRunner.Outcome) -> Void)? = nil) {
        ble.pauseWatchdog()
        var connArmed = true
        // Kapcsolatépítési időtúllépés-védő: ha a friss connect 15s alatt nem épül fel,
        // ne lógjon örökké a bólusz (AAPS connectTimeOut=15000).
        let connTimeout = DispatchWorkItem { [weak self] in
            guard let self, connArmed else { return }
            connArmed = false
            Task { @MainActor in
                self.ble.onReady = nil
                self.ble.onConnected = nil
                self.append("❌ \(kind) HIBA: kapcsolat-időtúllépés (15s) — pumpa nem elérhető")
                self.statusLine = "\(kind): HIBA — kapcsolat-időtúllépés"
                self.busy = false
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: connTimeout)
        // Egyszeri onReady: a parancsot CSAK akkor indítjuk, amikor a CCCD-notify ENGEDÉLYEZVE
        // van (= a karakterisztika kész az írásra). KORÁBBAN onConnected-re futott, ami túl
        // korai: a didConnect után a service/characteristic discovery még NEM fejeződött be,
        // így a uartChar==nil → writeNext "no peripheral/char" → disconnect → a parancs
        // sosem indult el rendesen. Az AAPS is onReady-ekvivalens ponton ír (notify enabled).
        ble.onReady = { [weak self] in
            guard let self else { return }
            self.ble.onReady = nil       // egyszeri
            Task { @MainActor in
                guard connArmed else { return }   // a conn-timeout már lefutott
                connArmed = false
                connTimeout.cancel()
                self.append("🔗 Pumpa kész (notify enabled) — parancs indul (\(kind))")
                self.runner.run(command: cmd, timeout: 30) { [weak self] outcome in
                    guard let self else { return }
                    if let completion {
                        Task { @MainActor in completion(outcome) }
                    } else {
                        self.handle(outcome, kind: kind)
                    }
                }
            }
        }
        if ble.isConnected {
            // Már él egy kapcsolat (watchdog tartotta): connectForCommand bontja és frissen
            // újraépíti, hogy a pumpa tiszta GATT-ot kapjon. onConnected ekkor is tüzel.
            append("🔄 Meglévő kapcsolat frissítése a parancshoz…")
            ble.connectForCommand()
        } else {
            append("🔌 Kapcsolatépítés a megtartott pumpához (scan nélkül)…")
            ble.connectForCommand()
        }
    }

    /// Diagnosztikai scan: MINDEN közeli BLE-eszközt listáz (nincs Equil-prefix
    /// és nincs SN-szűrő). Megmutatja a pumpa pontos hirdetett nevét + jelerősségét,
    /// és jelzi, hogy a beírt SN substring-ként megtalálható-e a névben.
    func startScan() {
        guard !busy else { return }
        discovered.removeAll()
        scanning = true
        statusLine = "Scan: közeli eszközök…"
        append("=== SCAN START (szűrő nélkül, minden eszköz) ===")
        let sn = serialNumber.lowercased()
        ble.nameFilterPrefix = nil      // diagnosztikai scanhez NINCS Equil-prefix
        ble.nameFilterContains = nil    // és NINCS SN-szűrő — mindent mutatunk
        ble.onDiscover = { [weak self] peripheral, name in
            Task { @MainActor in
                guard let self else { return }
                let id = peripheral.identifier.uuidString
                let match = !sn.isEmpty && name.lowercased().contains(sn)
                if self.discovered.contains(where: { $0.id == id }) {
                    // már láttuk — nem duplikáljuk
                } else {
                    self.discovered.append(DiscoveredDevice(id: id, name: name, rssi: 0, matchesSerial: match))
                    let mark = match ? "  ◀ EGYEZIK az SN-nel (\(self.serialNumber))" : ""
                    self.append("📡 \(name)\(mark)")
                }
            }
        }
        ble.startScan()
    }

    func stopScan() {
        ble.stopScan()
        scanning = false
        statusLine = "Scan leállítva (\(discovered.count) eszköz)"
        append("=== SCAN STOP (\(discovered.count) eszköz) ===")
        let hit = discovered.contains { $0.matchesSerial }
        append(hit ? "✅ Van az SN-re (\(serialNumber)) illeszkedő eszköz."
                   : "⚠️ NINCS olyan eszköz, ami az SN-t (\(serialNumber)) tartalmazná a nevében.")
    }

    func clearLog() { logLines.removeAll() }

    // MARK: BT Watchdog vezérlés
    @Published var watchdogOn: Bool = false

    /// Sikeres párosítás után: CSAK megtartjuk a peripheral-t (ID + referencia), hogy a
    /// következő parancs scan NÉLKÜL tudjon csatlakozni (connectForCommand). NINCS watchdog,
    /// NINCS állandó kapcsolat — az AAPS connect-per-command modellt követjük: a pumpa ~11s
    /// inaktivitás után magától bont, és minden parancs frissen csatlakozik.
    func activateWatchdogAfterPairing() {
        guard let p = ble.currentPeripheral else {
            append("⚠️ nincs aktuális peripheral a párosítás után — kihagyva")
            return
        }
        ble.holdPeripheral(p)   // csak eltárol (watchdogEnabled marad, de NINCS auto-reconnect/timer)
        watchdogOn = false
        append("✅ Pumpa megtartva (scan nélküli újracsatlakozáshoz). Connect-per-command mód — nincs watchdog.")
    }

    /// Kézi watchdog kapcsoló (UI).
    func toggleWatchdog() {
        if watchdogOn {
            ble.stopWatchdog()
            watchdogOn = false
            append("🐕 Watchdog KIKAPCSOLVA.")
        } else if let p = ble.currentPeripheral {
            ble.holdPeripheral(p)
            ble.startWatchdog(intervalSeconds: 3)
            watchdogOn = true
            append("🐕 Watchdog BEKAPCSOLVA.")
        } else {
            append("⚠️ Watchdog: előbb párosíts (nincs peripheral).")
        }
    }

    // MARK: Helpers
    private func handle(_ outcome: EquilCommandRunner.Outcome, kind: String) {
        busy = false
        switch outcome {
        case .success(let enacted):
            statusLine = "\(kind): SIKER (enacted=\(enacted))"
            append("✅ \(kind) SIKER (enacted=\(enacted))")
        case .failure(let msg):
            statusLine = "\(kind): HIBA — \(msg)"
            append("❌ \(kind) HIBA: \(msg)")
        }
        // CONNECT-PER-COMMAND lezárás: a parancs kész (siker/hiba). NINCS watchdog/reconnect:
        // hagyjuk, hogy a pumpa magától bontson (~11s), a következő parancs frissen csatlakozik.
        // Egyszeri onReady/onConnected handlerek eltakarítása, hogy ne tüzeljenek véletlen.
        ble.onReady = nil
        ble.onConnected = nil
    }

    private func append(_ line: String) {
        let ts = Self.tsFormatter.string(from: Date())
        let entry = "\(ts)  \(line)"
        logLines.append(entry)
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
        oslog.log("\(line, privacy: .public)")
        logServer.append(line)   // tükrözzük a HTTP log-szerverre is (curl-lel olvasható)
    }

    private static let tsFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    private static func describe(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: return "bekapcsolva"
        case .poweredOff: return "kikapcsolva"
        case .unauthorized: return "nincs engedély"
        case .unsupported: return "nem támogatott"
        case .resetting: return "újraindul"
        default: return "ismeretlen"
        }
    }
}
