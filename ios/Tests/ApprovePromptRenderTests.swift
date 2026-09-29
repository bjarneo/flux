import CryptoKit
import FluxKit
import SwiftUI
import UIKit
import XCTest
@testable import Flux

/// Renders the approval sheet for a request that FluxKit parses from the
/// packet that fluxd sends, and the screen of a device without a Secure
/// Enclave, and checks that each draws a screen, see `ScreenRender`.
@MainActor
final class ApprovePromptRenderTests: XCTestCase {
    /// The packet of internal/core/approve.go ApproveRequest.
    private func request() throws -> ApproveRequest {
        let nonce = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let p = Packet(PacketType.fluxApprove, [
            "kind": "request", "id": "3f9a1c0d7e2b4a6c8d0e1f2a", "host": "omarchy", "user": "snorre", "service": "sudo",
            "tty": "/dev/pts/3", "rhost": "", "time": Int64(Date().timeIntervalSince1970), "nonce": nonce, "timeout": 20,
        ])
        let wire = try XCTUnwrap(Packet.parse(p.serialize()))
        return try XCTUnwrap(ApproveMessage.parse(wire, computerId: "omarchy-id", computerName: "omarchy"))
    }

    private func render(_ view: some View, name: String) throws {
        try ScreenRender.render(view, name: name)
    }

    private func prompt(_ r: ApproveRequest, _ phase: ApprovePhase, texts: ApproveTexts = .current) -> some View {
        ApprovePromptView(request: r, phase: phase, deadline: Date().addingTimeInterval(14), texts: texts,
                          approve: {}, deny: {}, done: {})
            .background(Color(.systemBackground))
    }

    func testRendersTheRequest() throws {
        let r = try request()
        XCTAssertEqual(ApproveMessage.question(r), "Approve sudo for user snorre on host omarchy?")
        // The simulator reports Face ID for an iPhone 17 Pro, like the device.
        try render(prompt(r, .ask), name: "p7-03-prompt-request")
        try render(prompt(r, .working), name: "p7-04-prompt-working")
    }

    func testRendersTheResults() throws {
        let r = try request()
        let code = ApproveMessage.fingerprint(P256.Signing.PrivateKey().publicKey.derRepresentation)
        try render(prompt(r, .enrolled(code: code)), name: "p7-05-prompt-enrolled")
        try render(prompt(r, .failed(ApproveTexts.current.noSecureEnclave)), name: "p7-06-prompt-failed")
    }

    /// A device without a Secure Enclave. The simulator emulates one, so
    /// only this render shows the state.
    func testRendersTheUnavailableState() throws {
        let screen = NavigationStack {
            ApproveContent(plugin: ApprovePlugin(), deviceId: "omarchy-id", name: "omarchy",
                           readAvailability: { .noSecureEnclave(ApproveTexts.current.noSecureEnclave) })
                .navigationTitle("Approval")
                .navigationBarTitleDisplayMode(.inline)
        }
        try render(screen, name: "p7-02-no-secure-enclave")
    }
}
