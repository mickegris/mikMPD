import SwiftUI
struct OutputsView: View {
    @EnvironmentObject var store: MPDStore
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.outputs.isEmpty {
                        Text("No outputs").foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 8)
                    } else {
                        ForEach(store.outputs) { out in
                            OutputRow(output: out) { store.toggleOutput(out.outputID) }
                        }
                    }
                } header: { Text("Audio Outputs") }
                  footer: { Text("Toggle to enable or disable.") }
                if !store.partitions.isEmpty {
                    Section("Partitions") {
                        ForEach(store.partitions, id: \.self) { name in
                            Button { store.switchPartition(name) } label: {
                                HStack {
                                    Image(systemName: "square.split.2x1").foregroundColor(.accentColor)
                                    Text(name).foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "arrow.right.circle").foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped).navigationTitle("Outputs")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { store.loadOutputs(); store.loadPartitions() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
    }
}
struct OutputRow: View {
    let output: MPDOutput; let onToggle: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: output.enabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .foregroundColor(output.enabled ? .accentColor : .secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(output.name).font(.subheadline)
                if !output.plugin.isEmpty { Text(output.plugin).font(.caption).foregroundColor(.secondary) }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { output.enabled }, set: { _ in onToggle() })).labelsHidden()
        }.padding(.vertical, 4)
    }
}
