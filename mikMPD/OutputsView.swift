import SwiftUI
struct OutputsView: View {
    @EnvironmentObject var store: MPDStore
    @AppStorage("rememberPartitions") private var rememberPartitions = false
    @State private var showNewPartition = false
    @State private var transferTarget: String?
    @State private var transferResult: TransferResult?
    @State private var newPartitionName = ""
    @State private var partitionToDelete: String?
    @State private var partitionError: String?
    @State private var moveError: String?
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
                                            store.moveOutputToPartition(out.outputID, targetPartition: targetPartition) { err in
                                                moveError = err
                                            }
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
                partitionsSection
            }
            .listStyle(.insetGrouped).navigationTitle("Outputs")
            .confirmationDialog("Move playback?",
                                isPresented: Binding(get: { transferTarget != nil },
                                                     set: { if !$0 { transferTarget = nil } }),
                                titleVisibility: .visible) {
                if let target = transferTarget {
                    Button("Move to \(target)") {
                        store.transferQueue(toPartition: target) { if $0.needsAttention { transferResult = $0 } }
                        transferTarget = nil
                    }
                }
                Button("Cancel", role: .cancel) { transferTarget = nil }
            } message: {
                if let target = transferTarget {
                    Text("The queue moves from \(store.currentPartition) to \(target) and keeps playing from the same spot. \(store.currentPartition) stops.")
                }
            }
            .alert(transferResult?.alertTitle ?? "",
                   isPresented: Binding(get: { transferResult != nil },
                                        set: { if !$0 { transferResult = nil } })) {
                Button("OK", role: .cancel) { transferResult = nil }
            } message: {
                Text(transferResult?.alertMessage ?? "")
            }
            .alert("New Partition", isPresented: $showNewPartition) {
                TextField("Name", text: $newPartitionName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Create") {
                    store.createPartition(newPartitionName) { partitionError = $0 }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Delete Partition?", isPresented: Binding(
                get: { partitionToDelete != nil },
                set: { if !$0 { partitionToDelete = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    if let name = partitionToDelete {
                        store.deletePartition(name) { partitionError = $0 }
                    }
                    partitionToDelete = nil
                }
                Button("Cancel", role: .cancel) { partitionToDelete = nil }
            } message: {
                Text("“\(partitionToDelete ?? "")” must be empty — move its outputs out and disconnect other clients first.")
            }
            .alert("Partition Error", isPresented: Binding(
                get: { partitionError != nil },
                set: { if !$0 { partitionError = nil } }
            )) {
                Button("OK", role: .cancel) { partitionError = nil }
            } message: {
                Text(partitionError ?? "")
            }
            .alert("Move Failed", isPresented: Binding(
                get: { moveError != nil },
                set: { if !$0 { moveError = nil } }
            )) {
                Button("OK", role: .cancel) { moveError = nil }
            } message: {
                Text(moveError ?? "")
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { store.loadOutputs(); store.loadPartitions() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
        .onAppear { store.loadPartitions(); store.loadOutputs() }
    }

    // Extracted so the type checker can cope: inlined, this section pushed
    // the enclosing List past its inference budget.
    @ViewBuilder
    private var partitionsSection: some View {
        if !store.partitions.isEmpty {
            Section {
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
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if name != "default" && name != store.currentPartition {
                            Button(role: .destructive) { partitionToDelete = name } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        if store.canTransferQueue && name != store.currentPartition {
                            Button { transferTarget = name } label: {
                                Label("Move playback", systemImage: "arrow.left.arrow.right")
                            }.tint(.blue)
                        }
                    }
                }
                Button {
                    newPartitionName = ""
                    showNewPartition = true
                } label: {
                    Label("New Partition…", systemImage: "plus")
                }
            } header: {
                Text("Partitions")
            } footer: {
                // The one place the app talks about mpd.conf, and it earns
                // it: without this the feature looks broken for a reason
                // nothing on screen explains.
                Text(store.canTransferQueue
                     ? "Tap to switch. Swipe to move the playing queue to another partition, or to delete an empty one."
                     : "Moving a queue between partitions needs MPD\u{2019}s stored-playlist support, which is off on this server. Set playlist_directory in mpd.conf and restart MPD.")
            }
        }
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
