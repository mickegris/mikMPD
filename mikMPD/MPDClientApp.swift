import SwiftUI
@main struct MPDClientApp: App {
    @StateObject private var store = MPDStore()
    var body: some Scene { WindowGroup { ContentView().environmentObject(store) } }
}
