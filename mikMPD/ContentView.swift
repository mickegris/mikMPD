import SwiftUI
struct ContentView: View {
    @EnvironmentObject var store: MPDStore
    @State private var showSetupPrompt = false
    @State private var showConnection = false
    var body: some View {
        TabView {
            NowPlayingView().tabItem { Label("Now Playing", systemImage: "play.circle") }
            LibraryView().tabItem { Label("Library", systemImage: "music.note.list") }
            BrowserView().tabItem { Label("Browse", systemImage: "folder") }
            SearchView().tabItem { Label("Search", systemImage: "magnifyingglass") }
            MoreView().tabItem { Label("More", systemImage: "ellipsis.circle") }
        }
        .onAppear { if !store.isConfigured { showSetupPrompt = true } }
        .alert("No MPD Server Configured", isPresented: $showSetupPrompt) {
            Button("Set Up Server…") { showConnection = true }
            Button("Later", role: .cancel) {}
        } message: {
            Text("mikMPD needs an MPD server to play from. Do you want to set one up now?")
        }
        .sheet(isPresented: $showConnection) { ConnectionView() }
    }
}
