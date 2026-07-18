// MPDSocket.swift
import Foundation
import Darwin

nonisolated enum MPDError: LocalizedError {
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

// @unchecked Sendable: not thread-safe by itself — the invariant is that all
// access after init happens on MPDStore's serial queue Q (see CLAUDE.md).
nonisolated final class MPDSocket: @unchecked Sendable {
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
            try send("password \"\(password.esc)\"\n")
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
            // ACK is a protocol-level rejection — the connection is still valid
            if case MPDError.ack = error { throw error }
            disconnect(); throw error
        }
    }

    /// Send a command, return the raw response lines. Needed for
    /// `list … group …` responses, whose interleaved structure neither
    /// `listValues` (single key) nor `parseMPDRecords` (collapses — no
    /// record-starter keys) preserves.
    func rawLines(_ cmd: String) throws -> [String] {
        guard connected else { throw MPDError.notConnected }
        do {
            try send(cmd + "\n")
            let lines = try readUntilOK()
            if lines.first?.hasPrefix("ACK") == true { throw MPDError.ack(lines[0]) }
            return lines
        } catch {
            if case MPDError.ack = error { throw error }
            disconnect(); throw error
        }
    }

    /// Send a command, return all values for one key (for `list` responses).
    func listValues(_ cmd: String, key: String) throws -> [String] {
        let lk = key.lowercased()
        return try rawLines(cmd).compactMap { line -> String? in
            guard let c = line.firstIndex(of: ":") else { return nil }
            guard String(line[..<c]).trimmingCharacters(in: .whitespaces).lowercased() == lk else { return nil }
            return String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
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

        // Non-blocking connect with 5s timeout
        let flags = fcntl(s, F_GETFL)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        let ret = Darwin.connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
        if ret != 0 && errno != EINPROGRESS {
            Darwin.close(s)
            throw MPDError.connectionFailed("connect() failed: \(String(cString: strerror(errno)))")
        }
        if ret != 0 {
            var wset = fd_set()
            withUnsafeMutablePointer(to: &wset) { ptr in
                ptr.withMemoryRebound(to: Int32.self, capacity: Int(FD_SETSIZE) / 32) { buf in
                    buf.initialize(repeating: 0, count: Int(FD_SETSIZE) / 32)
                    buf[Int(s) / 32] |= Int32(1 << (Int(s) % 32))
                }
            }
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            let sel = select(s + 1, nil, &wset, nil, &tv)
            if sel <= 0 {
                Darwin.close(s)
                throw MPDError.connectionFailed(sel == 0 ? "Connection timed out" : "select() failed")
            }
            var sockErr: Int32 = 0
            var errLen = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(s, SOL_SOCKET, SO_ERROR, &sockErr, &errLen)
            if sockErr != 0 {
                Darwin.close(s)
                throw MPDError.connectionFailed("connect() failed: \(String(cString: strerror(sockErr)))")
            }
        }

        // Restore blocking mode, set I/O timeouts
        _ = fcntl(s, F_SETFL, flags)
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
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
        return parseMPDRecords(lines)
    }

    // MARK: - Binary commands (album art)

    /// Fetch album art via `albumart` (covers directory-level cover.jpg/png and some embedded art).
    func albumArt(uri: String) throws -> Data? {
        try fetchBinaryArt(command: "albumart", uri: uri)
    }

    /// Fetch embedded picture via `readpicture` (MPD 0.22+).
    func readPicture(uri: String) throws -> Data? {
        try fetchBinaryArt(command: "readpicture", uri: uri)
    }

    private func fetchBinaryArt(command: String, uri: String) throws -> Data? {
        guard connected else { return nil }
        do {
            var result = Data()
            var offset = 0
            var totalSize = 0

            repeat {
                try send("\(command) \"\(uri.esc)\" \(offset)\n")
                let (headers, chunk) = try readBinaryResponse()
                if chunk.isEmpty { return result.isEmpty ? nil : result }
                if let s = headers["size"] { totalSize = Int(s) ?? 0 }
                result.append(chunk)
                offset = result.count
            } while totalSize > 0 && result.count < totalSize

            return result.isEmpty ? nil : result
        } catch let error as MPDError {
            if case .ack = error { return nil }  // no art for this song
            disconnect(); throw error
        }
    }

    private func readBinaryResponse() throws -> (headers: [String: String], data: Data) {
        var headers: [String: String] = [:]
        while true {
            let line = try readLine()
            if line == "OK" { return (headers, Data()) }
            if line.hasPrefix("ACK") { throw MPDError.ack(line) }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if key == "binary" {
                let count = Int(val) ?? 0
                guard count > 0 else {
                    consumeUntilOK()
                    return (headers, Data())
                }
                let data = try readExact(count)
                consumeUntilOK()
                return (headers, data)
            }
            headers[key] = val
        }
    }

    private func readExact(_ count: Int) throws -> Data {
        while buf.count < count {
            var tmp = [UInt8](repeating: 0, count: max(4096, count - buf.count))
            let n = Darwin.recv(fd, &tmp, tmp.count, 0)
            guard n > 0 else { throw MPDError.io("recv failed") }
            buf.append(contentsOf: tmp[..<n])
        }
        let result = Data(buf.prefix(count))
        buf.removeSubrange(buf.startIndex..<buf.index(buf.startIndex, offsetBy: count))
        return result
    }

    private func consumeUntilOK() {
        while let line = try? readLine() {
            if line == "OK" || line.hasPrefix("ACK") { break }
        }
    }

}

// These keys mark the start of a new record in multi-record responses.
// We do NOT flush on duplicate keys — `attribute:` repeats inside output records.
private nonisolated let mpdRecordStarters: Set<String> = ["file", "directory", "playlist", "outputid", "partition"]

nonisolated func parseMPDRecords(_ lines: [String]) -> [MPDRecord] {
    var out: [MPDRecord] = []
    var cur: MPDRecord = [:]
    func flush() { if !cur.isEmpty { out.append(cur); cur = [:] } }
    for line in lines {
        guard let c = line.firstIndex(of: ":") else { continue }
        let k = String(line[..<c]).trimmingCharacters(in: .whitespaces).lowercased()
        let v = String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
        if mpdRecordStarters.contains(k) { flush() }
        cur[k] = v
    }
    flush()
    return out
}

/// Parse a grouped `list` response ("list album group albumartist"): a
/// `groupKey` line sets the current group, each `valueKey` line yields a pair.
/// Values before the first group line get an empty group; other keys are ignored.
nonisolated func parseGroupedValues(_ lines: [String], groupKey: String, valueKey: String) -> [(group: String, value: String)] {
    let gk = groupKey.lowercased(), vk = valueKey.lowercased()
    var group = ""
    var out: [(group: String, value: String)] = []
    for line in lines {
        guard let c = line.firstIndex(of: ":") else { continue }
        let key = String(line[..<c]).trimmingCharacters(in: .whitespaces).lowercased()
        let value = String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
        if key == gk { group = value }
        else if key == vk { out.append((group, value)) }
    }
    return out
}
