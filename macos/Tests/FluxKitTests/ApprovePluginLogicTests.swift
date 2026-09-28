import UserNotifications
import XCTest
@testable import FluxKit

/// The decisions of ApprovePlugin that need no Secure Enclave: which request
/// it refuses, where a notification action goes, and whether this device can
/// approve at all.
final class ApprovePluginLogicTests: XCTestCase {
    private let nonce = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
    private let phone = ApproveTexts(platform: .phone, type: .faceID)

    private func request(_ kind: ApproveRequest.Kind = .approve, time: Int64 = 1_790_000_000) -> ApproveRequest {
        ApproveRequest(computerId: "pc1", computerName: "omarchy-xps", id: "req1", kind: kind,
                       host: "omarchy-xps", user: "alice", service: kind == .approve ? "sudo" : "", tty: "", rhost: "",
                       time: time, nonce: nonce, timeoutSeconds: 20)
    }

    private func refusal(_ r: ApproveRequest?, now: Int64 = 1_790_000_010, hasKey: Bool = true, busy: Bool = false,
                         secureEnclave: Bool = true) -> String? {
        ApprovePlugin.refusal(r, now: now, hasKey: hasKey, busy: busy, secureEnclave: secureEnclave, texts: phone)
    }

    func testRefusals() {
        XCTAssertNil(refusal(request()), "a fresh request with a key opens the prompt")
        XCTAssertNil(refusal(request(.enroll), hasKey: false), "an enrollment needs no key")
        XCTAssertEqual(refusal(nil), "The request is not valid")
        XCTAssertEqual(refusal(request(), now: 1_790_000_000 + 601), phone.clockSkew)
        XCTAssertEqual(refusal(request(), hasKey: false), phone.noKey)
        XCTAssertEqual(refusal(request(), busy: true), phone.anotherOpen)
    }

    /// Without a Secure Enclave, as in the simulator, no request opens the
    /// prompt, and the computer learns why at once.
    func testNoSecureEnclaveRefusesEveryRequest() {
        XCTAssertEqual(refusal(request(.enroll), hasKey: false, secureEnclave: false), phone.noSecureEnclave)
        XCTAssertEqual(refusal(request(), hasKey: false, secureEnclave: false), phone.noSecureEnclave,
                       "the missing Secure Enclave explains the missing key")
        XCTAssertEqual(refusal(nil, secureEnclave: false), "The request is not valid")
    }

    func testNotificationRoutes() {
        XCTAssertEqual(ApprovePlugin.notificationRoute("approve", platform: .mac), .approve, "the Mac asks for Touch ID at once, as before")
        XCTAssertEqual(ApprovePlugin.notificationRoute("approve", platform: .phone), .present,
                       "the iPhone opens the prompt, and its Approve button asks for Face ID")
        XCTAssertEqual(ApprovePlugin.notificationRoute("deny", platform: .phone), .deny)
        XCTAssertEqual(ApprovePlugin.notificationRoute("deny", platform: .mac), .deny)
        XCTAssertEqual(ApprovePlugin.notificationRoute(UNNotificationDefaultActionIdentifier, platform: .phone), .present)
        XCTAssertEqual(ApprovePlugin.notificationRoute(UNNotificationDefaultActionIdentifier, platform: .mac), .present)
    }

    func testNotificationActions() throws {
        let phoneActions = ApprovePlugin.notificationActions(platform: .phone)
        let approve = try XCTUnwrap(phoneActions.first { $0.identifier == "approve" })
        XCTAssertTrue(approve.options.contains(.foreground), "Approve opens Flux")
        XCTAssertTrue(approve.options.contains(.authenticationRequired), "Approve needs an unlocked iPhone")
        let deny = try XCTUnwrap(phoneActions.first { $0.identifier == "deny" })
        XCTAssertEqual(deny.options, [.destructive], "a locked iPhone can deny, as the design allows")

        let macActions = ApprovePlugin.notificationActions(platform: .mac)
        XCTAssertEqual(macActions.map(\.identifier), ["approve", "deny"])
        XCTAssertEqual(macActions.map(\.options), [[.foreground], [.destructive]], "the Mac actions stay the same")
    }

    func testAvailability() {
        XCTAssertEqual(ApprovePlugin.availability(secureEnclave: true, biometryProblem: nil, texts: phone), .ready)
        XCTAssertEqual(ApprovePlugin.availability(secureEnclave: false, biometryProblem: nil, texts: phone), .noSecureEnclave(phone.noSecureEnclave))
        XCTAssertEqual(ApprovePlugin.availability(secureEnclave: false, biometryProblem: phone.notEnrolled, texts: phone),
                       .noSecureEnclave(phone.noSecureEnclave), "no setting fixes a missing Secure Enclave, so it comes first")
        XCTAssertEqual(ApprovePlugin.availability(secureEnclave: true, biometryProblem: phone.notEnrolled, texts: phone), .biometry(phone.notEnrolled))
    }

    /// The simulator cannot make a key that needs the biometry, so it shows
    /// that approval is not available and refuses each request.
    func testSimulatorHasNoUsableSecureEnclave() {
        #if targetEnvironment(simulator)
        XCTAssertFalse(ApprovePlugin.secureEnclaveAvailable)
        XCTAssertEqual(ApprovePlugin.availability(), .noSecureEnclave(ApproveTexts.current.noSecureEnclave))
        #endif
    }

    func testTimeSensitiveNotificationContent() {
        let plain = Notifier.content(category: "c", title: "t", body: "b")
        XCTAssertEqual(plain.interruptionLevel, .active, "a notification without a level keeps the default")
        let urgent = Notifier.content(category: "c", title: "t", body: "b", interruptionLevel: .timeSensitive)
        XCTAssertEqual(urgent.interruptionLevel, .timeSensitive)
        XCTAssertEqual(urgent.categoryIdentifier, "c")
    }
}
