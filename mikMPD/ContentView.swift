import SwiftUI
struct ContentView: View {
    @EnvironmentObject var store: MPDStore
    var body: some View {
        TabView {
            NowPlayingView().tabItem { Label("Now Playing", systemImage: "play.circle") }
            LibraryView().tabItem { Label("Library", systemImage: "music.note.list") }
            BrowserView().tabItem { Label("Browse", systemImage: "folder") }
            SearchView().tabItem { Label("Search", systemImage: "magnifyingglass") }
            MoreView().tabItem { Label("More", systemImage: "ellipsis.circle") }
        }
    }
}
