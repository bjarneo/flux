import XCTest
@testable import FluxCore
@testable import FluxProto

/// `LinkService.send` (D23): false with no sessions up — app-originated
/// packets (telephony, Focus, runcommand requests) are dropped, never
/// silently half-sent. Live-session fan-out needs a real link and is
/// device-gated. Same contract for live streams (D16): `offerStream` is
/// false with no sessions, `stopStream` is a silent no-op.
final class LinkServiceTests: XCTestCase {
    func testSendWithNoSessionsIsFalse() {
        let service = LinkService(deviceName: "iPhone")
        XCTAssertFalse(service.send(PingMessage.packet(message: "x")))
    }

    func testStopWithNoSessionsIsClean() {
        let service = LinkService(deviceName: "iPhone")
        service.stop()
        XCTAssertFalse(service.send(PingMessage.packet(message: "x")))
        XCTAssertEqual(.stopped, service.state)
    }

    func testOfferStreamWithNoSessionsIsFalse() {
        let service = LinkService(deviceName: "iPhone")
        let chunks = AsyncStream<Data> { $0.finish() }
        let offer = LiveOffer(kind: .mic, buildStart: { MicPackets.start(port: $0) }, chunks: chunks)
        XCTAssertFalse(service.offerStream(offer))
        // No sessions: stopping any kind is a silent no-op, never a trap.
        service.stopStream(kind: .mic)
        service.stopStream(kind: .webcam, announce: false)
    }

    /// `LinkService.sendFiles/sendCaptures` (D15/D18): false with no
    /// sessions up — app captures queue in the outbox, never silently
    /// half-sent. Fan-out over live runners needs a real link and is
    /// loopback-covered in `UploadLiveTests`.
    func testSendUploadsWithNoSessionsIsFalse() {
        let service = LinkService(deviceName: "iPhone")
        let file = URL(fileURLWithPath: "/tmp/flux-upload-queued.bin")
        XCTAssertFalse(service.sendFiles([file]))
        XCTAssertFalse(service.sendCaptures([]))
        XCTAssertFalse(service.sendCaptures(
            [TransferEngine.CaptureUpload(url: file, scan: true)]))
    }
}
