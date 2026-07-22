// SnapcastModels.swift
import Foundation

nonisolated struct SnapVolume: Equatable {
    var percent: Int    // 0…100
    var muted: Bool
}

nonisolated struct SnapClient: Identifiable, Equatable {
    var id: String
    var connected: Bool
    var hostName: String
    var name: String        // config.name — user-set label
    var volume: SnapVolume
    var latency: Int        // config.latency in ms (0 = no delay)
    var displayName: String { name.isEmpty ? hostName : name }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id        = id
        self.connected = json["connected"] as? Bool ?? false
        self.hostName  = (json["host"] as? [String: Any])?["name"] as? String ?? ""
        let config     = json["config"] as? [String: Any] ?? [:]
        self.name      = config["name"] as? String ?? ""
        self.latency   = config["latency"] as? Int ?? 0
        let vol        = config["volume"] as? [String: Any] ?? [:]
        self.volume    = SnapVolume(percent: vol["percent"] as? Int ?? 100,
                                   muted:   vol["muted"]   as? Bool ?? false)
    }
}

nonisolated struct SnapGroup: Identifiable, Equatable {
    var id: String
    var name: String
    var muted: Bool
    var streamID: String
    var clients: [SnapClient]
    var displayName: String { name.isEmpty ? streamID : name }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id       = id
        self.name     = json["name"]      as? String ?? ""
        self.muted    = json["muted"]     as? Bool   ?? false
        self.streamID = json["stream_id"] as? String ?? ""
        self.clients  = (json["clients"] as? [[String: Any]] ?? []).compactMap { SnapClient(json: $0) }
    }
}

nonisolated struct SnapStream: Identifiable, Equatable {
    var id: String
    var status: String  // "playing", "idle", "unknown"

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id     = id
        self.status = json["status"] as? String ?? "unknown"
    }
}

/// Decode groups from a Server.GetStatus result object.
nonisolated func decodeSnapGroups(from result: Any) -> [SnapGroup] {
    guard let dict = result as? [String: Any],
          let arr  = dict["groups"] as? [[String: Any]]
    else { return [] }
    return arr.compactMap { SnapGroup(json: $0) }
}

/// Decode streams from a Server.GetStatus result object.
nonisolated func decodeSnapStreams(from result: Any) -> [SnapStream] {
    guard let dict = result as? [String: Any],
          let arr  = dict["streams"] as? [[String: Any]]
    else { return [] }
    return arr.compactMap { SnapStream(json: $0) }
}

// MARK: - Pure wire helpers (testable without a live server)

/// Encode one JSON-RPC 2.0 request as a Data value (no trailing newline).
nonisolated func snapcastRequestData(method: String, params: [String: Any], id: Int) throws -> Data {
    let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
    return try JSONSerialization.data(withJSONObject: payload)
}

/// Find the response for `id` among interleaved lines, skipping notifications
/// (which have no `id` or a non-matching `id`). Used in unit tests.
nonisolated func snapcastFindResponse(in lines: [String], id: Int) -> [String: Any]? {
    for line in lines {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rid  = json["id"] as? Int, rid == id
        else { continue }
        return json
    }
    return nil
}
