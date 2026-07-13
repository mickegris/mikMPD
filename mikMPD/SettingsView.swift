import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject var store: MPDStore
    @Environment(\.dismiss) var dismiss
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
    case edit(MPDServerProfile)
    var id: String {
        switch self {
        case .add: "add"
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

    private var isAdd: Bool { if case .add = mode { true } else { false } }

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
            .navigationTitle(isAdd ? "Add Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(); dismiss() }
                        .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if case .edit(let profile) = mode {
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
        case .add:
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
