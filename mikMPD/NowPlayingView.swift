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

            ZStack {
                Text("Now Playing")
                    .font(.headline)
                HStack {
                    addToPlaylistButton
                    Spacer()
                    queueToggle
                    lyricsToggle
                }
            }
            .padding(.vertical, 6)

            Spacer(minLength: 0)

            // Tap-to-toggle lives on the art/lyrics panes, not the container —
            // a container gesture would swallow the queue list's row taps.
            Group {
                switch pane {
                case .art:    albumArt.onTapGesture { togglePane(.lyrics) }
                case .lyrics: lyricsPane.onTapGesture { togglePane(.lyrics) }
                case .queue:  queuePane
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)

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
                                .contentShape(Rectangle())
                                .onTapGesture { store.play(at: qSong.pos) }
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
            Text(song.displayTitle)
                .font(.title2.bold()).multilineTextAlignment(.center).lineLimit(2)
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

/// Single-line text that renders normally when it fits and auto-scrolls
/// (marquee) when it doesn't, so long album titles are readable in full.
/// State is reset via .id(text) whenever the text changes.
struct MarqueeText: View {
    let text: String
    var font: Font = .body
    var color: Color = .primary
    var underlined = false

    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var scrolling = false

    private let gap: CGFloat = 48
    private let pointsPerSecond: CGFloat = 30

    private var overflows: Bool { textWidth > boxWidth + 1 }

    var body: some View {
        // The (possibly truncated) base label defines height and available
        // width; a hidden fixed-size copy measures the full text width; the
        // scrolling pair overlays the base only when the text overflows.
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
            HStack(spacing: gap) {
                label.fixedSize()
                label.fixedSize()
            }
            .offset(x: scrolling ? -(textWidth + gap) : 0)
            .frame(width: boxWidth, alignment: .leading)
            .clipped()
            .animation(.linear(duration: Double((textWidth + gap) / pointsPerSecond))
                .repeatForever(autoreverses: false), value: scrolling)
            .onAppear { scrolling = true }
        }
    }
}

extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double { min(max(self, r.lowerBound), r.upperBound) }
}
