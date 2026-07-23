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

// Invariants:
//   connect() and request() — only from SnapcastStore's serial queue Q
//   disconnect()            — callable from any thread (main actor or Q)
//   onNotification          — set from Q before connect(); called from the reader Thread
nonisolated final class SnapcastSocket: @unchecked Sendable {

    // MARK: - State (protected by stateLock)
    private let stateLock = NSLock()
    private var _connected = false
    private var _fd: Int32 = -1
    private var _generation = 0

    // MARK: - Pending requests (protected by pendingLock)
    private let pendingLock = NSLock()
    private var pendingCallbacks: [Int: (Result<Any, Error>) -> Void] = [:]
    private var nextID = 1

    // Called from reader Thread with (method, JSON-encoded params as Data).
    // Data (Sendable) avoids non-Sendable [String:Any] crossing thread boundaries.
    var onNotification: (@Sendable (String, Data) -> Void)?

    var connected: Bool { stateLock.withLock { _connected } }

    // MARK: - Connection

    func connect(host: String, port: Int) throws {
        disconnect()    // clears state; safe to call before we have a new fd

        let s = try openTCP(host: host, port: port)
        let gen: Int
        stateLock.lock()
        _fd = s
        _connected = true
        _generation += 1
        gen = _generation
        stateLock.unlock()

        Thread.detachNewThread { self.readLoop(gen: gen, fd: s) }
    }

    /// Thread-safe: unblocks any in-progress request and stops the reader Thread.
    func disconnect() {
        stateLock.lock()
        _connected = false
        let oldFD = _fd; _fd = -1
        stateLock.unlock()

        if oldFD >= 0 {
            // shutdown() unblocks recv() in the reader Thread immediately
            Darwin.shutdown(oldFD, SHUT_RDWR)
            Darwin.close(oldFD)
        }

        // Fail all pending — signals any DispatchSemaphore waiting in request()
        pendingLock.lock()
        let pending = pendingCallbacks
        pendingCallbacks = [:]
        pendingLock.unlock()
        pending.values.forEach { $0(.failure(SnapcastError.notConnected)) }
    }

    // MARK: - JSON-RPC (call only from Q)

    func request(method: String, params: [String: Any] = [:]) throws -> Any {
        stateLock.lock()
        guard _connected else { stateLock.unlock(); throw SnapcastError.notConnected }
        let fd = _fd
        stateLock.unlock()

        let sema = DispatchSemaphore(value: 0)
        var callbackResult: Result<Any, Error> = .failure(SnapcastError.malformedResponse)
        let id: Int

        pendingLock.lock()
        id = nextID; nextID += 1
        pendingCallbacks[id] = { r in callbackResult = r; sema.signal() }
        pendingLock.unlock()

        let data = try snapcastRequestData(method: method, params: params, id: id)
        do {
            try sendRaw(fd: fd, data: data + [0x0a])
        } catch {
            pendingLock.lock()
            pendingCallbacks.removeValue(forKey: id)
            pendingLock.unlock()
            throw error
        }

        sema.wait()
        return try callbackResult.get()
    }

    // MARK: - Reader Thread

    private func readLoop(gen: Int, fd: Int32) {
        var buf = Data()    // local to this session; never shared with other threads
        while true {
            stateLock.lock()
            let current = _connected && _generation == gen
            stateLock.unlock()
            guard current else { break }

            let line: String
            do { line = try readOneLine(fd: fd, buf: &buf) }
            catch { break }

            stateLock.lock()
            let stillCurrent = _connected && _generation == gen
            stateLock.unlock()
            guard stillCurrent else { break }

            dispatchLine(line)
        }

        // Fail remaining pending requests (reader exited — no more responses coming)
        pendingLock.lock()
        let remaining = pendingCallbacks
        pendingCallbacks = [:]
        pendingLock.unlock()
        remaining.values.forEach { $0(.failure(SnapcastError.io("Connection closed"))) }

        stateLock.lock()
        if _generation == gen { _connected = false }
        stateLock.unlock()
    }

    private func dispatchLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let id = json["id"] as? Int {
            pendingLock.lock()
            let cb = pendingCallbacks.removeValue(forKey: id)
            pendingLock.unlock()
            if let result = json["result"] {
                cb?(.success(result))
            } else if let errDict = json["error"] as? [String: Any],
                      let msg = errDict["message"] as? String {
                cb?(.failure(SnapcastError.io(msg)))
            } else {
                cb?(.failure(SnapcastError.malformedResponse))
            }
        } else if let method = json["method"] as? String,
                  let notif = onNotification {
            let paramsObj = json["params"] ?? [String: Any]()
            if let paramsData = try? JSONSerialization.data(withJSONObject: paramsObj) {
                notif(method, paramsData)
            }
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
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return s
    }

    private func sendRaw(fd: Int32, data: Data) throws {
        let bytes = Array(data); var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { ptr in Darwin.send(fd, ptr.baseAddress! + sent, bytes.count - sent, 0) }
            guard n > 0 else { throw SnapcastError.io("send failed") }
            sent += n
        }
    }

    private func readOneLine(fd: Int32, buf: inout Data) throws -> String {
        while true {
            if let nl = buf.firstIndex(of: 10) {
                let line = String(data: buf[buf.startIndex..<nl], encoding: .utf8) ?? ""
                buf.removeSubrange(buf.startIndex...nl)
                return line
            }
            var tmp = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.recv(fd, &tmp, 4096, 0)
            if n > 0 {
                buf.append(contentsOf: tmp[..<n])
            } else if n == 0 {
                throw SnapcastError.io("Connection closed")
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw SnapcastError.io("recv failed (errno=\(errno))")
            }
        }
    }
}
