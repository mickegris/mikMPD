// SnapcastStore.swift
import Foundation
import Combine

// View-scoped ObservableObject — connect on appear, disconnect on disappear.
// All socket I/O runs on Q; @Published state updates on main thread.
final class SnapcastStore: ObservableObject {
    @Published var groups: [SnapGroup] = []
    @Published var isConnected = false
    @Published var connectionError: String? = nil

    // Clients being actively dragged — poll skips their volume to avoid slider snap-back.
    private(set) var draggingClients: Set<String> = []

    private let socket = SnapcastSocket()
    private let Q = DispatchQueue(label: "snapcast", qos: .userInitiated)
    private var pollTimer: DispatchSourceTimer?

    // MARK: - Lifecycle

    func connect(host: String, port: Int) {
        let sock = socket
        Q.async {
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
        let sock = socket
        Q.async { sock.disconnect() }
    }

    // MARK: - Commands

    func setVolume(clientID: String, percent: Int, muted: Bool) {
        // Optimistic update
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

    // MARK: - Drag locking (prevents poll from snapping sliders mid-drag)

    func beginDragging(clientID: String) { draggingClients.insert(clientID) }
    func endDragging(clientID: String)   { draggingClients.remove(clientID) }

    // MARK: - Private helpers

    private func startPollTimer() {
        let t = DispatchSource.makeTimerSource(queue: Q)
        t.schedule(deadline: .now(), repeating: 2)
        t.setEventHandler { @Sendable [weak self] in self?.poll() }
        t.resume()
        pollTimer = t
    }

    nonisolated private func poll() {
        guard socket.connected else { return }
        do {
            let result = try socket.request(method: "Server.GetStatus")
            let newGroups = decodeSnapGroups(from: result)
            DispatchQueue.main.async { [weak self] in
                self?.mergeGroups(newGroups)
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

    /// Apply poll result while preserving volumes for dragging clients.
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

    private func applyGroupMute(groupID: String, muted: Bool) {
        groups = groups.map { group in
            guard group.id == groupID else { return group }
            var g = group; g.muted = muted; return g
        }
    }
}
