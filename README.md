# Equil_patch_experiment — EquilController (iOS)

> 🔧 **Fejlesztő/agent vagy, és a nulláról folytatnád?** Olvasd el előbb az
> [AGENT_HANDOFF.md](AGENT_HANDOFF.md) fájlt — teljes technikai átadó,
> architektúra, buktatók (RUN mód!), és a következő teendők.

Saját iOS app az **Equil patch pumpa** (gen 1.0, firmware 5.3) vezérléséhez,
BLE-n keresztül. A protokoll-réteg **byte-szinten követi** az
[AndroidAPS](https://github.com/nightscout/AndroidAPS) Equil driverét (AGPL-3.0),
NEM másolat — Swift-re újraírt, byte-azonos implementáció.

> ⚠️ **Fejlesztési / kísérleti projekt.** Nem orvosi eszköz, nem klinikai
> használatra. A teszteket viselés nélkül, levegőbe adott dózisokkal végezzük.

## Állapot

| Funkció | Parancs | Állapot |
|---|---|---|
| Párosítás | `CmdPair` | ✅ működik |
| Bólusz | `CmdLargeBasalSet` | ✅ működik (RUN mód után) |
| Feltöltés / prime | `CmdStepSet` + `CmdResistanceGet` | ✅ működik |
| Futási mód (RUN/SUSPEND/STOP) | `CmdModelSet` | ✅ |
| Futási mód lekérdezés | `CmdRunningModeGet` | ✅ |
| Tartály / maradék inzulin | `CmdInsulinGet` | 🟡 build OK, élő teszt folyamatban |
| Temp basal (set/get/cancel) | `CmdTempBasalSet` / `CmdTempBasalGet` | 🟡 build OK, élő teszt folyamatban |
| Állapot / előzmény (akku, idő) | `CmdHistoryGet` | 🟡 build OK, élő teszt folyamatban |

### Kulcs-tanulság
A bólusz `Msg2` némán eldobódik, **amíg a pumpa nincs RUN módban**. Az AAPS a
párosítás utolsó lépéseként küld `CmdModelSet(RUN=1)`-et. Folyamat:
**párosítás → RUN mód → bólusz**.

## Felépítés

```
Sources/
  App/         SwiftUI (ContentView, EquilControllerModel) + LogServer
  Bluetooth/   BLE manager, EquilCommandRunner (parancs-futtató)
  Commands/    Cmd*.swift — egy fájl / pumpa-parancs (byte-azonos AAPS-szel)
  Crypto/      AES + byte-segédfüggvények (EquilUtils)
```

## Build

Xcode 26+, iOS device. A projektet `xcodegen` generálja a `project.yml`-ből:

```bash
xcodegen generate
xcodebuild -project EquilController.xcodeproj -scheme EquilController \
  -configuration Debug -destination 'platform=iOS,id=<DEVICE_ID>' \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=<TEAM_ID> build
```

A signing Team ID és device ID a sajátod legyen. A `.xcodeproj` generált —
nincs verziózva (`.gitignore`).

## Használat

1. Add meg a pumpa **SN-jét** (6 hex) és **jelszavát** az appban (nincs beégetve).
2. Párosítás (4 lépés).
3. **Futási mód → RUN.**
4. Prime / bólusz / temp basal / állapot-lekérdezések.

## Licenc / forrás

A protokoll-logika az AndroidAPS Equil driverén alapul (AGPL-3.0). Tartsd
tiszteletben az eredeti licencet.
