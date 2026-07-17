import SwiftUI

enum LibTab: String, CaseIterable { case albums="Albums"; case artists="Artists"; case genres="Genres"; case playlists="Playlists"; case radio="Radio"; case cd="CD" }

extension LibTab {
    var sfSymbol: String {
        switch self {
        case .albums:    "square.stack"
        case .artists:   "person"
        case .genres:    "tag"
        case .playlists: "music.note.list"
        case .radio:     "antenna.radiowaves.left.and.right"
        case .cd:        "opticaldisc"
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
                case .radio:     RadioView()
                case .cd:        CDView()
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
    @State private var albums:[String]=[];@State private var loading=true;@State private var filter=""
    var shown:[String]{ filter.isEmpty ? albums : albums.filter{$0.localizedCaseInsensitiveContains(filter)} }
    var body: some View {
        Group {
            if loading { ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity) }
            else {
                List(groupAlbumVariants(shown),id:\.base){ g in
                    NavigationLink(destination:AlbumDetailView(album:g.variants[0],artist:nil)){
                        HStack {
                            Label(g.base.isEmpty ? "(no title)" : g.base, systemImage:"square.stack").lineLimit(2)
                            if g.variants.count > 1 {
                                Spacer()
                                Text("\(g.variants.count) discs").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.listStyle(.plain).searchable(text:$filter,prompt:"Filter albums…")
            }
        }
        .onAppear{ guard albums.isEmpty else{return}; store.listTag("album"){albums=$0;loading=false} }
    }
}
struct AlbumDetailView: View {
    @EnvironmentObject var store: MPDStore
    let album:String; let artist:String?
    @State private var songs:[MPDSong]=[];@State private var loading=true
    @State private var wiki:String?=nil;@State private var wikiLoading=false;@State private var expanded=false
    @State private var addRequest:AddToPlaylistRequest?=nil
    @State private var mergedTags:[String]=[]  // >1 when sibling disc variants were merged
    var displayArtist:String{ artist ?? songs.first?.artist ?? "" }
    // Show the stripped base title only when variants really merged, so an album
    // legitimately named like a disc marker keeps its raw name.
    var displayAlbum:String{ mergedTags.count > 1 ? albumBaseAndDisc(album).base : album }
    var songsByDisc:[(disc:Int,songs:[MPDSong])]{
        let g = Dictionary(grouping:songs){ $0.effectiveDisc }
        return g.keys.sorted().map{ ($0, g[$0]!) }
    }
    var body: some View {
        List {
            Section {
                VStack(alignment:.leading,spacing:12){
                    HStack(alignment:.top,spacing:14){
                        ArtThumb(song:songs.first,size:90).cornerRadius(8)
                        VStack(alignment:.leading,spacing:4){
                            Text(displayAlbum.isEmpty ? "(no title)" : displayAlbum).font(.headline)
                            if !displayArtist.isEmpty {
                                NavigationLink(destination:ArtistDetailView(artist:displayArtist)){
                                    Text(displayArtist).font(.subheadline).foregroundStyle(.secondary).underline()
                                }
                            }
                            if !loading {
                                let discPrefix = songsByDisc.count > 1 ? "\(songsByDisc.count) discs · " : ""
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
            } else if songsByDisc.count > 1 {
                ForEach(songsByDisc,id:\.disc){ g in
                    Section(g.disc > 0 ? "Disc \(g.disc)" : "Tracks"){ trackRows(g.songs) }
                }
            } else {
                Section("Tracks"){ trackRows(songs) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(displayAlbum.isEmpty ? "(no title)" : displayAlbum).navigationBarTitleDisplayMode(.inline)
        .sheet(item:$addRequest){ AddToPlaylistSheet(uris:$0.uris) }
        .onAppear{ loadSongs() }
    }
    @ViewBuilder
    func trackRows(_ list:[MPDSong]) -> some View {
        ForEach(list){ s in
            SongRow(song:s).contentShape(Rectangle()).onTapGesture{ store.addAndPlay(uri:s.file) }
                .swipeActions(edge:.trailing){ Button{store.add(uri:s.file)} label:{Label("Add",systemImage:"plus")}.tint(.green) }
                .swipeActions(edge:.leading){ Button{addRequest=AddToPlaylistRequest(uris:[s.file])} label:{Label("Playlist",systemImage:"music.note.list")}.tint(.indigo) }
        }
    }
    // Merge sibling disc variants ("X [Disc 1]" + "X [Disc 2]") into one page,
    // whichever variant this view was opened with.
    func loadSongs(){
        let base = albumBaseAndDisc(album).base
        store.listTag("album", filter: artist==nil ? nil : "artist", value: artist){ all in
            let sibs = all.filter{ albumBaseAndDisc($0).base == base }
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
                songs = sortedByDiscAndTrack(acc); loading = false
                if let s = songs.first { store.fetchArtIfNeeded(for:s) }
                loadWiki()
                return
            }
            remaining.removeFirst()
            store.albumSongs(album:t,artist:artist){ acc.append(contentsOf:$0); next() }
        }
        next()
    }
    func loadWiki(){
        guard wiki==nil,!wikiLoading else{return}
        wikiLoading=true
        let a = displayArtist
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
    var shown:[String]{ filter.isEmpty ? artists : artists.filter{$0.localizedCaseInsensitiveContains(filter)} }
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
        .onAppear{ guard artists.isEmpty else{return}; store.listTag("artist"){artists=$0;loading=false} }
    }
}
struct ArtistDetailView: View {
    @EnvironmentObject var store: MPDStore
    let artist:String
    @State private var albums:[String]=[];@State private var loading=true
    @State private var wiki:String?=nil;@State private var wikiLoading=false;@State private var expanded=false
    @State private var artistImage:UIImage?=nil
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
                Button{ store.findSongs(tag:"artist",value:artist){store.enqueue(songs:$0,replace:true,playFirst:true)} } label:{Label("Play All",systemImage:"play.fill").frame(maxWidth:.infinity)}.buttonStyle(.borderedProminent)
                Button{ store.findSongs(tag:"artist",value:artist){store.enqueue(songs:$0)} } label:{Label("Add All",systemImage:"plus").frame(maxWidth:.infinity)}.buttonStyle(.bordered)
            }
            Section("Albums"){
                if loading { HStack{Spacer();ProgressView();Spacer()} }
                else {
                    ForEach(albumGroups,id:\.base){ g in
                        NavigationLink(destination:AlbumDetailView(album:g.variants[0],artist:artist)){
                            HStack(spacing:10){
                                ArtThumbByKey(artist:artist,album:g.variants[0],size:44).cornerRadius(4)
                                Text(g.base.isEmpty ? "(no title)" : g.base).lineLimit(2)
                                if g.variants.count > 1 {
                                    Spacer()
                                    Text("\(g.variants.count) discs").font(.caption).foregroundStyle(.secondary)
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
    func loadAlbums(){ store.listTag("album",filter:"artist",value:artist){albums=$0;loading=false} }
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
    @State private var albums:[String]=[];@State private var loading=true
    var body: some View {
        List {
            Section{
                Button{ store.findSongs(tag:"genre",value:genre){store.enqueue(songs:$0,replace:true,playFirst:true)} } label:{Label("Play All",systemImage:"play.fill").frame(maxWidth:.infinity)}.buttonStyle(.borderedProminent)
            }
            Section("Albums"){
                if loading { HStack{Spacer();ProgressView();Spacer()} }
                else {
                    ForEach(groupAlbumVariants(albums),id:\.base){ g in
                        NavigationLink(destination:AlbumDetailView(album:g.variants[0],artist:nil)){
                            HStack {
                                Label(g.base.isEmpty ? "(no title)":g.base,systemImage:"square.stack").lineLimit(2)
                                if g.variants.count > 1 {
                                    Spacer()
                                    Text("\(g.variants.count) discs").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(genre.isEmpty ? "(none)" : genre).navigationBarTitleDisplayMode(.inline)
        .onAppear{ store.listTag("album",filter:"genre",value:genre){albums=$0;loading=false} }
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
                    Button {
                        store.addAndPlay(uri: station.url)
                    } label: {
                        Label(station.name, systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
            }
            Section("Saved Stations") {
                if savedStations.isEmpty {
                    Text("No saved stations").foregroundStyle(.secondary).font(.subheadline)
                } else {
                    ForEach(savedStations) { station in
                        Button {
                            store.addAndPlay(uri: station.url)
                        } label: {
                            Label(station.name, systemImage: "antenna.radiowaves.left.and.right")
                        }
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
                            Label("Track \(i + 1)", systemImage: "opticaldisc")
                        }
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
struct SongRow: View {
    let song:MPDSong
    var body: some View {
        HStack(spacing:10){
            if !song.track.isEmpty { Text(song.track.components(separatedBy:"/").first ?? song.track).font(.caption2).foregroundStyle(.secondary).frame(minWidth:24,alignment:.trailing) }
            VStack(alignment:.leading,spacing:1){
                Text(song.displayTitle).font(.subheadline).lineLimit(1)
                if !song.artist.isEmpty { Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Text(formatTime(song.duration)).font(.caption2).foregroundStyle(.secondary)
        }.padding(.vertical,2)
    }
}
struct ArtThumbByKey: View {
    @EnvironmentObject var store:MPDStore
    let artist:String; let album:String; let size:CGFloat
    var artKey:String{ artCacheKey(artist:artist,album:album) }
    var body: some View {
        Group {
            if let img=store.albumArtCache[artKey] {
                Image(uiImage:img).resizable().aspectRatio(contentMode:.fill).frame(width:size,height:size).clipped()
            } else {
                ZStack{Color(.systemGray5);Image("MikMPDLogo").resizable().scaledToFit().padding(size * 0.18)}.frame(width:size,height:size)
            }
        }
        .onAppear{ store.fetchArtIfNeeded(artist:artist,album:album) }
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
        .onAppear{ if let s=song { store.fetchArtIfNeeded(for:s) } }
    }
}
