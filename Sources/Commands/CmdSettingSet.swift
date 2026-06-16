//
//  CmdSettingSet.swift
//  EquilKit
//
//  Byte-azonos port: AndroidAPS pump/equil manager/command/CmdSettingSet.kt
//  Mérvadó forrás: nightscout/AndroidAPS (AGPL-3.0)
//
//  PÁROSÍTÁS 4. (utolsó) LÉPÉSE — küszöbök beállítása. BaseSetting kézfogás,
//  DEFAULT_PORT (0F0F). isPairStep = true.
//
//   - getFirstData:  index(4LE) ++ [01,05]
//        ++ intToBytes(0)        [useTime]      (4 byte LE)
//        ++ intToBytes(0)        [autoCloseTime](4 byte LE)
//        ++ intToTwoBytes(1600)  [lowAlarm]     (2 byte)
//        ++ intToTwoBytes(0)     [fastBolus]    (2 byte)
//        ++ intToTwoBytes(2800)  [occlusion]    (2 byte)
//        ++ intToTwoBytes(8)     [insulinUnit]  (2 byte)
//        ++ intToTwoBytes(basalThresholdStep)   (2 byte)
//        ++ intToTwoBytes(bolusThresholdStep)   (2 byte)
//        pumpReqIndex++
//   - getNextData:   index(4LE) ++ [00,05,01]   pumpReqIndex++
//   - decodeConfirmData:  cmdSuccess = true.
//
//   basalThresholdStep = decodeSpeedToUH(maxBasal)
//   bolusThresholdStep = decodeSpeedToUH(maxBolus)
//

import Foundation

final class CmdSettingSet: EquilBaseSetting {

    let bolusThresholdStep: Int
    let basalThresholdStep: Int

    init(maxBolus: Double,
         maxBasal: Double,
         equilDevice: String,
         equilPassword: String,
         createTime: Int64) {
        self.bolusThresholdStep = EquilUtils.decodeSpeedToUH(maxBolus)
        self.basalThresholdStep = EquilUtils.decodeSpeedToUH(maxBasal)
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
        // BaseSetting DEFAULT_PORT (0F0F) — a CmdSettingSet nem írja felül a portot.
    }

    override var commandLabel: String { "Beállítások (CmdSettingSet)" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let equilCmd: [UInt8] = [0x01, 0x05]
        let useTime = EquilUtils.intToBytes(0)
        let autoCloseTime = EquilUtils.intToBytes(0)
        let lowAlarmByte = EquilUtils.intToTwoBytes(1600)
        let fastBolus = EquilUtils.intToTwoBytes(0)
        let occlusion = EquilUtils.intToTwoBytes(2800)
        let insulinUnit = EquilUtils.intToTwoBytes(8)
        let basalThreshold = EquilUtils.intToTwoBytes(basalThresholdStep)
        let bolusThreshold = EquilUtils.intToTwoBytes(bolusThresholdStep)
        var data = EquilUtils.concat(indexByte, equilCmd)
        data = EquilUtils.concat(data, useTime)
        data = EquilUtils.concat(data, autoCloseTime)
        data = EquilUtils.concat(data, lowAlarmByte)
        data = EquilUtils.concat(data, fastBolus)
        data = EquilUtils.concat(data, occlusion)
        data = EquilUtils.concat(data, insulinUnit)
        data = EquilUtils.concat(data, basalThreshold)
        data = EquilUtils.concat(data, bolusThreshold)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func getNextData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x00, 0x05, 0x01]
        let data = EquilUtils.concat(indexByte, data2)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func decodeConfirmData(_ data: [UInt8]) {
        cmdSuccess = true
    }
}
