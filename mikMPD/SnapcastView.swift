// SnapcastView.swift
import SwiftUI

struct SnapcastView: View {
    @EnvironmentObject var store: MPDStore
    @StateObject private var snap = SnapcastStore()

    // Local slider positions — synced from snap.groups, frozen per-client while dragging.
    @State private var localVolumes: [String: Double] = [:]

    // Disconnected-client visibility filter (off by default — connected clients only)
    @State private var showDisconnected = false

    // Rename alert state
    @State private var renameClientID: String? = nil
    @State private var renameText = ""

    // Latency alert state
    @State private var latencyClientID: String? = nil
    @State private var latencyText = ""

    private var activeProfile: MPDServerProfile? {
        store.servers.first { $0.id.uuidString == store.activeServerID }
    }
    private var snapHost: String {
        let h = activeProfile?.snapcastHost ?? ""
        return h.isEmpty ? store.host : h
    }
    private var snapPort: Int { activeProfile?.snapcastPort ?? 1705 }

    private var visibleGroups: [SnapGroup] {
        snap.groups.filter { group in
            showDisconnected || group.clients.contains(where: { $0.connected })
        }
    }

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
                ForEach(visibleGroups) { group in
                    groupSection(group)
                }
            }

            Section {
                Toggle(isOn: $showDisconnected) {
                    Label("Show disconnected clients", systemImage: "person.slash")
                }
                HStack {
                    Image(systemName: "network").foregroundStyle(.secondary)
                    Text(verbatim: "\(snapHost):\(snapPort)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Snapcast")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { snap.connect(host: snapHost, port: snapPort) }
        .onDisappear { snap.disconnect() }
        .onChange(of: store.activeServerID) { _, _ in
            snap.connect(host: snapHost, port: snapPort)
        }
        .onChange(of: snap.groups) { _, newGroups in
            for group in newGroups {
                for client in group.clients where !snap.draggingClients.contains(client.id) {
                    localVolumes[client.id] = Double(client.volume.percent)
                }
            }
        }
        // Rename alert
        .alert("Rename Client", isPresented: Binding(
            get: { renameClientID != nil },
            set: { if !$0 { renameClientID = nil } }
        )) {
            TextField("Name", text: $renameText)
                .autocorrectionDisabled()
            Button("Rename") {
                if let id = renameClientID, !renameText.isEmpty {
                    snap.setClientName(clientID: id, name: renameText)
                }
                renameClientID = nil
            }
            Button("Cancel", role: .cancel) { renameClientID = nil }
        } message: {
            Text("Enter a display name for this client.")
        }
        // Latency alert
        .alert("Set Latency", isPresented: Binding(
            get: { latencyClientID != nil },
            set: { if !$0 { latencyClientID = nil } }
        )) {
            TextField("0", text: $latencyText).keyboardType(.numberPad)
            Button("Set") {
                if let id = latencyClientID, let ms = Int(latencyText), ms >= 0 {
                    snap.setLatency(clientID: id, latency: ms)
                }
                latencyClientID = nil
            }
            Button("Cancel", role: .cancel) { latencyClientID = nil }
        } message: {
            Text("Milliseconds of audio delay (0 = no delay). Use to sync this client with others.")
        }
    }

    @ViewBuilder
    private func groupSection(_ group: SnapGroup) -> some View {
        let visibleClients = group.clients.filter { showDisconnected || $0.connected }
        Section {
            // Stream selector — only shown when multiple streams exist.
            // Uses Menu+Button instead of Picker so each option is a discrete committing tap.
            let streams = snap.streams
            if streams.count > 1 {
                Menu {
                    ForEach(streams) { s in
                        Button {
                            snap.setGroupStream(groupID: group.id, streamID: s.id)
                        } label: {
                            Label(s.id, systemImage: group.streamID == s.id ? "checkmark" : "music.note")
                        }
                    }
                } label: {
                    LabeledContent("Stream", value: group.streamID)
                }
            }

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

            ForEach(visibleClients) { client in
                clientRow(client, group: group)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !client.connected {
                            Button(role: .destructive) {
                                snap.deleteClient(clientID: client.id)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
            }
        } header: {
            Text(group.displayName)
        } footer: {
            if showDisconnected {
                Text("Long press a client for options · Swipe left to remove disconnected clients")
                    .font(.caption2)
            } else {
                Text("Long press a client for options")
                    .font(.caption2)
            }
        }
    }

    @ViewBuilder
    private func clientRow(_ client: SnapClient, group: SnapGroup) -> some View {
        let isDimmed = !client.connected
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(client.connected ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(client.displayName).fontWeight(.medium)
                if client.latency != 0 {
                    Text("+\(client.latency) ms")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    snap.setVolume(clientID: client.id,
                                   percent: client.volume.percent,
                                   muted: !client.volume.muted)
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
            Section {
                Button {
                    snap.setVolume(clientID: client.id, percent: 100, muted: false)
                    localVolumes[client.id] = 100
                } label: { Label("Set to Full Volume", systemImage: "speaker.wave.3.fill") }

                Button {
                    snap.setVolume(clientID: client.id,
                                   percent: client.volume.percent,
                                   muted: !client.volume.muted)
                } label: {
                    Label(client.volume.muted ? "Unmute" : "Mute",
                          systemImage: client.volume.muted ? "speaker.fill" : "speaker.slash.fill")
                }
            }

            Section {
                Button {
                    renameText = client.displayName
                    renameClientID = client.id
                } label: { Label("Rename…", systemImage: "pencil") }

                Button {
                    latencyText = "\(client.latency)"
                    latencyClientID = client.id
                } label: { Label("Set Latency…", systemImage: "timer") }

                let otherGroups = snap.groups.filter { $0.id != group.id }
                if !otherGroups.isEmpty {
                    Menu("Move to Group") {
                        ForEach(otherGroups) { otherGroup in
                            Button(otherGroup.displayName) {
                                snap.moveClient(clientID: client.id,
                                                fromGroupID: group.id,
                                                toGroupID: otherGroup.id)
                            }
                        }
                    }
                }
            }

            if !client.connected {
                Section {
                    Button(role: .destructive) {
                        snap.deleteClient(clientID: client.id)
                    } label: { Label("Remove from Server", systemImage: "trash") }
                }
            }
        }
    }
}
