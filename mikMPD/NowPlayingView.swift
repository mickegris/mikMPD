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
            ScrollView {
                VStack(spacing: 24) {
                    connectionStatus
                    
                    albumArt
                        .frame(width: 260, height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
                        .padding(.top, 16)

                    songInfo

                    seekBar

                    transportButtons

                    volumeSlider

                    modeButtons

                    audioInfo
                }
                .padding(.bottom, 32)
            }
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onReceive(store.$volume) { localVolume = Double($0 < 0 ? 80 : $0) }
    }

    // MARK: - Subviews

    var connectionStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: store.isConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(store.isConnected ? .green : .red)
                .font(.caption)
            
            Text(store.isConnected 
                ? "Connected to \(store.host):\(store.portStr)"
                : "Not connected")
                .font(.caption)
                .foregroundColor(store.isConnected ? .secondary : .red)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(store.isConnected ? Color(.systemGray6) : Color.red.opacity(0.1))
        )
    }

    @ViewBuilder
    var albumArt: some View {
        if let img = store.albumArtCache[song.artKey] {
            Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(Color(.systemGray5))
                Image(systemName: "music.note").font(.system(size: 80)).foregroundStyle(.secondary)
            }
        }
    }

    var songInfo: some View {
        VStack(spacing: 4) {
            Text(song.displayTitle)
                .font(.title2.bold()).multilineTextAlignment(.center).lineLimit(2)
            Text(song.artist.isEmpty ? "Unknown Artist" : song.artist)
                .font(.subheadline).foregroundStyle(.secondary)
            if !song.album.isEmpty {
                Text(song.album).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal)
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
            .padding(.horizontal)
            .tint(.primary)

            HStack {
                Text(formatTime(displayElapsed))
                Spacer()
                Text(formatTime(store.duration))
            }
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            .padding(.horizontal)
        }
    }

    var transportButtons: some View {
        HStack(spacing: 44) {
            Button { store.previous() } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            Button { store.togglePlay() } label: {
                Image(systemName: store.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 66))
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.default, value: store.isPlaying)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            Button { store.next() } label: {
                Image(systemName: "forward.fill").font(.title)
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
        }.padding(.horizontal)
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
            .frame(minWidth: 60, minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(active ? Color.accentColor.opacity(0.15) : Color(.systemGray6)))
        }
    }
}

extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double { min(max(self, r.lowerBound), r.upperBound) }
}

