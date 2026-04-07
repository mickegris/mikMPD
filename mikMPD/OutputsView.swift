import SwiftUI
struct OutputsView: View {
    @EnvironmentObject var store: MPDStore
    @AppStorage("rememberPartitions") private var rememberPartitions = false
    var body: some View {
        NavigationStack {
            List {
                if !store.currentPartition.isEmpty {
                    Section {
                        HStack {
                            Image(systemName: "square.split.2x1")
                                .foregroundColor(.accentColor)
                            Text("Active partition:")
                                .foregroundColor(.secondary)
                            Text(store.currentPartition)
                                .fontWeight(.medium)
                        }
                        .font(.subheadline)
                    }
                }
                
                Section {
                    if store.outputs.isEmpty {
                        Text("No outputs").foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 8)
                    } else {
                        ForEach(store.outputs) { out in
                            OutputRow(
                                output: out,
                                onToggle: { store.toggleOutput(out.outputID) }
                            )
                            .contextMenu {
                                let outputPartition = store.outputPartitions[out.outputID]
                                
                                if let part = outputPartition {
                                    Text("Output in: \(part)").font(.caption).foregroundColor(.secondary)
                                    
                                    Divider()
                                    
                                    // Show move options for all partitions except the one it's currently in
                                    ForEach(store.partitions.filter { $0 != part }, id: \.self) { targetPartition in
                                        Button {
                                            store.moveOutputToPartition(out.outputID, targetPartition: targetPartition)
                                        } label: {
                                            Label("Move to \(targetPartition)", systemImage: "arrow.right.circle")
                                        }
                                    }
                                } else {
                                    Text("Partition: unknown").font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                } header: { Text("Audio Outputs") }
                  footer: {
                      if store.partitions.count > 1 {
                          Text("Toggle to enable/disable. Long press to move between partitions.")
                      } else {
                          Text("Toggle to enable or disable.")
                      }
                  }
                if !store.partitions.isEmpty {
                    Section("Partitions") {
                        Toggle("Remember partitions between restarts", isOn: $rememberPartitions)
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
        .onAppear { store.loadPartitions(); store.loadOutputs() }
    }
}
struct OutputRow: View {
    let output: MPDOutput
    let onToggle: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: output.enabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .foregroundColor(output.enabled ? .accentColor : .secondary)
                .frame(width: 28)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(output.name).font(.subheadline)
                if !output.plugin.isEmpty {
                    Text(output.plugin)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Toggle("", isOn: Binding(get: { output.enabled }, set: { _ in onToggle() }))
                .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}
