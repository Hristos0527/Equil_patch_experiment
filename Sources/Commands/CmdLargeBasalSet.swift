//
//  CmdLargeBasalSet.swift
//  EquilKit
//
//  Byte-azonos port: AndroidAPS pump/equil manager/command/CmdLargeBasalSet.kt
//  Mérvadó forrás: nightscout/AndroidAPS (AGPL-3.0)
//
//  BÓLUS parancs. port = 0404 (örökölt default, nincs felülírva).
//    step     = (insulin / 0.05 * 8).toInt()
//    stepTime = (insulin / 0.05 * 2).toInt()
//
//  getFirstData (22 byte):
//    index(4LE) ++ [0x01,0x03] ++ step(4LE) ++ stepTime(4LE) ++ 0(4LE) ++ 0(4LE)
//  getNextData (11 byte):
//    index(4LE) ++ [0x00,0x03,0x01] ++ 0(4LE)
//
//  Példa (insulin=0.05, pumpReqIndex=10):
//    0A000000 0103 08000000 02000000 00000000 00000000
//

import Foundation

final class CmdLargeBasalSet: EquilBaseSetting {

    let insulin: Double
    var step: Int = 0
    var stepTime: Int = 0

    init(insulin: Double, createTime: Int64, equilDevice: String, equilPassword: String) {
        self.insulin = insulin
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
        // port marad "0404" (BaseCmd default)
        if insulin != 0.0 {
            step = Int(insulin / 0.05 * 8)
            stepTime = Int(insulin / 0.05 * 2)
        }
    }

    override var commandLabel: String { "Bólusz (CmdLargeBasalSet)" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x01, 0x03]
        let data3 = EquilUtils.intToBytes(step)
        let data4 = EquilUtils.intToBytes(stepTime)
        let data5 = EquilUtils.intToBytes(0)
        let data = EquilUtils.concat(indexByte, data2, data3, data4, data5, data5)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func getNextData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x00, 0x03, 0x01]
        let data3 = EquilUtils.intToBytes(0)
        let data = EquilUtils.concat(indexByte, data2, data3)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func decodeConfirmData(_ data: [UInt8]) {
        cmdSuccess = true
    }
}
