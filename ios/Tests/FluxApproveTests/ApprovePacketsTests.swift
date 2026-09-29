import XCTest
@testable import FluxApprove
@testable import FluxProto

/// Ports of Android `core/ApproveMessageTest.kt` (parse + answer packets)
/// on top of the Go `internal/approve/message_test.go` byte vectors that
/// `FluxApproveTests` already covers.
final class ApprovePacketsTests: XCTestCase {
    private let nonce = ApproveMessage.testNonce

    private var request: ApproveRequest {
        ApproveRequest(
            computerId: "pc1", computerName: "omarchy-xps", id: "req1", kind: .approve,
            host: "omarchy-xps", user: "alice", service: "sudo",
            tty: "/dev/pts/3", rhost: "",
            time: 1_790_000_000, nonce: nonce, timeoutSeconds: 20
        )
    }

    private func packet(_ extra: [String: Any?] = [:]) -> Packet {
        var values: [String: Any?] = [
            "kind": "request", "id": "req1",
            "host": "omarchy-xps", "user": "alice", "service": "sudo",
            "tty": "/dev/pts/3", "rhost": "", "time": 1_790_000_000,
            "nonce": nonce, "timeout": 20,
        ]
        for (k, v) in extra { values[k] = v }
        var body: [String: JSONValue] = [:]
        for (k, v) in values { body[k] = JSONValue.make(v) }
        return Packet(type: PacketType.fluxApprove, body: body)
    }

    // MARK: - Parse

    func testParseRequest() {
        XCTAssertEqual(request, ApproveMessage.parse(packet(), computerId: "pc1", computerName: "omarchy-xps"))
    }

    func testParseDefaults() {
        // No tty/rhost/timeout: empty strings + the 20 s default.
        var p = packet()
        p.body.removeValue(forKey: "tty")
        p.body.removeValue(forKey: "rhost")
        p.body.removeValue(forKey: "timeout")
        let r = ApproveMessage.parse(p, computerId: "pc1", computerName: "pc")
        XCTAssertEqual("", r?.tty)
        XCTAssertEqual("", r?.rhost)
        XCTAssertEqual(20, r?.timeoutSeconds)
        // Timeout clamps to 5…120 like Android `coerceIn`.
        XCTAssertEqual(5, ApproveMessage.parse(packet(["timeout": 1]), computerId: "pc1", computerName: "pc")?.timeoutSeconds)
        XCTAssertEqual(120, ApproveMessage.parse(packet(["timeout": 999]), computerId: "pc1", computerName: "pc")?.timeoutSeconds)
    }

    func testParseRefusesBadRequests() {
        XCTAssertNil(ApproveMessage.parse(packet(["user": "alice\nservice=sshd"]), computerId: "pc1", computerName: "pc"))
        XCTAssertNil(ApproveMessage.parse(packet(["nonce": "abcd"]), computerId: "pc1", computerName: "pc"))
        XCTAssertNil(ApproveMessage.parse(packet(["host": ""]), computerId: "pc1", computerName: "pc"))
        XCTAssertNil(ApproveMessage.parse(packet(["service": ""]), computerId: "pc1", computerName: "pc"))
        XCTAssertNil(ApproveMessage.parse(packet(["kind": "other"]), computerId: "pc1", computerName: "pc"))
        XCTAssertNil(ApproveMessage.parse(packet(["id": ""]), computerId: "pc1", computerName: "pc"))
        XCTAssertNil(ApproveMessage.parse(packet(["id": String(repeating: "x", count: 65)]), computerId: "pc1", computerName: "pc"))
        var missing = packet()
        missing.body.removeValue(forKey: "time")
        XCTAssertNil(ApproveMessage.parse(missing, computerId: "pc1", computerName: "pc"))
        var other = packet()
        other.type = PacketType.ping
        XCTAssertNil(ApproveMessage.parse(other, computerId: "pc1", computerName: "pc"))
    }

    func testParseEnrollment() {
        let r = ApproveMessage.parse(
            packet(["kind": "enroll", "service": nil]),
            computerId: "pc1", computerName: "omarchy-xps")
        XCTAssertNotNil(r)
        XCTAssertEqual(.enroll, r?.kind)
        XCTAssertEqual("", r?.service)
        XCTAssertEqual(
            "Use this phone to approve sudo for user alice on host omarchy-xps?",
            ApproveMessage.question(r!))
    }

    func testQuestion() {
        XCTAssertEqual(
            "Approve sudo for user alice on host omarchy-xps?",
            ApproveMessage.question(request))
    }

    func testFreshness() {
        XCTAssertTrue(ApproveMessage.fresh(request, nowSeconds: request.time + 30))
        XCTAssertTrue(ApproveMessage.fresh(request, nowSeconds: request.time - 30))
        XCTAssertFalse(ApproveMessage.fresh(request, nowSeconds: request.time + 601))
        XCTAssertFalse(ApproveMessage.fresh(request, nowSeconds: request.time - 601))
    }

    // MARK: - Cancel

    func testCancelId() {
        let cancel = Packet.of(PacketType.fluxApprove, ("kind", "cancel"), ("id", "req1"))
        XCTAssertEqual("req1", ApproveMessage.cancelId(cancel))
        XCTAssertNil(ApproveMessage.cancelId(packet()))
        let empty = Packet.of(PacketType.fluxApprove, ("kind", "cancel"), ("id", ""))
        XCTAssertNil(ApproveMessage.cancelId(empty))
    }

    // MARK: - Replies

    func testAnswerPackets() throws {
        let sig = Data([1, 2, 3])
        let a = ApproveMessage.approved(id: "req1", signature: sig)
        XCTAssertEqual(PacketType.fluxApprove, a.type)
        XCTAssertEqual("response", a.string("kind"))
        XCTAssertEqual("req1", a.string("id"))
        XCTAssertEqual(sig.base64EncodedString(), a.string("signature"))
        XCTAssertNil(a.bool("denied"))

        let d = ApproveMessage.denied(id: "req1")
        XCTAssertEqual("response", d.string("kind"))
        XCTAssertEqual(true, d.bool("denied"))
        XCTAssertNil(d.string("signature"))

        let e = ApproveMessage.enrolled(id: "req1", spki: Data("key".utf8), signature: sig)
        XCTAssertEqual("enrolled", e.string("kind"))
        XCTAssertEqual(Data("key".utf8).base64EncodedString(), e.string("publicKey"))

        let f = ApproveMessage.failed(id: "req1", message: String(repeating: "x", count: 500))
        XCTAssertEqual(200, f.string("error")?.count)

        // A packet survives the wire format.
        let back = Packet.parse(try a.serialize())
        XCTAssertEqual(a.string("signature"), back?.string("signature"))
    }
}
