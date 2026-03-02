import SwiftUI
struct QueueView: View {
    @EnvironmentObject var store: MPDStore
    var body: some View {
        NavigationStack {
            Group {
                if store.queue.isEmpty {
                    ContentUnavailableView("Queue is Empty", systemImage: "list.bullet",
                        description: Text("Add songs from the Library or Browser."))
                } else {
                    List {
                        ForEach(store.queue) { song in
                            QueueRow(song: song, isCurrent: song.pos == store.playlistPos)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { store.play(at: song.pos) }
                                .listRowBackground(song.pos == store.playlistPos
                                    ? Color.accentColor.opacity(0.12) : Color.clear)
                        }
                        .onDelete { store.delete(at: $0) }
                    }.listStyle(.plain)
                }
            }
            .navigationTitle("Queue")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Clear", role: .destructive) { store.clearQueue() }.disabled(store.queue.isEmpty)
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
                if !song.artist.isEmpty { Text(song.artist).font(.caption).foregroundColor(.secondary).lineLimit(1) }
            }
            Spacer()
            Text(formatTime(song.duration)).font(.caption).foregroundColor(.secondary)
        }.padding(.vertical, 2)
    }
}
