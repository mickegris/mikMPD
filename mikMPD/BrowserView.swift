import SwiftUI
struct BrowserView: View {
    @EnvironmentObject var store: MPDStore
    var body: some View {
        NavigationStack {
            Group {
                if store.browseItems.isEmpty { ContentUnavailableView("Empty", systemImage:"folder") }
                else {
                    List(store.browseItems) { item in
                        BrowserRow(item:item).contentShape(Rectangle())
                            .onTapGesture { if item.kind == .directory { store.browse(item.path) } }
                            .onTapGesture(count:2) { doubleTap(item) }
                            .swipeActions(edge:.trailing) {
                                Button { addItem(item) } label: { Label("Add",systemImage:"plus") }.tint(.green)
                                if item.kind == .file {
                                    Button { store.addAndPlay(uri:item.path) } label: { Label("Play",systemImage:"play.fill") }.tint(.blue)
                                }
                            }
                    }.listStyle(.plain)
                }
            }
            .navigationTitle(store.isAtRoot ? "Browse" : URL(fileURLWithPath:store.browsePath).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.navigationBarLeading) {
                    if !store.isAtRoot {
                        Button { store.browseUp() } label: { Label("Up", systemImage:"chevron.left") }
                    }
                }
                ToolbarItem(placement:.navigationBarTrailing) {
                    Button { store.browse("") } label: { Image(systemName:"house") }
                }
            }
        }
    }
    func doubleTap(_ i: MPDBrowseItem) {
        switch i.kind { case .directory: store.browse(i.path); case .file: store.addAndPlay(uri:i.path); case .playlist: store.loadPlaylist(i.path) }
    }
    func addItem(_ i: MPDBrowseItem) {
        switch i.kind { case .directory,.file: store.add(uri:i.path); case .playlist: store.loadPlaylist(i.path) }
    }
}
struct BrowserRow: View {
    let item: MPDBrowseItem
    var color: Color { item.kind == .directory ? .blue : item.kind == .playlist ? .purple : .primary }
    var body: some View {
        HStack(spacing:12) {
            Image(systemName:item.sfSymbol).foregroundColor(color).frame(width:24)
            Text(item.displayName).lineLimit(2).font(.subheadline)
            if item.kind == .directory { Spacer(); Image(systemName:"chevron.right").font(.caption).foregroundColor(.secondary) }
        }.padding(.vertical,2)
    }
}
