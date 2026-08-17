// DiagnosticsView.swift
// Read-only view of the recent MPD command log, so a stall or a hung daemon can be
// diagnosed after the fact. See plans/mpd-hang-investigation.md.
import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject var store: MPDStore
    @State private var entries: [MPDCommandLogEntry] = []
    @State private var copied = false
    @State private var confirmClearArt = false
    @State private var artCleared = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        List {
            Section {
                if entries.isEmpty {
                    Text("No commands recorded yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(e.command)
                                    .font(.caption.monospaced())
                                    .lineLimit(2)
                                Spacer()
                                Text(String(format: "%.0f ms", e.duration * 1000))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(e.isSlow ? Color.orange : Color.secondary)
                            }
                            HStack(spacing: 6) {
                                Text(Self.timeFormatter.string(from: e.at))
                                Text("·")
                                Text(e.outcome).lineLimit(1)
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 1)
                    }
                }
            } header: {
                Text("Recent MPD Commands")
            } footer: {
                Text("Newest first, up to 250 entries. Anything slower than 2 s is highlighted — that is where to look first if the server stalls or stops responding.")
            }
            Section {
                Button(role: .destructive) { confirmClearArt = true } label: {
                    Label("Clear Album Art Cache", systemImage: "photo.badge.arrow.down")
                }
            } footer: {
                Text("Deletes every cached cover and every \"no art found\" marker. Albums whose art failed to load are not retried for 7 days, so clearing the cache is the way to make them try again.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        UIPasteboard.general.string = MPDCommandLog.shared.plainText()
                        copied = true
                    } label: { Label("Copy Log", systemImage: "doc.on.doc") }
                    Button { entries = MPDCommandLog.shared.recent } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) {
                        MPDCommandLog.shared.clear()
                        entries = []
                    } label: { Label("Clear", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .alert("Copied", isPresented: $copied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The command log is on the clipboard.")
        }
        .alert("Clear Album Art Cache?", isPresented: $confirmClearArt) {
            Button("Clear", role: .destructive) {
                store.clearAlbumArtCache()
                artCleared = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Covers will be fetched again as you browse. This can take a while on a large library.")
        }
        .alert("Album Art Cache Cleared", isPresented: $artCleared) {
            Button("OK", role: .cancel) {}
        }
        .onAppear { entries = MPDCommandLog.shared.recent }
    }
}
