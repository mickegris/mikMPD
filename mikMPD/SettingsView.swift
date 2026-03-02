import SwiftUI
struct ConnectionView: View {
    @EnvironmentObject var store: MPDStore
    @Environment(\.dismiss) var dismiss
    @State private var host = ""; @State private var port = ""; @State private var pw = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("MPD Server") {
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
                Section {
                    Button("Connect") { store.host=host; store.portStr=port; store.password=pw; store.connect(); dismiss() }
                        .frame(maxWidth: .infinity, alignment: .center)
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
            .onAppear { host=store.host; port=store.portStr; pw=store.password }
        }
    }
}
