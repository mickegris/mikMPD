import SwiftUI
struct QueueView: View {
    @EnvironmentObject var store: MPDStore
    @State private var addRequest: AddToPlaylistRequest?
    var body: some View {
        NavigationStack {
            Group {
                if store.queue.isEmpty {
                    ContentUnavailableView("Queue is Empty", systemImage: "list.bullet",
                        description: Text("Add songs from the Library or Browser."))
                } else {
                    List {
                        Section {
                            ForEach(store.queue) { song in
                                QueueRow(song: song, isCurrent: song.pos == store.playlistPos)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { store.play(at: song.pos) }
                                    .listRowBackground(song.pos == store.playlistPos
                                        ? Color.accentColor.opacity(0.12) : Color.clear)
                                    .swipeActions(edge: .leading) {
                                        Button { addRequest = AddToPlaylistRequest(uris: [song.file]) } label: {
                                            Label("Playlist", systemImage: "music.note.list")
                                        }.tint(.indigo)
                                    }
                                    .contextMenu {
                                        Button { addRequest = AddToPlaylistRequest(uris: [song.file]) } label: {
                                            Label("Add to Playlist…", systemImage: "music.note.list")
                                        }
                                    }
                            }
                            .onDelete { store.delete(at: $0) }
                            .onMove { store.moveRow(from: $0, to: $1) }
                        } footer: {
                            Text("Double-tap to play. Long press or swipe to add to a playlist.")
                        }
                    }.listStyle(.plain)
                }
            }
            .navigationTitle("Queue")
            .sheet(item: $addRequest) { AddToPlaylistSheet(uris: $0.uris) }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Clear", role: .destructive) { store.clearQueue() }.disabled(store.queue.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton().disabled(store.queue.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { store.toggleConsume() } label: {
                        Image(systemName: store.consumeMode ? "arrow.down.circle.fill" : "arrow.down.circle")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { store.loadQueue() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
    }
}
struct QueueRow: View {
    let song: MPDSong; let isCurrent: Bool
    var body: some View {
        HStack(spacing: 10) {
            Group {
                if isCurrent { Image(systemName: "speaker.wave.2.fill").foregroundColor(.accentColor) }
                else { Text("\(song.pos + 1)").foregroundColor(.secondary).frame(minWidth: 28, alignment: .trailing) }
            }.font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.displayTitle).font(isCurrent ? .subheadline.bold() : .subheadline).lineLimit(1)
                HStack(spacing:4){
                    if !song.artist.isEmpty {
                        NavigationLink(destination:ArtistDetailView(artist:song.artist)){
                            Text(song.artist).font(.caption).foregroundColor(.secondary).lineLimit(1).underline()
                        }.buttonStyle(.plain)
                    }
                    if !song.artist.isEmpty && !song.album.isEmpty { Text("·").font(.caption).foregroundColor(.secondary) }
                    if !song.album.isEmpty {
                        NavigationLink(destination:AlbumDetailView(album:song.album,artist:song.artist.isEmpty ? nil : song.artist)){
                            Text(song.album).font(.caption).foregroundColor(.secondary).lineLimit(1).underline()
                        }.buttonStyle(.plain)
                    }
                }
            }
            Spacer()
            Text(formatTime(song.duration)).font(.caption).foregroundColor(.secondary)
        }.padding(.vertical, 2)
    }
}
