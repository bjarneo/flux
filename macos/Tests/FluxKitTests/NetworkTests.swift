import NIOCore
import NIOPosix
import NIOSSL
import XCTest
@testable import FluxKit

/// Connects to a port on this device, with TLS as `peer`, or with plain TCP
/// when `peer` is nil. A test closes the channel after 10 seconds at the
/// latest, so that a missing close fails an assertion and does not hang.
private func dial(_ port: Int, as peer: LocalCertificate?) async throws -> Channel {
    let tls = try peer.map { try FluxTLS(local: $0) }
    let ch = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                if let tls { try channel.pipeline.syncOperations.addHandler(tls.clientHandler()) }
            }
        }
        .connect(host: "127.0.0.1", port: port).get()
    ch.eventLoop.scheduleTask(in: .seconds(10)) { ch.close(promise: nil) }
    return ch
}

/// A payload listener waits for the paired computer. A port scan, a
/// stranger, or a late peer must not stop the app or take the transfer.
final class PayloadServerTests: XCTestCase {
    private static let phone = try! LocalCertificate.generate(deviceId: "0f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b")
    private static let computer = try! LocalCertificate.generate(deviceId: "9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b")
    private static let stranger = try! LocalCertificate.generate(deviceId: "8f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b")

    private func open() async throws -> PayloadServer {
        try await PayloadServer.open(tls: FluxTLS(local: Self.phone), expected: Self.computer.certificateDER, ports: 41739...41764)
    }

    /// Reads the stream until it has `count` bytes, then closes it.
    private func read(_ stream: TLSStream, count: Int) async throws -> String {
        try await stream.executeThenClose { inbound, _ in
            var text = ""
            for try await buffer in inbound {
                text += String(buffer: buffer)
                if text.utf8.count >= count { break }
            }
            return text
        }
    }

    func testAConnectionThatClosesDoesNotTakeTheTransfer() async throws {
        let server = try await open()
        let scan = try await dial(server.port, as: nil)
        try await scan.close()
        let peer = try await dial(server.port, as: Self.computer)
        try await peer.writeAndFlush(ByteBuffer(string: "hello"))
        let stream = try await server.accept(timeout: .seconds(10))
        XCTAssertEqual(stream.peerCertificate, Self.computer.certificateDER)
        let text = try await read(stream, count: 5)
        XCTAssertEqual(text, "hello", "the bytes right after the handshake arrive")
        try? await peer.close()
    }

    func testAStrangerCertificateDoesNotTakeTheTransfer() async throws {
        let server = try await open()
        let stranger = try await dial(server.port, as: Self.stranger)
        try? await stranger.writeAndFlush(ByteBuffer(string: "evil"))
        let start = ContinuousClock.now
        try await stranger.closeFuture.get()
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(9), "the listener closes the stranger after its handshake")
        let peer = try await dial(server.port, as: Self.computer)
        try await peer.writeAndFlush(ByteBuffer(string: "hello"))
        let stream = try await server.accept(timeout: .seconds(10))
        XCTAssertEqual(stream.peerCertificate, Self.computer.certificateDER)
        let text = try await read(stream, count: 5)
        XCTAssertEqual(text, "hello")
        try? await peer.close()
    }

    func testALatePeerGetsNoStream() async throws {
        let server = try await open()
        let first = try await dial(server.port, as: Self.computer)
        let stream = try await server.accept(timeout: .seconds(10))
        // The listener closes with the accept. A second peer finds no
        // listener, or the listener closes its connection.
        let second = try? await dial(server.port, as: Self.computer)
        if let second {
            let start = ContinuousClock.now
            try await second.closeFuture.get()
            XCTAssertLessThan(ContinuousClock.now - start, .seconds(9))
        }
        await stream.discard()
        try? await first.close()
    }

    func testAcceptEndsAtTheTimeout() async throws {
        let server = try await open()
        let scan = try await dial(server.port, as: nil)
        do {
            _ = try await server.accept(timeout: .milliseconds(300))
            XCTFail("no computer connected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("did not connect"), String(describing: error))
        }
        let start = ContinuousClock.now
        try await scan.closeFuture.get()
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(9), "the end closes the connections that wait")
    }

    func testCloseEndsTheWait() async throws {
        let server = try await open()
        let wait = Task { try await server.accept(timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        server.close()
        do {
            _ = try await wait.value
            XCTFail("the listener closed")
        } catch {}
    }
}

/// Connections before their link must not outlive a stop.
final class LinkHandshakeTests: XCTestCase {
    func testDataAfterAStopDoesNotStopTheApp() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suite = "org.omarchy.flux.test." + UUID().uuidString
        var config = LanConfig()
        config.loopbackOnly = true
        config.udpPort = 0
        config.tcpPorts = 0...0
        let core = try FluxCore(paths: FluxPaths(data: dir, suite: suite), lanConfig: config, plugins: [])
        addTeardownBlock {
            core.stop()
            try? FileManager.default.removeItem(at: dir)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        core.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while core.state.tcpPort == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let port = core.state.tcpPort
        XCTAssertGreaterThan(port, 0)

        let ch = try await dial(port, as: nil)
        try await Task.sleep(for: .milliseconds(100))
        core.stop()
        let identity = Identity(deviceId: "9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b", deviceName: "desk", deviceType: "desktop",
                                protocolVersion: 8, incoming: [PacketType.fluxTunnel], outgoing: []).packet().serialize()
        try? await ch.writeAndFlush(ByteBuffer(bytes: identity))
        let start = ContinuousClock.now
        try await ch.closeFuture.get()
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(9), "the stop closes the connection before its link")
    }
}
