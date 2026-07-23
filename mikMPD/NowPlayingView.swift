// NowPlayingView.swift
// Reads store.elapsed, store.isPlaying etc directly — no @State bridging.
// The store's display timer drives elapsed; this view just renders it.
import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject var store: MPDStore

    // Slider drag state — only active while finger is on the slider
    @State private var dragging     = false
    @State private var dragFraction = 0.0   // 0..1

    // Local volume copy (synced from store, committed on release)
    @State private var localVolume  = 80.0

    // What fills the square region: artwork, lyrics, or the queue
    enum Pane { case art, lyrics, queue }
    @State private var pane: Pane = .art

    // Presents the shared "Add to Playlist" sheet for the current song
    @State private var addRequest: AddToPlaylistRequest?

    // Presents ConnectionView from the "no server configured" banner
    @State private var showConnection = false

    // Presents the Recently Played sheet
    @State private var showHistory = false

    var song: MPDSong { store.currentSong }

    // What fraction to show in the slider
    var sliderFraction: Double {
        if dragging { return dragFraction }
        guard store.duration > 0 else { return 0 }
        return (store.elapsed / store.duration).clamped(to: 0...1)
    }

    // What time to show in the elapsed label
    var displayElapsed: Double {
        dragging ? dragFraction * store.duration : store.elapsed
    }

    var body: some View {
        NavigationStack {
        VStack(spacing: 0) {
            connectionStatus
                .padding(.top, 8)

            Spacer(minLength: 8)

            // Buttons flank the art instead of crowding a header row — the
            // square pane is height-bound on most layouts, so the side gutters
            // are otherwise unused space. Fixed column widths keep the pane
            // centered even when the playlist button is hidden (CD source).
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 18) {
                    addToPlaylistButton
                    historyButton
                }
                .frame(width: 30)

                // No tap-to-toggle on the panes: accidental art taps kept
                // flipping to lyrics. The flanking buttons are the only toggles.
                Group {
                    switch pane {
                    case .art:    albumArt
                    case .lyrics: lyricsPane
                    case .queue:  queuePane
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)

                VStack(spacing: 18) {
                    queueToggle
                    lyricsToggle
                }
                .frame(width: 30)
            }

            Spacer(minLength: 4)

            VStack(spacing: 8) {
                songInfo
                seekBar
                transportButtons
                volumeSlider
                modeButtons
                audioInfo
                phoneStreamToggle
            }
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 20)
        .sheet(item: $addRequest) { AddToPlaylistSheet(uris: $0.uris) }
        .onReceive(store.$volume) { localVolume = Double($0 < 0 ? 80 : $0) }
        } // NavigationStack
    }

    // CD tracks can't live in stored playlists; stream URLs can.
    @ViewBuilder
    var addToPlaylistButton: some View {
        if !song.file.isEmpty && song.sourceKind != .cd {
            Button { addRequest = AddToPlaylistRequest(uris: [song.file]) } label: {
                Image(systemName: "text.badge.plus")
                    .font(.body)
            }
        }
    }

    var historyButton: some View {
        Button { showHistory = true } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.body)
        }
        .accessibilityLabel("Recently played")
        .sheet(isPresented: $showHistory) { RecentlyPlayedSheet() }
    }

    // MARK: - Subviews

    @ViewBuilder
    var connectionStatus: some View {
        if !store.isConfigured {
            // Persistent setup affordance after dismissing the first-run prompt.
            Button { showConnection = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text("No MPD server configured — tap to set up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray6)))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showConnection) { ConnectionView() }
        } else {
            HStack(spacing: 8) {
                Image(systemName: store.isConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(store.isConnected ? .green : .red)
                    .font(.caption)

                VStack(alignment: .leading, spacing: 2) {
                    Text(store.isConnected
                        ? "Connected to \(store.host):\(store.portStr)"
                        : "Not connected")
                    .font(.caption)
                    .foregroundColor(store.isConnected ? .secondary : .red)

                    if store.isConnected {
                        Text("Partition: \(store.currentPartition)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(store.isConnected ? Color(.systemGray6) : Color.red.opacity(0.1))
            )
        }
    }

    @ViewBuilder
    var albumArt: some View {
        if let img = store.albumArtCache[song.artKey] {
            Color.clear.overlay {
                Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
            }.clipped()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(Color(.systemGray5))
                Image(song.fallbackArtAssetName)
                    .resizable()
                    .scaledToFit()
                    .padding(32)
            }
        }
    }

    // MARK: - Lyrics

    /// Switch to the given pane, or back to the artwork when it's already showing.
    func togglePane(_ p: Pane) {
        withAnimation(.easeInOut(duration: 0.25)) { pane = (pane == p) ? .art : p }
        if pane == .queue { store.loadQueue() }
    }

    var lyricsToggle: some View {
        Button {
            togglePane(.lyrics)
        } label: {
            Image(systemName: pane == .lyrics ? "quote.bubble.fill" : "quote.bubble")
                .font(.body)
                .foregroundStyle(pane == .lyrics ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pane == .lyrics ? "Hide lyrics" : "Show lyrics")
    }

    // MARK: - Queue pane

    var queueToggle: some View {
        Button {
            togglePane(.queue)
        } label: {
            Image(systemName: pane == .queue ? "list.bullet.circle.fill" : "list.bullet")
                .font(.body)
                .foregroundStyle(pane == .queue ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pane == .queue ? "Hide queue" : "Show queue")
    }

    var queuePane: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Color(.systemGray6))
            if store.queue.isEmpty {
                ContentUnavailableView("Queue is Empty", systemImage: "list.bullet")
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(store.queue) { qSong in
                            QueueRow(song: qSong, isCurrent: qSong.pos == store.playlistPos)
                                .playableRow{ store.play(at: qSong.pos) }
                                .listRowBackground(qSong.pos == store.playlistPos
                                    ? Color.accentColor.opacity(0.12) : Color.clear)
                                .id(qSong.pos)
                        }
                        .onDelete { store.delete(at: $0) }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .onAppear { scrollToCurrent(proxy, animated: false) }
                    .onChange(of: store.playlistPos) { _, _ in scrollToCurrent(proxy, animated: true) }
                }
            }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy, animated: Bool) {
        guard store.playlistPos >= 0 else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(store.playlistPos, anchor: .center) }
        } else {
            proxy.scrollTo(store.playlistPos, anchor: .center)
        }
    }

    var lyricsPane: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Color(.systemGray6))
            lyricsContent.padding(16)
        }
    }

    @ViewBuilder
    var lyricsContent: some View {
        switch store.lyricsState {
        case .loading:
            ProgressView()
        case .unavailable:
            lyricsNote("text.quote", "No lyrics available")
        case .loaded(let lyrics):
            if lyrics.instrumental {
                lyricsNote("music.note", "Instrumental")
            } else if let synced = lyrics.synced, !synced.isEmpty {
                syncedLyricsView(synced)
            } else if let plain = lyrics.plain {
                ScrollView {
                    Text(plain)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
            } else {
                lyricsNote("text.quote", "No lyrics available")
            }
        }
    }

    func lyricsNote(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.title).foregroundStyle(.secondary)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    /// Scrolling synced lyrics with the active line highlighted, kept centered.
    func syncedLyricsView(_ lines: [LyricLine]) -> some View {
        let t = store.elapsed - LyricsService.syncOffset
        let active = lines.lastIndex { $0.secs <= t }
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(i == active ? .body.bold() : .callout)
                            .foregroundStyle(i == active ? Color.accentColor : Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .padding(.vertical, 8)
            }
            .animation(.easeInOut(duration: 0.2), value: active)
            .onChange(of: active) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    var songInfo: some View {
        VStack(spacing: 4) {
            MarqueeText(text: song.displayTitle, font: .title2.bold(), color: .primary)
            if !song.artist.isEmpty {
                NavigationLink(destination: ArtistDetailView(artist: song.artist)) {
                    Text(song.artist)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .underline()
                }
            } else {
                Text("Unknown Artist")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if !song.album.isEmpty {
                NavigationLink(destination: AlbumDetailView(album: song.album, artist: song.artist.isEmpty ? nil : song.artist)) {
                    MarqueeText(text: song.album, font: .caption, color: .secondary, underlined: true)
                }
            }
            if let ctx = store.playbackContext {
                NavigationLink(destination: PlaylistDetailView(name: ctx)) {
                    Label("Playing from \(ctx)", systemImage: "music.note.list")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    var seekBar: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { sliderFraction },
                    set: { dragFraction = $0 }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if editing {
                        dragging = true
                    } else {
                        let target = dragFraction * store.duration
                        dragging = false
                        store.seek(to: target)
                    }
                }
            )
            .tint(.primary)

            HStack {
                Text(formatTime(displayElapsed))
                Spacer()
                Text(formatTime(store.duration))
            }
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    var transportButtons: some View {
        HStack(spacing: 36) {
            Button { store.previous() } label: {
                Image(systemName: "backward.fill").font(.title2)
            }
            Button { store.togglePlay() } label: {
                Image(systemName: store.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 54))
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.default, value: store.isPlaying)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            Button { store.stop() } label: {
                Image(systemName: "stop.fill").font(.title2)
            }
            Button { store.next() } label: {
                Image(systemName: "forward.fill").font(.title2)
            }
        }
        .foregroundStyle(.primary)
    }

    var volumeSlider: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
            Slider(value: $localVolume, in: 0...100,
                   onEditingChanged: { if !$0 { store.setVolume(localVolume) } })
                .tint(.gray)
            Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
        }
    }

    var modeButtons: some View {
        HStack(spacing: 10) {
            ModeBtn("Repeat",  "repeat",                "repeat",             store.repeatMode)  { store.toggleRepeat()  }
            ModeBtn("Shuffle", "shuffle",               "shuffle",            store.randomMode)  { store.toggleRandom()  }
            ModeBtn("Single",  "1.circle.fill",         "1.circle",           store.singleMode)  { store.toggleSingle()  }
            ModeBtn("Consume", "fork.knife.circle.fill","fork.knife.circle",  store.consumeMode) { store.toggleConsume() }
        }
    }

    @ViewBuilder
    var audioInfo: some View {
        let parts = [
            store.bitrate.isEmpty  ? nil : "\(store.bitrate) kbps",
            store.audioFmt.isEmpty ? nil : store.audioFmt
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: "  ·  "))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    var phoneStreamToggle: some View {
        let hasURL = !store.httpStreamURL.trimmingCharacters(in: .whitespaces).isEmpty
        Button { store.togglePhoneStream() } label: {
            HStack(spacing: 8) {
                Image(systemName: store.isPhoneStreaming ? "iphone.radiowaves.left.and.right" : "iphone")
                Text(store.isPhoneStreaming ? "Streaming to phone" : "Listen on phone")
            }
            .font(.caption)
            .foregroundStyle(store.isPhoneStreaming ? Color.accentColor : .secondary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(store.isPhoneStreaming
                ? Color.accentColor.opacity(0.15) : Color(.systemGray6)))
        }
        .buttonStyle(.plain)
        .disabled(!hasURL)
        .opacity(hasURL ? 1 : 0.5)
    }
}

struct ModeBtn: View {
    let label, sfOn, sfOff: String
    let active: Bool
    let action: () -> Void
    init(_ label: String, _ sfOn: String, _ sfOff: String, _ active: Bool, action: @escaping () -> Void) {
        self.label = label; self.sfOn = sfOn; self.sfOff = sfOff; self.active = active; self.action = action
    }
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: active ? sfOn : sfOff).font(.title3)
                Text(label).font(.caption2)
            }
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
            .frame(minWidth: 60, minHeight: 40)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(active ? Color.accentColor.opacity(0.15) : Color(.systemGray6)))
        }
    }
}

/// Client-side listening history (MPD has no history command — only what
/// played while the app was connected is captured). Albums tab: grid of album tiles;
/// Tracks tab: per-track list with tap-to-play and swipe actions.
struct RecentlyPlayedSheet: View {
    @EnvironmentObject var store: MPDStore
    @Environment(\.dismiss) var dismiss
    @State private var addRequest: AddToPlaylistRequest?
    @State private var showAlbums = true

    private var albums: [RecentAlbum] { recentAlbumGroups(store.recentlyPlayed) }

    var body: some View {
        NavigationStack {
            Group {
                if store.recentlyPlayed.isEmpty {
                    ContentUnavailableView("Nothing Played Yet", systemImage: "clock.arrow.circlepath",
                        description: Text("Songs appear here after they've played for a while."))
                } else {
                    VStack(spacing: 0) {
                        Picker("", selection: $showAlbums) {
                            Text("Albums").tag(true)
                            Text("Tracks").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .padding([.horizontal, .top])

                        if showAlbums {
                            albumGridView
                        } else {
                            trackListView
                        }
                    }
                }
            }
            .navigationTitle("Recently Played").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Clear", role: .destructive) { store.clearRecentlyPlayed() }
                        .disabled(store.recentlyPlayed.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $addRequest) { AddToPlaylistSheet(uris: $0.uris) }
        }
        .presentationDetents([.medium, .large])
    }

    private var albumGridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 16) {
                ForEach(albums) { ra in
                    albumTile(ra)
                }
            }
            .padding()
            Text("Long press a tile for album options")
                .font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func albumTile(_ ra: RecentAlbum) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if ra.albumless {
                    Button { store.addAndPlay(uri: ra.file) } label: {
                        ArtThumbByKey(artist: ra.artist, album: ra.album, size: 110).cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink(destination: AlbumDetailView(
                        album: ra.album, artist: ra.artist.isEmpty ? nil : ra.artist)) {
                        ArtThumbByKey(artist: ra.artist, album: ra.album, size: 110).cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(ra.albumless ? ra.title : ra.album)
                .font(.subheadline).lineLimit(2)
            if !ra.artist.isEmpty {
                Text(ra.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(relativeDay(ra.lastPlayed))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .contextMenu {
            if !ra.albumless {
                Button {
                    store.albumSongs(album: ra.album, artist: ra.artist.isEmpty ? nil : ra.artist) { songs in
                        store.enqueue(songs: songs, replace: true, playFirst: true)
                    }
                } label: { Label("Play Album", systemImage: "play.fill") }
                Button {
                    store.albumSongs(album: ra.album, artist: ra.artist.isEmpty ? nil : ra.artist) { songs in
                        store.enqueue(songs: songs)
                    }
                } label: { Label("Add to Queue", systemImage: "plus") }
                Button {
                    store.albumSongs(album: ra.album, artist: ra.artist.isEmpty ? nil : ra.artist) { songs in
                        addRequest = AddToPlaylistRequest(uris: songs.map(\.file))
                    }
                } label: { Label("Add to Playlist…", systemImage: "music.note.list") }
            }
        }
    }

    private var trackListView: some View {
        List(store.recentlyPlayed) { entry in
            HStack(spacing: 10) {
                ArtThumbByKey(artist: entry.artist, album: entry.album, size: 44).cornerRadius(4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.subheadline).lineLimit(1)
                    HStack(spacing: 4) {
                        if !entry.artist.isEmpty {
                            NavigationLink(destination: ArtistDetailView(artist: entry.artist)) {
                                Text(entry.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1).underline()
                            }.buttonStyle(.plain)
                        }
                        if !entry.artist.isEmpty && !entry.album.isEmpty {
                            Text("·").font(.caption).foregroundStyle(.secondary)
                        }
                        if !entry.album.isEmpty {
                            NavigationLink(destination: AlbumDetailView(album: entry.album, artist: entry.artist.isEmpty ? nil : entry.artist)) {
                                Text(entry.album).font(.caption).foregroundStyle(.secondary).lineLimit(1).underline()
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Spacer()
                if entry.file == store.currentSong.file {
                    Image(systemName: "speaker.wave.2.fill").font(.caption2).foregroundStyle(.tint)
                }
                Text(relativeDay(entry.playedAt))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .playableRow{ store.addAndPlay(uri: entry.file) }
            .swipeActions(edge: .trailing) {
                Button { store.add(uri: entry.file) } label: {
                    Label("Add", systemImage: "plus")
                }.tint(.green)
            }
            .swipeActions(edge: .leading) {
                // CD tracks can't live in stored playlists
                if !entry.file.lowercased().hasPrefix("cdda") {
                    Button { addRequest = AddToPlaylistRequest(uris: [entry.file]) } label: {
                        Label("Playlist", systemImage: "music.note.list")
                    }.tint(.indigo)
                }
            }
        }
        .listStyle(.plain)
    }
}

/// Single-line text that renders normally when it fits and ping-pongs when it
/// doesn't (scroll to the end, dwell, scroll back), so long names are readable
/// in full. Driven by PhaseAnimator — a `.animation(value:)` + repeatForever
/// combination gets cancelled by Now Playing's 10 Hz elapsed re-renders and by
/// identity churn on song change, which froze the scroll. State resets via
/// .id(text) whenever the text changes.
struct MarqueeText: View {
    let text: String
    var font: Font = .body
    var color: Color = .primary
    var underlined = false

    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0

    private let pointsPerSecond: CGFloat = 30

    private var overflows: Bool { textWidth > boxWidth + 1 }

    var body: some View {
        // The (possibly truncated) base label defines height and available
        // width; a hidden fixed-size copy measures the full text width; the
        // animated copy overlays the base only when the text overflows.
        label
            .lineLimit(1)
            .opacity(overflows ? 0 : 1)
            .background(
                label.fixedSize().hidden().background(GeometryReader { g in
                    Color.clear.onAppear { textWidth = g.size.width }
                })
            )
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { boxWidth = g.size.width }
                    .onChange(of: g.size.width) { _, w in boxWidth = w }
            })
            .overlay(marquee)
            .id(text)
    }

    private var label: some View {
        Text(text).font(font).foregroundStyle(color).underline(underlined)
    }

    @ViewBuilder private var marquee: some View {
        if overflows {
            let distance = textWidth - boxWidth
            // Trigger-less PhaseAnimator cycles forever: start → end → start …
            // The delay gives a readable dwell at each end.
            PhaseAnimator([false, true]) { atEnd in
                label.fixedSize()
                    .offset(x: atEnd ? -distance : 0)
                    .frame(width: boxWidth, alignment: .leading)
                    .clipped()
            } animation: { _ in
                .linear(duration: max(1.0, Double(distance / pointsPerSecond))).delay(0.8)
            }
        }
    }
}

extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double { min(max(self, r.lowerBound), r.upperBound) }
}
