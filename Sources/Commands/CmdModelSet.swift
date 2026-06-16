//
//  CmdModelSet.swift
//  EquilKit
//
//  Byte-azonos port: AndroidAPS pump/equil manager/command/CmdModelSet.kt
//  Mérvadó forrás: nightscout/AndroidAPS (AGPL-3.0)
//
//  FUTÁSI MÓD beállítása. port = 0404 (default).
//    mode: 0=SUSPEND, 1=RUN, 2=STOP  (RunMode.command)
//    getFirstData: index(4LE) ++ [0x01,0x00] ++ mode(4LE)
//    getNextData : index(4LE) ++ [0x00,0x00,0x01]
//    decodeConfirmData → cmdSuccess = true
//
//  A párosítás UTOLSÓ lépése az AAPS-ben: CmdModelSet(RUN=1) → a pumpa
//  innentől fogad bóluszt. NÉLKÜLE a pumpa némán eldobja a bólusz Msg2-t.
//

import Foundation

final class CmdModelSet: EquilBaseSetting {

    let mode: Int   // 0=SUSPEND, 1=RUN, 2=STOP

    init(mode: Int, createTime: Int64, equilDevice: String, equilPassword: String) {
        self.mode = mode
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
        // port marad "0404" (BaseCmd default)
    }

    override var commandLabel: String { "Futási mód (CmdModelSet mode=\(mode))" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x01, 0x00]
        let data3 = EquilUtils.intToBytes(mode)
        let data = EquilUtils.concat(indexByte, data2, data3)
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

    override func decodeConfirmData(_ data: [UInt8]) {
        EquilBaseCmd.dlog("🔬 CmdModelSet: mód beállítva = \(mode)")
        cmdSuccess = true
    }
}
