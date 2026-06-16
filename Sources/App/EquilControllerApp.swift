import SwiftUI

/// Standalone iOS controller app for bringing up the Equil patch pump over BLE.
/// Development tool only — the pump is NOT worn; boluses go "into the air".
@main
struct EquilControllerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
