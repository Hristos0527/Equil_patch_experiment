import SwiftUI

struct ContentView: View {
    @StateObject private var model = EquilControllerModel()
    @FocusState private var keyboardFocused: Bool

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                statusHeader
                Divider()
                logLinkBar
                Divider()
                // A vezérlők GÖRGETHETŐK — így a billentyűzet/gombsor nem takar ki semmit.
                ScrollView {
                    controls
                }
                .scrollDismissesKeyboard(.interactively)
                .frame(maxHeight: 380)
                Divider()
                logView
            }
            .navigationTitle("Equil vezérlő")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // "Kész" gomb a billentyűzet felett — bármikor elrejthető a keyboard.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Kész") { keyboardFocused = false }
                }
            }
            // Bárhová koppintva is eltűnik a billentyűzet.
            .contentShape(Rectangle())
            .onTapGesture { keyboardFocused = false }
        }
        .navigationViewStyle(.stack)
    }

    /// A log-szerver linkje (a Macen: curl ezzel a címmel) + watchdog kapcsoló.
    private var logLinkBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .font(.caption)
                .foregroundStyle(.blue)
            Text(model.logURL)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.blue)
                .textSelection(.enabled)
                .lineLimit(1)
            Spacer()
            Button(action: model.toggleWatchdog) {
                Label(model.watchdogOn ? "WD be" : "WD ki",
                      systemImage: model.watchdogOn ? "pawprint.fill" : "pawprint")
                    .font(.caption2)
            }
            .tint(model.watchdogOn ? .green : .gray)
        }
        .padding(.horizontal).padding(.vertical, 6)
    }

    private var statusHeader: some View {
        HStack {
            Circle()
                .fill(model.btState == "bekapcsolva" ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
            Text("BT: \(model.btState)")
                .font(.footnote)
            Spacer()
            Text(model.statusLine)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            // --- Párosítás blokk: SN (6 hex) + jelszó (4 hex) ---
            HStack {
                Text("SN")
                    .frame(width: 70, alignment: .leading)
                TextField("pl. A1B2C3", text: $model.serialNumber)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled(true)
                validIcon(model.serialNumberValid, empty: model.serialNumber.isEmpty)
            }

            HStack {
                Text("Jelszó")
                    .frame(width: 70, alignment: .leading)
                TextField("0000", text: $model.pairPassword)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                validIcon(model.pairPasswordValid, empty: model.pairPassword.isEmpty)
            }

            HStack {
                Text("Max E / E/h")
                    .frame(width: 70, alignment: .leading)
                    .font(.caption2)
                TextField("max bólusz", text: $model.maxBolus)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.decimalPad)
                    .focused($keyboardFocused)
                TextField("max basal", text: $model.maxBasal)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.decimalPad)
                    .focused($keyboardFocused)
            }

            // --- Scanner (diagnosztika): közeli BLE-eszközök ---
            Button(action: { model.scanning ? model.stopScan() : model.startScan() }) {
                Label(model.scanning ? "Scan leállítása" : "Közeli eszközök keresése",
                      systemImage: model.scanning ? "stop.circle" : "dot.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.busy)

            if !model.discovered.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.discovered) { dev in
                        HStack {
                            Image(systemName: dev.matchesSerial ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(dev.matchesSerial ? .green : .gray)
                                .font(.caption2)
                            Text(dev.name)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(dev.matchesSerial ? .green : .primary)
                            Spacer()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Button(action: model.startPairing) {
                Text("Párosítás (4 lépés)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy || model.scanning || !model.serialNumberValid || !model.pairPasswordValid)

            Divider().padding(.vertical, 2)

            // --- Prime / feltöltés blokk ---
            Button(action: model.startPrime) {
                Text("Feltöltés (prime) — pin a pisztonhoz")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .disabled(model.busy || model.pairedDevice.isEmpty)

            // --- Futási mód (RUN) blokk — a bólusz előfeltétele ---
            HStack(spacing: 8) {
                Button(action: model.setRunMode) {
                    Text("Futási mód → RUN")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .disabled(model.busy || model.pairedDevice.isEmpty)

                Button(action: model.queryRunningMode) {
                    Text("Mód lekérdezés")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.busy || model.pairedDevice.isEmpty)
            }

            // --- Bólusz blokk ---
            HStack {
                Text("Bólusz E")
                    .frame(width: 70, alignment: .leading)
                TextField("0.05", text: $model.bolusUnits)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.decimalPad)
                    .focused($keyboardFocused)
                Button(action: model.sendBolus) {
                    Text("Bólusz a levegőbe")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.busy || model.pairedDevice.isEmpty)
            }

            if !model.pairedDevice.isEmpty {
                Text("Párosítva ✓  device=\(model.pairedDevice.prefix(12))…")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }

    /// Kis validációs ikon a beviteli mezők mellett (zöld pipa / piros x / szürke).
    @ViewBuilder
    private func validIcon(_ valid: Bool, empty: Bool) -> some View {
        if empty {
            Image(systemName: "circle")
                .foregroundStyle(.gray)
        } else if valid {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var logView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Élő log")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Törlés", action: model.clearLog)
                    .font(.caption)
            }
            .padding(.horizontal).padding(.top, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .onChange(of: model.logLines.count) { _ in
                    if let last = model.logLines.indices.last {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            .background(Color(.secondarySystemBackground))
        }
    }
}
