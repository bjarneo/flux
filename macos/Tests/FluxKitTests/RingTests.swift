import XCTest
@testable import FluxKit

final class RingTests: XCTestCase {
    func testPluginTakesTheRingRequest() {
        let plugin = MainActor.assumeIsolated { RingPlugin() }
        XCTAssertEqual(plugin.incoming, [PacketType.findMyPhone])
        XCTAssertEqual(PacketType.findMyPhone, "kdeconnect.findmyphone.request", "fluxd sends it for flux-cli ring")
        XCTAssertEqual(plugin.outgoing, [])
    }

    @MainActor
    func testASecondRingStops() {
        // Like Ringer.kt: a ring request while the phone rings stops it, so
        // the computer can stop a ring that nobody reaches.
        let plugin = RingPlugin()
        plugin.ring(from: "omarchy")
        XCTAssertEqual(plugin.model.ringing, "omarchy")
        plugin.ring(from: "omarchy")
        XCTAssertNil(plugin.model.ringing)
        plugin.ring(from: "roger")
        XCTAssertEqual(plugin.model.ringing, "roger")
        plugin.stop()
        XCTAssertNil(plugin.model.ringing)
    }

    @MainActor
    func testRingEndsByItself() async throws {
        let plugin = RingPlugin(maxDuration: .milliseconds(50))
        plugin.ring(from: "omarchy")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(plugin.model.ringing, "a ring that nobody stops ends")
        XCTAssertEqual(RingPlugin.defaultDuration, .seconds(120), "2 minutes, like on Android")
    }

    @MainActor
    func testAnOldTimeoutDoesNotStopANewRing() async throws {
        let plugin = RingPlugin(maxDuration: .milliseconds(200))
        plugin.ring(from: "omarchy")
        plugin.stop()
        try await Task.sleep(for: .milliseconds(120))
        plugin.ring(from: "omarchy")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(plugin.model.ringing, "omarchy", "the first ring's timeout is gone")
    }

    func testToneIsAWaveFile() {
        let wav = RingTone.wav()
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(le32(wav, 4), UInt32(wav.count - 8))
        XCTAssertEqual(le16(wav, 20), 1, "PCM")
        XCTAssertEqual(le16(wav, 22), 1, "mono")
        XCTAssertEqual(le32(wav, 24), UInt32(RingTone.sampleRate))
        XCTAssertEqual(le16(wav, 34), 16, "16 bits")
        XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")
        let samples = Int(le32(wav, 40)) / 2
        XCTAssertEqual(samples, Int(RingTone.duration * Double(RingTone.sampleRate)))
        var peak: Int16 = 0
        for i in 0..<samples {
            let v = Int16(bitPattern: le16(wav, 44 + i * 2))
            peak = max(peak, v == .min ? .max : abs(v))
        }
        XCTAssertGreaterThan(peak, 25_000, "the tone is loud")
        XCTAssertEqual(Int16(bitPattern: le16(wav, 44)), 0, "it starts at zero, so the loop does not click")
    }

    private func le16(_ d: Data, _ at: Int) -> UInt16 { UInt16(d[at]) | UInt16(d[at + 1]) << 8 }
    private func le32(_ d: Data, _ at: Int) -> UInt32 { UInt32(le16(d, at)) | UInt32(le16(d, at + 2)) << 16 }
}
