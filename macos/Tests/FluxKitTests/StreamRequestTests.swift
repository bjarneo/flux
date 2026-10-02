import XCTest
@testable import FluxKit

/// The parts of a stream request that need no core: the packet, the texts,
/// and the time limits of `StreamRequestBook`.
final class StreamRequestTests: XCTestCase {
    private let t0 = ContinuousClock.now

    private func at(_ seconds: Double) -> ContinuousClock.Instant {
        t0 + .milliseconds(Int64(seconds * 1000))
    }

    /// The packet that fluxd sends, after a trip through the wire format.
    private func wire(_ body: [String: Any?], type: String = PacketType.fluxStreamRequest) throws -> Packet {
        try XCTUnwrap(Packet.parse(Packet(type, body).serialize()))
    }

    func testThePacketType() {
        XCTAssertEqual(PacketType.fluxStreamRequest, "flux.stream.request", "fluxd and Android use the same name")
    }

    func testParsesTheKinds() throws {
        XCTAssertEqual(StreamRequest.Kind.parse(try wire(["kind": "webcam"])), .webcam)
        XCTAssertEqual(StreamRequest.Kind.parse(try wire(["kind": "mic"])), .mic)
    }

    func testIgnoresOtherKindsAndKeepsExtraFields() throws {
        XCTAssertNil(StreamRequest.Kind.parse(try wire(["kind": "screen"])))
        XCTAssertNil(StreamRequest.Kind.parse(try wire(["kind": "Webcam"])), "the kind is exact")
        XCTAssertNil(StreamRequest.Kind.parse(try wire(["kind": ""])))
        XCTAssertNil(StreamRequest.Kind.parse(try wire([:])))
        XCTAssertNil(StreamRequest.Kind.parse(try wire(["kind": 1])))
        XCTAssertNil(StreamRequest.Kind.parse(try wire(["kind": "webcam"], type: PacketType.fluxWebcam)), "only flux.stream.request asks")
        XCTAssertEqual(StreamRequest.Kind.parse(try wire(["kind": "mic", "start": true, "port": 1745])), .mic,
                       "an extra field changes nothing")
    }

    func testTheTextsOfTheContract() {
        XCTAssertEqual(StreamRequest.Kind.webcam.title(computer: "omarchy"), "omarchy asks for the webcam")
        XCTAssertEqual(StreamRequest.Kind.mic.title(computer: "omarchy"), "omarchy asks for the mic")
        XCTAssertEqual(StreamRequest.Kind.webcam.startLabel, "Start webcam")
        XCTAssertEqual(StreamRequest.Kind.mic.startLabel, "Start the mic")
        XCTAssertEqual(StreamRequest.notNowLabel, "Not now")
        XCTAssertEqual(StreamRequest.Kind.webcam.notificationText, "Tap to start the webcam.")
        XCTAssertEqual(StreamRequest.Kind.mic.notificationText, "Tap to start the mic.")
        XCTAssertEqual(StreamRequest.Kind.webcam.detail(computer: "omarchy", platform: .phone),
                       "Apps on omarchy see this iPhone as Flux Camera. The camera stays off until you select Start webcam.")
        XCTAssertEqual(StreamRequest.Kind.mic.detail(computer: "omarchy", platform: .mac),
                       "Apps on omarchy see this Mac as Flux Microphone. The microphone stays off until you select Start the mic.")
        XCTAssertEqual(StreamRequest.Kind.webcam.notificationCategory, "stream.webcam")
        XCTAssertEqual(StreamRequest.Kind.mic.notificationCategory, "stream.mic")
    }

    func testTheTimeLimits() {
        XCTAssertEqual(StreamRequest.minInterval, .seconds(3))
        XCTAssertEqual(StreamRequest.lifetime, .seconds(60))
    }

    func testARequestOpens() {
        var book = StreamRequestBook()
        let outcome = book.receive(.webcam, computerId: "pc1", computerName: "omarchy", streaming: false, at: at(0))
        let r = StreamRequest(computerId: "pc1", computerName: "omarchy", kind: .webcam, received: at(0))
        XCTAssertEqual(outcome, .opened(r))
        XCTAssertEqual(book.requests, [r])
        XCTAssertEqual(r.id, "stream.webcam.pc1")
        XCTAssertEqual(r.title, "omarchy asks for the webcam")
    }

    func testTheSameKindFromTheSameComputerWaits3Seconds() {
        var book = StreamRequestBook()
        _ = book.receive(.webcam, computerId: "pc1", computerName: "omarchy", streaming: false, at: at(0))
        XCTAssertEqual(book.receive(.webcam, computerId: "pc1", computerName: "omarchy", streaming: false, at: at(2.9)), .tooSoon)
        XCTAssertEqual(book.requests.map(\.received), [at(0)], "the ignored request changes nothing")
        guard case .opened(let next) = book.receive(.webcam, computerId: "pc1", computerName: "omarchy", streaming: false, at: at(3)) else {
            return XCTFail("a request 3 seconds after the last one opens")
        }
        XCTAssertEqual(book.requests, [next], "it replaces the open request of the same computer and kind")
        XCTAssertEqual(next.received, at(3))
    }

    func testAnIgnoredRequestDoesNotMoveTheLimit() {
        var book = StreamRequestBook()
        _ = book.receive(.mic, computerId: "pc1", computerName: "omarchy", streaming: false, at: at(0))
        XCTAssertEqual(book.receive(.mic, computerId: "pc1", computerName: "omarchy", streaming: false, at: at(2)), .tooSoon)
        guard case .opened = book.receive(.mic, computerId: "pc1", computerName: "omarchy", streaming: false, at: at(3.5)) else {
            return XCTFail("the limit counts from the last request that the device took")
        }
    }

    func testOtherKindsAndComputersDoNotWait() {
        var book = StreamRequestBook()
        _ = book.receive(.webcam, computerId: "pc1", computerName: "omarchy", streaming: false, at: at(0))
        guard case .opened = book.receive(.mic, computerId: "pc1", computerName: "omarchy", streaming: false, at: at(0.5)),
              case .opened = book.receive(.webcam, computerId: "pc2", computerName: "studio", streaming: false, at: at(1)) else {
            return XCTFail("the limit is per computer and kind")
        }
        XCTAssertEqual(book.requests.map(\.id), ["stream.webcam.pc1", "stream.mic.pc1", "stream.webcam.pc2"], "the oldest first")
    }

    func testARunningStreamIgnoresTheRequest() {
        var book = StreamRequestBook()
        XCTAssertEqual(book.receive(.webcam, computerId: "pc1", computerName: "omarchy", streaming: true, at: at(0)), .streaming)
        XCTAssertTrue(book.requests.isEmpty)
        guard case .opened = book.receive(.webcam, computerId: "pc1", computerName: "omarchy", streaming: false, at: at(1)) else {
            return XCTFail("a request that the device ignored starts no limit")
        }
    }

    func testARequestEndsAfter60Seconds() {
        var book = StreamRequestBook()
        _ = book.receive(.webcam, computerId: "pc1", computerName: "omarchy", streaming: false, at: at(0))
        _ = book.receive(.mic, computerId: "pc1", computerName: "omarchy", streaming: false, at: at(30))
        let webcam = book.requests[0]
        XCTAssertTrue(book.fresh(webcam, at: at(59.9)))
        XCTAssertFalse(book.fresh(webcam, at: at(60)))
        XCTAssertEqual(book.expire(at: at(59.9)), [])
        XCTAssertEqual(book.expire(at: at(60)).map(\.id), ["stream.webcam.pc1"])
        XCTAssertEqual(book.requests.map(\.id), ["stream.mic.pc1"])
        XCTAssertEqual(book.expire(at: at(90)).map(\.id), ["stream.mic.pc1"])
        XCTAssertTrue(book.requests.isEmpty)
    }

    func testRemoveAndForget() {
        var book = StreamRequestBook()
        _ = book.receive(.webcam, computerId: "pc1", computerName: "omarchy", streaming: false, at: at(0))
        _ = book.receive(.mic, computerId: "pc1", computerName: "omarchy", streaming: false, at: at(0))
        _ = book.receive(.mic, computerId: "pc2", computerName: "studio", streaming: false, at: at(0))
        XCTAssertEqual(book.remove("stream.mic.pc2")?.computerName, "studio")
        XCTAssertNil(book.remove("stream.mic.pc2"), "a request ends once")
        XCTAssertEqual(book.forget("pc1").map(\.id), ["stream.webcam.pc1", "stream.mic.pc1"])
        XCTAssertTrue(book.requests.isEmpty)
        guard case .opened = book.receive(.webcam, computerId: "pc1", computerName: "omarchy", streaming: false, at: at(1)) else {
            return XCTFail("a computer that pairs again starts with no limit")
        }
    }
}
