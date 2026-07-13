import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject var store: MPDStore
    @Environment(\.dismiss) var dismiss
    @StateObject private var discovery = MPDDiscoveryService()
    @State private var formMode: ServerFormMode?
    @State private var serverToDelete: MPDServerProfile?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(store.servers) { server in
                        Button { store.switchToServer(server, force: true) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name)
                                    Text("\(server.host):\(String(server.port))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .foregroundStyle(.primary)
                                Spacer()
                                if server.id.uuidString == store.activeServerID {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { serverToDelete = server } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { formMode = .edit(server) } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                        }
                        .contextMenu {
                            Button { formMode = .edit(server) } label: {
                                Label("Edit…", systemImage: "pencil")
                            }
                        }
                    }
                    Button { formMode = .add } label: {
                        Label("Add Server…", systemImage: "plus")
                    }
                } header: {
                    Text("Servers")
                } footer: {
                    Text("Tap a server to connect. Swipe for edit and delete.")
                }
                Section {
                    if discovery.permissionDenied {
                        Text("Local network access denied. Allow it for mikMPD in Settings › Privacy & Security › Local Network.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(discovery.servers) { found in
                            Button { formMode = .discovered(found) } label: {
                                HStack {
                                    Image(systemName: "server.rack").foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(found.name).foregroundStyle(.primary)
                                        Text("\(found.host):\(String(found.port))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle").foregroundStyle(.secondary)
                                }
                            }
                        }
                        if discovery.isBrowsing {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Searching…").font(.subheadline).foregroundStyle(.secondary)
                            }
                        } else if discovery.servers.isEmpty {
                            Text("No servers found.").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if !discovery.isBrowsing {
                        Button { discovery.start() } label: {
                            Label("Scan Again", systemImage: "arrow.clockwise")
                        }
                    }
                } header: {
                    Text("Nearby Servers")
                } footer: {
                    Text("Servers appear here if MPD has Zeroconf enabled. Tap one to add it.")
                }
                Section("Status") {
                    HStack(spacing: 8) {
                        Circle().fill(store.isConnected ? .green : .red).frame(width: 10, height: 10)
                        Text(store.isConnected
                            ? "Connected to \(store.host):\(store.portStr)"
                            : (store.connectionError ?? "Not connected"))
                            .font(.subheadline).foregroundColor(store.isConnected ? .green : .red)
                    }
                }
            }
            .navigationTitle("Connection").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
            .onAppear { discovery.start() }
            .onDisappear { discovery.stop() }
            .sheet(item: $formMode) { mode in ServerFormView(mode: mode) }
            .alert("Delete Server?", isPresented: Binding(
                get: { serverToDelete != nil },
                set: { if !$0 { serverToDelete = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    if let server = serverToDelete { store.deleteServer(server) }
                    serverToDelete = nil
                }
                Button("Cancel", role: .cancel) { serverToDelete = nil }
            } message: {
                Text("“\(serverToDelete?.name ?? "")” and its password will be removed.")
            }
        }
    }
}

enum ServerFormMode: Identifiable {
    case add
    case discovered(DiscoveredServer)
    case edit(MPDServerProfile)
    var id: String {
        switch self {
        case .add: "add"
        case .discovered(let server): "discovered:\(server.id)"
        case .edit(let profile): profile.id.uuidString
        }
    }
}

struct ServerFormView: View {
    @EnvironmentObject var store: MPDStore
    @Environment(\.dismiss) var dismiss
    let mode: ServerFormMode
    @State private var name = ""
    @State private var host = ""
    @State private var port = "6600"
    @State private var pw = ""
    @State private var streamURL = ""

    private var isEdit: Bool { if case .edit = mode { true } else { false } }

    var body: some View {
        NavigationStack {
            Form {
                Section("MPD Server") {
                    LabeledContent("Name") {
                        TextField("Living room", text: $name)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Host") {
                        TextField("192.168.1.1 or hostname", text: $host)
                            .multilineTextAlignment(.trailing).keyboardType(.asciiCapable)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    LabeledContent("Port") {
                        TextField("6600", text: $port).multilineTextAlignment(.trailing).keyboardType(.numberPad)
                    }
                    LabeledContent("Password") {
                        SecureField("optional", text: $pw).multilineTextAlignment(.trailing)
                    }
                }
                Section("Phone Streaming") {
                    LabeledContent("Stream URL") {
                        TextField("http://host:port/", text: $streamURL)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.URL).autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    Text("URL of an MPD httpd output on this server. Enable \u{201C}Listen on phone\u{201D} in Now Playing to stream it to this device.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(isEdit ? "Edit Server" : "Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(); dismiss() }
                        .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                switch mode {
                case .add:
                    break
                case .discovered(let found):
                    name = found.name
                    host = found.host
                    port = String(found.port)
                case .edit(let profile):
                    name = profile.name
                    host = profile.host
                    port = String(profile.port)
                    streamURL = profile.streamURL
                    pw = store.password(forServer: profile.id)
                }
            }
        }
    }

    private func save() {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let displayName = trimmedName.isEmpty ? trimmedHost : trimmedName
        let trimmedStream = streamURL.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .add, .discovered:
            let profile = MPDServerProfile(name: displayName, host: trimmedHost,
                                           port: Int(port) ?? 6600, streamURL: trimmedStream)
            store.addServer(profile, password: pw)
        case .edit(var profile):
            profile.name = displayName
            profile.host = trimmedHost
            profile.port = Int(port) ?? 6600
            profile.streamURL = trimmedStream
            store.setPassword(pw, forServer: profile.id)
            store.updateServer(profile)
        }
    }
}
