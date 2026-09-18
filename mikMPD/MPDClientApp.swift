import SwiftUI
@main struct MPDClientApp: App {
    @StateObject private var store = MPDStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(store.clock)
        }
        .onChange(of: scenePhase) { _, phase in
            store.setSceneActive(phase == .active)
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
