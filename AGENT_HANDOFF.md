# AGENT_HANDOFF — EquilController fejlesztői átadó

> Ez a dokumentum egy **friss agentet vagy fejlesztőt a nulláról** elindít.
> Olvasd el végig, mielőtt bármit módosítasz. A projekt egy Equil patch pumpa
> (gen 1.0, firmware 5.3) iOS-vezérlője; a protokoll byte-szinten az
> [AndroidAPS](https://github.com/nightscout/AndroidAPS) Equil driverét követi.

---

## 0. Aranyszabályok (NE szegd meg)

1. **A pairing működik — NEM szabad elrontani.** A `CmdPair.swift` és az
   `EquilCommandRunner.swift` byte-szinten kész. Minden szerkesztés UTÁN
   ellenőrizd, hogy az md5-jük változatlan:
   - `EquilCommandRunner.swift` = `41d77d5265fa97fc5686f972ba90693e`
   - `CmdPair.swift` = `653022ca149e9919293a9821ac323c67`
   Ha ezek változnak, valamit elrontottál — állítsd vissza.
2. **Byte-azonos parítás, NEM Kotlin→Swift copy-paste.** Minden új parancs az
   AAPS megfelelő `Cmd*.kt`-jét követi byte-pontosan (portok, payload-offsetek,
   endianness), de Swiftül újraírva.
3. **Fejlesztői/kísérleti projekt.** A teszteket viselés nélkül, levegőbe adott
   dózisokkal végezzük. Nem orvosi eszköz.
4. **Minden működő mérföldkő után git commit + tag.** Visszaállítási pont:
   `git checkout WORKING-bolus-ok` adja a bólusz-működő verziót.

---

## 1. A LEGFONTOSABB tanulság: RUN mód

A pumpa kétféle parancsot kezel eltérően:

| Parancstípus | Példa | RUN mód kell? |
|---|---|---|
| **GET / lekérdezés** | resistance, temp basal get, insulin get, history | ❌ nem — RUN nélkül is működik |
| **SET / vezérlés** | bólusz, temp basal set, basal set | ✅ **IGEN** — különben a pumpa **némán eldobja** a Msg2-t (30s timeout) |

Az AAPS a **párosítás utolsó lépéseként** küld `CmdModelSet(RUN=1)`-et
(`EquilPairConfirmFragment.setModel`). A mi appunk ezt külön gombbal teszi.

**KÖTELEZŐ tesztsorrend minden SET-parancshoz:**
```
párosítás (4 lépés) → "Futási mód → RUN" → SET parancs (bólusz / temp basal set / …)
```
Ha egy SET parancs 30s-et timeoutol „némán", az ELSŐ gyanú mindig: nem volt RUN mód.

---

## 2. Funkció-státusz

| Funkció | Parancs | Port | Státusz |
|---|---|---|---|
| Párosítás | `CmdPair` | 0F0F / 0E0E | ✅ működik (firmware 5.3) |
| Bólusz | `CmdLargeBasalSet` | 0404 | ✅ működik (RUN után) |
| Prime / feltöltés | `CmdStepSet` + `CmdResistanceGet` | 0707 / 1515 | ✅ működik |
| Futási mód set | `CmdModelSet` (0=SUSPEND,1=RUN,2=STOP) | 0404 | ✅ |
| Futási mód get | `CmdRunningModeGet` | 0404 | ✅ |
| Temp basal **get** | `CmdTempBasalGet` | 0404 | ✅ decode bizonyított: step=80→1.0 E/h, time=3600s→60p |
| Temp basal **set/cancel** | `CmdTempBasalSet` | 0404 | 🟡 kód kész; RUN módban kell élőben tesztelni (RUN nélkül timeoutol) |
| Tartály / inzulin | `CmdInsulinGet` | 0505 | 🟡 build OK; élő teszt hátravan |
| Állapot / előzmény | `CmdHistoryGet` | 0505 | 🟡 build OK; élő teszt hátravan |

---

## 3. Architektúra

```
Sources/
  App/
    EquilControllerApp.swift     – belépési pont
    ContentView.swift            – SwiftUI UI (gombok, mezők)
    EquilControllerModel.swift   – @MainActor model: minden funkció-metódus
    LogServer.swift              – beépített HTTP log-szerver (port 8080)
  Bluetooth/
    EquilBLEManager.swift        – CoreBluetooth (scan/connect/notify/write)
    EquilCommandRunner.swift     – parancs-futtató állapotgép (NE módosítsd!)
    EquilCommandDriving+Adapters.swift
  Commands/
    EquilBaseCmd.swift           – közös ős; statikus számlálók; dlog
    EquilBaseSetting.swift       – 3-üzenetes "setting" kézfogás (lásd lent)
    Cmd*.swift                   – egy fájl / pumpa-parancs
    EquilConst.swift, EquilFraming.swift
  Crypto/
    AESUtil.swift                – AES enc/dec
    Crc.swift, EquilUtils.swift  – CRC + byte-segédfüggvények
```

### A 3-üzenetes "setting" kézfogás (EquilBaseSetting)
Minden SET/GET-setting parancs ezt követi:
1. **Msg1 — `getEquilResponse`**: `getReqData` = index(4LE)+SN, tárolt jelszóval
   titkosítva, port `<port>0000` (default port `0404`).
2. **Msg2 — `decode`**: a pump Msg1-válaszából `runPwd = decrypt(...)[8..]`
   (hex string, első 8 hexchar levágva). Majd `getFirstData()` runPwd-vel
   titkosítva, port `<port>+runCode`. **Itt akad el RUN mód nélkül a SET.**
3. **Msg3 — `decodeConfirm`**: `decodeConfirmData(...)` beállítja a sikert
   (`cmdSuccess=true`), majd `getNextData()` küldése.
   - A tiszta **GET** parancsok (resistance, temp basal get, insulin, history,
     running mode) **felülírják `decodeConfirm()`-et**, hogy a Msg2-válaszból
     dekódoljanak és **NE küldjenek Msg3-at** (üres EquilResponse-t adnak vissza).

### Fontos részletek
- `EquilUtils.intToBytes` = **4-byte LITTLE-endian**. `bytes2Int([…])` 4-byte LE.
  `bytesToInt(high, low)` = 2-byte (`high<<8 | low`).
- Statikus számlálók `EquilBaseCmd`-ben: `pumpReqIndex` (10-ről), `reqIndex` (0),
  `rspIndex` (-1). `resetState()` a `run()` elején nullázza.
- A parancs `onReady`-re (notify engedélyezve) indul; a régi watchdog eltávolítva.
- A model `runCommandPerConnection(_:kind:completion:)` connect-per-command
  módon futtat: friss BLE connect → onReady → runner.run(timeout:30). A GET-ek
  a `completion` closure-ben olvassák ki a dekódolt értéket a cmd objektumból.

---

## 4. Új parancs hozzáadása (minta)

1. Keresd meg az AAPS-megfelelőt:
   `AndroidAPS/.../pump/equil/manager/command/Cmd<X>.kt`.
2. Hozz létre `Sources/Commands/Cmd<X>.swift`-et, `EquilBaseSetting` alosztály.
3. Implementáld byte-pontosan:
   - `getFirstData()` = index(4LE) ++ [parancs-byte-ok] ++ payload(4LE…)
   - `getNextData()` = index(4LE) ++ [záró byte-ok] ++ 0(4LE)
   - `decodeConfirmData(_:)` = state beolvasás (offsetek az AAPS szerint),
     `cmdSuccess = true`
   - Ha tiszta GET: írd felül `decodeConfirm()`-et (Msg2-ből dekódol, üres
     választ ad — lásd `CmdResistanceGet.swift` mint mintát).
   - Ha a port nem 0404: állítsd be az `init`-ben (`port = "0505"` stb.).
4. Add hozzá a model-metódust `EquilControllerModel.swift`-ben (minta: a többi).
5. Tegyél gombot a `ContentView.swift`-be.
6. Build + install (lásd lent), majd élő teszt **RUN módban** (ha SET).

---

## 5. Build & install

Xcode 26+, fizikai iOS eszköz. A `.xcodeproj` generált (xcodegen), nincs
verziózva.

```bash
cd <repo>
xcodegen generate
xcodebuild -project EquilController.xcodeproj -scheme EquilController \
  -configuration Debug \
  -destination 'platform=iOS,id=<A_TE_DEVICE_ID-D>' \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=<A_TE_TEAM_ID-D> build

APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/EquilController-*/Build/Products/Debug-iphoneos/EquilController.app | head -1)
xcrun devicectl device install app --device <A_TE_DEVICE_ID-D> "$APP"
```

> A `project.yml`-ben szereplő `DEVELOPMENT_TEAM` és bundle id a projekt eredeti
> tulajdonosáé — **cseréld a sajátodra** (Apple Developer Team ID). A „No
> provider was found" install-figyelmeztetés jóindulatú, a telepítés sikerül.

---

## 6. Naplózás

Az app egy HTTP log-szervert futtat a telefonon (port 8080). A futás közben a
telefon a Wi-Fi IP-jén szolgálja ki a logot:
`http://<telefon-IP>:8080`. A log-ablak első sora kiírja a pontos URL-t.
Innen olvasható a teljes BLE-forgalom (write/notify hexek), a dekódolt
state és a `🔬` debug-sorok — ez a fő diagnosztikai eszköz.

---

## 7. Konfigurálás futásidőben (NINCS beégetve)

- A pumpa **SN-jét** (6 hex) és **jelszavát** az appban add meg — a kódban
  nincs beégetve (publikus repo).
- Az Equil alap-jelszó tipikusan `0000`, de eszközönként eltérhet.

---

## 8. Következő teendők (prioritás szerint)

1. **Temp basal SET élő teszt RUN módban** — várhatóan átmegy (a get már
   bizonyítottan jó). Sorrend: pair → RUN → „Temp beállít" → „Temp lekérdez"
   (a lekérdezésnek a frissen beállított rátát/időt kell visszaadnia).
2. **Tartály-állapot (`CmdInsulinGet`) élő teszt** — ellenőrizd a log nyers hex
   tartalmát; ha a `data[6]` offset eltér, igazítsd az AAPS `CmdInsulinGet.kt`
   szerint.
3. **Állapot/előzmény (`CmdHistoryGet`) élő teszt** — ugyanígy ellenőrizd az
   offseteket (battery=data[12], medicine=data[13], stb.).
4. Opcionális: a `CmdModelSet(RUN=1)` automatikus beillesztése a párosítás
   záró lépéseként (mint az AAPS), hogy ne kelljen kézzel nyomni — a pairing
   md5-ök sértetlenül hagyásával, csak a model-rétegben.

---

## 9. Hasznos referenciák

- AAPS Equil driver:
  `AndroidAPS/pump/equil/src/main/kotlin/app/aaps/pump/equil/manager/command/`
  (minden `Cmd*.kt`). Ez a MÉRVADÓ forrás minden byte-kérdéshez.
- `RunMode` enum: RUN(1), STOP(2), SUSPEND(0), NONE(-1).
- Ellenállás-küszöb (`getResistanceThreshold`): SN első karaktere ∈ {0,1,3,A,D}
  → 500 (régi pumpa), különben 220.
