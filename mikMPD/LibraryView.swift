import SwiftUI

enum LibTab: String, CaseIterable { case albums="Albums"; case artists="Artists"; case genres="Genres"; case radio="Radio" }

struct LibraryView: View {
    @State private var tab: LibTab = .albums
    var body: some View {
        NavigationStack {
            VStack(spacing:0) {
                Picker("",selection:$tab) { ForEach(LibTab.allCases,id:\.self){Text($0.rawValue)} }
                    .pickerStyle(.segmented).padding(.horizontal).padding(.vertical,8)
                Divider()
                switch tab {
                case .albums:  AlbumListView()
                case .artists: ArtistListView()
                case .genres:  GenreListView()
                case .radio:   RadioView()
                }
            }
            .navigationTitle("Library").navigationBarTitleDisplayMode(.inline)
        }
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
                List(shown,id:\.self){ a in
                    NavigationLink(destination:AlbumDetailView(album:a,artist:nil)){
                        Label(a.isEmpty ? "(no title)" : a, systemImage:"square.stack").lineLimit(2)
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
    var displayArtist:String{ artist ?? songs.first?.artist ?? "" }
    var body: some View {
        List {
            Section {
                VStack(alignment:.leading,spacing:12){
                    HStack(alignment:.top,spacing:14){
                        ArtThumb(song:songs.first,size:90).cornerRadius(8)
                        VStack(alignment:.leading,spacing:4){
                            Text(album.isEmpty ? "(no title)" : album).font(.headline).lineLimit(3)
                            if !displayArtist.isEmpty { Text(displayArtist).font(.subheadline).foregroundStyle(.secondary) }
                            if !loading { Text("\(songs.count) tracks · \(formatTime(songs.map(\.duration).reduce(0,+)))").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    HStack(spacing:12){
                        Button{ store.enqueue(songs:songs,replace:true,playFirst:true) } label:{Label("Play",systemImage:"play.fill").frame(maxWidth:.infinity)}.buttonStyle(.borderedProminent).disabled(loading)
                        Button{ store.enqueue(songs:songs) } label:{Label("Add",systemImage:"plus").frame(maxWidth:.infinity)}.buttonStyle(.bordered).disabled(loading)
                    }
                }.padding(.vertical,4)
            }
            if wikiLoading { Section("About"){ HStack{Spacer();ProgressView();Spacer()} } }
            else if let w=wiki {
                Section("About"){
                    Text(w).font(.caption).foregroundStyle(.secondary).lineLimit(expanded ? nil:4).animation(.easeInOut,value:expanded)
                    Button(expanded ? "Show less":"Show more"){expanded.toggle()}.font(.caption)
                }
            }
            Section("Tracks"){
                if loading { HStack{Spacer();ProgressView();Spacer()} }
                else {
                    ForEach(songs){ s in
                        SongRow(song:s).contentShape(Rectangle()).onTapGesture{ store.addAndPlay(uri:s.file) }
                            .swipeActions(edge:.trailing){ Button{store.add(uri:s.file)} label:{Label("Add",systemImage:"plus")}.tint(.green) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(album.isEmpty ? "(no title)" : album).navigationBarTitleDisplayMode(.inline)
        .onAppear{ loadSongs(); loadWiki() }
    }
    func loadSongs(){ store.albumSongs(album:album,artist:artist){songs=$0;loading=false} }
    func loadWiki(){
        guard wiki==nil,!wikiLoading else{return}; wikiLoading=true
        Task{ let t=await WikipediaService.shared.fetch(query:"\(album) album"); await MainActor.run{wiki=t;wikiLoading=false} }
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
    var body: some View {
        List {
            if wikiLoading { Section("About"){ HStack{Spacer();ProgressView();Spacer()} } }
            else if let w=wiki {
                Section("About"){
                    Text(w).font(.caption).foregroundStyle(.secondary).lineLimit(expanded ? nil:6).animation(.easeInOut,value:expanded)
                    Button(expanded ? "Show less":"Show more"){expanded.toggle()}.font(.caption)
                }
            }
            Section{
                Button{ store.findSongs(tag:"artist",value:artist){store.enqueue(songs:$0,replace:true,playFirst:true)} } label:{Label("Play All",systemImage:"play.fill").frame(maxWidth:.infinity)}.buttonStyle(.borderedProminent)
                Button{ store.findSongs(tag:"artist",value:artist){store.enqueue(songs:$0)} } label:{Label("Add All",systemImage:"plus").frame(maxWidth:.infinity)}.buttonStyle(.bordered)
            }
            Section("Albums"){
                if loading { HStack{Spacer();ProgressView();Spacer()} }
                else {
                    ForEach(albums,id:\.self){ a in
                        NavigationLink(destination:AlbumDetailView(album:a,artist:artist)){
                            Label(a.isEmpty ? "(no title)" : a, systemImage:"square.stack").lineLimit(2)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(artist.isEmpty ? "(unknown)" : artist).navigationBarTitleDisplayMode(.inline)
        .onAppear{ loadAlbums(); loadWiki() }
    }
    func loadAlbums(){ store.listTag("album",filter:"artist",value:artist){albums=$0;loading=false} }
    func loadWiki(){
        guard wiki==nil,!wikiLoading else{return}; wikiLoading=true
        Task{ let t=await WikipediaService.shared.fetch(query:artist); await MainActor.run{wiki=t;wikiLoading=false} }
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
                else { ForEach(albums,id:\.self){ a in NavigationLink(destination:AlbumDetailView(album:a,artist:nil)){Label(a.isEmpty ? "(no title)":a,systemImage:"square.stack").lineLimit(2)} } }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(genre.isEmpty ? "(none)" : genre).navigationBarTitleDisplayMode(.inline)
        .onAppear{ store.listTag("album",filter:"genre",value:genre){albums=$0;loading=false} }
    }
}

// MARK: - Radio
struct RadioStation: Identifiable {
    let name: String
    let url: String
    var id: String { url }
}

private let radioStations: [RadioStation] = [
    RadioStation(name: "SR P1", url: "https://live1.sr.se/p1-aac-320"),
    RadioStation(name: "SR P2 (AAC)", url: "https://live1.sr.se/p2-aac-320"),
    RadioStation(name: "SR P2 (FLAC)", url: "https://live1.sr.se/p2-flac"),
    RadioStation(name: "SR P3", url: "https://live1.sr.se/p3-aac-320"),
    RadioStation(name: "SR P4 Göteborg", url: "https://live1.sr.se/p4gbg-aac-320"),
]

struct SavedStation: Codable, Identifiable, Equatable {
    let name: String
    let url: String
    var id: String { url }
}

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
                ForEach(radioStations) { station in
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
struct ArtThumb: View {
    @EnvironmentObject var store:MPDStore
    let song:MPDSong?; let size:CGFloat
    var body: some View {
        Group {
            if let s=song, let img=store.albumArtCache[s.artKey] {
                Image(uiImage:img).resizable().aspectRatio(contentMode:.fill).frame(width:size,height:size).clipped()
            } else {
                ZStack{Color(.systemGray5);Image(systemName:"square.stack").foregroundStyle(.secondary)}.frame(width:size,height:size)
            }
        }
        .onAppear{ if let s=song { store.fetchArtIfNeeded(for:s) } }
    }
}
