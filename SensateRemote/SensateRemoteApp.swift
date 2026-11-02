import SwiftUI

@main
struct SensateRemoteApp: App {
    @StateObject private var ble = SensateBLE()
    @StateObject private var session = SessionEngine()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(ble)
                .environmentObject(session)
        }
    }
}
