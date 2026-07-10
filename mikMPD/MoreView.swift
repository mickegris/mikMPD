import SwiftUI

struct MoreView: View {
    @EnvironmentObject var store: MPDStore
    @State private var showConnection = false
    
    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    QueueView()
                } label: {
                    HStack {
                        Image(systemName: "list.number")
                            .foregroundColor(.accentColor)
                            .frame(width: 28)
                        Text("Queue")
                    }
                }
                
                Button {
                    showConnection = true
                } label: {
                    HStack {
                        Image(systemName: "network")
                            .foregroundColor(.accentColor)
                            .frame(width: 28)
                        Text("Connection")
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
                
                NavigationLink {
                    OutputsView()
                } label: {
                    HStack {
                        Image(systemName: "speaker.wave.2")
                            .foregroundColor(.accentColor)
                            .frame(width: 28)
                        Text("Outputs & Partitions")
                    }
                }
                
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                            .foregroundColor(.secondary)
                    }
                    NavigationLink {
                        AcknowledgmentsView()
                    } label: {
                        Text("Acknowledgments")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("More")
        }
        .sheet(isPresented: $showConnection) {
            ConnectionView()
        }
    }
}

struct AcknowledgmentsView: View {
    var body: some View {
        List {
            Section {
                Text("mikMPD uses the following third-party services to display album art, artist information, and lyrics.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section("LRCLIB") {
                Text("Song lyrics (plain and time-synced) retrieved from LRCLIB, a free and open-source, community-maintained lyrics database. LRCLIB's data is released into the public domain, and its source code is available under the MIT license.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("lrclib.net", destination: URL(string: "https://lrclib.net")!)
                    .font(.caption)
            }
            Section("MusicBrainz") {
                Text("Music metadata used to locate album artwork. MusicBrainz data is released into the public domain under CC0.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("musicbrainz.org", destination: URL(string: "https://musicbrainz.org")!)
                    .font(.caption)
            }
            Section("Cover Art Archive") {
                Text("Album artwork sourced via the Cover Art Archive, a joint project of MusicBrainz and the Internet Archive. Individual images are provided under their respective licenses as specified by contributors.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("coverartarchive.org", destination: URL(string: "https://coverartarchive.org")!)
                    .font(.caption)
            }
            Section("Wikipedia") {
                Text("Artist biographies and images retrieved from Wikipedia. Text content is available under the Creative Commons Attribution-ShareAlike 4.0 (CC BY-SA 4.0) license. Images may be subject to individual licenses as specified on their Wikipedia file pages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("wikipedia.org", destination: URL(string: "https://www.wikipedia.org")!)
                    .font(.caption)
                Link("CC BY-SA 4.0 License", destination: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!)
                    .font(.caption)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Acknowledgments")
        .navigationBarTitleDisplayMode(.inline)
    }
}
