import FluxKit
import SwiftUI
import XCTest
@testable import Flux

/// The stream request in the iPhone app: the screen that opens and the
/// prompt. FluxKitTests tests the start that waits for Flux on the screen
/// and for the link, see `PendingStart`.
@MainActor
final class StreamRequestAppTests: XCTestCase {
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
