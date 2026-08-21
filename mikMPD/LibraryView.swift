import SwiftUI

// Chip-bar order follows this declaration order (CaseIterable).
enum LibTab: String, CaseIterable { case albums="Albums"; case artists="Artists"; case recentlyAdded="Recent"; case genres="Genres"; case playlists="Playlists"; case radio="Radio"; case cd="CD" }

extension LibTab {
    var sfSymbol: String {
        switch self {
        case .albums:        "square.stack"
        case .artists:       "person"
        case .genres:        "tag"
        case .playlists:     "music.note.list"
        case .radio:         "antenna.radiowaves.left.and.right"
        case .cd:            "opticaldisc"
        case .recentlyAdded: "sparkles"
        }
    }
}

struct LibraryView: View {
    @State private var tab: LibTab = .albums
    var body: some View {
        NavigationStack {
            VStack(spacing:0) {
                tabBar
                Divider()
                switch tab {
                case .albums:    AlbumListView()
                case .artists:   ArtistListView()
                case .genres:    GenreListView()
                case .playlists: PlaylistListView()
                case .radio:         RadioView()
                case .cd:            CDView()
                case .recentlyAdded: RecentlyAddedView()
                }
            }
            .navigationTitle("Library").navigationBarTitleDisplayMode(.inline)
        }
    }

    // Six categories don't fit a segmented picker on small iPhones — a
    // horizontally scrolling chip bar degrades by scrolling, not truncating.
    var tabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators:false) {
                HStack(spacing:8) {
                    ForEach(LibTab.allCases,id:\.self){ t in tabChip(t).id(t) }
                }
                .padding(.horizontal)
            }
            .padding(.vertical,8)
            .onChange(of:tab){ _, newTab in withAnimation { proxy.scrollTo(newTab) } }
            .onAppear{ proxy.scrollTo(tab) }
        }
    }

    @ViewBuilder
    func tabChip(_ t: LibTab) -> some View {
        let button = Button { tab = t } label: {
            Label(t.rawValue, systemImage:t.sfSymbol).font(.subheadline)
        }
        if t == tab { button.buttonStyle(.glassProminent) }
        else        { button.buttonStyle(.glass) }
    }
}

// MARK: - Albums
struct AlbumListView: View {
    @EnvironmentObject var store: MPDStore
    @State private var albums: [(artist: String, album: String)] = []
    @State private var loading = true
    @State private var filter = ""
    @State private var addRequest: AddToPlaylistRequest?
    @AppStorage("librarySortAlbums") private var albumSort: AlbumSort = .artistAsc
    @AppStorage("libraryAlbumLayout") private var useGrid: Bool = false
    @State private var discMap: [String: Int] = [:]
    /// album grouping key → shared directory, for rows detected as compilations
    @State private var compilations: [String: String] = [:]

    var shown: [(artist: String, album: String)] {
        filter.isEmpty ? albums : albums.filter {
            $0.album.localizedCaseInsensitiveContains(filter) || $0.artist.localizedCaseInsensitiveContains(filter)
        }
    }
    var groups: [AlbumGroup] {
        let collapsed = compilations.isEmpty ? groupAlbumVariants(shown)
            : collapsingCompilations(groupAlbumVariants(shown)) { base in
                // A non-empty stand-in is enough: the directory is already known,
                // and compilationIdentity only needs files that share it.
                compilations[albumGroupingKey(base)].map { ["\($0)/x"] } ?? []
            }
        var gs = sortedAlbumGroups(collapsed, by: albumSort)
        if !discMap.isEmpty {
            // Only apply tagDiscs when the base name is unambiguous (owned by exactly one
            // artist in the current view), so "Greatest Hits" by two artists never gets
            // the disc count from the other artist's multi-disc release.
            var byBase: [String: Set<String>] = [:]
            for g in gs { byBase[g.groupingKey, default: []].insert(g.artist.lowercased()) }
            for i in gs.indices where byBase[gs[i].groupingKey]?.count == 1 {
                gs[i].tagDiscs = discMap[gs[i].groupingKey]
            }
        }
        return gs
    }

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if useGrid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12, alignment: .leading)], spacing: 16) {
                        ForEach(groups) { g in albumGridTile(g) }
                    }
                    .padding()
                }
            } else {
                List(groups) { g in AlbumGroupRow(group: g) }
                    .listStyle(.plain)
            }
        }
        .searchable(text: $filter, prompt: "Filter albums…")
        .sheet(item: $addRequest) { AddToPlaylistSheet(uris: $0.uris) }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { useGrid.toggle() } label: {
                    Image(systemName: useGrid ? "list.bullet" : "square.grid.2x2")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    ForEach(AlbumSort.allCases, id: \.self) { sort in
                        Button { albumSort = sort } label: {
                            if albumSort == sort { Label(sort.rawValue, systemImage: "checkmark") }
                            else { Text(sort.rawValue) }
                        }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
            }
        }
        .onAppear {
            guard albums.isEmpty else { return }
            store.listAlbumsByArtist { pairs in
                albums = pairs
                loading = false
                // One probe pass over the handful of albums owned by more than
                // one artist; the result is a key → directory map the `groups`
                // computation applies without re-querying on every keystroke.
                store.collapseCompilations(groupAlbumVariants(pairs)) { merged in
                    compilations = merged.reduce(into: [:]) { out, g in
                        if let base = g.compilationBase { out[g.groupingKey] = base }
                    }
                }
            }
            store.listDiscCounts { discMap = $0 }
        }
    }

    /// A compilation has no album artist to filter on, so it loads by directory.
    private func albumSongs(_ g: AlbumGroup, then use: @escaping @MainActor ([MPDSong]) -> Void) {
        if let base = g.compilationBase {
            store.compilationSongs(album: g.base, base: base, completion: use)
        } else {
            store.albumSongs(album: g.variants[0],
                             artist: g.artist.isEmpty ? nil : g.artist,
                             artistTag: "albumartist", completion: use)
        }
    }

    private func isPlayingAlbum(_ g: AlbumGroup) -> Bool {
        isCurrentAlbum(rowArtist: g.artist, rowAlbum: g.base,
                       compilationBase: g.compilationBase, current: store.currentSong)
    }

    @ViewBuilder
    private func albumGridTile(_ g: AlbumGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            NavigationLink(destination: AlbumDetailView(album: g.variants[0],
                                                        artist: g.artist.isEmpty ? nil : g.artist,
                                                        artistTag: "albumartist",
                                                        compilationBase: g.compilationBase)) {
                ArtThumbByKey(artist: g.artKeyArtist, album: g.variants[0],
                              isCompilation: g.compilationBase != nil)
                    .cornerRadius(8)
                    .nowPlayingCover(isPlayingAlbum(g), cornerRadius: 8)
            }
            .buttonStyle(.plain)
            // reservesSpace keeps every tile's text block the same height, so a title
            // that wraps to two lines doesn't push its artist caption out of line with
            // the neighbouring tile's. The artist line is always rendered for the same
            // reason — an album with no albumartist would otherwise sit shorter.
            Text(g.base.isEmpty ? "(no title)" : g.base)
                .font(.subheadline)
                .foregroundStyle(isPlayingAlbum(g) ? Color.accentColor : .primary)
                .lineLimit(2, reservesSpace: true)
            Text(g.artist)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1, reservesSpace: true)
        }
        // Fill the column so tile width is independent of how long the title is —
        // otherwise a wrapping title widens the VStack and moves its artwork.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button {
                albumSongs(g) { store.enqueue(songs: $0, replace: true, playFirst: true) }
            } label: { Label("Play Album", systemImage: "play.fill") }
            Button {
                albumSongs(g) { store.enqueue(songs: $0) }
            } label: { Label("Add to Queue", systemImage: "plus") }
            Button {
                albumSongs(g) { addRequest = AddToPlaylistRequest(uris: $0.map(\.file)) }
            } label: { Label("Add to Playlist…", systemImage: "music.note.list") }
        }
    }
}

/// Row for an artist-aware album list entry — same-named albums by different
/// artists are separate rows, told apart by the artist caption.
struct AlbumGroupRow: View {
    @EnvironmentObject var store: MPDStore
    let group: AlbumGroup
    private var isPlaying: Bool {
        isCurrentAlbum(rowArtist: group.artist, rowAlbum: group.base,
                       compilationBase: group.compilationBase, current: store.currentSong)
    }
    var body: some View {
        NavigationLink(destination:AlbumDetailView(album:group.variants[0],
                                                   artist:group.artist.isEmpty ? nil : group.artist,
                                                   artistTag:"albumartist",
                                                   compilationBase:group.compilationBase)){
            HStack {
                Label {
                    VStack(alignment:.leading,spacing:2){
                        Text(group.base.isEmpty ? "(no title)" : group.base)
                            .foregroundStyle(isPlaying ? Color.accentColor : .primary)
                        if !group.artist.isEmpty {
                            Text(group.artist).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "square.stack")
                        .foregroundStyle(isPlaying ? Color.accentColor : .secondary)
                }
                if group.discCount > 1 {
                    Spacer()
                    Text("\(group.discCount) discs").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .nowPlayingRow(isPlaying)
    }
}
struct AlbumDetailView: View {
    @EnvironmentObject var store: MPDStore
    let album:String; let artist:String?
    // "artist" for song-link navigation, "albumartist" from the grouped lists
    var artistTag:String = "artist"
    /// Set for a compilation: the directory its tracks share. Its tracks have no
    /// album artist in common, so `base` is the only way to select them.
    var compilationBase:String? = nil
    @State private var songs:[MPDSong]=[];@State private var loading=true
    @State private var wiki:String?=nil;@State private var wikiLoading=false;@State private var expanded=false
    @State private var addRequest:AddToPlaylistRequest?=nil
    @State private var mergedTags:[String]=[]  // >1 when sibling disc variants were merged
    var displayArtist:String{ compilationBase != nil ? variousArtistsLabel : (artist ?? songs.first?.displayArtist ?? "") }
    /// "Various Artists" is a placeholder, not a tag value — linking it would
    /// push an artist page that no query can fill.
    var artistIsLinkable:Bool{ compilationBase == nil && !displayArtist.isEmpty }
    // Show the stripped base title only when variants really merged, so an album
    // legitimately named like a disc marker keeps its raw name.
    var displayAlbum:String{ mergedTags.count > 1 ? albumBaseAndDisc(album).base : album }
    var songsByDisc:[(disc:Int,songs:[MPDSong])]{
        let g = Dictionary(grouping:songs){ $0.effectiveDisc }
        return g.keys.sorted().map{ ($0, g[$0]!) }
    }
    var maxDiscNumber: Int { songsByDisc.map(\.disc).max() ?? 0 }
    var isMultiDisc: Bool { songsByDisc.count > 1 && maxDiscNumber > 1 }
    var body: some View {
        List {
            Section {
                VStack(alignment:.leading,spacing:12){
                    HStack(alignment:.top,spacing:14){
                        Group {
                            if let base = compilationBase {
                                ArtThumbByKey(artist: base, album: album,
                                              isCompilation: true, size: 90)
                            } else {
                                ArtThumb(song:songs.first,size:90)
                            }
                        }.cornerRadius(8)
                        VStack(alignment:.leading,spacing:4){
                            Text(displayAlbum.isEmpty ? "(no title)" : displayAlbum).font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            if artistIsLinkable {
                                NavigationLink(destination:ArtistDetailView(artist:displayArtist)){
                                    Text(displayArtist).font(.subheadline).foregroundStyle(.secondary).underline()
                                }
                            } else if !displayArtist.isEmpty {
                                Text(displayArtist).font(.subheadline).foregroundStyle(.secondary)
                            }
                            if !loading {
                                let discPrefix = isMultiDisc ? "\(maxDiscNumber) discs · " : ""
                                Text(discPrefix + "\(songs.count) tracks · \(formatTime(songs.map(\.duration).reduce(0,+)))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack(spacing:12){
                        Button{ store.enqueue(songs:songs,replace:true,playFirst:true) } label:{Label("Play",systemImage:"play.fill").frame(maxWidth:.infinity)}.buttonStyle(.borderedProminent).disabled(loading)
                        Button{ store.enqueue(songs:songs) } label:{Label("Add",systemImage:"plus").frame(maxWidth:.infinity)}.buttonStyle(.bordered).disabled(loading)
                        Menu {
                            Button{ addRequest=AddToPlaylistRequest(uris:songs.map(\.file)) } label:{Label("Add Album to Playlist…",systemImage:"music.note.list")}
                        } label: { Image(systemName:"ellipsis.circle") }.disabled(loading||songs.isEmpty)
                    }
                }.padding(.vertical,4)
            }
            if wikiLoading { Section("About"){ HStack{Spacer();ProgressView();Spacer()} } }
            else if let w=wiki {
                Section("About"){
                    Text(w).font(.caption).foregroundStyle(.secondary).lineLimit(expanded ? nil:4).animation(.easeInOut,value:expanded)
                    Button(expanded ? "Show less":"Show more"){expanded.toggle()}.font(.caption)
                    Text("Source: Wikipedia · CC BY-SA 4.0").font(.caption2).foregroundStyle(.quaternary)
                }
            }
            if loading {
                Section("Tracks"){ HStack{Spacer();ProgressView();Spacer()} }
            } else if isMultiDisc {
                ForEach(songsByDisc,id:\.disc){ g in
                    Section(g.disc > 0 ? "Disc \(g.disc)" : "Tracks"){ trackRows(g.songs) }
                }
            } else {
                Section("Tracks"){ trackRows(songs) }
            }
            if !loading && !songs.isEmpty {
                Section {} footer: {
                    Text("Long press or swipe trailing to add to queue, play next, or add to a playlist.")
                }
            }
        }
        .listStyle(.insetGrouped)
        // The inline bar title truncates long names — that's fine, the header
        // in the page shows the full name (fixedSize guarantees wrapping).
        .navigationTitle(displayAlbum.isEmpty ? "(no title)" : displayAlbum).navigationBarTitleDisplayMode(.inline)
        .sheet(item:$addRequest){ AddToPlaylistSheet(uris:$0.uris) }
        .onAppear{ loadSongs() }
    }
    @ViewBuilder
    func trackRows(_ list:[MPDSong]) -> some View {
        ForEach(list){ s in
            SongRow(song:s, isCurrentlyPlaying: isCurrentTrack(file: s.file, currentFile: store.currentSong.file))
                .nowPlayingRow(isCurrentTrack(file: s.file, currentFile: store.currentSong.file))
                .playableRow{ store.addAndPlay(uri:s.file) }
                .swipeActions(edge:.trailing){
                    Button{store.add(uri:s.file)} label:{Label("Add",systemImage:"plus")}.tint(.green)
                    Button{store.addNext(uri:s.file)} label:{Label("Add Next",systemImage:"text.line.first.and.arrowtriangle.forward")}.tint(.orange)
                }
                .swipeActions(edge:.leading){ Button{addRequest=AddToPlaylistRequest(uris:[s.file])} label:{Label("Playlist",systemImage:"music.note.list")}.tint(.indigo) }
                .contextMenu {
                    Button{store.addNext(uri:s.file)} label:{Label("Add Next",systemImage:"text.line.first.and.arrowtriangle.forward")}
                    Button{addRequest=AddToPlaylistRequest(uris:[s.file])} label:{Label("Add to Playlist…",systemImage:"music.note.list")}
                }
        }
    }
    // Merge sibling disc variants ("X [Disc 1]" + "X [Disc 2]") into one page,
    // whichever variant this view was opened with. Album identity includes the
    // artist: without one there is no safe way to pick siblings (same-named
    // albums by other artists would merge), so merging is skipped.
    func loadSongs(){
        if let base = compilationBase {
            mergedTags = [album]
            store.compilationSongs(album: album, base: base) { found in
                songs = dedupedAlbumTracks(found); loading = false
                // The compilation variant, not the plain one: both key on the
                // directory, but only this one keeps that path out of the
                // MusicBrainz query, where it matches nothing and would record
                // a 7-day miss under the key the header art also uses.
                if !songs.isEmpty { store.fetchArtIfNeeded(compilationBase: base, album: album) }
                loadWiki()
            }
            return
        }
        guard let artist, !artist.isEmpty else {
            mergedTags = [album]
            loadSongs(tags: [album])
            return
        }
        let key = albumGroupingKey(album)
        store.listTag("album", filter: artistTag, value: artist){ all in
            let sibs = all.filter{ albumGroupingKey($0) == key }
            let tags = sibs.count > 1 ? sibs : [album]
            mergedTags = tags
            loadSongs(tags: tags)
        }
    }
    func loadSongs(tags:[String]){
        var remaining = tags
        var acc:[MPDSong] = []
        func next(){
            guard let t = remaining.first else {
                songs = dedupedAlbumTracks(sortedByDiscAndTrack(acc)); loading = false
                if let s = songs.first { store.fetchArtIfNeeded(for:s) }
                loadWiki()
                return
            }
            remaining.removeFirst()
            store.albumSongs(album:t,artist:artist,artistTag:artistTag){ acc.append(contentsOf:$0); next() }
        }
        next()
    }
    func loadWiki(){
        guard wiki==nil,!wikiLoading else{return}
        wikiLoading=true
        // A compilation sends no artist: "Various Artists" is a placeholder, so it
        // would be a guaranteed miss at best and a wrong article at worst. An
        // empty artist degrades to a title-only lookup, still title-validated.
        let a = compilationBase != nil ? "" : displayArtist
        Task{
            let t=await WikipediaService.shared.fetchAlbum(album:album,artist:a)
            await MainActor.run{wiki=t;wikiLoading=false}
        }
    }
}

// MARK: - Artists
struct ArtistListView: View {
    @EnvironmentObject var store: MPDStore
    @State private var artists:[String]=[];@State private var loading=true;@State private var filter=""
    @AppStorage("librarySortArtists") private var artistSort: ArtistSort = .az
    var shown:[String]{
        let filtered = filter.isEmpty ? artists : artists.filter{$0.localizedCaseInsensitiveContains(filter)}
        return sortedArtists(filtered, by: artistSort)
    }
    var body: some View {
        Group {
            if loading { ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity) }
            else {
                List(shown,id:\.self){ a in
                    NavigationLink(destination:ArtistDetailView(artist:a)){
                        Label(a.isEmpty ? "(unknown)" : a, systemImage:"person").lineLimit(2)
                    }
                }.listStyle(.plain).searchable(text:$filter,prompt:"Filter artists…")
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    ForEach(ArtistSort.allCases, id: \.self) { sort in
                        Button { artistSort = sort } label: {
                            if artistSort == sort { Label(sort.rawValue, systemImage: "checkmark") }
                            else { Text(sort.rawValue) }
                        }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
            }
        }
        .onAppear{ guard artists.isEmpty else{return}; store.listArtists{artists=$0;loading=false} }
    }
}
struct ArtistDetailView: View {
    @EnvironmentObject var store: MPDStore
    let artist:String
    /// Which tag this artist's content is scoped by. "albumartist" keeps an
    /// album whole; "artist" is the fallback for an artist that exists only as a
    /// track credit on files with no albumartist to group by.
    @State private var scopeTag = "albumartist"
    @State private var albums:[String]=[];@State private var loading=true
    @State private var wiki:String?=nil;@State private var wikiLoading=false;@State private var expanded=false
    @State private var artistImage:UIImage?=nil
    @State private var tagDiscs:[String:Int]=[:]
    var albumGroups:[(base:String,variants:[String])]{ groupAlbumVariants(albums) }
    var body: some View {
        List {
            Section {
                VStack(spacing:8){
                    if let img=artistImage {
                        Image(uiImage:img).resizable().aspectRatio(contentMode:.fill)
                            .frame(width:180,height:180).clipShape(Circle())
                    } else {
                        ZStack{Circle().fill(Color(.systemGray5)).frame(width:180,height:180);Image(systemName:"person.fill").font(.system(size:60)).foregroundStyle(.secondary)}
                    }
                    Text(artist).font(.title3.bold())
                    if !loading { Text("\(albumGroups.count) album\(albumGroups.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth:.infinity)
                .padding(.vertical,8)
                .listRowBackground(Color.clear)
            }
            if wikiLoading { Section("About"){ HStack{Spacer();ProgressView();Spacer()} } }
            else if let w=wiki {
                Section("About"){
                    Text(w).font(.caption).foregroundStyle(.secondary).lineLimit(expanded ? nil:6).animation(.easeInOut,value:expanded)
                    Button(expanded ? "Show less":"Show more"){expanded.toggle()}.font(.caption)
                    Text("Source: Wikipedia · CC BY-SA 4.0").font(.caption2).foregroundStyle(.quaternary)
                }
            }
            Section{
                Button{ store.enqueueMatching(tag:scopeTag,value:artist,replace:true,playFirst:true) } label:{Label("Play All",systemImage:"play.fill").frame(maxWidth:.infinity)}.buttonStyle(.borderedProminent)
                Button{ store.enqueueMatching(tag:scopeTag,value:artist) } label:{Label("Add All",systemImage:"plus").frame(maxWidth:.infinity)}.buttonStyle(.bordered)
            }
            Section("Albums"){
                if loading { HStack{Spacer();ProgressView();Spacer()} }
                else {
                    ForEach(albumGroups,id:\.base){ g in
                        NavigationLink(destination:AlbumDetailView(album:g.variants[0],artist:artist,artistTag:scopeTag)){
                            HStack(spacing:10){
                                ArtThumbByKey(artist:artist,album:g.variants[0],size:44).cornerRadius(4)
                                Text(g.base.isEmpty ? "(no title)" : g.base)
                                let nd = albumDiscCount(variants: g.variants, tagDiscs: tagDiscs[albumGroupingKey(g.base)])
                                if nd > 1 {
                                    Spacer()
                                    Text("\(nd) discs").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(artist.isEmpty ? "(unknown)" : artist).navigationBarTitleDisplayMode(.inline)
        .onAppear{ loadAlbums(); loadWiki(); loadArtistImage() }
    }
    func loadAlbums(){
        guard albums.isEmpty else { return }
        // Scope by albumartist so an album stays whole: filtering on `artist`
        // drops any track whose artist carries a featuring credit, which is how
        // Tre amigos came to show 14 of its 15 tracks.
        store.listTag("album",filter:"albumartist",value:artist){ found in
            guard found.isEmpty else {
                albums = found; loading = false
                store.listDiscCounts(filter:"albumartist",value:artist){tagDiscs=$0}
                return
            }
            // Nothing under that albumartist: this artist exists only as a track
            // credit on files that carry no albumartist, so `artist` is the only
            // identity they have. It cannot reintroduce the split — such files
            // are never part of an albumartist-tagged album.
            scopeTag = "artist"
            store.listTag("album",filter:"artist",value:artist){albums=$0;loading=false}
            store.listDiscCounts(filter:"artist",value:artist){tagDiscs=$0}
        }
    }
    func loadWiki(){
        guard wiki==nil,!wikiLoading else{return}; wikiLoading=true
        Task{ let t=await WikipediaService.shared.fetchArtist(query:artist); await MainActor.run{wiki=t;wikiLoading=false} }
    }
    func loadArtistImage(){
        guard artistImage==nil else{return}
        Task{ let img=await WikipediaService.shared.fetchArtistImage(query:artist); await MainActor.run{artistImage=img} }
    }
}

// MARK: - Genres
struct GenreListView: View {
    @EnvironmentObject var store: MPDStore
    @State private var genres:[String]=[];@State private var loading=true;@State private var filter=""
    var shown:[String]{ filter.isEmpty ? genres : genres.filter{$0.localizedCaseInsensitiveContains(filter)} }
    var body: some View {
        Group {
            if loading { ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity) }
            else {
                List(shown,id:\.self){ g in
                    NavigationLink(destination:GenreDetailView(genre:g)){
                        Label(g.isEmpty ? "(none)" : g, systemImage:"tag").lineLimit(2)
                    }
                }.listStyle(.plain).searchable(text:$filter,prompt:"Filter genres…")
            }
        }
        .onAppear{ guard genres.isEmpty else{return}; store.listTag("genre"){genres=$0;loading=false} }
    }
}
struct GenreDetailView: View {
    @EnvironmentObject var store: MPDStore
    let genre:String
    @State private var albums:[(artist: String, album: String)]=[];@State private var loading=true
    @State private var discMap:[String:Int]=[:]
    var groups:[AlbumGroup]{
        var gs=groupAlbumVariants(albums)
        if !discMap.isEmpty {
            var byBase:[String:Set<String>]=[:]
            for g in gs { byBase[g.groupingKey, default:[]].insert(g.artist.lowercased()) }
            for i in gs.indices where byBase[gs[i].groupingKey]?.count==1 {
                gs[i].tagDiscs=discMap[gs[i].groupingKey]
            }
        }
        return gs
    }
    var body: some View {
        List {
            Section{
                Button{ store.enqueueMatching(tag:"genre",value:genre,replace:true,playFirst:true) } label:{Label("Play All",systemImage:"play.fill").frame(maxWidth:.infinity)}.buttonStyle(.borderedProminent)
            }
            Section("Albums"){
                if loading { HStack{Spacer();ProgressView();Spacer()} }
                else {
                    ForEach(groups){ g in AlbumGroupRow(group: g) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(genre.isEmpty ? "(none)" : genre).navigationBarTitleDisplayMode(.inline)
        .onAppear{
            store.listAlbumsByArtist(filter:"genre",value:genre){albums=$0;loading=false}
            store.listDiscCounts(filter:"genre",value:genre){discMap=$0}
        }
    }
}

// MARK: - Radio
nonisolated struct SavedStation: Codable, Identifiable, Equatable {
    let name: String
    let url: String
    var id: String { url }
}

private let builtInStations: [SavedStation] = [
    SavedStation(name: "SR P1", url: "https://live1.sr.se/p1-aac-320"),
    SavedStation(name: "SR P2 (AAC)", url: "https://live1.sr.se/p2-aac-320"),
    SavedStation(name: "SR P2 (FLAC)", url: "https://live1.sr.se/p2-flac"),
    SavedStation(name: "SR P3", url: "https://live1.sr.se/p3-aac-320"),
    SavedStation(name: "SR P4 Göteborg", url: "https://live1.sr.se/p4gbg-aac-320"),
]

struct RadioView: View {
    @EnvironmentObject var store: MPDStore
    @AppStorage("savedRadioStations") private var savedStationsData: Data = Data()
    @State private var customName = ""
    @State private var customURL = ""

    private var savedStations: [SavedStation] {
        (try? JSONDecoder().decode([SavedStation].self, from: savedStationsData)) ?? []
    }

    private func saveSavedStations(_ stations: [SavedStation]) {
        savedStationsData = (try? JSONEncoder().encode(stations)) ?? Data()
    }

    var body: some View {
        List {
            Section("Stations") {
                ForEach(builtInStations) { station in
                    stationRow(station)
                        .playableRow { store.addAndPlay(uri: station.url) }
                }
            }
            Section("Saved Stations") {
                if savedStations.isEmpty {
                    Text("No saved stations").foregroundStyle(.secondary).font(.subheadline)
                } else {
                    ForEach(savedStations) { station in
                        stationRow(station)
                            .playableRow { store.addAndPlay(uri: station.url) }
                    }
                    .onDelete { offsets in
                        var stations = savedStations
                        stations.remove(atOffsets: offsets)
                        saveSavedStations(stations)
                    }
                }
            }
            Section("Add Custom Station") {
                TextField("Station Name", text: $customName)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                HStack {
                    TextField("Stream URL", text: $customURL)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button {
                        let url = customURL.trimmingCharacters(in: .whitespaces)
                        let name = customName.trimmingCharacters(in: .whitespaces)
                        guard !url.isEmpty else { return }
                        let displayName = name.isEmpty ? url : name
                        var stations = savedStations
                        stations.append(SavedStation(name: displayName, url: url))
                        saveSavedStations(stations)
                        customName = ""
                        customURL = ""
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(customURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func stationRow(_ station: SavedStation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .frame(width: 24)
            Text(station.name).font(.subheadline)
            Spacer()
            if isCurrentTrack(file: station.url, currentFile: store.currentSong.file) {
                NowPlayingMarker()
            }
        }
        .padding(.vertical, 2)
        .nowPlayingRow(isCurrentTrack(file: station.url, currentFile: store.currentSong.file))
    }
}

// MARK: - Recently Added

private struct AddedAlbum: Identifiable {
    let artist: String       // song.groupingArtist
    let album: String
    var hasAlbumArtist: Bool // true if *any* track of this album carried the tag
    var artistTag: String { hasAlbumArtist ? "albumartist" : "artist" }
    var id: String { artCacheKey(artist: artist, album: album) }
}

struct RecentlyAddedView: View {
    @EnvironmentObject var store: MPDStore
    @State private var albums: [AddedAlbum] = []
    @State private var loading = true
    @State private var addRequest: AddToPlaylistRequest?
    @AppStorage("libraryAlbumLayout") private var useGrid: Bool = false

    // Derive and cap once on load so the dedup loop doesn't re-run on every
    // body evaluation. Songs are sorted newest-first by the store before this.
    private static func deriveAlbums(from songs: [MPDSong]) -> [AddedAlbum] {
        var order: [String] = []
        var byKey: [String: AddedAlbum] = [:]
        for song in songs {
            guard !song.album.isEmpty else { continue }
            let key = artCacheKey(artist: song.groupingArtist, album: song.album)
            if byKey[key] == nil {
                guard order.count < 50 else { continue }
                order.append(key)
                byKey[key] = AddedAlbum(artist: song.groupingArtist,
                                        album: song.album,
                                        hasAlbumArtist: !song.albumArtist.isEmpty)
            } else if !song.albumArtist.isEmpty, byKey[key]?.hasAlbumArtist == false {
                // A later track of this album carries the AlbumArtist tag that the newest
                // one lacked. Upgrade the flag (keeping the newest track's names) so
                // AlbumDetailView filters by "albumartist" — filtering a partially-tagged
                // album by plain "artist" can return only one artist's tracks.
                byKey[key]?.hasAlbumArtist = true
            }
        }
        return order.compactMap { byKey[$0] }
    }

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if albums.isEmpty {
                ContentUnavailableView("Nothing Recently Added", systemImage: "sparkles",
                    description: Text("No tracks added in the last 30 days."))
            } else if useGrid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12, alignment: .leading)], spacing: 16) {
                        ForEach(albums) { g in albumGridTile(g) }
                    }
                    .padding()
                }
            } else {
                List(albums) { g in
                    NavigationLink(destination: AlbumDetailView(album: g.album,
                                                                artist: g.artist.isEmpty ? nil : g.artist,
                                                                artistTag: g.artistTag)) {
                        HStack(spacing: 10) {
                            ArtThumbByKey(artist: g.artist, album: g.album, size: 44)
                                .cornerRadius(4)
                                .nowPlayingCover(isPlayingAlbum(g), cornerRadius: 4)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(g.album).lineLimit(2)
                                    .foregroundStyle(isPlayingAlbum(g) ? Color.accentColor : .primary)
                                if !g.artist.isEmpty {
                                    Text(g.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                    .nowPlayingRow(isPlayingAlbum(g))
                }
                .listStyle(.plain)
                .refreshable { reload() }
            }
        }
        .sheet(item: $addRequest) { AddToPlaylistSheet(uris: $0.uris) }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { reload() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { useGrid.toggle() } label: {
                    Image(systemName: useGrid ? "list.bullet" : "square.grid.2x2")
                }
            }
        }
        .onAppear {
            guard loading else { return }
            reload()
        }
    }

    private func reload() {
        loading = true
        store.loadRecentlyAdded { songs in
            albums = Self.deriveAlbums(from: songs)
            loading = false
        }
    }

    private func isPlayingAlbum(_ g: AddedAlbum) -> Bool {
        isCurrentAlbum(rowArtist: g.artist, rowAlbum: g.album, current: store.currentSong)
    }

    @ViewBuilder
    private func albumGridTile(_ g: AddedAlbum) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            NavigationLink(destination: AlbumDetailView(album: g.album,
                                                        artist: g.artist.isEmpty ? nil : g.artist,
                                                        artistTag: g.artistTag)) {
                ArtThumbByKey(artist: g.artist, album: g.album)
                    .cornerRadius(8)
                    .nowPlayingCover(isPlayingAlbum(g), cornerRadius: 8)
            }
            .buttonStyle(.plain)
            Text(g.album.isEmpty ? "(no title)" : g.album)
                .font(.subheadline)
                .foregroundStyle(isPlayingAlbum(g) ? Color.accentColor : .primary)
                .lineLimit(2, reservesSpace: true)
            Text(g.artist)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1, reservesSpace: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button {
                store.albumSongs(album: g.album, artist: g.artist.isEmpty ? nil : g.artist, artistTag: g.artistTag) {
                    store.enqueue(songs: $0, replace: true, playFirst: true)
                }
            } label: { Label("Play Album", systemImage: "play.fill") }
            Button {
                store.albumSongs(album: g.album, artist: g.artist.isEmpty ? nil : g.artist, artistTag: g.artistTag) {
                    store.enqueue(songs: $0)
                }
            } label: { Label("Add to Queue", systemImage: "plus") }
            Button {
                store.albumSongs(album: g.album, artist: g.artist.isEmpty ? nil : g.artist, artistTag: g.artistTag) {
                    addRequest = AddToPlaylistRequest(uris: $0.map(\.file))
                }
            } label: { Label("Add to Playlist…", systemImage: "music.note.list") }
        }
    }
}

// MARK: - CD
struct CDView: View {
    @EnvironmentObject var store: MPDStore
    @State private var tracks: [MPDBrowseItem] = []
    @State private var loading = false

    var body: some View {
        List {
            Section("Audio CD") {
                Button {
                    store.playCD()
                } label: {
                    Label("Play Whole CD", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.vertical, 4)

                Button {
                    loadTracks()
                } label: {
                    Label("Load Track List", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
            }

            if loading {
                Section("Tracks") {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            } else if !tracks.isEmpty {
                Section("Tracks") {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { i, track in
                        Button {
                            store.playCD(track: track.path)
                        } label: {
                            HStack {
                                Label("Track \(i + 1)", systemImage: "opticaldisc")
                                if isCurrentTrack(file: track.path, currentFile: store.currentSong.file) {
                                    Spacer()
                                    NowPlayingMarker()
                                }
                            }
                        }
                        .nowPlayingRow(isCurrentTrack(file: track.path, currentFile: store.currentSong.file))
                        .swipeActions(edge: .leading) {
                            Button {
                                store.playCD(track: track.path)
                            } label: {
                                Label("Play", systemImage: "play.fill")
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                store.addCD(track: track.path)
                            } label: {
                                Label("Add to Queue", systemImage: "plus")
                            }
                            .tint(.green)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("CD")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadTracks() }
    }

    private func loadTracks() {
        loading = true
        tracks = []
        store.probeCDTracks { items in
            tracks = items
            loading = false
        }
    }
}

// MARK: - Shared helpers

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}

private struct PlayableRowModifier: ViewModifier {
    let action: () -> Void
    @State private var flashing = false
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(flashing ? 0.25 : 0))
                    .animation(.easeOut(duration: 0.35), value: flashing)
            )
            .onTapGesture {
                Haptics.tap()
                action()
                flashing = true
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    flashing = false
                }
            }
    }
}

extension View {
    func playableRow(action: @escaping () -> Void) -> some View {
        modifier(PlayableRowModifier(action: action))
    }
}

struct SongRow: View {
    let song: MPDSong
    var isCurrentlyPlaying: Bool = false
    var body: some View {
        HStack(spacing:10){
            if !song.track.isEmpty { Text(song.track.components(separatedBy:"/").first ?? song.track).font(.caption2).foregroundStyle(.secondary).frame(minWidth:24,alignment:.trailing) }
            VStack(alignment:.leading,spacing:1){
                Text(song.displayTitle).font(.subheadline).lineLimit(1)
                if !song.displayArtist.isEmpty { Text(song.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if isCurrentlyPlaying { NowPlayingMarker() }
            Text(formatTime(song.duration)).font(.caption2).foregroundStyle(.secondary)
        }.padding(.vertical,2)
    }
}
struct ArtThumbByKey: View {
    @EnvironmentObject var store: MPDStore
    let artist: String; let album: String
    /// True when `artist` is a compilation's directory rather than a real name.
    var isCompilation: Bool = false
    /// Fixed square side, or `nil` to fill the available width (still square).
    /// Grid tiles fill: a fixed 130 pt cover inside a ~179 pt column left 49 pt of
    /// dead space per cell, which is what made tile alignment look wrong no matter
    /// which alignment was chosen. Filling removes the slack instead of moving it.
    var size: CGFloat? = nil

    var artKey: String { artCacheKey(artist: artist, album: album) }

    @ViewBuilder private var imageLayer: some View {
        if let img = store.albumArtCache[artKey] {
            Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color(.systemGray5)
                Image("MikMPDLogo").resizable().scaledToFit()
                    .padding(size.map { $0 * 0.18 } ?? 26)
            }
        }
    }

    var body: some View {
        Group {
            if let size {
                imageLayer.frame(width: size, height: size).clipped()
            } else {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { imageLayer }
                    .clipped()
            }
        }
        .task(id: artKey) {
            if isCompilation { store.fetchArtIfNeeded(compilationBase: artist, album: album) }
            else             { store.fetchArtIfNeeded(artist: artist, album: album) }
        }
    }
}
struct ArtThumb: View {
    @EnvironmentObject var store:MPDStore
    let song:MPDSong?; let size:CGFloat
    var body: some View {
        Group {
            if let s=song, let img=store.albumArtCache[s.artKey] {
                Image(uiImage:img).resizable().aspectRatio(contentMode:.fill).frame(width:size,height:size).clipped()
            } else {
                ZStack{Color(.systemGray5);Image(song?.fallbackArtAssetName ?? "MikMPDLogo").resizable().scaledToFit().padding(size * 0.18)}.frame(width:size,height:size)
            }
        }
        .task(id: song?.artKey ?? "") { if let s = song { store.fetchArtIfNeeded(for: s) } }
    }
}
