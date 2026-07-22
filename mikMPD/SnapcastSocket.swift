// SnapcastSocket.swift
import Foundation
import Darwin

nonisolated enum SnapcastError: LocalizedError {
    case connectionFailed(String)
    case io(String)
    case notConnected
    case malformedResponse
    var errorDescription: String? {
        switch self {
        case .connectionFailed(let s): return s
        case .io(let s):               return s
        case .notConnected:            return "Not connected to Snapcast"
        case .malformedResponse:       return "Unexpected response from Snapcast"
        }
    }
}

// @unchecked Sendable: not thread-safe by itself — the invariant is that all
// access after init happens on SnapcastStore's serial queue (mirrors MPDSocket).
nonisolated final class SnapcastSocket: @unchecked Sendable {
    private(set) var connected = false
    private var fd: Int32 = -1
    private var buf = Data()
    private var nextID = 1

    // MARK: - Connection

    func connect(host: String, port: Int) throws {
        disconnect()
        fd = try openTCP(host: host, port: port)
        buf = Data()
        connected = true
    }

    func disconnect() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        buf = Data(); connected = false
    }

    // MARK: - JSON-RPC

    /// Send one JSON-RPC 2.0 request and return the `result` value,
    /// skipping any interleaved notification lines.
    func request(method: String, params: [String: Any] = [:]) throws -> Any {
        guard connected else { throw SnapcastError.notConnected }
        let id = nextID; nextID += 1
        let data = try snapcastRequestData(method: method, params: params, id: id)
        try sendRaw(data + [0x0a])   // newline-delimited
        while true {
            let line = try readLine()
            guard let d    = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let rid  = json["id"] as? Int, rid == id
            else { continue }   // notification or parse error — skip
            guard let result = json["result"] else { throw SnapcastError.malformedResponse }
            return result
        }
    }

    // MARK: - TCP helpers (mirrors MPDSocket)

    private func openTCP(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "\(port)", &hints, &res) == 0, let ai = res else {
            throw SnapcastError.connectionFailed("Cannot resolve \(host)")
        }
        defer { freeaddrinfo(res) }
        let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard s >= 0 else { throw SnapcastError.connectionFailed("socket() failed") }

        let flags = fcntl(s, F_GETFL)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        let ret = Darwin.connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
        if ret != 0 && errno != EINPROGRESS {
            Darwin.close(s)
            throw SnapcastError.connectionFailed("connect() failed: \(String(cString: strerror(errno)))")
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
                throw SnapcastError.connectionFailed(sel == 0 ? "Connection timed out" : "select() failed")
            }
            var sockErr: Int32 = 0
            var errLen = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(s, SOL_SOCKET, SO_ERROR, &sockErr, &errLen)
            if sockErr != 0 {
                Darwin.close(s)
                throw SnapcastError.connectionFailed("connect() failed: \(String(cString: strerror(sockErr)))")
            }
        }
        _ = fcntl(s, F_SETFL, flags)
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return s
    }

    private func sendRaw(_ data: Data) throws {
        let bytes = Array(data); var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { ptr in Darwin.send(fd, ptr.baseAddress! + sent, bytes.count - sent, 0) }
            guard n > 0 else { throw SnapcastError.io("send failed") }
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
            guard n > 0 else { throw SnapcastError.io("recv failed (n=\(n) errno=\(errno))") }
            buf.append(contentsOf: tmp[..<n])
        }
    }
}
