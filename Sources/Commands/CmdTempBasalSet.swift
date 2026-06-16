//
//  CmdTempBasalSet.swift
//  EquilKit
//
//  Byte-azonos port: AndroidAPS pump/equil manager/command/CmdTempBasalSet.kt
//  Mérvadó forrás: nightscout/AndroidAPS (AGPL-3.0)
//
//  IDEIGLENES BAZÁL (temp basal) beállítása / törlése. port = 0404 (default).
//    step     = (insulin / 0.05 * 8).toInt() / 2     (insulin = E/h ráta)
//    pumpTime = duration * 60                          (perc → másodperc)
//    insulin == 0 → step = 0 → temp basal TÖRLÉS (cancel)
//
//  getFirstData: index(4LE) ++ [0x01,0x04] ++ step(4LE) ++ pumpTime(4LE)
//  getNextData : index(4LE) ++ [0x00,0x04,0x01] ++ 0(4LE)
//  decodeConfirmData → cmdSuccess = true
//

import Foundation

final class CmdTempBasalSet: EquilBaseSetting {

    let insulin: Double   // E/h ráta
    let duration: Int     // perc
    var step: Int = 0
    var pumpTime: Int = 0
    var cancel: Bool { insulin == 0.0 }

    init(insulin: Double, duration: Int, createTime: Int64, equilDevice: String, equilPassword: String) {
        self.insulin = insulin
        self.duration = duration
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
        // port marad "0404" (BaseCmd default)
        if insulin != 0.0 {
            step = Int(insulin / 0.05 * 8) / 2
        } else {
            step = 0
        }
        pumpTime = duration * 60
    }

    override var commandLabel: String {
        cancel ? "Temp basal TÖRLÉS (CmdTempBasalSet)" : "Temp basal (CmdTempBasalSet \(insulin)E/h \(duration)p)"
    }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x01, 0x04]
        let data3 = EquilUtils.intToBytes(step)
        let data4 = EquilUtils.intToBytes(pumpTime)
        let data = EquilUtils.concat(indexByte, data2, data3, data4)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func getNextData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x00, 0x04, 0x01]
        let data3 = EquilUtils.intToBytes(0)
        let data = EquilUtils.concat(indexByte, data2, data3)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func decodeConfirmData(_ data: [UInt8]) {
        EquilBaseCmd.dlog("🔬 CmdTempBasalSet: step=\(step) pumpTime=\(pumpTime) cancel=\(cancel)")
        cmdSuccess = true
    }
}
