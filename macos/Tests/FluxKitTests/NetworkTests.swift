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
        try await PayloadServer.open(tls: FluxTLS(local: Self.phone), expected: Self.computer.certificateDER, ports: 42070...42099)
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

/// Connects to the link port of a core as the computer `peer`, like fluxd:
/// the identity goes out in plain text, this side is the TLS server, and the
/// identity goes out again inside TLS. NIOSSL holds the second identity until
/// the handshake ends. The test closes the channel after 10 seconds at the
/// latest.
private func connectLink(_ port: Int, as peer: LocalCertificate) async throws -> Channel {
    let tls = try FluxTLS(local: peer)
    let identity = Identity(deviceId: peer.deviceId, deviceName: "desk", deviceType: "desktop",
                            protocolVersion: 8, incoming: [PacketType.fluxTunnel], outgoing: []).packet().serialize()
    let ch = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(tls.serverHandler())
            }
        }
        .connect(host: "127.0.0.1", port: port)
        .flatMapThrowing { ch -> Channel in
            // The plain identity goes out below the TLS handler.
            let ctx = try ch.pipeline.syncOperations.context(handlerType: NIOSSLServerHandler.self)
            ctx.writeAndFlush(NIOAny(ByteBuffer(bytes: identity)), promise: nil)
            return ch
        }
        .get()
    ch.eventLoop.scheduleTask(in: .seconds(10)) { ch.close(promise: nil) }
    try? await ch.writeAndFlush(ByteBuffer(bytes: identity))
    return ch
}

/// Keeps the packets that a test link receives from the core.
private final class Replies: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let lock = NSLock()
    private var text = ""

    /// The number of pair packets with pair false so far.
    var refusals: Int {
        lock.withLock { text }.split(separator: "\n")
            .compactMap { Packet.parse(Data($0.utf8)) }
            .filter { $0.type == PacketType.pair && $0.bool("pair") == false }
            .count
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        lock.withLock { text += String(buffer: buffer) }
    }
}

/// Connections before their link must not outlive a stop, and a link must
/// keep the certificate of its device.
final class LinkHandshakeTests: XCTestCase {
    private static let desk = "9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b"

    private func makeCore() throws -> FluxCore {
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
        return core
    }

    /// Starts the network of the core and returns its link port.
    private func startNetwork(_ core: FluxCore) async throws -> Int {
        core.start()
        try await waitUntil("the core listens") { core.state.tcpPort > 0 }
        return core.state.tcpPort
    }

    /// Waits up to 5 seconds for the condition. The test fails when it stays false.
    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out: \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Waits until the channel closes. The test fails when it stays open for 9 seconds.
    private func assertCloses(_ ch: Channel, _ message: String) async throws {
        let start = ContinuousClock.now
        try await ch.closeFuture.get()
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(9), message)
    }

    func testDataAfterAStopDoesNotStopTheApp() async throws {
        let core = try makeCore()
        let port = try await startNetwork(core)
        XCTAssertGreaterThan(port, 0)

        let ch = try await dial(port, as: nil)
        try await Task.sleep(for: .milliseconds(100))
        core.stop()
        let identity = Identity(deviceId: Self.desk, deviceName: "desk", deviceType: "desktop",
                                protocolVersion: 8, incoming: [PacketType.fluxTunnel], outgoing: []).packet().serialize()
        try? await ch.writeAndFlush(ByteBuffer(bytes: identity))
        try await assertCloses(ch, "the stop closes the connection before its link")
    }

    /// A pairing is bound to the link and the certificate on which it
    /// started. Another certificate for the same device ID is refused while
    /// the pairing is open and after it, and the pairing pins the first one.
    func testAPairingPinsTheCertificateOfItsLink() async throws {
        let core = try makeCore()
        let port = try await startNetwork(core)
        let first = try LocalCertificate.generate(deviceId: Self.desk)
        let other = try LocalCertificate.generate(deviceId: Self.desk)
        let pairState = { core.state.devices.first { $0.id == Self.desk }?.pairState }

        let link = try await connectLink(port, as: first)
        let request = Packet(PacketType.pair, ["pair": true, "timestamp": Int64(Date().timeIntervalSince1970)]).serialize()
        try await link.writeAndFlush(ByteBuffer(bytes: request))
        try await waitUntil("the request arrives") { pairState() == .incoming }

        let during = try await connectLink(port, as: other)
        try await assertCloses(during, "the core refuses another certificate while the pairing is open")
        XCTAssertEqual(pairState(), .incoming, "the refused link leaves the pairing open")
        XCTAssertNil(core.trust.get(Self.desk))

        core.acceptPair(Self.desk)
        XCTAssertEqual(pairState(), .paired)
        XCTAssertEqual(core.trust.get(Self.desk)?.certificateDER, first.certificateDER, "the pin is the certificate behind the key")

        let after = try await connectLink(port, as: other)
        try await assertCloses(after, "the core refuses another certificate after the pairing")
        XCTAssertTrue(link.isActive, "the paired link stays open")
        XCTAssertEqual(core.state.devices.first { $0.id == Self.desk }?.online, true)
        try? await link.close()
    }

    /// A pairing is bound to the link on which it started. A new link with
    /// the same certificate ends the incoming request, and Accept then does
    /// nothing.
    func testANewLinkEndsAnIncomingPairing() async throws {
        let core = try makeCore()
        let port = try await startNetwork(core)
        let desk = try LocalCertificate.generate(deviceId: Self.desk)
        let pairState = { core.state.devices.first { $0.id == Self.desk }?.pairState }

        let first = try await connectLink(port, as: desk)
        let request = Packet(PacketType.pair, ["pair": true, "timestamp": Int64(Date().timeIntervalSince1970)]).serialize()
        try await first.writeAndFlush(ByteBuffer(bytes: request))
        try await waitUntil("the request arrives") { pairState() == .incoming }

        let second = try await connectLink(port, as: desk)
        try await waitUntil("the new link ends the pairing") { pairState() == PairState.none }
        core.acceptPair(Self.desk)
        XCTAssertEqual(pairState(), PairState.none, "Accept does nothing after the pairing ended")
        XCTAssertNil(core.trust.get(Self.desk))
        try await assertCloses(first, "the new link replaces the old one")
        try? await second.close()
    }

    /// A new link also ends a request that this side sent.
    func testANewLinkEndsARequestThatThisSideSent() async throws {
        let core = try makeCore()
        let port = try await startNetwork(core)
        let desk = try LocalCertificate.generate(deviceId: Self.desk)
        let pairState = { core.state.devices.first { $0.id == Self.desk }?.pairState }

        let first = try await connectLink(port, as: desk)
        try await waitUntil("the link arrives") { core.state.devices.first { $0.id == Self.desk }?.online == true }
        core.pair(Self.desk, timestamp: Int64(Date().timeIntervalSince1970))
        XCTAssertEqual(pairState(), .requested)

        let second = try await connectLink(port, as: desk)
        try await waitUntil("the new link ends the pairing") { pairState() == PairState.none }
        try await assertCloses(first, "the new link replaces the old one")
        try? await second.close()
    }

    /// An incoming request that timed out does not hold the only open
    /// request. The same computer that asks again at once gets pair false,
    /// and no request opens.
    func testARequestThatTimedOutWaitsBeforeItCountsAgain() async throws {
        let core = try makeCore()
        core.incomingPairSeconds = 1
        let port = try await startNetwork(core)
        let desk = try LocalCertificate.generate(deviceId: Self.desk)
        let pairState = { core.state.devices.first { $0.id == Self.desk }?.pairState }
        let request = { Packet(PacketType.pair, ["pair": true, "timestamp": Int64(Date().timeIntervalSince1970)]).serialize() }

        let link = try await connectLink(port, as: desk)
        let replies = Replies()
        try await link.pipeline.addHandler(replies)
        try await link.writeAndFlush(ByteBuffer(bytes: request()))
        try await waitUntil("the request arrives") { pairState() == .incoming }
        try await waitUntil("the request times out") { pairState() == PairState.none }

        try await link.writeAndFlush(ByteBuffer(bytes: request()))
        try await waitUntil("the core refuses the new request") { replies.refusals == 1 }
        XCTAssertEqual(pairState(), PairState.none, "the refused request does not open, so it holds no slot")
        try? await link.close()
    }
}
