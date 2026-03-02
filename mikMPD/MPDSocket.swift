// MPDSocket.swift
import Foundation
import Darwin

enum MPDError: LocalizedError {
    case notConnected, connectionFailed(String), badHandshake, authFailed, io(String), ack(String)
    var errorDescription: String? {
        switch self {
        case .notConnected:         return "Not connected"
        case .connectionFailed(let s): return s
        case .badHandshake:         return "Bad handshake"
        case .authFailed:           return "Wrong password"
        case .io(let s):            return s
        case .ack(let s):           return s
        }
    }
}

/// One key/value pair from MPD. Records are lists of these.
typealias MPDRecord = [String: String]

final class MPDSocket {
    private(set) var connected = false
    private var fd: Int32 = -1
    private var buf = Data()

    // MARK: - Connection

    func connect(host: String, port: Int, password: String) throws {
        disconnect()
        fd = try openTCP(host: host, port: port)
        buf = Data()
        // Read banner
        let banner = try readLine()
        guard banner.hasPrefix("OK MPD") else { disconnect(); throw MPDError.badHandshake }
        // Auth
        if !password.isEmpty {
            try send("password \(password)\n")
            let resp = try readUntilOK()
            if resp.first?.hasPrefix("ACK") == true { disconnect(); throw MPDError.authFailed }
        }
        connected = true
    }

    func disconnect() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        buf = Data(); connected = false
    }

    // MARK: - Commands

    /// Send a command, return parsed records.
    @discardableResult
    func command(_ cmd: String) throws -> [MPDRecord] {
        guard connected else { throw MPDError.notConnected }
        do {
            try send(cmd + "\n")
            return try readRecords()
        } catch {
            disconnect(); throw error
        }
    }

    /// Send a command, return all values for one key (for `list` responses).
    func listValues(_ cmd: String, key: String) throws -> [String] {
        guard connected else { throw MPDError.notConnected }
        do {
            try send(cmd + "\n")
            let lines = try readUntilOK()
            if lines.first?.hasPrefix("ACK") == true { throw MPDError.ack(lines[0]) }
            let lk = key.lowercased()
            return lines.compactMap { line -> String? in
                guard let c = line.firstIndex(of: ":") else { return nil }
                guard String(line[..<c]).trimmingCharacters(in: .whitespaces).lowercased() == lk else { return nil }
                return String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
            }
        } catch {
            disconnect(); throw error
        }
    }

    // MARK: - Private helpers

    private func openTCP(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "\(port)", &hints, &res) == 0, let ai = res else {
            throw MPDError.connectionFailed("Cannot resolve \(host)")
        }
        defer { freeaddrinfo(res) }
        let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard s >= 0 else { throw MPDError.connectionFailed("socket() failed") }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard Darwin.connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 else {
            Darwin.close(s)
            throw MPDError.connectionFailed("connect() failed: \(String(cString: strerror(errno)))")
        }
        return s
    }

    private func send(_ s: String) throws {
        let data = Array(s.utf8); var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { ptr in Darwin.send(fd, ptr.baseAddress! + sent, data.count - sent, 0) }
            guard n > 0 else { throw MPDError.io("send failed") }
            sent += n
        }
    }

    private func readLine() throws -> String {
        while true {
            if let nl = buf.firstIndex(of: 10) {
                let line = String(data: buf[buf.startIndex..<nl], encoding: .utf8) ?? ""
                buf.removeSubrange(buf.startIndex...nl)
                return line
            }
            var tmp = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.recv(fd, &tmp, 4096, 0)
            guard n > 0 else { throw MPDError.io("recv failed (n=\(n) errno=\(errno))") }
            buf.append(contentsOf: tmp[..<n])
        }
    }

    private func readUntilOK() throws -> [String] {
        var lines: [String] = []
        while true {
            let line = try readLine()
            if line == "OK" { return lines }
            if line.hasPrefix("ACK") { return [line] }
            lines.append(line)
        }
    }

    private func readRecords() throws -> [MPDRecord] {
        let lines = try readUntilOK()
        if lines.first?.hasPrefix("ACK") == true { throw MPDError.ack(lines[0]) }
        return parseRecords(lines)
    }

    // These keys mark the start of a new record in multi-record responses.
    // We do NOT flush on duplicate keys — `attribute:` repeats inside output records.
    private let recordStarters: Set<String> = ["file", "directory", "playlist", "outputid", "partition"]

    private func parseRecords(_ lines: [String]) -> [MPDRecord] {
        var out: [MPDRecord] = []
        var cur: MPDRecord = [:]
        func flush() { if !cur.isEmpty { out.append(cur); cur = [:] } }
        for line in lines {
            guard let c = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<c]).trimmingCharacters(in: .whitespaces).lowercased()
            let v = String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
            if recordStarters.contains(k) { flush() }
            cur[k] = v
        }
        flush()
        return out
    }
}
