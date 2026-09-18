// MovePlaybackView.swift
// Roon-style "transfer zone": choose where the music should go. Each partition
// shows its enabled outputs and what it is doing, so a room that cannot play is
// visible before it is chosen rather than after.
import SwiftUI

struct MovePlaybackSheet: View {
    @EnvironmentObject var store: MPDStore
    @Environment(\.dismiss) private var dismiss
    @State private var summaries: [PartitionSummary] = []
    @State private var loading = true
    @State private var result: TransferResult?

    private var targets: [PartitionSummary] {
        summaries.filter { $0.name != store.currentPartition }
    }

    var body: some View {
        NavigationStack {
            List {
                if !store.canTransferQueue {
                    Section {
                        Label("Moving playback needs MPD’s stored-playlist support, which is off on this server. Set playlist_directory in mpd.conf and restart MPD.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                } else if store.queue.isEmpty {
                    Section {
                        Text("The queue is empty — there is nothing to move.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        if loading {
                            HStack { Spacer(); ProgressView(); Spacer() }
                        } else if targets.isEmpty {
                            Text("There is no other partition to move to.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(targets) { target in
                                Button { move(to: target.name) } label: {
                                    MovePlaybackRow(summary: target)
                                }
                                .buttonStyle(.plain)
                                .disabled(store.isTransferringQueue || target.enabledOutputs.isEmpty)
                            }
                        }
                    } header: {
                        Text("From \(store.currentPartition) to")
                    } footer: {
                        Text("The queue moves with its current song and position and keeps playing there; \(store.currentPartition) stops. If the new partition’s speakers are switched off, nothing is moved.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Move Playback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if store.isTransferringQueue {
                    ToolbarItem(placement: .confirmationAction) { ProgressView() }
                }
            }
            .alert(result?.alertTitle ?? "",
                   isPresented: Binding(get: { result != nil },
                                        set: { if !$0 { closeAfterAlert() } })) {
                Button("OK", role: .cancel) { closeAfterAlert() }
            } message: {
                Text(result?.alertMessage ?? "")
            }
            .onAppear {
                store.loadPartitionSummaries { summaries = $0; loading = false }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func move(to target: String) {
        store.transferQueue(toPartition: target) { outcome in
            if outcome.needsAttention { result = outcome } else { dismiss() }
        }
    }

    /// A moved queue with a note still closes the sheet once the note is read;
    /// a failure leaves it open so another partition can be chosen.
    private func closeAfterAlert() {
        let moved = result?.failure == nil
        result = nil
        if moved { dismiss() }
    }
}

private struct MovePlaybackRow: View {
    let summary: PartitionSummary

    private var canPlay: Bool { !summary.enabledOutputs.isEmpty }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hifispeaker.2")
                .foregroundStyle(canPlay ? Color.accentColor : Color.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.name)
                    .foregroundStyle(canPlay ? Color.primary : Color.secondary)
                Text(canPlay ? summary.enabledOutputs.joined(separator: ", ") : "No enabled outputs")
                    .font(.caption)
                    .foregroundStyle(canPlay ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }
            Spacer()
            Text(summary.stateLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
