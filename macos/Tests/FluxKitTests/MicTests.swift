import XCTest
@testable import FluxKit

@MainActor
final class MicTests: XCTestCase {
    func testCapabilityIsInBothLists() {
        let plugin = MicPlugin()
        XCTAssertTrue(plugin.incoming.contains(PacketType.fluxMic))
        XCTAssertTrue(plugin.outgoing.contains(PacketType.fluxMic))
    }

    func testStartBodyHasTheFormat() {
        let p = MicPackets.start(port: 1745)
        XCTAssertEqual(p.type, PacketType.fluxMic)
        XCTAssertEqual(p.string("state"), "start")
        XCTAssertEqual(p.int("port"), 1745)
        XCTAssertEqual(p.int("rate"), 48000)
        XCTAssertEqual(p.int("channels"), 1)
        XCTAssertEqual(p.string("format"), "s16le")
        XCTAssertEqual(Packet.parse(p.serialize())?.int("port"), 1745)
    }

    func testParsesReplies() {
        XCTAssertEqual(MicReply.parse(Packet(PacketType.fluxMic, ["state": "live", "source": "Flux Microphone"])), .live(source: "Flux Microphone"))
        XCTAssertEqual(MicReply.parse(Packet(PacketType.fluxMic, ["state": "live"])), .live(source: "Flux Microphone"))
        XCTAssertEqual(MicReply.parse(Packet(PacketType.fluxMic, ["state": "error", "message": "no pw-cat"])), .failed("no pw-cat"))
        XCTAssertEqual(MicReply.parse(Packet(PacketType.fluxMic, ["state": "error", "message": ""])), .failed("The computer could not start the microphone"))
        XCTAssertEqual(MicReply.parse(Packet(PacketType.fluxMic, ["state": "stop"])), .stop)
        XCTAssertNil(MicReply.parse(Packet(PacketType.fluxMic, ["state": "start"])))
        XCTAssertNil(MicReply.parse(Packet(PacketType.fluxWebcam, ["state": "live"])))
    }

    func testWritesLittleEndianSamples() {
        let samples: [Int16] = [0x0102, -1, .min, .max]
        var out = [UInt8](repeating: 0, count: 8)
        samples.withUnsafeBufferPointer { s in out.withUnsafeMutableBytes { Pcm.toLittleEndian(s, into: $0) } }
        XCTAssertEqual(out, [0x02, 0x01, 0xff, 0xff, 0x00, 0x80, 0xff, 0x7f])
    }

    func testPeakGoesFromSilenceToFullScale() {
        func peak(_ samples: [Int16], _ n: Int) -> Float {
            samples.withUnsafeBufferPointer { Pcm.peak(UnsafeBufferPointer(rebasing: $0[0..<n])) }
        }
        XCTAssertEqual(peak([Int16](repeating: 0, count: 10), 10), 0)
        XCTAssertEqual(peak([100, -16384, 20], 3), 0.5, accuracy: 0.001)
        XCTAssertEqual(peak([.min], 1), 1)
        // Only the samples in the buffer count.
        XCTAssertEqual(peak([0, .max], 1), 0)
    }
}
