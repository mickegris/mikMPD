// SocketResetTests.swift
// A connection the peer has reset must fail with an error, not kill the app.
//
// Without SO_NOSIGPIPE the first send() after a reset raises SIGPIPE, whose
// default action terminates the process — this test would then take the whole
// test run down with it rather than fail, which is what makes it a real
// regression test: it cannot pass by accident. Needs no MPD server; a loopback
// listener plays the part.
import Testing
import Foundation
import Darwin
@testable import mikMPD

/// A one-connection loopback server that greets like MPD, then resets the
/// connection (SO_LINGER 0 → RST) when told to.
private final class ResettingServer: @unchecked Sendable {
    let port: Int
    private let listener: Int32
    private let accepted = DispatchSemaphore(value: 0)
    private let resetNow = DispatchSemaphore(value: 0)
    private let didReset = DispatchSemaphore(value: 0)

    init(banner: String?) throws {
        let l = socket(AF_INET, SOCK_STREAM, 0)
        listener = l
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(l, $0, len) == 0 && listen(l, 1) == 0 && getsockname(l, $0, &len) == 0
            }
        }
        try #require(ok, "loopback listener")
        port = Int(UInt16(bigEndian: addr.sin_port))

        let fd = listener
        Thread { [self] in
            let conn = accept(fd, nil, nil)
            if let banner { _ = Array(banner.utf8).withUnsafeBytes { send(conn, $0.baseAddress, $0.count, 0) } }
            accepted.signal()
            resetNow.wait()
            var lg = linger(l_onoff: 1, l_linger: 0)
            setsockopt(conn, SOL_SOCKET, SO_LINGER, &lg, socklen_t(MemoryLayout<linger>.size))
            close(conn)
            close(fd)
            didReset.signal()
        }.start()
    }

    /// Reset the connection and give the client's kernel time to receive the RST.
    func reset() {
        accepted.wait()
        resetNow.signal()
        didReset.wait()
        usleep(200_000)
    }
}

@Suite(.serialized) struct SocketResetTests {

    @Test func mpdSocketThrowsInsteadOfDyingOnAResetConnection() throws {
        let server = try ResettingServer(banner: "OK MPD 0.24.0\n")
        let socket = MPDSocket()
        try socket.connect(host: "127.0.0.1", port: server.port, password: "")
        server.reset()

        #expect(throws: MPDError.self) { try socket.command("status") }
        #expect(socket.connected == false)
        // And again, on the now-disconnected socket: still an error, still alive.
        #expect(throws: MPDError.self) { try socket.command("status") }
    }

    @Test func snapcastSocketThrowsInsteadOfDyingOnAResetConnection() throws {
        let server = try ResettingServer(banner: nil)
        let socket = SnapcastSocket()
        try socket.connect(host: "127.0.0.1", port: server.port)
        server.reset()

        // The reader thread may notice the reset first and disconnect, in which
        // case this throws notConnected before sending; otherwise the send gets
        // EPIPE. Either is correct — dying is not.
        #expect(throws: (any Error).self) { try socket.request(method: "Server.GetStatus") }
        socket.disconnect()
    }
}
