import XCTest
@testable import FluxCore
@testable import FluxProto

/// M3 packet + router + destination tests: `flux.tunnel` answers, SFTP
/// offers, capability advertisement, `uniquePath` parity, progress
/// throttling. Mirrors Android `protocol/Tunnel.kt` + Go
/// `internal/core/share.go` naming rules.
final class TransferTests: XCTestCase {
    // MARK: - flux.tunnel packets

    func testTunnelReadyRoundTrip() {
        let p = TunnelPackets.ready(token: "abc123", port: 1741)
        XCTAssertEqual(PacketType.fluxTunnel, p.type)
        guard let t = TunnelPackets.parse(p) else { return XCTFail("unparseable") }
        XCTAssertEqual("abc123", t.token)
        XCTAssertEqual(1741, t.port)
        XCTAssertNil(t.error)
        // Wire shape: {"id","port"} like Android `TunnelPackets.ready`.
        XCTAssertEqual("abc123", p.string("id"))
        XCTAssertEqual(1741, p.int("port"))
    }

    func testTunnelFailedRoundTrip() {
        let p = TunnelPackets.failed(token: "abc123", error: "no free port")
        guard let t = TunnelPackets.parse(p) else { return XCTFail("unparseable") }
        XCTAssertEqual("abc123", t.token)
        XCTAssertEqual("no free port", t.error)
    }

    func testTunnelParseRejects() {
        XCTAssertNil(TunnelPackets.parse(Packet(type: PacketType.ping)))
        XCTAssertNil(TunnelPackets.parse(Packet(type: PacketType.fluxTunnel)))
        XCTAssertNil(TunnelPackets.parse(Packet.of(PacketType.fluxTunnel, ("port", 1741))))
    }

    // MARK: - SFTP offers

    private func tunnelOffer() -> Packet {
        Packet.of(
            PacketType.sftp,
            ("user", "kdeconnect"), ("password", "one-time"),
            ("tunnel", "tok9"), ("path", "/home/ed"),
            ("multiPaths", ["/home/ed", "/home/ed/Downloads"] as [Any]),
            ("pathNames", ["Home", "Downloads"] as [Any]))
    }

    func testSftpTunnelOffer() {
        guard let offer = SftpOffer.parse(tunnelOffer()) else { return XCTFail("unparseable") }
        XCTAssertTrue(offer.viaTunnel)
        XCTAssertEqual("tok9", offer.tunnel)
        XCTAssertEqual("kdeconnect", offer.user)
        XCTAssertEqual([("Home", "/home/ed"), ("Downloads", "/home/ed/Downloads")], offer.roots, by: {
            $0.0 == $1.0 && $0.1 == $1.1
        })
    }

    func testSftpClassicOffer() {
        let p = Packet.of(
            PacketType.sftp,
            ("ip", "192.168.1.5"), ("port", 1739),
            ("user", "kdeconnect"), ("password", "pw"), ("path", "/"))
        guard let offer = SftpOffer.parse(p) else { return XCTFail("unparseable") }
        XCTAssertFalse(offer.viaTunnel)
        XCTAssertEqual("192.168.1.5", offer.ip)
        XCTAssertEqual([("Home", "/")], offer.roots, by: { $0.0 == $1.0 && $0.1 == $1.1 })
    }

    func testSftpOfferRejects() {
        // Error answers and unroutable packets parse as nil (the caller
        // reads `errorMessage` for the refusal reason).
        XCTAssertNil(SftpOffer.parse(Packet.of(PacketType.sftp, ("errorMessage", "Browsing is off"))))
        XCTAssertNil(SftpOffer.parse(Packet.of(PacketType.sftp, ("user", "kdeconnect"))))
        XCTAssertNil(SftpOffer.parse(Packet.of(PacketType.sftp, ("port", 0))))
        XCTAssertNil(SftpOffer.parse(Packet(type: PacketType.sftpRequest)))
        XCTAssertEqual(
            "Browsing is off",
            SftpOffer.errorMessage(Packet.of(PacketType.sftp, ("errorMessage", "Browsing is off"))))
        XCTAssertNil(SftpOffer.errorMessage(Packet(type: PacketType.ping)))
    }

    func testSftpRequestPacket() {
        let p = SftpPackets.requestPacket()
        XCTAssertEqual(PacketType.sftpRequest, p.type)
        XCTAssertEqual(true, p.bool("startBrowsing"))
    }

    // MARK: - Sending-side announcements

    func testFilePacketSerializesPort() {
        let p = ShareMessage.filePacket(
            filename: "a.bin", numberOfFiles: 2, totalPayloadSize: 20,
            payloadSize: 7, payloadPort: 1740)
        XCTAssertTrue(p.hasPayload)
        guard case .file(let f) = ShareMessage.parse(p) else { return XCTFail("unparseable") }
        XCTAssertEqual("a.bin", f.filename)
        XCTAssertEqual(7, f.payloadSize)
        XCTAssertEqual(1740, f.payloadPort)
        XCTAssertNil(f.payloadTunnel)
        XCTAssertEqual(2, f.numberOfFiles)
        XCTAssertEqual(20, f.totalPayloadSize)
    }

    func testTunnelAnnouncementParses() {
        let p = Packet(
            type: PacketType.share, body: ["filename": .string("b.bin")],
            payloadSize: 9, payloadTunnel: "tok1")
        XCTAssertTrue(p.hasPayload)
        guard case .file(let f) = ShareMessage.parse(p) else { return XCTFail("unparseable") }
        XCTAssertEqual("tok1", f.payloadTunnel)
        XCTAssertEqual(0, f.payloadPort)
    }

    // MARK: - Router

    private func ctx() -> FeatureContext {
        FeatureContext(peerId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", peerName: "pc", paired: true)
    }

    func testRouterTunnelPackets() {
        var router = FeatureRouter()
        XCTAssertEqual(
            [.event(.tunnelReady(token: "t", port: 1741))],
            router.route(TunnelPackets.ready(token: "t", port: 1741), ctx: ctx()))
        XCTAssertEqual(
            [.event(.tunnelFailed(token: "t", error: "busy"))],
            router.route(TunnelPackets.failed(token: "t", error: "busy"), ctx: ctx()))
        XCTAssertEqual(
            [.event(.ignored(type: PacketType.fluxTunnel, reason: .unhandled))],
            router.route(Packet(type: PacketType.fluxTunnel), ctx: ctx()))
    }

    func testRouterSftp() {
        var router = FeatureRouter()
        let actions = router.route(tunnelOffer(), ctx: ctx())
        guard case .event(.sftpOffer(let offer)) = actions.first, actions.count == 1 else {
            return XCTFail("expected one sftpOffer, got \(actions)")
        }
        XCTAssertEqual("tok9", offer.tunnel)
        XCTAssertEqual(
            [.event(.sftpError(message: "Browsing is off"))],
            router.route(Packet.of(PacketType.sftp, ("errorMessage", "Browsing is off")), ctx: ctx()))
        XCTAssertEqual(
            [.event(.sftpServeRequested)],
            router.route(Packet.of(PacketType.sftpRequest, ("startBrowsing", true)), ctx: ctx()))
        XCTAssertEqual(
            [.event(.ignored(type: PacketType.sftp, reason: .unhandled))],
            router.route(Packet(type: PacketType.sftp), ctx: ctx()))
    }

    func testAdvertisedCapabilities() {
        // Plan §2.2: the phone takes tunnel answers + desktop SFTP offers
        // and hears desktop browse requests (serving stays deferred).
        XCTAssertTrue(incomingCapabilities.contains(PacketType.fluxTunnel))
        XCTAssertTrue(incomingCapabilities.contains(PacketType.sftp))
        XCTAssertTrue(incomingCapabilities.contains(PacketType.sftpRequest))
        XCTAssertTrue(outgoingCapabilities.contains(PacketType.fluxTunnel))
        XCTAssertTrue(outgoingCapabilities.contains(PacketType.sftpRequest))
        XCTAssertFalse(outgoingCapabilities.contains(PacketType.sftp))
    }

    // MARK: - Destinations (Go `uniquePath` parity)

    func testUniqueDestination() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flux-unique-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = TransferEngine.uniqueDestination(directory: dir, filename: "a.txt")
        XCTAssertEqual("a.txt", first.lastPathComponent)
        try Data("x".utf8).write(to: first)
        XCTAssertEqual("a (2).txt", TransferEngine.uniqueDestination(directory: dir, filename: "a.txt").lastPathComponent)
        try Data("x".utf8).write(to: dir.appendingPathComponent("a (2).txt"))
        XCTAssertEqual("a (3).txt", TransferEngine.uniqueDestination(directory: dir, filename: "a.txt").lastPathComponent)

        // Extensionless names keep no trailing dot.
        try Data("x".utf8).write(to: dir.appendingPathComponent("f"))
        XCTAssertEqual("f (2)", TransferEngine.uniqueDestination(directory: dir, filename: "f").lastPathComponent)
    }

    // MARK: - Progress gate (Go `progress` ≤4/s parity)

    func testProgressGate() {
        var gate = ProgressGate()
        XCTAssertTrue(gate.allow(done: 0, size: 100))   // first report passes
        XCTAssertFalse(gate.allow(done: 1, size: 100))  // same tick suppressed
        XCTAssertTrue(gate.allow(done: 100, size: 100)) // final always passes
    }

    // MARK: - LiveUploadBox (D15/D18 app-originated uploads)

    func testUploadBoxDetachedPresence() {
        // No session: batches are accepted (held for the attach), never
        // dropped — `LinkService` reports false with no runners at all.
        let box = LiveUploadBox()
        XCTAssertFalse(box.attached)
        let file = URL(fileURLWithPath: "/tmp/flux-upload-hold.bin")
        XCTAssertTrue(box.sendFiles([file]))
        XCTAssertTrue(box.sendCaptures([TransferEngine.CaptureUpload(url: file, photo: true)]))
        XCTAssertFalse(box.attached)
        // Detach with no engine never traps and drops the held batches.
        box.detach()
        XCTAssertFalse(box.attached)
    }

    // MARK: - LiveSendBox (D23 app-originated packets)

    func testLiveSendWithoutSessionIsFalse() {
        let box = LiveSendBox()
        XCTAssertFalse(box.send(PingMessage.packet(message: "x")))
    }

    func testLiveSendPublishClearCycle() {
        let box = LiveSendBox()
        var sent: [String] = []
        box.publish { sent.append($0.type); return true }
        XCTAssertTrue(box.send(PingMessage.packet(message: "x")))
        XCTAssertEqual([PacketType.ping], sent)
        box.clear()
        XCTAssertFalse(box.send(PingMessage.packet(message: "x")))
        XCTAssertEqual(1, sent.count)
    }

    func testLiveSendPropagatesWriterFailure() {
        let box = LiveSendBox()
        box.publish { _ in false }
        XCTAssertFalse(box.send(PingMessage.packet(message: "x")))
    }
}

private func XCTAssertEqual(
    _ expected: [(String, String)], _ actual: [(String, String)],
    by eq: ((String, String), (String, String)) -> Bool,
    _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertTrue(expected.count == actual.count && zip(expected, actual).allSatisfy(eq),
                  "\(message) expected \(expected), got \(actual)", file: file, line: line)
}
