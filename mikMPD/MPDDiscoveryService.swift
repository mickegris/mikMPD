// MPDDiscoveryService.swift
// Bonjour discovery of MPD servers (_mpd._tcp). MPD advertises itself when
// built with zeroconf support and zeroconf_enabled is on (the usual default).
// Requires NSBonjourServices + NSLocalNetworkUsageDescription in Info.plist.
import Foundation
import Combine
import Network

struct DiscoveredServer: Identifiable, Equatable {
    let name: String   // the advertised service name, e.g. "Music Player @ host"
    let host: String
    let port: Int
    var id: String { name }
}

final class MPDDiscoveryService: ObservableObject {
    @Published var servers: [DiscoveredServer] = []
    @Published var isBrowsing = false
    @Published var permissionDenied = false

    private var browser: NWBrowser?
    private var resolvers: [NWConnection] = []
    private var timeoutWork: DispatchWorkItem?
    private static let scanTimeout: TimeInterval = 10

    func start() {
        stop()
        servers = []
        permissionDenied = false
        isBrowsing = true
        let browser = NWBrowser(for: .bonjour(type: "_mpd._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .waiting(let error):
                // Typically the local-network permission prompt was denied
                if case .dns = error { self.permissionDenied = true }
                self.stop()
            case .failed:
                self.stop()
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var currentNames = Set<String>()
            for result in results {
                if case .service(let name, _, _, _) = result.endpoint {
                    currentNames.insert(name)
                    self.resolve(endpoint: result.endpoint, name: name)
                }
            }
            self.servers.removeAll { !currentNames.contains($0.name) }
        }
        // Main queue so the handlers can touch @Published state directly
        browser.start(queue: .main)
        self.browser = browser
        // Bonjour browsing never completes on its own; stop after a fixed
        // window so the UI can settle into "no servers found" + rescan.
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scanTimeout, execute: work)
    }

    func stop() {
        timeoutWork?.cancel(); timeoutWork = nil
        browser?.cancel(); browser = nil
        resolvers.forEach { $0.cancel() }; resolvers = []
        isBrowsing = false
    }

    /// Browse results carry unresolved service endpoints; a throwaway
    /// connection resolves one to host:port, then is cancelled.
    private func resolve(endpoint: NWEndpoint, name: String) {
        guard !servers.contains(where: { $0.name == name }) else { return }
        let conn = NWConnection(to: endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .ready:
                if let remote = conn.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = remote,
                   !self.servers.contains(where: { $0.name == name }) {
                    self.servers.append(DiscoveredServer(name: name,
                                                         host: Self.displayHost(host),
                                                         port: Int(port.rawValue)))
                    self.servers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                }
                conn.cancel()
            case .failed, .cancelled:
                self.resolvers.removeAll { $0 === conn }
            default:
                break
            }
        }
        resolvers.append(conn)
        conn.start(queue: .main)
    }

    /// Prefer readable host strings; strip IPv6 scope suffixes ("%en0").
    nonisolated static func displayHost(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let name, _):
            return name
        case .ipv4(let address):
            return "\(address)"
        case .ipv6(let address):
            return "\(address)".components(separatedBy: "%").first ?? "\(address)"
        @unknown default:
            return "\(host)"
        }
    }
}
