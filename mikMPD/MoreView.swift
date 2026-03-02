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
                        Text("1.0")
                            .foregroundColor(.secondary)
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
