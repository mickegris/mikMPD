import SwiftUI

struct SearchView: View {
    @EnvironmentObject var store: MPDStore
    @State private var query = ""
    @State private var selectedSongs: Set<String> = []
    @State private var artists: [String] = []
    @State private var albums: [AlbumGroup] = []
    @State private var playlistMatches: [PlaylistMatch] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var addRequest: AddToPlaylistRequest?
    @State private var flashedSongID: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isSearching {
                    ProgressView("Searching…")
                        .padding(.top, 40)
                    Spacer()
                } else if query.isEmpty {
                    ContentUnavailableView(
                        "Search Library",
                        systemImage: "magnifyingglass",
                        description: Text("Search for songs, artists, and albums")
                    )
                    Spacer()
                } else if store.searchResults.isEmpty && artists.isEmpty && albums.isEmpty
                            && playlistMatches.isEmpty {
                    ContentUnavailableView.search(text: query)
                    Spacer()
                } else {
                    searchResults
                }
            }
            .navigationTitle("Search")
            .sheet(item: $addRequest) { AddToPlaylistSheet(uris: $0.uris) }
            .searchable(text: $query, prompt: "Songs, artists, albums…")
            .onChange(of: query) { _, newValue in
                searchTask?.cancel()
                if newValue.isEmpty {
                    clearResults()
                } else {
                    searchTask = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        performSearch(newValue)
                    }
                }
            }
        }
    }
    
    private var searchResults: some View {
        List {
            // Artists section
            if !artists.isEmpty {
                Section {
                    ForEach(artists, id: \.self) { artist in
                        NavigationLink {
                            ArtistDetailView(artist: artist)
                        } label: {
                            HStack {
                                Image(systemName: "person.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.title3)
                                Text(artist)
                                    .font(.subheadline)
                            }
                        }
                    }
                } header: {
                    Text("Artists (\(artists.count))")
                }
            }
            
            // Albums section
            if !albums.isEmpty {
                Section {
                    ForEach(albums) { item in
                        let playing = isCurrentAlbum(rowArtist: item.artist, rowAlbum: item.base,
                                                     compilationBase: item.compilationBase,
                                                     current: store.currentSong)
                        NavigationLink {
                            AlbumDetailView(album: item.variants[0], artist: item.artist,
                                            artistTag: "albumartist",
                                            compilationBase: item.compilationBase)
                        } label: {
                            HStack(spacing: 12) {
                                // Album art thumbnail
                                ArtThumbByKey(artist: item.artKeyArtist, album: item.variants[0],
                                              isCompilation: item.compilationBase != nil, size: 50)
                                    .cornerRadius(6)
                                    .nowPlayingCover(playing)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.base.isEmpty ? "(no title)" : item.base)
                                        .font(.subheadline)
                                        .foregroundStyle(playing ? Color.accentColor : .primary)
                                    if !item.artist.isEmpty {
                                        Text(item.artist)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    if item.discCount > 1 {
                                        Text("\(item.discCount) discs")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .nowPlayingRow(playing)
                    }
                } header: {
                    Text("Albums (\(albums.count))")
                }
            }

            // Playlists section — matched by name and by contents
            if !playlistMatches.isEmpty {
                Section {
                    ForEach(playlistMatches) { pl in
                        let isPlaying = store.playbackContext == pl.name
                        NavigationLink(destination: PlaylistDetailView(name: pl.name)) {
                            HStack(spacing: 12) {
                                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "music.note.list")
                                    .foregroundStyle(isPlaying ? Color.accentColor : .secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pl.name).font(.subheadline).lineLimit(2)
                                        .foregroundStyle(isPlaying ? Color.accentColor : .primary)
                                    if pl.trackCount > 0 {
                                        Text("\(pl.trackCount) matching track\(pl.trackCount == 1 ? "" : "s")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text("Name matches").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .nowPlayingRow(isPlaying)
                        .swipeActions(edge: .trailing) {
                            Button { store.loadPlaylist(pl.name, replace: true, play: true) } label: {
                                Label("Play", systemImage: "play.fill")
                            }.tint(.blue)
                            Button { store.loadPlaylist(pl.name) } label: {
                                Label("Add", systemImage: "plus")
                            }.tint(.green)
                        }
                        .contextMenu {
                            Button { store.loadPlaylist(pl.name, replace: true, play: true) } label: {
                                Label("Play Playlist", systemImage: "play.fill")
                            }
                            Button { store.shufflePlayPlaylist(pl.name) } label: {
                                Label("Shuffle Play", systemImage: "shuffle")
                            }
                            Button { store.loadPlaylist(pl.name) } label: {
                                Label("Add to Queue", systemImage: "plus")
                            }
                        }
                    }
                } header: {
                    Text("Playlists (\(playlistMatches.count))")
                }
            }
            
            // Songs section
            if !store.searchResults.isEmpty {
                Section {
                    ForEach(store.searchResults) { song in
                        SearchRow(song: song, selected: selectedSongs.contains(song.id),
                                  isCurrentlyPlaying: isCurrentTrack(file: song.file, currentFile: store.currentSong.file))
                            .nowPlayingRow(isCurrentTrack(file: song.file, currentFile: store.currentSong.file))
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.accentColor.opacity(flashedSongID == song.id ? 0.25 : 0))
                                    .animation(.easeOut(duration: 0.35), value: flashedSongID == song.id)
                            )
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded { _ in
                                    Haptics.tap()
                                    store.addAndPlay(uri: song.file)
                                    let id = song.id
                                    flashedSongID = id
                                    Task {
                                        try? await Task.sleep(for: .milliseconds(350))
                                        if flashedSongID == id { flashedSongID = nil }
                                    }
                                }
                            )
                            .simultaneousGesture(
                                TapGesture(count: 1).onEnded { _ in
                                    if selectedSongs.contains(song.id) {
                                        selectedSongs.remove(song.id)
                                    } else {
                                        selectedSongs.insert(song.id)
                                    }
                                }
                            )
                            .listRowBackground(
                                selectedSongs.contains(song.id)
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear
                            )
                            .swipeActions(edge: .leading) {
                                if song.sourceKind == .library {
                                    Button { store.addNext(uri: song.file) } label: {
                                        Label("Add Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                                    }.tint(.orange)
                                }
                                Button { addRequest = AddToPlaylistRequest(uris: [song.file]) } label: {
                                    Label("Playlist", systemImage: "music.note.list")
                                }.tint(.indigo)
                            }
                            .contextMenu {
                                if song.sourceKind == .library {
                                    Button { store.addNext(uri: song.file) } label: {
                                        Label("Add Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                                    }
                                }
                                Button { addRequest = AddToPlaylistRequest(uris: [song.file]) } label: {
                                    Label("Add to Playlist…", systemImage: "music.note.list")
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text("Songs (\(store.searchResults.count))")
                        Spacer()
                        if !selectedSongs.isEmpty {
                            Button("Add Selected") {
                                let selected = store.searchResults.filter { selectedSongs.contains($0.id) }
                                store.enqueue(songs: selected)
                                selectedSongs.removeAll()
                            }
                            .font(.caption)
                        }
                        Button("Add All") {
                            store.enqueue(songs: store.searchResults)
                        }
                        .font(.caption)
                    }
                } footer: {
                    Text("Double-tap to play. Long press or swipe for options.")
                }
            }
        }
        .listStyle(.plain)
    }
    
    private func performSearch(_ query: String) {
        isSearching = true
        selectedSongs.removeAll()

        store.search(field: "any", query: query)
        store.searchPlaylists(query: query) { self.playlistMatches = $0 }

        // Album artist, not artist: listing the raw `artist` tag surfaces every
        // per-track featuring credit as its own artist and splits its album.
        store.listArtists { allArtists in
            let matchingArtists = allArtists.filter { $0.localizedCaseInsensitiveContains(query) }
            self.artists = matchingArtists

            var albumArtistPairs: [(artist: String, album: String)] = []
            let group = DispatchGroup()

            for artist in matchingArtists.prefix(10) {
                group.enter()
                store.listTag("album", filter: "albumartist", value: artist) { albums in
                    for album in albums {
                        albumArtistPairs.append((artist: artist, album: album))
                    }
                    group.leave()
                }
            }

            group.enter()
            store.listTag("album") { allAlbums in
                let matchingAlbums = allAlbums.filter { $0.localizedCaseInsensitiveContains(query) }

                for album in matchingAlbums.prefix(10) {
                    group.enter()
                    store.albumSongs(album: album) { songs in
                        if let firstSong = songs.first {
                            // groupingArtist: keyed and navigated by the album's
                            // artist, so a featuring track can't name the album.
                            let owner = firstSong.groupingArtist
                            if !albumArtistPairs.contains(where: { $0.album == album && $0.artist == owner }) {
                                albumArtistPairs.append((artist: owner, album: album))
                            }
                        }
                        group.leave()
                    }
                }
                group.leave()
            }

            group.notify(queue: .main) {
                let sorted = albumArtistPairs.sorted { a, b in
                    if a.artist == b.artist {
                        return a.album < b.album
                    }
                    return a.artist < b.artist
                }
                // Disc variants of one artist's album collapse into one row;
                // AlbumDetailView re-expands to all discs when opened. Then the
                // same compilation pass the Albums tab runs — without it a
                // various-artists album shows here credited to whichever track
                // artist sorted first, with art that no key will ever fill.
                let grouped = groupAlbumVariants(sorted)
                self.albums = grouped
                self.isSearching = false
                store.resolveCompilations(grouped) { resolved in
                    guard self.query == query else { return }   // a newer search won
                    self.albums = resolved
                }
            }
        }
    }
    
    private func clearResults() {
        store.searchResults = []
        artists = []
        albums = []
        playlistMatches = []
        selectedSongs.removeAll()
    }
}

struct SearchRow: View {
    let song: MPDSong
    let selected: Bool
    var isCurrentlyPlaying: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(song.displayTitle)
                    .font(.subheadline.bold())
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if !song.displayArtist.isEmpty {
                        // Credit shown, album artist navigated to — see MPDSong.linkArtist.
                        NavigationLink(destination:ArtistDetailView(artist:song.linkArtist)){
                            Text(song.displayArtist).foregroundStyle(.secondary).underline()
                        }.buttonStyle(.plain)
                    }
                    if !song.displayArtist.isEmpty && !song.album.isEmpty {
                        Text("·").foregroundStyle(.secondary)
                    }
                    if !song.album.isEmpty {
                        NavigationLink(destination:AlbumDetailView(album:song.album,artist:song.linkArtist.isEmpty ? nil : song.linkArtist,artistTag:"albumartist")){
                            Text(song.album).foregroundStyle(.secondary).underline()
                        }.buttonStyle(.plain)
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }

            Spacer()

            if isCurrentlyPlaying { NowPlayingMarker() }
            Text(formatTime(song.duration))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

