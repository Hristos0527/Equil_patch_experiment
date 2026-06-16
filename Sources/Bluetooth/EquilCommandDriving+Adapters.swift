import Foundation

// Az EquilCommandDriving konformanciát az EquilBaseCmd ősosztály teljesíti
// (lásd EquilBaseCmd.swift): a decodeEquilPacket állapotgép, a cmdSuccess/enacted
// siker-jelzők, valamint a label/firstResponse az ősön + leszármazott-felülírásokon
// keresztül. Ezért itt NINCS külön extension — a CmdPair és CmdLargeBasalSet
// automatikusan EquilCommandDriving, mert az EquilBaseCmd leszármazottai.
//
// (A fájl szándékosan üres; megtartjuk a projektszerkezet stabilitásáért.)
