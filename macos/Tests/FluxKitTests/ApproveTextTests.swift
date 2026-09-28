import LocalAuthentication
import XCTest
@testable import FluxKit

final class ApproveTextTests: XCTestCase {
    func testBiometryNames() {
        XCTAssertEqual(ApproveTexts.biometry(.touchID, platform: .mac), "Touch ID")
        XCTAssertEqual(ApproveTexts.biometry(.none, platform: .mac), "your password")
        XCTAssertEqual(ApproveTexts.biometry(.faceID, platform: .phone), "Face ID")
        XCTAssertEqual(ApproveTexts.biometry(.touchID, platform: .phone), "Touch ID")
        XCTAssertEqual(ApproveTexts.biometry(.opticID, platform: .phone), "Optic ID")
        XCTAssertEqual(ApproveTexts.biometry(.none, platform: .phone), "your passcode")
    }

    /// The Mac texts are the ones that Flux for macOS always showed.
    func testMacTextsStayTheSame() {
        let t = ApproveTexts(platform: .mac, type: .touchID)
        XCTAssertEqual(t.deviceNoun, "this Mac")
        XCTAssertEqual(t.clockSkew, "The clocks of this Mac and the computer differ by more than 10 minutes")
        XCTAssertEqual(t.noKey, "This Mac has no key for the computer. Run: sudo flux-cli approve enroll")
        XCTAssertEqual(t.anotherOpen, "Another request is open on this Mac")
        XCTAssertEqual(t.enrollTitle(host: "omarchy-xps"), "Enroll this Mac on omarchy-xps?")
        XCTAssertEqual(t.enrollDetail(computer: "roger"), "Flux makes a key for roger in the Secure Enclave of this Mac. Each approval then needs Touch ID.")
        XCTAssertEqual(t.enrollQuestion(user: "alice", host: "omarchy-xps"), "Use this Mac to approve sudo for user alice on host omarchy-xps?")
        XCTAssertEqual(t.enrollReason(user: "alice", host: "omarchy-xps"), "enroll this Mac to approve sudo for alice on omarchy-xps")
        XCTAssertEqual(t.biometryChanged, "The fingerprints on this Mac changed. Enroll again with: sudo flux-cli approve enroll")
        XCTAssertEqual(t.saveFailed, "This Mac could not save its approval key.")
        XCTAssertEqual(t.notEnrolled, "Set up Touch ID in System Settings first.")
        XCTAssertEqual(t.lockedOut, "Touch ID is locked. Unlock this Mac with the password first.")
        XCTAssertEqual(t.unavailable, "Touch ID is not available. Open the lid of this Mac, or connect a keyboard with Touch ID.")
        XCTAssertEqual(t.unavailableShort, "Touch ID is not available.")
        XCTAssertEqual(t.notRecognized, "Touch ID did not recognize the fingerprint.")
        XCTAssertEqual(t.deviceLocked, "This Mac is locked, so it cannot use its approval key.")
        XCTAssertEqual(t.makeFailed, "This Mac could not make its approval key.")
        XCTAssertEqual(t.useFailed, "This Mac could not use its approval key.")
    }

    func testPhoneTexts() {
        let t = ApproveTexts(platform: .phone, type: .faceID)
        XCTAssertEqual(t.deviceNoun, "this iPhone")
        XCTAssertEqual(t.noKey, "This iPhone has no key for the computer. Run: sudo flux-cli approve enroll")
        XCTAssertEqual(t.enrollDetail(computer: "roger"), "Flux makes a key for roger in the Secure Enclave of this iPhone. Each approval then needs Face ID.")
        XCTAssertEqual(t.enrollQuestion(user: "alice", host: "omarchy-xps"), "Use this iPhone to approve sudo for user alice on host omarchy-xps?")
        XCTAssertEqual(t.notEnrolled, "Set up Face ID in Settings first.")
        XCTAssertEqual(t.lockedOut, "Face ID is locked. Unlock this iPhone with the passcode first.")
        XCTAssertEqual(t.unavailable, "Face ID is not available on this iPhone.")
        XCTAssertEqual(t.notRecognized, "Face ID did not recognize the face.")
        XCTAssertEqual(t.biometryChanged, "Face ID on this iPhone changed. Enroll again with: sudo flux-cli approve enroll")
        XCTAssertEqual(ApproveTexts(platform: .phone, type: .touchID).notRecognized, "Touch ID did not recognize the fingerprint.")
        XCTAssertEqual(ApproveTexts(platform: .phone, type: .none).notRecognized, "The passcode was wrong.")
        XCTAssertEqual(ApproveTexts(platform: .phone, type: .none).lockedOut, "Your passcode is locked. Unlock this iPhone with the passcode first.")
        XCTAssertEqual(t.noSecureEnclave, "This iPhone has no Secure Enclave, so it cannot keep an approval key.")
    }

    /// The symbol and the hint while the biometry runs follow the biometry.
    func testBiometrySymbolsAndHints() {
        XCTAssertEqual(ApproveTexts(platform: .phone, type: .faceID).symbol, "faceid")
        XCTAssertEqual(ApproveTexts(platform: .phone, type: .touchID).symbol, "touchid")
        XCTAssertEqual(ApproveTexts(platform: .mac, type: .touchID).symbol, "touchid")
        XCTAssertEqual(ApproveTexts(platform: .phone, type: .none).symbol, "lock")
        XCTAssertEqual(ApproveTexts(platform: .phone, type: .faceID).working, "Look at this iPhone.")
        XCTAssertEqual(ApproveTexts(platform: .phone, type: .touchID).working, "Touch the Touch ID sensor.")
        XCTAssertEqual(ApproveTexts(platform: .mac, type: .touchID).working, "Touch the Touch ID sensor.", "the text of the Mac prompt")
        XCTAssertEqual(ApproveTexts(platform: .phone, type: .none).working, "Enter your passcode.")
    }

    func testCurrentPlatform() {
        #if os(macOS)
        XCTAssertEqual(ApproveTexts.current.deviceNoun, "this Mac")
        XCTAssertEqual(ApproveTexts.current.biometry, "Touch ID", "Macs approve only with Touch ID")
        #else
        XCTAssertEqual(ApproveTexts.current.deviceNoun, "this iPhone")
        #endif
    }
}
