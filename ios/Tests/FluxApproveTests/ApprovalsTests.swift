import XCTest
@testable import FluxApprove
@testable import FluxProto

/// Port of the Android `Approvals.receive` rules: one request at a time,
/// fail-closed refusals, cancel, and local timeout. Clock and key presence
/// are injected — no biometrics, no sockets.
final class ApprovalsTests: XCTestCase {
    private let nonce = ApproveMessage.testNonce
    private let now: Int64 = 1_790_000_000
    private let computerId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    private func store(hasKey: Bool = true, at: Int64? = nil) -> ApprovalsStore {
        let now = at ?? self.now
        return ApprovalsStore(nowSeconds: { now }, hasKey: { _ in hasKey })
    }

    private func requestPacket(id: String = "req1", kind: String = "request", extra: [String: Any?] = [:]) -> Packet {
        var values: [String: Any?] = [
            "kind": kind, "id": id,
            "host": "omarchy-xps", "user": "alice", "service": "sudo",
            "tty": "/dev/pts/3", "rhost": "", "time": now,
            "nonce": nonce, "timeout": 20,
        ]
        for (k, v) in extra { values[k] = v }
        var body: [String: JSONValue] = [:]
        for (k, v) in values { body[k] = JSONValue.make(v) }
        return Packet(type: PacketType.fluxApprove, body: body)
    }

    private func failedMessage(_ intake: ApprovalsStore.Intake?) -> String? {
        guard case .reply(let p) = intake else { return nil }
        return p.string("error")
    }

    // MARK: - Receive

    func testHoldValidRequest() {
        var s = store()
        let intake = s.receive(requestPacket(), computerId: computerId, computerName: "omarchy-xps")
        guard case .hold(let r) = intake else { return XCTFail("expected hold") }
        XCTAssertEqual("req1", r.id)
        XCTAssertEqual(.approve, r.kind)
        XCTAssertEqual("req1", s.current?.id)
    }

    func testHoldEnrollmentWithoutKey() {
        // Enrollments make the key: no `hasKey` check (Android parity).
        var s = store(hasKey: false)
        let intake = s.receive(requestPacket(id: "enr1", kind: "enroll"), computerId: computerId, computerName: "pc")
        guard case .hold(let r) = intake else { return XCTFail("expected hold") }
        XCTAssertEqual(.enroll, r.kind)
    }

    func testInvalidPacketGetsFailedReply() {
        var s = store()
        let intake = s.receive(requestPacket(extra: ["nonce": "abcd"]), computerId: computerId, computerName: "pc")
        XCTAssertEqual(ApproveMessage.invalidRequest, failedMessage(intake))
        XCTAssertNil(s.current)
    }

    func testIdLessPacketDropsSilently() {
        var s = store()
        var p = requestPacket()
        p.body.removeValue(forKey: "id")
        XCTAssertNil(s.receive(p, computerId: computerId, computerName: "pc"))
        XCTAssertNil(s.current)
    }

    func testStaleTimeGetsClockReply() {
        var s = store()
        let intake = s.receive(
            requestPacket(extra: ["time": now - 601]), computerId: computerId, computerName: "pc")
        XCTAssertEqual(ApproveMessage.clockSkewProblem, failedMessage(intake))
        XCTAssertNil(s.current)
    }

    func testApprovalWithoutKeyGetsEnrollReply() {
        var s = store(hasKey: false)
        let intake = s.receive(requestPacket(), computerId: computerId, computerName: "pc")
        XCTAssertEqual(ApproveMessage.noKeyProblem, failedMessage(intake))
        XCTAssertNil(s.current)
    }

    func testSecondRequestGetsBusyReply() {
        var s = store()
        _ = s.receive(requestPacket(id: "req1"), computerId: computerId, computerName: "pc")
        let intake = s.receive(requestPacket(id: "req2"), computerId: computerId, computerName: "pc")
        XCTAssertEqual(ApproveMessage.busyProblem, failedMessage(intake))
        // The first request still waits.
        XCTAssertEqual("req1", s.current?.id)
    }

    func testSameIdReplaces() {
        // A re-sent request with the same id is the same request, not busy.
        var s = store()
        _ = s.receive(requestPacket(id: "req1"), computerId: computerId, computerName: "pc")
        let intake = s.receive(requestPacket(id: "req1"), computerId: computerId, computerName: "pc")
        guard case .hold(let r) = intake else { return XCTFail("expected hold") }
        XCTAssertEqual("req1", r.id)
    }

    // MARK: - Cancel / resolve / expire

    func testCancelClears() {
        var s = store()
        _ = s.receive(requestPacket(), computerId: computerId, computerName: "pc")
        XCTAssertTrue(s.cancel(id: "req1"))
        XCTAssertNil(s.current)
        XCTAssertFalse(s.cancel(id: "req1"))
        XCTAssertFalse(s.cancel(id: "other"))
    }

    func testResolveClearsAfterAnswer() {
        var s = store()
        _ = s.receive(requestPacket(), computerId: computerId, computerName: "pc")
        XCTAssertTrue(s.resolve(id: "req1"))
        XCTAssertNil(s.current)
    }

    func testExpireClosesAtTimeout() {
        let clock = MutableNow(now)
        var s = ApprovalsStore(nowSeconds: clock.get, hasKey: { _ in true })
        _ = s.receive(requestPacket(extra: ["timeout": 20]), computerId: computerId, computerName: "pc")
        clock.set(now + 19)
        XCTAssertNil(s.expire())
        XCTAssertEqual("req1", s.current?.id)
        clock.set(now + 20)
        XCTAssertEqual("req1", s.expire()?.id)
        XCTAssertNil(s.current)
    }
}

/// Lock-guarded test clock for the injectable `nowSeconds`.
private final class MutableNow: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Int64

    init(_ t: Int64) { self.t = t }

    func get() -> Int64 { lock.withLock { t } }
    func set(_ v: Int64) { lock.withLock { t = v } }
}
