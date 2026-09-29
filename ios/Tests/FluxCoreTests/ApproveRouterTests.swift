import XCTest
@testable import FluxCore
@testable import FluxProto
@testable import FluxApprove

/// `flux.approve` routing: capability + pairing gates, request/enroll
/// prompts, cancel, and the fail-closed refusals that go straight back on
/// the wire. Mirrors Android `core/Approvals.kt` + Go `handleApprove`.
final class ApproveRouterTests: XCTestCase {
    private let nonce = ApproveMessage.testNonce
    private let nowMs: Int64 = 1_790_000_000_000
    private let computerId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    private func ctx(
        paired: Bool = true,
        incoming: [String] = incomingCapabilities,
        hasApproveKey: Bool = true
    ) -> FeatureContext {
        FeatureContext(
            peerId: computerId, peerName: "omarchy-xps", paired: paired,
            incoming: incoming, nowMs: nowMs, hasApproveKey: hasApproveKey
        )
    }

    private func packet(_ values: [String: Any?]) -> Packet {
        var body: [String: JSONValue] = [:]
        for (k, v) in values { body[k] = JSONValue.make(v) }
        return Packet(type: PacketType.fluxApprove, body: body)
    }

    private func requestPacket(id: String = "req1", kind: String = "request", extra: [String: Any?] = [:]) -> Packet {
        // Approval freshness compares against the live phone clock, so
        // requests carry live timestamps (stale cases subtract from it).
        let now = Int64(Date().timeIntervalSince1970)
        var values: [String: Any?] = [
            "kind": kind, "id": id,
            "host": "omarchy-xps", "user": "alice", "service": "sudo",
            "tty": "/dev/pts/3", "rhost": "", "time": now,
            "nonce": nonce, "timeout": 20,
        ]
        for (k, v) in extra { values[k] = v }
        return packet(values)
    }

    private func route(_ p: Packet, ctx: FeatureContext? = nil) -> (FeatureRouter, [FeatureAction]) {
        var router = FeatureRouter()
        let actions = router.route(p, ctx: ctx ?? self.ctx())
        return (router, actions)
    }

    // MARK: - Gates

    func testUnpairedDrops() {
        let (_, actions) = route(requestPacket(), ctx: ctx(paired: false))
        XCTAssertEqual([.event(.ignored(type: PacketType.fluxApprove, reason: .unpaired))], actions)
    }

    func testUnadvertisedDrops() {
        let (_, actions) = route(requestPacket(), ctx: ctx(incoming: [PacketType.ping]))
        XCTAssertEqual([.event(.ignored(type: PacketType.fluxApprove, reason: .unadvertised))], actions)
    }

    // MARK: - Prompts

    func testRequestPrompts() {
        let (_, actions) = route(requestPacket())
        guard case .event(.approveRequested(let r)) = actions.first, actions.count == 1 else {
            return XCTFail("expected one approveRequested, got \(actions)")
        }
        XCTAssertEqual("req1", r.id)
        XCTAssertEqual(.approve, r.kind)
        XCTAssertEqual(computerId, r.computerId)
    }

    func testEnrollPromptsWithoutKey() {
        let (_, actions) = route(requestPacket(id: "enr1", kind: "enroll"), ctx: ctx(hasApproveKey: false))
        guard case .event(.approveRequested(let r)) = actions.first else {
            return XCTFail("expected approveRequested, got \(actions)")
        }
        XCTAssertEqual(.enroll, r.kind)
    }

    func testCancelSurfaces() {
        let (_, actions) = route(packet(["kind": "cancel", "id": "req1"]))
        XCTAssertEqual([.event(.approveCancelled(id: "req1"))], actions)
    }

    func testMalformedStaysUnhandled() {
        // Bad nonce: nothing to hold, and no id-safe refusal path at the
        // router (the store answers `failed` on the wire instead — see below).
        let (router, actions) = route(requestPacket(extra: ["nonce": "xyz"]))
        XCTAssertEqual(1, actions.count)
        if case .send(let pkt) = actions.first {
            XCTAssertEqual("response", pkt.string("kind"))
            XCTAssertEqual(ApproveMessage.invalidRequest, pkt.string("error"))
        } else {
            XCTFail("expected a failed send, got \(actions)")
        }
        XCTAssertNil(router.approvals.current)
    }

    // MARK: - Fail-closed refusals (answered on the wire)

    func testStaleTimeRefused() {
        let stale = Int64(Date().timeIntervalSince1970) - 601
        let (_, actions) = route(requestPacket(extra: ["time": stale]))
        guard case .send(let pkt) = actions.first else { return XCTFail("expected send, got \(actions)") }
        XCTAssertEqual(ApproveMessage.clockSkewProblem, pkt.string("error"))
    }

    func testApprovalWithoutKeyRefused() {
        let (_, actions) = route(requestPacket(), ctx: ctx(hasApproveKey: false))
        guard case .send(let pkt) = actions.first else { return XCTFail("expected send, got \(actions)") }
        XCTAssertEqual(ApproveMessage.noKeyProblem, pkt.string("error"))
    }

    func testSecondRequestRefusedWhileOpen() {
        var router = FeatureRouter()
        let c = ctx()
        let first = router.route(requestPacket(id: "req1"), ctx: c)
        guard case .event(.approveRequested) = first.first else { return XCTFail("expected prompt, got \(first)") }
        let second = router.route(requestPacket(id: "req2"), ctx: c)
        guard case .send(let pkt) = second.first else { return XCTFail("expected send, got \(second)") }
        XCTAssertEqual(ApproveMessage.busyProblem, pkt.string("error"))
        XCTAssertEqual("req1", router.approvals.current?.id)
    }

    func testClearAndExpire() {
        var router = FeatureRouter()
        let c = ctx()
        _ = router.route(requestPacket(id: "req1"), ctx: c)
        XCTAssertTrue(router.approveClear(id: "req1"))
        XCTAssertNil(router.approvals.current)
        XCTAssertFalse(router.approveClear(id: "req1"))
    }
}
