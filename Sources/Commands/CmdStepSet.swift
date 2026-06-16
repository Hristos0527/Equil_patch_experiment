//
//  CmdStepSet.swift
//  EquilKit
//
//  Byte-azonos port: AndroidAPS pump/equil manager/command/CmdStepSet.kt
//  Mérvadó forrás: nightscout/AndroidAPS (AGPL-3.0)
//
//  DUGATTYÚ-MOZGATÁS (prime/feltöltés/légtelenítés). port = 0404 (default).
//    getFirstData: index(4LE) ++ [0x01,0x07] ++ step(4LE)
//    getNextData : index(4LE) ++ [0x00,0x07,0x01] ++ 0(4LE)
//    decodeConfirmData → cmdSuccess = true
//    sendConfig=false → decodeConfirm() NEM küld 3. üzenetet.
//
//  EquilConst: EQUIL_STEP_FILL=160, EQUIL_STEP_AIR=120, EQUIL_STEP_MAX=32000.
//

import Foundation

final class CmdStepSet: EquilBaseSetting {

    let sendConfig: Bool
    let step: Int

    init(sendConfig: Bool, step: Int, createTime: Int64, equilDevice: String, equilPassword: String) {
        self.sendConfig = sendConfig
        self.step = step
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
        // port marad "0404" (BaseCmd default)
    }

    override var commandLabel: String { "Dugattyú-mozgatás (CmdStepSet step=\(step))" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x01, 0x07]
        let data3 = EquilUtils.intToBytes(step)
        let data = EquilUtils.concat(indexByte, data2, data3)
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

    override func decodeConfirmData(_ data: [UInt8]) {
        EquilBaseCmd.dlog("🔬 CmdStepSet: pin movement OK, step=\(step)")
        cmdSuccess = true
    }
}
