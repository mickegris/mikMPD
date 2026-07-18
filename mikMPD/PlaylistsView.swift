// PlaylistsView.swift
// Stored-playlist browsing inside the Library tab, plus the shared
// "Add to Playlist" sheet used from Now Playing, albums, queue, and search.
import SwiftUI

// MARK: - Playlist list (Library tab)

struct PlaylistListView: View {
    @EnvironmentObject var store: MPDStore
    @State private var filter = ""
    @State private var playlistToDelete: MPDPlaylist?
    @State private var renameTarget: MPDPlaylist?
    @State private var renameName = ""
    @State private var showSaveQueue = false
    @State private var saveName = ""
    @State private var actionError: String?

    var shown: [MPDPlaylist] {
        filter.isEmpty ? store.playlists : store.playlists.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        Group {
            if store.playlists.isEmpty {
                ContentUnavailableView("No Playlists", systemImage: "music.note.list",
                    description: Text("Save the queue as a playlist, or use “Add to Playlist” on a song or album."))
            } else {
                List {
                    Section {
                        ForEach(shown) { pl in
                            NavigationLink(destination: PlaylistDetailView(name: pl.name)) {
                                Label(pl.name, systemImage: "music.note.list").lineLimit(2)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { playlistToDelete = pl } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button {
                                    renameName = pl.name
                                    renameTarget = pl
                                } label: {
                                    Label("Rename…", systemImage: "pencil")
                                }
                            }
                        }
                    } footer: {
                        Text("Long press a playlist to rename it. Swipe to delete.")
                    }
                }
                .listStyle(.plain)
                .searchable(text: $filter, prompt: "Filter playlists…")
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    saveName = ""
                    showSaveQueue = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(store.queue.isEmpty)
            }
        }
        .alert("Save Queue as Playlist", isPresented: $showSaveQueue) {
            TextField("Name", text: $saveName)
                .autocorrectionDisabled()
            Button("Save") {
                if let name = validatePlaylistName(saveName) {
                    store.saveQueueAsPlaylist(name: name) { actionError = $0 }
                } else {
                    actionError = "Playlist names must not be empty or contain slashes."
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Playlist", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameName)
                .autocorrectionDisabled()
            Button("Rename") {
                if let target = renameTarget, let name = validatePlaylistName(renameName) {
                    if name != target.name {
                        store.renamePlaylist(target.name, to: name) { actionError = $0 }
                    }
                } else {
                    actionError = "Playlist names must not be empty or contain slashes."
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert("Delete Playlist?", isPresented: Binding(
            get: { playlistToDelete != nil },
            set: { if !$0 { playlistToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let pl = playlistToDelete { store.deletePlaylist(name: pl.name) }
                playlistToDelete = nil
            }
            Button("Cancel", role: .cancel) { playlistToDelete = nil }
        } message: {
            Text("“\(playlistToDelete?.name ?? "")” will be removed from the server.")
        }
        .alert("Playlist Error", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .onAppear { store.loadPlaylists() }
    }
}

// MARK: - Playlist detail

struct PlaylistDetailView: View {
    @EnvironmentObject var store: MPDStore
    let name: String
    @State private var songs: [MPDSong] = []
    @State private var loading = true
    @State private var addRequest: AddToPlaylistRequest?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 14) {
                        ArtThumb(song: songs.first, size: 90).cornerRadius(8)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name).font(.headline).lineLimit(3)
                            if !loading {
                                Text("\(songs.count) tracks · \(formatTime(songs.map(\.duration).reduce(0, +)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack(spacing: 12) {
                        Button { store.loadPlaylist(name, replace: true, play: true) } label: {
                            Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).disabled(loading || songs.isEmpty)
                        Button { store.loadPlaylist(name) } label: {
                            Label("Add", systemImage: "plus").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).disabled(loading || songs.isEmpty)
                    }
                }.padding(.vertical, 4)
            }
            Section {
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if songs.isEmpty {
                    Text("Empty playlist").foregroundStyle(.secondary)
                } else {
                    ForEach(songs) { s in
                        SearchRow(song: s, selected: false)
                            .contentShape(Rectangle())
                            .onTapGesture { store.playPlaylist(name: name, at: s.pos) }
                            .swipeActions(edge: .leading) {
                                Button { store.add(uri: s.file) } label: {
                                    Label("Queue", systemImage: "plus")
                                }.tint(.green)
                                Button { addRequest = AddToPlaylistRequest(uris: [s.file]) } label: {
                                    Label("Playlist", systemImage: "music.note.list")
                                }.tint(.indigo)
                            }
                            .contextMenu {
                                Button { addRequest = AddToPlaylistRequest(uris: [s.file]) } label: {
                                    Label("Add to Playlist…", systemImage: "music.note.list")
                                }
                            }
                    }
                    .onDelete { offsets in
                        store.removeFromPlaylist(name: name, at: offsets) { reload() }
                    }
                    .onMove { offsets, destination in
                        // Optimistic local reorder, mirroring the queue's moveRow
                        songs.move(fromOffsets: offsets, toOffset: destination)
                        for i in songs.indices { songs[i].pos = i }
                        store.movePlaylistSong(name: name, from: offsets, to: destination) { reload() }
                    }
                }
            } header: {
                Text("Tracks")
            } footer: {
                Text("Long press or swipe a track to add it to another playlist.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton().disabled(songs.isEmpty)
            }
        }
        .sheet(item: $addRequest) { AddToPlaylistSheet(uris: $0.uris, excluding: name) }
        .onAppear { reload() }
    }

    private func reload() {
        store.playlistSongs(name: name) { songs = $0; loading = false }
    }
}

// MARK: - Shared "Add to Playlist" sheet

/// Identifiable wrapper so views can present the sheet via .sheet(item:).
struct AddToPlaylistRequest: Identifiable {
    let id = UUID()
    let uris: [String]
}

struct AddToPlaylistSheet: View {
    @EnvironmentObject var store: MPDStore
    @Environment(\.dismiss) var dismiss
    let uris: [String]
    var excluding: String? = nil
    @State private var newName = ""
    @State private var nameError = false

    private var lists: [MPDPlaylist] { store.playlists.filter { $0.name != excluding } }

    var body: some View {
        NavigationStack {
            List {
                Section("New Playlist") {
                    HStack {
                        TextField("Name", text: $newName)
                            .autocorrectionDisabled()
                        Button {
                            if let name = validatePlaylistName(newName) {
                                add(to: name)
                            } else {
                                nameError = true
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("Playlists") {
                    if lists.isEmpty {
                        Text("No playlists yet").foregroundStyle(.secondary)
                    } else {
                        ForEach(lists) { pl in
                            Button { add(to: pl.name) } label: {
                                Label(pl.name, systemImage: "music.note.list")
                            }
                        }
                    }
                }
            }
            .navigationTitle(uris.count == 1 ? "Add to Playlist" : "Add \(uris.count) Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .alert("Invalid Playlist Name", isPresented: $nameError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Playlist names must not be empty or contain slashes.")
            }
            .onAppear { store.loadPlaylists() }
        }
    }

    private func add(to name: String) {
        store.addToPlaylist(name: name, uris: uris)
        dismiss()
    }
}
