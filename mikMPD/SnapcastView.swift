// SnapcastView.swift
import SwiftUI

struct SnapcastView: View {
    @EnvironmentObject var store: MPDStore
    @StateObject private var snap = SnapcastStore()

    // Local slider positions — synced from snap.groups, frozen per-client while dragging.
    @State private var localVolumes: [String: Double] = [:]

    private var activeProfile: MPDServerProfile? {
        store.servers.first { $0.id.uuidString == store.activeServerID }
    }
    private var snapHost: String {
        let h = activeProfile?.snapcastHost ?? ""
        return h.isEmpty ? store.host : h
    }
    private var snapPort: Int { activeProfile?.snapcastPort ?? 1705 }

    var body: some View {
        List {
            if !snap.isConnected {
                if let err = snap.connectionError {
                    ContentUnavailableView(
                        "Snapcast Unreachable",
                        systemImage: "hifispeaker.2.fill",
                        description: Text("\(err)\n\nCheck the Snapcast host in More → Connection → Edit Server.")
                    )
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowBackground(Color.clear)
                }
            } else {
                ForEach(snap.groups) { group in
                    groupSection(group)
                }
            }

            Section {
                HStack {
                    Image(systemName: "network")
                        .foregroundStyle(.secondary)
                    Text("\(snapHost):\(snapPort)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Snapcast")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            snap.connect(host: snapHost, port: snapPort)
        }
        .onDisappear { snap.disconnect() }
        .onChange(of: snap.groups) { _, newGroups in
            // Sync local volumes for non-dragging clients
            for group in newGroups {
                for client in group.clients {
                    if !snap.draggingClients.contains(client.id) {
                        localVolumes[client.id] = Double(client.volume.percent)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func groupSection(_ group: SnapGroup) -> some View {
        Section {
            // Group mute row
            HStack {
                Image(systemName: group.muted ? "speaker.slash.fill" : "speaker.2.fill")
                    .foregroundStyle(group.muted ? Color.secondary : Color.accentColor)
                    .frame(width: 24)
                Text("Mute group")
                Spacer()
                Toggle("", isOn: Binding(
                    get: { group.muted },
                    set: { snap.setGroupMute(groupID: group.id, muted: $0) }
                ))
                .labelsHidden()
            }

            ForEach(group.clients) { client in
                clientRow(client)
            }
        } header: {
            Text(group.displayName)
        } footer: {
            Text("Long press a client for options · Slider commits on release")
                .font(.caption2)
        }
    }

    @ViewBuilder
    private func clientRow(_ client: SnapClient) -> some View {
        let isDimmed = !client.connected
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(client.connected ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(client.displayName)
                    .fontWeight(.medium)
                Spacer()
                Button {
                    let muted = !client.volume.muted
                    snap.setVolume(clientID: client.id,
                                   percent: client.volume.percent,
                                   muted: muted)
                } label: {
                    Image(systemName: client.volume.muted ? "speaker.slash.fill" : "speaker.fill")
                        .foregroundStyle(client.volume.muted ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(isDimmed)
            }
            Slider(
                value: Binding(
                    get: { localVolumes[client.id] ?? Double(client.volume.percent) },
                    set: { localVolumes[client.id] = $0 }
                ),
                in: 0...100, step: 1
            ) { editing in
                if editing {
                    snap.beginDragging(clientID: client.id)
                } else {
                    snap.endDragging(clientID: client.id)
                    let pct = Int((localVolumes[client.id] ?? Double(client.volume.percent)).rounded())
                    snap.setVolume(clientID: client.id,
                                   percent: pct,
                                   muted: client.volume.muted)
                }
            }
            .disabled(isDimmed)
        }
        .opacity(isDimmed ? 0.4 : 1)
        .contextMenu {
            Button {
                snap.setVolume(clientID: client.id, percent: 100, muted: false)
                localVolumes[client.id] = 100
            } label: { Label("Set to Full Volume", systemImage: "speaker.wave.3.fill") }

            Button {
                let muted = !client.volume.muted
                snap.setVolume(clientID: client.id,
                               percent: client.volume.percent,
                               muted: muted)
            } label: {
                Label(client.volume.muted ? "Unmute" : "Mute",
                      systemImage: client.volume.muted ? "speaker.fill" : "speaker.slash.fill")
            }
        }
    }
}
