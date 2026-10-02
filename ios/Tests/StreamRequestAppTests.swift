import FluxKit
import SwiftUI
import XCTest
@testable import Flux

/// The stream request in the iPhone app: the start that waits for Flux on
/// the screen and for the link, the screen that opens, and the prompt.
@MainActor
final class StreamRequestAppTests: XCTestCase {
    private func pending(_ kind: StreamRequest.Kind = .webcam, deadline: ContinuousClock.Instant) -> PendingStart {
        PendingStart(kind: kind, computerId: "pc1", computerName: "omarchy", deadline: deadline)
    }

    func testTheStartWaitsForTheScreenAndTheLink() {
        let now = ContinuousClock.now
        let p = pending(deadline: now + .seconds(15))
        XCTAssertEqual(p.step(active: true, online: true, now: now), .start)
        XCTAssertEqual(p.step(active: false, online: true, now: now), .wait, "the camera of an iPhone needs Flux on the screen")
        XCTAssertEqual(p.step(active: true, online: false, now: now), .wait, "the link comes back after Flux opens")
        XCTAssertEqual(p.step(active: true, online: false, now: now + .seconds(15)), .giveUp)
        XCTAssertEqual(p.step(active: true, online: true, now: now + .seconds(20)), .start, "a late link still starts")
        XCTAssertEqual(PendingStart.wait, .seconds(15))
    }

    func testTheTextWhenTheStreamDidNotStart() {
        let now = ContinuousClock.now
        XCTAssertEqual(pending(.webcam, deadline: now).failedText, "The webcam did not start, because omarchy is not connected.")
        XCTAssertEqual(pending(.mic, deadline: now).failedText, "The microphone did not start, because omarchy is not connected.")
    }

    func testTheStartOpensTheScreenOfControl() {
        XCTAssertEqual(PendingStart.route(.webcam, computerId: "pc1"), .cameraMode("pc1", .webcam))
        XCTAssertEqual(PendingStart.route(.mic, computerId: "pc1"), .mic("pc1"))
    }

    func testTheIPhoneListsTheRequest() throws {
        let app = try TestApp.model(plugins: PluginRegistry.make())
        XCTAssertTrue(app.core.incomingCapabilities.contains(PacketType.fluxStreamRequest), "the iPhone streams the webcam and the mic")
        XCTAssertTrue(DemoMode.outgoing.contains(PacketType.fluxStreamRequest), "fluxd sends the request")
    }

    func testRendersThePrompt() throws {
        for kind in StreamRequest.Kind.allCases {
            let request = StreamRequest(computerId: "pc1", computerName: "omarchy", kind: kind, received: .now)
            try ScreenRender.render(StreamRequestSheet(request: request, start: {}, notNow: {}), name: "stream-request-\(kind.rawValue)")
        }
    }
}
