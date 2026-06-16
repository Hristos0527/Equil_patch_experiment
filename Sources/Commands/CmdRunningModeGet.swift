//
//  CmdRunningModeGet.swift
//  EquilKit
//
//  Byte-azonos port: AndroidAPS pump/equil manager/command/CmdRunningModeGet.kt
//  Mérvadó forrás: nightscout/AndroidAPS (AGPL-3.0)
//
//  FUTÁSI MÓD LEKÉRDEZÉSE. port = 0404 (default).
//    getFirstData: index(4LE) ++ [0x02,0x00]
//    getNextData : index(4LE) ++ [0x00,0x02,0x01]
//    decodeConfirmData: mode = data[6] & 0xff   (0=SUSPEND,1=RUN,2=STOP)
//    decodeConfirm() → nincs 3. üzenet (csak status olvasás).
//

import Foundation

final class CmdRunningModeGet: EquilBaseSetting {

    var mode: Int = -1

    override var commandLabel: String { "Futási mód lekérdezés (CmdRunningModeGet)" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x02, 0x00]
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
        EquilBaseCmd.dlog("🔬 CmdRunningModeGet confirm content=\(EquilUtils.bytesToHex(data)) (\(data.count)B)")
        guard data.count >= 7 else {
            EquilBaseCmd.dlog("🔬 CmdRunningModeGet: content túl rövid (\(data.count)B)")
            cmdSuccess = true
            return
        }
        mode = Int(data[6]) & 0xff
        let name = mode == 0 ? "SUSPEND" : (mode == 1 ? "RUN" : (mode == 2 ? "STOP" : "ismeretlen"))
        EquilBaseCmd.dlog("🔬 CmdRunningModeGet: mode=\(mode) (\(name))")
        cmdSuccess = true
    }
}
