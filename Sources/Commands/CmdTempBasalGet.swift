//
//  CmdTempBasalGet.swift
//  EquilKit
//
//  Byte-azonos port: AndroidAPS pump/equil manager/command/CmdTempBasalGet.kt
//  Mérvadó forrás: nightscout/AndroidAPS (AGPL-3.0)
//
//  AKTUÁLIS IDEIGLENES BAZÁL lekérdezése. port = 0404 (default).
//    getFirstData: index(4LE) ++ [0x02,0x04]
//    getNextData : index(4LE) ++ [0x00,0x04,0x02] ++ 0(4LE)
//    decodeConfirmData:
//      step = bytes2Int(data[6..9])   (4-byte LE)
//      time = bytes2Int(data[10..13]) (4-byte LE, másodperc)
//    decodeConfirm() → status olvasás, NINCS 3. üzenet.
//

import Foundation

final class CmdTempBasalGet: EquilBaseSetting {

    var step: Int = 0
    var time: Int = 0   // másodperc

    /// step → E/h ráta visszaszámolása (set: step = insulin/0.05*8/2 → insulin = step*2*0.05/8)
    var rate: Double { Double(step) * 2.0 * 0.05 / 8.0 }
    var durationMinutes: Int { time / 60 }

    override var commandLabel: String { "Temp basal lekérdezés (CmdTempBasalGet)" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x02, 0x04]
        let data = EquilUtils.concat(indexByte, data2)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func getNextData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x00, 0x04, 0x02]
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
        EquilBaseCmd.dlog("🔬 CmdTempBasalGet confirm content=\(EquilUtils.bytesToHex(data)) (\(data.count)B)")
        guard data.count >= 14 else {
            EquilBaseCmd.dlog("🔬 CmdTempBasalGet: content túl rövid (\(data.count)B)")
            cmdSuccess = true
            return
        }
        step = EquilUtils.bytes2Int([data[6], data[7], data[8], data[9]])
        time = EquilUtils.bytes2Int([data[10], data[11], data[12], data[13]])
        EquilBaseCmd.dlog("🔬 CmdTempBasalGet: step=\(step) (≈\(rate) E/h) time=\(time)s (\(durationMinutes)p)")
        cmdSuccess = true
    }
}
