import XCTest
@testable import FluxCore
@testable import FluxProto
@testable import FluxApprove
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// `ApproveFlow` biometric outcomes (D20): enrollment-change invalidation +
/// re-enroll guidance, lockout vs. gone, cancel, and the stale-resolve
/// guard. Auth is injected (no finger on CI); keys are harness-only
/// memory keys (`createTestKey(stored:false)`), so these leave zero
/// Keychain residue. The enroll path is NOT covered here: `answerEnroll`
/// calls the production `ApproveKeys.create`, which touches the real
/// Keychain — that branch is device-gated by design.
final class ApproveFlowTests: XCTestCase {
    private func request(id: String, kind: ApproveRequest.Kind = .approve, timeout: Int = 5) -> ApproveRequest {
        ApproveRequest(
            computerId: "flowtest-\(id)", computerName: "omarchy-xps", id: id, kind: kind,
            host: "omarchy-xps", user: "alice", service: "sudo",
            tty: "/dev/pts/3", rhost: "",
            time: Int64(Date().timeIntervalSince1970), nonce: ApproveMessage.testNonce,
            timeoutSeconds: timeout)
    }

    /// Runs `decide` on a thread, accepts once the prompt opens, and
    /// returns the reply. `pendingRequest` retries internally, so the
    /// accept cannot precede the open (the resolve guard would drop it).
    private func decideAccepting(_ flow: ApproveFlow, _ r: ApproveRequest) -> Packet? {
        var reply: Packet?
        let done = expectation(description: "decide \(r.id)")
        Thread.detachNewThread {
            reply = flow.decide(r)
            done.fulfill()
        }
        XCTAssertNotNil(flow.pendingRequest(id: r.id), "prompt \(r.id) never opened")
        flow.resolve(id: r.id, accept: true)
        wait(for: [done], timeout: 10)
        return reply
    }

    func testBiometryGoneDeletesKeyAndPointsAtReenroll() throws {
        let cid = "flowtest-gone-\(UUID().uuidString)"
        try ApproveKeys.createTestKey(computerId: cid, stored: false)
        XCTAssertTrue(ApproveKeys.has(computerId: cid))
        let flow = ApproveFlow(authenticate: { _ in .biometryGone })
        let r = request(id: "gone1")
        // Re-key the request at this test's computer id.
        let req = ApproveRequest(
            computerId: cid, computerName: r.computerName, id: r.id, kind: r.kind,
            host: r.host, user: r.user, service: r.service, tty: r.tty, rhost: r.rhost,
            time: r.time, nonce: r.nonce, timeoutSeconds: r.timeoutSeconds)
        let reply = decideAccepting(flow, req)
        XCTAssertEqual(ApproveMessage.biometryChangedProblem, reply?.string("error"))
        XCTAssertFalse(ApproveKeys.has(computerId: cid), "dead key must be deleted")
        // The UI reads the message once for the `.failed` phase…
        XCTAssertEqual(ApproveMessage.biometryChangedProblem, flow.failureMessage(id: req.id))
        // …then it is gone (read-once, no residue).
        XCTAssertNil(flow.failureMessage(id: req.id))
    }

    func testNoKeyShortCircuitsBeforeAuth() {
        // With no enrolled key the flow answers enroll-first without ever
        // prompting biometrics (the injected auth must not run).
        let flow = ApproveFlow(authenticate: { _ in
            XCTFail("no-key approvals must not reach auth")
            return .failed("unreachable")
        })
        let reply = decideAccepting(flow, request(id: "nokey1"))
        XCTAssertEqual(ApproveMessage.noKeyProblem, reply?.string("error"))
        XCTAssertEqual(ApproveMessage.noKeyProblem, flow.failureMessage(id: "nokey1"))
    }

#if canImport(LocalAuthentication)
    func testAuthErrorMapping() {
        func err(_ code: LAError.Code) -> NSError {
            NSError(domain: "com.apple.LocalAuthentication", code: code.rawValue, userInfo: nil)
        }
        // Device finding 2026-09-27: a misread after adding a fingerprint
        // must read as a retry, never as a dead key. Unknown auth causes
        // retry too (key kept); only proven-dead keys are deleted.
        if case .failed(let m) = ApproveFlow.mapAuthError(err(.authenticationFailed)) {
            XCTAssertEqual(ApproveMessage.biometryRetryProblem, m)
        } else {
            XCTFail("authenticationFailed must map to the retry message")
        }
        // "Enter Password" on the biometric dialog is a decline.
        if case .cancelled = ApproveFlow.mapAuthError(err(.userFallback)) {
        } else {
            XCTFail("userFallback must map to cancelled")
        }
        if case .cancelled = ApproveFlow.mapAuthError(err(.userCancel)) {
        } else {
            XCTFail("userCancel must map to cancelled")
        }
        if case .biometryGone = ApproveFlow.mapAuthError(err(.biometryNotEnrolled)) {
        } else {
            XCTFail("biometryNotEnrolled must map to biometryGone")
        }
        if case .lockedOut = ApproveFlow.mapAuthError(err(.biometryLockout)) {
        } else {
            XCTFail("biometryLockout must map to lockedOut")
        }
        // Unknown cause (and nil): retry, key kept.
        if case .failed(let m) = ApproveFlow.mapAuthError(err(.invalidContext)) {
            XCTAssertEqual(ApproveMessage.biometryRetryProblem, m)
        } else {
            XCTFail("unknown errors must map to the retry message")
        }
        if case .failed(let m) = ApproveFlow.mapAuthError(nil) {
            XCTAssertEqual(ApproveMessage.biometryRetryProblem, m)
        } else {
            XCTFail("nil errors must map to the retry message")
        }
    }
#endif

    func testLockoutKeepsKeyAndNamesThePasscode() throws {
        let cid = "flowtest-lock-\(UUID().uuidString)"
        try ApproveKeys.createTestKey(computerId: cid, stored: false)
        let flow = ApproveFlow(authenticate: { _ in .lockedOut })
        let base = request(id: "lock1")
        let req = ApproveRequest(
            computerId: cid, computerName: base.computerName, id: base.id, kind: base.kind,
            host: base.host, user: base.user, service: base.service, tty: base.tty,
            rhost: base.rhost, time: base.time, nonce: base.nonce,
            timeoutSeconds: base.timeoutSeconds)
        let reply = decideAccepting(flow, req)
        XCTAssertEqual(ApproveMessage.biometryLockoutProblem, reply?.string("error"))
        XCTAssertTrue(ApproveKeys.has(computerId: cid), "lockout must not delete the key")
        ApproveKeys.delete(computerId: cid)
    }

    func testCancelledIsDeniedWithoutFailureMessage() {
        let flow = ApproveFlow(authenticate: { _ in
            XCTFail("cancelled must not reach auth")
            return .failed("unreachable")
        })
        var reply: Packet?
        let done = expectation(description: "decide cancel1")
        let r = request(id: "cancel1")
        Thread.detachNewThread {
            reply = flow.decide(r)
            done.fulfill()
        }
        XCTAssertNotNil(flow.pendingRequest(id: r.id))
        flow.resolve(id: r.id, accept: false)
        wait(for: [done], timeout: 10)
        XCTAssertEqual(true, reply?.bool("denied"))
        XCTAssertNil(flow.failureMessage(id: r.id))
    }

    func testStaleResolveIsIgnored() {        let flow = ApproveFlow(authenticate: { _ in
            XCTFail("stale verdict must not reach auth")
            return .failed("unreachable")
        })
        // A verdict with nobody waiting must not linger: the prompt below
        // must time out instead of consuming it.
        flow.resolve(id: "ghost", accept: true)
        var reply: Packet? = Packet(type: PacketType.ping)
        let done = expectation(description: "decide ghost")
        Thread.detachNewThread {
            reply = flow.decide(self.request(id: "ghost", timeout: 1))
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertNil(reply, "stale accept must not answer a later prompt")
        XCTAssertNil(flow.failureMessage(id: "ghost"))
    }

#if canImport(LocalAuthentication)
    func testApprovedSignatureVerifies() throws {
        let cid = "flowtest-ok-\(UUID().uuidString)"
        let spki = try ApproveKeys.createTestKey(computerId: cid, stored: false)
        let flow = ApproveFlow(authenticate: { _ in .ok(LAContext()) })
        let base = request(id: "ok1")
        let req = ApproveRequest(
            computerId: cid, computerName: base.computerName, id: base.id, kind: base.kind,
            host: base.host, user: base.user, service: base.service, tty: base.tty,
            rhost: base.rhost, time: base.time, nonce: base.nonce,
            timeoutSeconds: base.timeoutSeconds)
        let reply = decideAccepting(flow, req)
        guard let sigB64 = reply?.string("signature"),
              let sig = Data(base64Encoded: sigB64) else {
            return XCTFail("expected an approved packet with a signature")
        }
        let msg = try ApproveMessage.approval(
            host: req.host, user: req.user, service: req.service,
            tty: req.tty, rhost: req.rhost, time: req.time, nonce: req.nonce)
        XCTAssertTrue(ApproveKeys.verify(signature: sig, message: msg, spki: spki))
        XCTAssertNil(flow.failureMessage(id: req.id), "approvals carry no error")
        ApproveKeys.delete(computerId: cid)
    }
#endif
}
