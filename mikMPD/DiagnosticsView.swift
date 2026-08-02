// DiagnosticsView.swift
// Read-only view of the recent MPD command log, so a stall or a hung daemon can be
// diagnosed after the fact. See plans/mpd-hang-investigation.md.
import SwiftUI

struct DiagnosticsView: View {
    @State private var entries: [MPDCommandLogEntry] = []
    @State private var copied = false

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
        .onAppear { entries = MPDCommandLog.shared.recent }
    }
}
