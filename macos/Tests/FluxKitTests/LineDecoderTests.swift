import NIOCore
import NIOEmbedded
import XCTest
@testable import FluxKit

/// Links of devices that are not paired read at most 64 KiB for each line.
/// A pairing raises the limit of the link to 16 MiB.
final class LineDecoderTests: XCTestCase {
    /// An embedded channel that closes at the end of the test. NIO stops a
    /// test that leaves one open.
    private func embedded() -> EmbeddedChannel {
        let ch = EmbeddedChannel()
        addTeardownBlock { _ = try? ch.finish() }
        return ch
    }

    private func channel(_ limit: LineLimit) throws -> EmbeddedChannel {
        let ch = embedded()
        try ch.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineDecoder(limit: limit)))
        return ch
    }

    /// `count` bytes of text, with a newline at the end when `newline` is true.
    private func bytes(_ count: Int, newline: Bool = false) -> ByteBuffer {
        var line = [UInt8](repeating: UInt8(ascii: "a"), count: count)
        if newline { line.append(0x0A) }
        return ByteBuffer(bytes: line)
    }

    private func lines(_ ch: EmbeddedChannel) throws -> [String] {
        var out: [String] = []
        while let line = try ch.readInbound(as: ByteBuffer.self) { out.append(String(buffer: line)) }
        return out
    }

    func testAnUnpairedLinkRefusesALongLine() throws {
        let ch = try channel(LineLimit(maxUnpairedLine))
        XCTAssertThrowsError(try ch.writeInbound(bytes(maxUnpairedLine + 1)))
    }

    func testAnUnpairedLinkRefusesALongLineInParts() throws {
        let ch = try channel(LineLimit(maxUnpairedLine))
        XCTAssertNoThrow(try ch.writeInbound(bytes(maxUnpairedLine / 2)))
        XCTAssertNoThrow(try ch.writeInbound(bytes(maxUnpairedLine / 2)))
        XCTAssertThrowsError(try ch.writeInbound(bytes(1)))
    }

    func testAnUnpairedLinkReadsALineAtTheLimit() throws {
        let ch = try channel(LineLimit(maxUnpairedLine))
        try ch.writeInbound(bytes(maxUnpairedLine, newline: true))
        XCTAssertEqual(try ch.readInbound(as: ByteBuffer.self)?.readableBytes, maxUnpairedLine)
    }

    func testARaisedLimitReadsTheLongLine() throws {
        let limit = LineLimit(maxUnpairedLine)
        let ch = try channel(limit)
        try ch.writeInbound(bytes(maxUnpairedLine))
        limit.set(maxLine)
        try ch.writeInbound(bytes(1, newline: true))
        XCTAssertEqual(try ch.readInbound(as: ByteBuffer.self)?.readableBytes, maxUnpairedLine + 1)
    }

    func testALineInPartsGivesOneLine() throws {
        let ch = try channel(LineLimit(maxUnpairedLine))
        try ch.writeInbound(ByteBuffer(string: "{\"type\":"))
        try ch.writeInbound(ByteBuffer(string: "\"flux.pair\""))
        try ch.writeInbound(ByteBuffer(string: "}\n{\"a\""))
        try ch.writeInbound(ByteBuffer(string: ":1}\n"))
        XCTAssertEqual(try lines(ch), ["{\"type\":\"flux.pair\"}", "{\"a\":1}"])
        XCTAssertTrue(try ch.finish().isClean)
    }

    // MARK: The limit of a device

    private let desk = Identity(deviceId: "9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b", deviceName: "desk", deviceType: "desktop",
                                protocolVersion: 8, incoming: [PacketType.fluxTunnel], outgoing: [])

    private func makeCore() throws -> FluxCore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suite = "org.omarchy.flux.test." + UUID().uuidString
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        var config = LanConfig()
        config.loopbackOnly = true
        return try FluxCore(paths: FluxPaths(data: dir, suite: suite), lanConfig: config, plugins: [])
    }

    private func link(_ limit: LineLimit) -> Link {
        Link(channel: embedded(), identity: desk, peerCertificate: [1, 2, 3], limit: limit)
    }

    func testPairingRaisesTheLimitOfTheLink() throws {
        let core = try makeCore()
        let d = Device(core: core, identity: desk)
        let limit = LineLimit(maxLine)
        d.link = link(limit)
        XCTAssertEqual(limit.value, maxUnpairedLine, "a device that is not paired gets the low limit")
        d.pairState = .incoming
        XCTAssertEqual(limit.value, maxUnpairedLine)
        d.pairState = .paired
        XCTAssertEqual(limit.value, maxLine, "the pairing raises the limit")
        d.pairState = .none
        XCTAssertEqual(limit.value, maxUnpairedLine, "an unpair lowers the limit")

        d.pairState = .paired
        let next = LineLimit(maxUnpairedLine)
        d.link = link(next)
        XCTAssertEqual(next.value, maxLine, "a new link of a paired device gets the high limit")
        withExtendedLifetime(core) {}
    }
}
