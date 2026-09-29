import XCTest
@testable import FluxFeatures
@testable import FluxProto
@testable import FluxApprove
#if canImport(UserNotifications)
import UserNotifications
#endif

/// M6 approval notification mapping: titles, time-sensitive content, and
/// the Approve/Deny category. Delivery over a locked phone is
/// device-gated; the mapping below runs on macOS.
final class ApproveNotificationsTests: XCTestCase {
    private func request(kind: ApproveRequest.Kind = .approve) -> ApproveRequest {
        ApproveRequest(
            computerId: "pc1", computerName: "omarchy-xps", id: "req1", kind: kind,
            host: "omarchy-xps", user: "alice", service: "sudo",
            tty: "/dev/pts/3", rhost: "",
            time: 1_790_000_000, nonce: ApproveMessage.testNonce, timeoutSeconds: 20)
    }

    func testTitles() {
        XCTAssertEqual("Approve sudo on omarchy-xps?", ApproveNotifications.title(for: request()))
        XCTAssertEqual("Enroll this phone on omarchy-xps?", ApproveNotifications.title(for: request(kind: .enroll)))
    }

    func testContentMapping() {
#if canImport(UserNotifications)
        guard let content = ApproveNotifications.content(for: request()) as? UNMutableNotificationContent else {
            return XCTFail("expected notification content")
        }
        XCTAssertEqual("Approve sudo on omarchy-xps?", content.title)
        XCTAssertEqual("Approve sudo for user alice on host omarchy-xps?", content.body)
        XCTAssertEqual(ApproveNotifications.categoryId, content.categoryIdentifier)
        XCTAssertEqual("flux-approve-req1", content.threadIdentifier)
        if #available(iOS 15.0, macOS 13.0, *) {
            // Level exonerated 2026-09-27 (off changed nothing on device).
            XCTAssertEqual(.timeSensitive, content.interruptionLevel)
        }
#else
        XCTAssertNil(ApproveNotifications.content(for: request()))
#endif
    }

    func testActionIdentifiers() {
        XCTAssertEqual("org.omarchy.flux.approve", ApproveNotifications.categoryId)
        XCTAssertEqual("org.omarchy.flux.approve.approve", ApproveNotifications.approveActionId)
        XCTAssertEqual("org.omarchy.flux.approve.deny", ApproveNotifications.denyActionId)
    }

    func testNotificationIdRoundTrip() {
        XCTAssertEqual("flux-approve-req1", ApproveNotifications.notificationId(for: "req1"))
        XCTAssertEqual("req1", ApproveNotifications.promptId(fromNotificationId: "flux-approve-req1"))
    }

    func testPromptIdRejectsForeignIdentifiers() {
        XCTAssertNil(ApproveNotifications.promptId(fromNotificationId: "something-else"))
        XCTAssertNil(ApproveNotifications.promptId(fromNotificationId: "flux-approve-"))
        XCTAssertNil(ApproveNotifications.promptId(
            fromNotificationId: "flux-approve-" + String(repeating: "x", count: 65)))
    }

    func testVerdictMapping() {
        XCTAssertEqual(true, ApproveNotifications.verdict(forActionId: ApproveNotifications.approveActionId))
        XCTAssertEqual(false, ApproveNotifications.verdict(forActionId: ApproveNotifications.denyActionId))
        // A plain tap on the notification body opens the app with no
        // verdict — the sheet stays the decision surface there.
        XCTAssertNil(ApproveNotifications.verdict(forActionId: "bogus-action"))
#if canImport(UserNotifications)
        XCTAssertNil(ApproveNotifications.verdict(forActionId: UNNotificationDefaultActionIdentifier))
        XCTAssertNil(ApproveNotifications.verdict(forActionId: UNNotificationDismissActionIdentifier))
#endif
    }
}
