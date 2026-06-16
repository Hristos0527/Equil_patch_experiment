//
//  CmdResistanceGet.swift
//  EquilKit
//
//  Byte-azonos port: AndroidAPS pump/equil manager/command/CmdResistanceGet.kt
//  Mérvadó forrás: nightscout/AndroidAPS (AGPL-3.0)
//
//  ELLENÁLLÁS-LEKÉRDEZÉS (a dugattyú elérte-e a pisztont). port = 1515.
//    getFirstData: index(4LE) ++ [0x02,0x02]
//    getNextData : index(4LE) ++ [0x00,0x02,0x01]
//    decodeConfirmData: value = bytesToInt(data[7],data[6])
//                       enacted = value >= threshold  (A09F2A → 'A' → régi → 500)
//    decodeConfirm() → nincs 3. üzenet (csak status olvasás).
//
//  threshold: SN első karaktere ∈ {0,1,3,A,D} → 500 (régi), különben 220.
//

import Foundation

final class CmdResistanceGet: EquilBaseSetting {

    let threshold: Int

    init(threshold: Int, createTime: Int64, equilDevice: String, equilPassword: String) {
        self.threshold = threshold
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
        port = "1515"
    }

    override var commandLabel: String { "Ellenállás-lekérdezés (CmdResistanceGet)" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x02, 0x02]
        let data = EquilUtils.concat(indexByte, data2)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func getNextData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x00, 0x02, 0x01]
        let data = EquilUtils.concat(indexByte, data2)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    // AAPS CmdResistanceGet.decodeConfirm() FELÜLÍRJA: a Msg2 válaszából dekódol,
    // és NEM küld 3. üzenetet (csak status olvasás). A runner a cmdSuccess-re befejez.
    override func decodeConfirm() throws -> EquilResponse {
        let model = decodeModel()
        runCode = model.code
        guard let runPwd = runPwd else { throw EquilError.invalidState("runPwd nil") }
        let content = try AESUtil.decrypt(model, key: EquilUtils.hexStringToBytes(runPwd))
        decodeConfirmData(EquilUtils.hexStringToBytes(content))
        // NINCS getNextData / Msg3 — üres válasz (a runner cmdSuccess-re zár).
        return EquilResponse(createTime: createTime)
    }

    override func decodeConfirmData(_ data: [UInt8]) {
        EquilBaseCmd.dlog("🔬 CmdResistanceGet confirm content=\(EquilUtils.bytesToHex(data)) (\(data.count)B)")
        guard data.count >= 8 else {
            EquilBaseCmd.dlog("🔬 CmdResistanceGet: content túl rövid (\(data.count)B) — nem értelmezhető")
            cmdSuccess = true
            enacted = false
            return
        }
        let value = EquilUtils.bytesToInt(data[7], data[6])
        cmdSuccess = true
        enacted = value >= threshold
        EquilBaseCmd.dlog("🔬 CmdResistanceGet: resistance=\(value), threshold=\(threshold), enacted=\(enacted) (pin \(enacted ? "REACHED" : "NOT reached") piston)")
    }
}
