import SwiftUI

struct SearchView: View {
    @EnvironmentObject var store: MPDStore
    @State private var query = ""
    @State private var selectedSongs: Set<String> = []
    @State private var artists: [String] = []
    @State private var albums: [(artist: String, album: String)] = []
    @State private var isSearching = false
    
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
                } else if store.searchResults.isEmpty && artists.isEmpty && albums.isEmpty {
                    ContentUnavailableView.search(text: query)
                    Spacer()
                } else {
                    searchResults
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Songs, artists, albums…")
            .onChange(of: query) { _, newValue in
                if !newValue.isEmpty {
                    performSearch(newValue)
                } else {
                    clearResults()
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
                    ForEach(albums, id: \.album) { item in
                        NavigationLink {
                            AlbumDetailView(album: item.album, artist: item.artist)
                        } label: {
                            HStack(spacing: 12) {
                                // Album art thumbnail
                                AlbumArtThumb(artist: item.artist, album: item.album, size: 50)
                                    .cornerRadius(6)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.album)
                                        .font(.subheadline)
                                        .lineLimit(2)
                                    if !item.artist.isEmpty {
                                        Text(item.artist)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("Albums (\(albums.count))")
                }
            }
            
            // Songs section
            if !store.searchResults.isEmpty {
                Section {
                    ForEach(store.searchResults) { song in
                        SearchRow(song: song, selected: selectedSongs.contains(song.id))
                            .contentShape(Rectangle())
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded { _ in
                                    store.addAndPlay(uri: song.file)
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
                }
            }
        }
        .listStyle(.plain)
    }
    
    private func performSearch(_ query: String) {
        isSearching = true
        selectedSongs.removeAll()
        
        // Search for songs
        store.search(field: "any", query: query)
        
        // Search for artists whose name contains the query
        store.listTag("artist") { allArtists in
            self.artists = allArtists.filter { artist in
                artist.localizedCaseInsensitiveContains(query)
            }
        }
        
        // Search for albums
        // First, find all artists that match
        store.listTag("artist") { allArtists in
            let matchingArtists = allArtists.filter { $0.localizedCaseInsensitiveContains(query) }
            
            // Get albums for matching artists
            var albumArtistPairs: [(artist: String, album: String)] = []
            let group = DispatchGroup()
            
            // Add albums from matching artists
            for artist in matchingArtists.prefix(10) {
                group.enter()
                store.listTag("album", filter: "artist", value: artist) { albums in
                    for album in albums {
                        albumArtistPairs.append((artist: artist, album: album))
                    }
                    group.leave()
                }
            }
            
            // Also search for albums whose title contains the query
            group.enter()
            store.listTag("album") { allAlbums in
                let matchingAlbums = allAlbums.filter { $0.localizedCaseInsensitiveContains(query) }
                
                // Get artist for each matching album
                for album in matchingAlbums.prefix(10) {
                    group.enter()
                    store.albumSongs(album: album) { songs in
                        if let firstSong = songs.first {
                            // Avoid duplicates
                            if !albumArtistPairs.contains(where: { $0.album == album && $0.artist == firstSong.artist }) {
                                albumArtistPairs.append((artist: firstSong.artist, album: album))
                            }
                        }
                        group.leave()
                    }
                }
                group.leave()
            }
            
            group.notify(queue: .main) {
                self.albums = albumArtistPairs.sorted { a, b in
                    if a.artist == b.artist {
                        return a.album < b.album
                    }
                    return a.artist < b.artist
                }
                self.isSearching = false
            }
        }
    }
    
    private func clearResults() {
        store.searchResults = []
        artists = []
        albums = []
        selectedSongs.removeAll()
    }
}

struct SearchRow: View {
    let song: MPDSong
    let selected: Bool
    
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
                    if !song.artist.isEmpty {
                        Text(song.artist)
                            .foregroundStyle(.secondary)
                    }
                    if !song.album.isEmpty {
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(song.album)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
            
            Spacer()
            
            Text(formatTime(song.duration))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// Album art thumbnail for search results
struct AlbumArtThumb: View {
    @EnvironmentObject var store: MPDStore
    let artist: String
    let album: String
    let size: CGFloat
    
    var artKey: String {
        "\(artist)|\(album)".lowercased()
    }
    
    var body: some View {
        Group {
            if let img = store.albumArtCache[artKey] {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                ZStack {
                    Color(.systemGray5)
                    Image(systemName: "square.stack")
                        .foregroundStyle(.secondary)
                        .font(.system(size: size * 0.4))
                }
                .frame(width: size, height: size)
            }
        }
        .onAppear {
            // Create a temporary song to fetch art
            let tempSong = MPDSong()
            var song = tempSong
            song.artist = artist
            song.album = album
            store.fetchArtIfNeeded(for: song)
        }
    }
}

