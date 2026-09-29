import XCTest
@testable import FluxKit

/// A pairing is bound to the link and the certificate on which it started.
/// A new link for a device must show the pinned certificate, the certificate
/// of an open pairing, and the certificate of a live link.
final class PairingBindingTests: XCTestCase {
    private let a: [UInt8] = [0x30, 0x82, 0x01, 0x22, 0x80]
    private let b: [UInt8] = [0x30, 0x82, 0x01, 0x22, 0x7F]

    private func refusal(new: [UInt8], pinned: [UInt8]? = nil, pairState: PairState = .none,
                         pairCertificate: [UInt8]? = nil, live: [UInt8]? = nil) -> String? {
        FluxCore.linkRefusal(new: new, pinned: pinned, pairState: pairState, pairCertificate: pairCertificate, live: live)
    }

    func testANewDeviceIsAccepted() {
        XCTAssertNil(refusal(new: a))
    }

    func testATrustEntryWithAnotherCertificateRefusesTheLink() {
        XCTAssertNotNil(refusal(new: b, pinned: a, pairState: .paired))
        XCTAssertNil(refusal(new: a, pinned: a, pairState: .paired))
    }

    func testATrustEntryWhoseCertificateDoesNotReadRefusesEveryLink() {
        XCTAssertNotNil(refusal(new: a, pinned: []))
    }

    func testARequestedPairingWithAnotherCertificateRefusesTheLink() {
        XCTAssertNotNil(refusal(new: b, pairState: .requested, pairCertificate: a))
        XCTAssertNil(refusal(new: a, pairState: .requested, pairCertificate: a))
    }

    func testAnIncomingPairingWithAnotherCertificateRefusesTheLink() {
        XCTAssertNotNil(refusal(new: b, pairState: .incoming, pairCertificate: a))
        XCTAssertNil(refusal(new: a, pairState: .incoming, pairCertificate: a))
    }

    func testAnOpenPairingWithoutACertificateRefusesTheLink() {
        XCTAssertNotNil(refusal(new: a, pairState: .incoming))
    }

    func testALiveLinkWithAnotherCertificateRefusesTheLink() {
        XCTAssertNotNil(refusal(new: b, live: a))
        XCTAssertNil(refusal(new: a, live: a), "the same device can connect again")
    }

    func testTheKeyHoldsOnlyForItsCertificate() {
        XCTAssertTrue(Device.keyHolds(pairCertificate: a, certificate: a, linkCertificate: a))
        XCTAssertFalse(Device.keyHolds(pairCertificate: a, certificate: b, linkCertificate: b), "the certificate changed after the key was shown")
        XCTAssertFalse(Device.keyHolds(pairCertificate: a, certificate: a, linkCertificate: b), "the link shows another certificate")
        XCTAssertFalse(Device.keyHolds(pairCertificate: a, certificate: a, linkCertificate: nil), "the device has no link")
        XCTAssertFalse(Device.keyHolds(pairCertificate: nil, certificate: a, linkCertificate: a), "no key was shown")
    }
}
