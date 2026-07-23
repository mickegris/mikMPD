// SnapcastStore.swift
import Foundation
import Combine

// View-scoped ObservableObject — connect on appear, disconnect on disappear.
// All socket I/O (connect, request) runs on Q; @Published state updates on main thread.
// disconnect() is called directly from main actor — SnapcastSocket.disconnect() is thread-safe.
final class SnapcastStore: ObservableObject {
    @Published var groups: [SnapGroup] = []
    @Published var streams: [SnapStream] = []
    @Published var isConnected = false
    @Published var connectionError: String? = nil

    // Clients being actively dragged — poll skips their volume to avoid slider snap-back.
    private(set) var draggingClients: Set<String> = []

    private let socket = SnapcastSocket()
    private let Q = DispatchQueue(label: "snapcast", qos: .userInitiated)
    private var pollTimer: DispatchSourceTimer?

    // MARK: - Lifecycle

    func connect(host: String, port: Int) {
        // disconnect() is thread-safe; call directly to unblock any in-flight request
        socket.disconnect()

        let sock = socket
        Q.async {
            // Wire notification handler before starting the reader Thread inside connect()
            sock.onNotification = { @Sendable [weak self] method, paramsData in
                DispatchQueue.main.async { self?.handleNotification(method: method, paramsData: paramsData) }
            }
            do {
                try sock.connect(host: host, port: port)
                DispatchQueue.main.async { [weak self] in
                    self?.isConnected = true
                    self?.connectionError = nil
                    self?.startPollTimer()
                }
            } catch {
                let msg = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    self?.isConnected = false
                    self?.connectionError = msg
                }
            }
        }
    }

    func disconnect() {
        pollTimer?.cancel()
        pollTimer = nil
        isConnected = false
        // Thread-safe: shuts down the fd, unblocking any sema.wait() in request()
        socket.disconnect()
    }

    // MARK: - Commands

    func setVolume(clientID: String, percent: Int, muted: Bool) {
        applyClientVolume(clientID: clientID, volume: SnapVolume(percent: percent, muted: muted))
        let sock = socket
        Q.async {
            _ = try? sock.request(method: "Client.SetVolume",
                                  params: ["id": clientID,
                                           "volume": ["percent": percent, "muted": muted]])
        }
    }

    func setGroupMute(groupID: String, muted: Bool) {
        applyGroupMute(groupID: groupID, muted: muted)
        let sock = socket
        Q.async {
            _ = try? sock.request(method: "Group.SetMute",
                                  params: ["id": groupID, "mute": muted])
        }
    }

    func setLatency(clientID: String, latency: Int) {
        applyClientLatency(clientID: clientID, latency: latency)
        let sock = socket
        Q.async {
            _ = try? sock.request(method: "Client.SetLatency",
                                  params: ["id": clientID, "latency": latency])
        }
    }

    func setClientName(clientID: String, name: String) {
        applyClientName(clientID: clientID, name: name)
        let sock = socket
        Q.async {
            _ = try? sock.request(method: "Client.SetName",
                                  params: ["id": clientID, "name": name])
        }
    }

    func deleteClient(clientID: String) {
        groups = groups.map { group in
            var g = group
            g.clients.removeAll { $0.id == clientID }
            return g
        }
        let sock = socket
        Q.async {
            _ = try? sock.request(method: "Server.DeleteClient", params: ["id": clientID])
        }
    }

    func setGroupStream(groupID: String, streamID: String) {
        applyGroupStream(groupID: groupID, streamID: streamID)
        let sock = socket
        Q.async { [weak self] in
            do {
                _ = try sock.request(method: "Group.SetStream",
                                     params: ["id": groupID, "stream_id": streamID])
            } catch {
                let msg = error.localizedDescription
                DispatchQueue.main.async {
                    self?.connectionError = "Set stream failed: \(msg)"
                    self?.refreshStatus()
                }
            }
        }
    }

    /// Move a client from its current group to another group via Group.SetClients.
    func moveClient(clientID: String, fromGroupID: String, toGroupID: String) {
        // Capture current client ID lists for the RPCs (before optimistic update)
        var srcIDs = groups.first(where: { $0.id == fromGroupID })?.clients.map(\.id) ?? []
        var dstIDs = groups.first(where: { $0.id == toGroupID })?.clients.map(\.id) ?? []
        srcIDs.removeAll { $0 == clientID }
        if !dstIDs.contains(clientID) { dstIDs.append(clientID) }

        // Optimistic: move SnapClient object from source to destination
        let movingClient = groups.flatMap(\.clients).first(where: { $0.id == clientID })
        groups = groups.map { group in
            if group.id == fromGroupID {
                var g = group; g.clients.removeAll { $0.id == clientID }; return g
            }
            if group.id == toGroupID, let c = movingClient {
                var g = group
                if !g.clients.contains(where: { $0.id == clientID }) { g.clients.append(c) }
                return g
            }
            return group
        }

        let sock = socket
        Q.async { [srcIDs, dstIDs] in
            _ = try? sock.request(method: "Group.SetClients",
                                  params: ["id": fromGroupID, "clients": srcIDs])
            _ = try? sock.request(method: "Group.SetClients",
                                  params: ["id": toGroupID, "clients": dstIDs])
        }
    }

    // MARK: - Drag locking (prevents poll from snapping sliders mid-drag)

    func beginDragging(clientID: String) { draggingClients.insert(clientID) }
    func endDragging(clientID: String)   { draggingClients.remove(clientID) }

    // MARK: - Notification handling (called on main actor via DispatchQueue.main.async)

    private func handleNotification(method: String, paramsData: Data) {
        guard let params = (try? JSONSerialization.jsonObject(with: paramsData)) as? [String: Any]
        else { return }
        switch method {
        case "Client.OnVolumeChanged":
            guard let id  = params["id"] as? String,
                  let vol = params["volume"] as? [String: Any] else { return }
            applyClientVolume(clientID: id, volume: SnapVolume(
                percent: vol["percent"] as? Int  ?? 100,
                muted:   vol["muted"]   as? Bool ?? false))

        case "Client.OnConnect":
            refreshStatus()

        case "Client.OnDisconnect":
            if let clientJSON = params["client"] as? [String: Any],
               let id = clientJSON["id"] as? String {
                applyClientConnected(clientID: id, connected: false)
            }

        case "Client.OnLatencyChanged":
            guard let id = params["id"] as? String,
                  let ms = params["latency"] as? Int else { return }
            applyClientLatency(clientID: id, latency: ms)

        case "Client.OnNameChanged":
            guard let id   = params["id"] as? String,
                  let name = params["name"] as? String else { return }
            applyClientName(clientID: id, name: name)

        case "Group.OnMute":
            guard let id    = params["id"] as? String,
                  let muted = params["mute"] as? Bool else { return }
            applyGroupMute(groupID: id, muted: muted)

        case "Group.OnStreamChanged":
            guard let id       = params["id"] as? String,
                  let streamID = params["stream_id"] as? String else { return }
            applyGroupStream(groupID: id, streamID: streamID)

        case "Server.OnUpdate":
            if let server = params["server"] {
                mergeGroups(decodeSnapGroups(from: server))
                streams = decodeSnapStreams(from: server)
            }

        default:
            break
        }
    }

    // MARK: - Private helpers

    private func startPollTimer() {
        pollTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: Q)
        t.schedule(deadline: .now(), repeating: 2)
        t.setEventHandler { @Sendable [weak self] in self?.poll() }
        t.resume()
        pollTimer = t
    }

    nonisolated private func poll() {
        guard socket.connected else { return }
        do {
            let result    = try socket.request(method: "Server.GetStatus")
            // Server.GetStatus result is {server: {groups:[], streams:[]}}; unwrap the inner object.
            let serverObj = (result as? [String: Any])?["server"] ?? result
            let newGroups = decodeSnapGroups(from: serverObj)
            let newStreams = decodeSnapStreams(from: serverObj)
            DispatchQueue.main.async { [weak self] in
                self?.mergeGroups(newGroups)
                self?.streams = newStreams
                self?.isConnected = true
            }
        } catch {
            socket.disconnect()
            let msg = error.localizedDescription
            DispatchQueue.main.async { [weak self] in
                self?.isConnected = false
                self?.connectionError = msg
            }
        }
    }

    /// Re-poll Server.GetStatus for notifications that carry only partial state.
    private func refreshStatus() {
        let sock = socket
        Q.async {
            guard sock.connected,
                  let result = try? sock.request(method: "Server.GetStatus") else { return }
            let serverObj = (result as? [String: Any])?["server"] ?? result
            let newGroups = decodeSnapGroups(from: serverObj)
            let newStreams = decodeSnapStreams(from: serverObj)
            DispatchQueue.main.async { [weak self] in
                self?.mergeGroups(newGroups)
                self?.streams = newStreams
            }
        }
    }

    /// Apply poll result while preserving volumes for clients being dragged.
    private func mergeGroups(_ newGroups: [SnapGroup]) {
        if draggingClients.isEmpty {
            groups = newGroups
            return
        }
        let currentByID = Dictionary(
            uniqueKeysWithValues: groups.flatMap(\.clients).map { ($0.id, $0) }
        )
        groups = newGroups.map { group in
            var g = group
            g.clients = g.clients.map { client in
                if draggingClients.contains(client.id),
                   let current = currentByID[client.id] {
                    var c = client; c.volume = current.volume; return c
                }
                return client
            }
            return g
        }
    }

    private func applyClientVolume(clientID: String, volume: SnapVolume) {
        groups = groups.map { group in
            var g = group
            g.clients = g.clients.map { client in
                guard client.id == clientID else { return client }
                var c = client; c.volume = volume; return c
            }
            return g
        }
    }

    private func applyClientLatency(clientID: String, latency: Int) {
        groups = groups.map { group in
            var g = group
            g.clients = g.clients.map { client in
                guard client.id == clientID else { return client }
                var c = client; c.latency = latency; return c
            }
            return g
        }
    }

    private func applyClientName(clientID: String, name: String) {
        groups = groups.map { group in
            var g = group
            g.clients = g.clients.map { client in
                guard client.id == clientID else { return client }
                var c = client; c.name = name; return c
            }
            return g
        }
    }

    private func applyClientConnected(clientID: String, connected: Bool) {
        groups = groups.map { group in
            var g = group
            g.clients = g.clients.map { client in
                guard client.id == clientID else { return client }
                var c = client; c.connected = connected; return c
            }
            return g
        }
    }

    private func applyGroupMute(groupID: String, muted: Bool) {
        groups = groups.map { group in
            guard group.id == groupID else { return group }
            var g = group; g.muted = muted; return g
        }
    }

    private func applyGroupStream(groupID: String, streamID: String) {
        groups = groups.map { group in
            guard group.id == groupID else { return group }
            var g = group; g.streamID = streamID; return g
        }
    }
}
