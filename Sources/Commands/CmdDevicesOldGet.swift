//
//  CmdDevicesOldGet.swift
//  EquilKit
//
//  Byte-azonos port: AndroidAPS pump/equil manager/command/CmdDevicesOldGet.kt
//  Mérvadó forrás: nightscout/AndroidAPS (AGPL-3.0)
//
//  PÁROSÍTÁS 1. LÉPÉSE (pre-pair firmware lekérdezés). port = 0E0E.
//
//  ELTÉRÉSEK a normál BaseSetting kézfogástól (FONTOS — itt szokott elromlani):
//   - getEquilResponse:  NEM titkosított. Fix 14-byte nyitóüzenet:
//       00 00 0E 00 80 78 00 00 00 00 01 7B 02 00
//     (ezt egyetlen EquilResponse-csomagként küldi).
//   - getFirstData:  index(4LE) ++ [02,00]            (pumpReqIndex++)
//   - getNextData:   index(4LE) ++ [00,00,01]         (pumpReqIndex++)
//   - decode:  saját decodeModel() → ciphertext nyers byte-ok (NINCS tag/iv,
//       AES NÉLKÜL). firmwareVersion = data[12].data[13]. A válasz egy
//       responseCmd(reqModel, "0000"+code), ahol reqModel.ciphertext =
//       getNextData() nyers byte-jai. cmdSuccess = true.
//   - decodeModel:  SAJÁT — a 0. csomagból a code = [10,11], és a payloadhoz
//       csak a csomag UTOLSÓ 2 byte-ja (size-2, size-1); a többi csomagból a
//       6. byte-tól a végéig. tag="" iv="".
//   - decodeConfirmData:  firmwareVersion = data[18].data[19]. cmdSuccess=true.
//   - isSupport(SN):  ha SN első karaktere {0,1,3,A,D} egyikében → fw >= 5.3
//       szükséges; különben mindig támogatott.
//

import Foundation

final class CmdDevicesOldGet: EquilBaseSetting {

    let address: String
    private(set) var firmwareVersion: Float = 0

    init(address: String, createTime: Int64) {
        self.address = address
        super.init(createTime: createTime, equilDevice: "", equilPassword: "")
        self.port = "0E0E"
    }

    // MARK: - 1. üzenet: fix 14-byte, TITKOSÍTÁS NÉLKÜL
    override func getEquilResponse() throws -> EquilResponse {
        config = false
        isEnd = false
        response = EquilResponse(createTime: createTime)
        var temp = EquilResponse(createTime: createTime)
        let opener: [UInt8] = [
            0x00, 0x00, 0x0E, 0x00, 0x80, 0x78,
            0x00, 0x00, 0x00, 0x00, 0x01, 0x7B, 0x02, 0x00
        ]
        temp.add(opener)
        return temp
    }

    override var commandLabel: String { "Eszköz lekérdezés (CmdDevicesOldGet)" }
    override func makeFirstResponse() throws -> EquilResponse { try getEquilResponse() }

    // MARK: - getFirstData / getNextData (nyers byte-ok)
    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x02, 0x00]
        let data = EquilUtils.concat(indexByte, data2)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func getNextData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x00, 0x00, 0x01]
        let data = EquilUtils.concat(indexByte, data2)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    // MARK: - SAJÁT decodeModel (NINCS tag/iv; ciphertext = nyers byte-ok)
    override func decodeModel() -> EquilCmdModel {
        var model = EquilCmdModel()
        var list: [UInt8] = []
        var index = 0
        guard let response = response else { return model }
        for bs in response.send {
            if index == 0 {
                let codeByte = [bs[10], bs[11]]
                list.append(bs[bs.count - 2])
                list.append(bs[bs.count - 1])
                model.code = EquilUtils.bytesToHex(codeByte).lowercased()
            } else {
                for i in 6..<bs.count { list.append(bs[i]) }
            }
            index += 1
        }
        model.ciphertext = EquilUtils.bytesToHex(list).lowercased()
        model.tag = ""
        model.iv = ""
        return model
    }

    // MARK: - 1. fázis lezárása: firmware-verzió + következő üzenet
    func decode() throws -> EquilResponse? {
        var reqModel = decodeModel()
        let data = EquilUtils.hexStringToBytes(reqModel.ciphertext ?? "")
        // fv = data[12] + "." + data[13]  (mindkettő decimális Int)
        let fv = "\(Int(data[12])).\(Int(data[13]))"
        firmwareVersion = Float(fv) ?? 0
        reqModel.ciphertext = EquilUtils.bytesToHex(getNextData() ?? [])
        cmdSuccess = true
        return responseCmd(reqModel, port: "0000" + (reqModel.code ?? ""))
    }

    // MARK: - 2. fázis lezárása: megerősítés
    override func decodeConfirmData(_ data: [UInt8]) {
        // fv = data[18] + "." + data[19]
        let fv = "\(Int(data[18])).\(Int(data[19]))"
        firmwareVersion = Float(fv) ?? 0
        cmdSuccess = true
    }

    // MARK: - Beérkező állapotgép (BaseSetting-azonos, de saját decode())
    override func decodeStep() -> EquilResponse? {
        do { return try decode() }
        catch { response = EquilResponse(createTime: createTime); return nil }
    }

    override func decodeConfirmStep() -> EquilResponse? {
        // CmdDevicesOldGet: a 2. fázis csak megerősítés (decodeConfirmData),
        // nincs további kimenő üzenet — a BaseSetting decodeConfirm() a
        // decodeConfirmData()-t hívja, majd getNextData()-t küldene; itt a
        // megerősítés a folyamat vége (cmdSuccess már true).
        let model = decodeModel()
        let data = EquilUtils.hexStringToBytes(model.ciphertext ?? "")
        if data.count >= 20 { decodeConfirmData(data) } else { cmdSuccess = true }
        return nil
    }

    // MARK: - Támogatottság-ellenőrzés (firmware 5.3 küszöb)
    func isSupport(serialNumber: String) -> Bool {
        guard let firstChar = serialNumber.uppercased().first else { return true }
        let needsVersionCheck: Set<Character> = ["0", "1", "3", "A", "D"]
        if needsVersionCheck.contains(firstChar) {
            return firmwareVersion >= EquilConst.EQUIL_SUPPORT_LEVEL
        }
        return true
    }
}
