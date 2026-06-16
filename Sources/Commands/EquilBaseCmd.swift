//
//  EquilBaseCmd.swift
//  EquilKit
//
//  Byte-azonos port: AndroidAPS pump/equil manager/command/BaseCmd.kt
//  Mérvadó forrás: nightscout/AndroidAPS (AGPL-3.0)
//
//  A parancs-hierarchia gyökere. Tárolja a megosztott állapotot (port, config,
//  reqIndex stb.), a bit-műveleteket, a csomag-építést (EquilFraming) és a
//  válasz-darabok összefűzését (decodeModel).
//
//  FONTOS: a Kotlin BaseCmd companion objektumban reqIndex / pumpReqIndex / rspIndex
//  STATIKUS (megosztott) változók. Itt is statikusként tartjuk a byte-parity miatt:
//  a pumpReqIndex egy párosítási/bólus szekvencián belül folyamatosan nő (10,11,...),
//  és ez beépül a payloadba. Egy szekvencia indításakor resetState()-tel állítjuk vissza.
//

import Foundation

/// EquilResponse megfelelője: a kimenő BLE csomagok listája.
struct EquilResponse {
    let createTime: Int64
    var send: [[UInt8]] = []

    init(createTime: Int64) { self.createTime = createTime }

    mutating func add(_ packet: [UInt8]) { send.append(packet) }
}

class EquilBaseCmd {

    // MARK: - Companion (statikus, megosztott) állapot — BaseCmd.companion
    static let DEFAULT_PORT = "0F0F"
    static var reqIndex: Int = 0
    static var pumpReqIndex: Int = 10
    static var rspIndex: Int = -1

    /// Diagnosztikai log-kimenet (a parancs-réteg a runner/UI logjába írhat).
    /// A modell köti be a párosítás után; ha nil, csendben elnyeli.
    static var debugLog: ((String) -> Void)?
    static func dlog(_ msg: String) { debugLog?(msg) }

    /// Egy parancs-szekvencia (pairing vagy bólus) ELŐTT hívandó.
    /// Visszaállítja a megosztott indexeket az AAPS kezdőértékeire.
    static func resetState() {
        reqIndex = 0
        pumpReqIndex = 10
        rspIndex = -1
    }

    // MARK: - Példányállapot
    let createTime: Int64
    var port: String = "0404"
    var config: Bool = false
    var isEnd: Bool = false
    var cmdSuccess: Bool = false
    var enacted: Bool = true
    var response: EquilResponse?
    var runPwd: String?
    var runCode: String?

    /// A párosító/SN/jelszó adatok injektálva (AAPS-ben Preferences-ből jön).
    var equilDevice: String          // tárolt device hex (SN-származék)
    var equilPassword: String        // tárolt 64-hex jelszó

    init(createTime: Int64, equilDevice: String, equilPassword: String) {
        self.createTime = createTime
        self.equilDevice = equilDevice
        self.equilPassword = equilPassword
    }

    func getEquilDevices() -> String { equilDevice }
    func getEquilPassWord() -> String { equilPassword }

    // MARK: - Bit-műveletek (BaseCmd)
    func toNewStart(_ number: UInt8) -> UInt8 { number & ~(1 << 7) }
    func toNewEndConf(_ number: UInt8) -> UInt8 { number | (1 << 7) }
    func isEnd(_ b: UInt8) -> Bool { getBit(b, 7) == 1 }
    func getIndex(_ b: UInt8) -> Int { Int(b) & 63 }
    func getBit(_ b: UInt8, _ i: Int) -> Int { (Int(b) >> i) & 0x1 }

    /// BaseCmd.convertString — minden karakter elé "0".
    func convertString(_ input: String) -> String {
        var sb = ""
        for ch in input { sb += "0"; sb.append(ch) }
        return sb
    }

    func up1(_ value: Double) -> Int { Int(ceil(value)) }

    // MARK: - checkData (BaseCmd.checkData)
    /// Beérkező csomag ellenőrzése: index != előző index, és crc8Maxim egyezés.
    func checkData(_ data: [UInt8]) -> Bool {
        if let response = response, !response.send.isEmpty {
            let preData = response.send[response.send.count - 1]
            let index = Int(data[3]) & 0xFF
            let preIndex = Int(preData[3]) & 0xFF
            if index == preIndex { return false }
        }
        let crc = Int(data[5]) & 0xFF
        let crc1 = Crc.crc8Maxim(Array(data[0..<5]))
        if crc != crc1 { return false }
        return true
    }

    // MARK: - responseCmd (BaseCmd.responseCmd) — a kritikus BLE framing
    /// Becsomagolja az EquilCmdModel-t (tag|iv|ciphertext) BLE csomagokba,
    /// majd reqIndex++.
    func responseCmd(_ model: EquilCmdModel, port: String) -> EquilResponse {
        let packets = EquilFraming.responseCmd(
            port: port,
            tag: model.tag ?? "",
            iv: model.iv ?? "",
            ciphertext: model.ciphertext ?? "",
            reqIndex: EquilBaseCmd.reqIndex
        )
        var resp = EquilResponse(createTime: createTime)
        resp.send = packets
        EquilBaseCmd.reqIndex += 1
        return resp
    }

    // MARK: - decodeModel (BaseCmd.decodeModel)
    /// A beérkezett csomag-darabokból visszaállítja a tag/iv/ciphertext mezőket.
    /// Csomagstruktúra: az első csomagban a payload az utolsó 4 byte + a code a [10,11],
    /// a többiben a 6. byte-tól a végéig.
    func decodeModel() -> EquilCmdModel {
        var model = EquilCmdModel()
        var list: [UInt8] = []
        var index = 0
        guard let response = response else { return model }
        for bs in response.send {
            if index == 0 {
                // utolsó 4 byte
                for i in (bs.count - 4)..<bs.count { list.append(bs[i]) }
                let codeByte = [bs[10], bs[11]]
                model.code = EquilUtils.bytesToHex(codeByte).lowercased()
            } else {
                for i in 6..<bs.count { list.append(bs[i]) }
            }
            index += 1
        }
        // list felosztás: tag(0..16), iv(16..28), ciphertext(28..)
        let list1 = Array(list[0..<16])
        let list2 = Array(list[16..<(12 + 16)])
        let list3 = Array(list[(12 + 16)..<list.count])
        model.iv = EquilUtils.bytesToHex(list2).lowercased()
        model.tag = EquilUtils.bytesToHex(list1).lowercased()
        model.ciphertext = EquilUtils.bytesToHex(list3).lowercased()
        return model
    }

    // MARK: - decodeEquilPacket (BaseSetting/CmdPair állapotgép)
    //
    //  A BLE notify-ból érkező egyes csomagokat gyűjti, és ha a csomag isEnd
    //  bitje (bit7) be van állítva, lefuttatja a fázishoz tartozó decode lépést.
    //  Két fázis a `config` flag szerint:
    //    - config == false → 1. fázis: gyűjt, majd decode() → 2. üzenet payloadja,
    //                        config = true.
    //    - config == true  → 2. fázis: gyűjt, majd decodeConfirm() → 3. üzenet /
    //                        siker (isEnd = true).
    //
    //  A decode()/decodeConfirm() lépéseket az alosztály adja (BaseSetting/CmdPair).
    //  Visszatérési érték: a következő kimenő EquilResponse, vagy nil ha még nincs
    //  teljes üzenet (vagy a folyamat lezárult).
    func decodeEquilPacket(_ data: [UInt8]) -> EquilResponse? {
        guard checkData(data) else { return nil }
        let code = data[4]
        let intValue = getIndex(code)

        if config {
            if EquilBaseCmd.rspIndex == intValue { return nil }   // duplikált csomag
            let flag = isEnd(code)
            response?.add(data)
            if !flag { return nil }
            let next = decodeConfirmStep()
            isEnd = true
            response = EquilResponse(createTime: createTime)
            EquilBaseCmd.rspIndex = intValue
            return next
        }

        let flag = isEnd(code)
        response?.add(data)
        if !flag { return nil }
        let next = decodeStep()
        response = EquilResponse(createTime: createTime)
        config = true
        EquilBaseCmd.rspIndex = intValue
        return next
    }

    /// Az 1. fázis lezárása (BaseSetting/CmdPair `decode()`). Alosztály felülírja.
    func decodeStep() -> EquilResponse? { nil }
    /// A 2. fázis lezárása (BaseSetting/CmdPair `decodeConfirm()`). Alosztály felülírja.
    func decodeConfirmStep() -> EquilResponse? { nil }

    // MARK: - EquilCommandDriving alapok (a runner ezeket hívja)
    //
    //  A `decodeEquilPacket`, `cmdSuccess`, `enacted` itt, az ősön él — közös minden
    //  parancsra. A `label` és `firstResponse()` parancsfüggő: az ős ad egy alapértelmezést
    //  (a leszármazott felülírja). Így az `EquilBaseCmd: EquilCommandDriving` konformancia
    //  egy helyen, az ősön teljesül; a CmdPair/CmdLargeBasalSet csak felülír.
    var commandLabel: String { "Equil parancs" }
    func makeFirstResponse() throws -> EquilResponse {
        throw EquilError.invalidState("firstResponse nincs implementálva (\(type(of: self)))")
    }
}

// Az ősosztály teljesíti az EquilCommandDriving követelményeit. A leszármazottak
// (CmdPair, CmdLargeBasalSet) csak a `commandLabel`-t és a `makeFirstResponse()`-t
// írják felül — a decode-állapotgép és a siker-jelzők közösek.
extension EquilBaseCmd: EquilCommandDriving {
    var label: String { commandLabel }
    func firstResponse() throws -> EquilResponse { try makeFirstResponse() }
}
