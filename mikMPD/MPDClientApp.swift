import SwiftUI
@main struct MPDClientApp: App {
    @StateObject private var store = MPDStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                store.handleEnteringBackground()
            case .active:
                store.refreshOnForeground()
            default:
                break
            }
        }
    }
}
