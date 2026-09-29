import XCTest
@testable import FluxApprove

/// Ports of Go `internal/approve/message_test.go` + Android
/// `core/ApproveMessageTest.kt`. Bytes must match exactly.
final class FluxApproveTests: XCTestCase {
    private let nonce = ApproveMessage.testNonce

    func testApprovalBytes() throws {
        let msg = try ApproveMessage.approval(host: "omarchy-xps", user: "alice", service: "sudo", tty: "/dev/pts/3", rhost: "", time: 1_790_000_000, nonce: nonce)
        let want = "flux-approve-v1\nhost=omarchy-xps\nuser=alice\nservice=sudo\ntty=/dev/pts/3\nrhost=\ntime=1790000000\nnonce=\(nonce)\n"
        XCTAssertEqual(want, String(data: msg, encoding: .utf8))
    }

    func testEnrollmentBytes() throws {
        let msg = try ApproveMessage.enrollment(host: "omarchy-xps", user: "alice", spki: Data("test-key".utf8), time: 1_790_000_000, nonce: nonce)
        let want = "flux-approve-enroll-v1\nhost=omarchy-xps\nuser=alice\n" +
            "key=62af8704764faf8ea82fc61ce9c4c3908b6cb97d463a634e9e587d7c885db0ef\n" +
            "time=1790000000\nnonce=\(nonce)\n"
        XCTAssertEqual(want, String(data: msg, encoding: .utf8))
    }

    func testFingerprint() {
        XCTAssertEqual("62AF 8704 764F AF8E", ApproveMessage.fingerprint(Data("test-key".utf8)))
    }

    func testFieldRules() {
        XCTAssertTrue(ApproveMessage.validField("/dev/pts/3"))
        XCTAssertTrue(ApproveMessage.validField(""))
        XCTAssertTrue(ApproveMessage.validField("Pixel 8 · Office"))
        XCTAssertFalse(ApproveMessage.validField("alice\nservice=sshd"))
        XCTAssertFalse(ApproveMessage.validField("tab\there"))
        XCTAssertFalse(ApproveMessage.validField("c1"))
        XCTAssertFalse(ApproveMessage.validField(String(repeating: "x", count: 257)))
        XCTAssertTrue(ApproveMessage.validNonce(nonce))
        XCTAssertFalse(ApproveMessage.validNonce(nonce.uppercased()))
        XCTAssertFalse(ApproveMessage.validNonce(String(nonce.dropLast(2))))
    }

    func testFieldRulesThrow() {
        XCTAssertThrowsError(try ApproveMessage.approval(host: "", user: "alice", service: "sudo", tty: "", rhost: "", time: 0, nonce: nonce))
        XCTAssertThrowsError(try ApproveMessage.approval(host: "h", user: "alice\nservice=sshd", service: "sudo", tty: "", rhost: "", time: 0, nonce: nonce))
        XCTAssertThrowsError(try ApproveMessage.approval(host: "h", user: "alice", service: "sudo", tty: "", rhost: "", time: 0, nonce: "abcd"))
    }

    func testFreshness() {
        XCTAssertTrue(ApproveMessage.fresh(signedTime: 1_790_000_000, now: 1_790_000_030))
        XCTAssertTrue(ApproveMessage.fresh(signedTime: 1_790_000_000, now: 1_789_999_970))
        XCTAssertFalse(ApproveMessage.fresh(signedTime: 1_790_000_000, now: 1_790_000_601))
        XCTAssertFalse(ApproveMessage.fresh(signedTime: 1_790_000_000, now: 1_789_999_399))
    }
}
