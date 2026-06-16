//
//  CmdInsulinGet.swift
//  EquilKit
//
//  Byte-azonos port: AndroidAPS pump/equil manager/command/CmdInsulinGet.kt
//  Mérvadó forrás: nightscout/AndroidAPS (AGPL-3.0)
//
//  TARTÁLY / MARADÉK INZULIN lekérdezése. port = 0505.
//    getFirstData: index(4LE) ++ [0x02,0x07]
//    getNextData : index(4LE) ++ [0x00,0x07,0x01] ++ 0(4LE)
//    decodeConfirmData: insulin = data[6] & 0xff  (maradék egységek)
//    decodeConfirm() → status olvasás, NINCS 3. üzenet.
//

import Foundation

final class CmdInsulinGet: EquilBaseSetting {

    var insulin: Int = -1

    override init(createTime: Int64, equilDevice: String, equilPassword: String) {
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
        port = "0505"
    }

    override var commandLabel: String { "Tartály-állapot (CmdInsulinGet)" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x02, 0x07]
        let data = EquilUtils.concat(indexByte, data2)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func getNextData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x00, 0x07, 0x01]
        let data3 = EquilUtils.intToBytes(0)
        let data = EquilUtils.concat(indexByte, data2, data3)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    // AAPS: a Msg2 válaszából dekódol, NEM küld 3. üzenetet.
    override func decodeConfirm() throws -> EquilResponse {
        let model = decodeModel()
        runCode = model.code
        guard let runPwd = runPwd else { throw EquilError.invalidState("runPwd nil") }
        let content = try AESUtil.decrypt(model, key: EquilUtils.hexStringToBytes(runPwd))
        decodeConfirmData(EquilUtils.hexStringToBytes(content))
        return EquilResponse(createTime: createTime)
    }

    override func decodeConfirmData(_ data: [UInt8]) {
        EquilBaseCmd.dlog("🔬 CmdInsulinGet confirm content=\(EquilUtils.bytesToHex(data)) (\(data.count)B)")
        guard data.count >= 7 else {
            EquilBaseCmd.dlog("🔬 CmdInsulinGet: content túl rövid (\(data.count)B)")
            cmdSuccess = true
            return
        }
        insulin = Int(data[6]) & 0xff
        EquilBaseCmd.dlog("🔬 CmdInsulinGet: maradék inzulin = \(insulin) E")
        cmdSuccess = true
    }
}
