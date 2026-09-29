import XCTest
import Foundation
#if canImport(Security)
import Security
#endif
@testable import FluxCore
@testable import FluxProto

/// Identity persistence + key attributes. Keychain I/O runs against the
/// in-memory façade; the live backend only changes the storage closures.
final class IdentityTests: XCTestCase {
    func testDeviceIDFormat() {
        for _ in 0..<10 {
            XCTAssertTrue(validDeviceId(DeviceID.make()))
        }
        XCTAssertEqual(32, DeviceID.make().count)
    }

    func testDeviceIDPersists() {
        let kc = KeychainClient.inMemory()
        let first = DeviceID.loadOrCreate(keychain: kc)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, DeviceID.loadOrCreate(keychain: kc))
    }

    func testDeviceIDInvalidStoredReturnsNil() {
        let kc = KeychainClient.inMemory()
        kc.save(DeviceID.service, DeviceID.account, Data("short".utf8))
        XCTAssertNil(DeviceID.loadOrCreate(keychain: kc))
    }

    func testKeyAttributes() {
        let live = IdentityKeys.keyAttributes(secureEnclave: true)
#if canImport(Security)
        XCTAssertEqual(256, live[kSecAttrKeySizeInBits as String] as? Int)
        XCTAssertEqual(true, live[kSecAttrIsPermanent as String] as? Bool)
        XCTAssertEqual(IdentityKeys.applicationTag, String(data: live[kSecAttrApplicationTag as String] as? Data ?? Data(), encoding: .utf8))
        XCTAssertNotNil(live[kSecAttrTokenID as String])
        XCTAssertNotNil(live[kSecAttrAccessible as String])

        let soft = IdentityKeys.keyAttributes(secureEnclave: false)
        XCTAssertNil(soft[kSecAttrTokenID as String])
#else
        XCTAssertEqual(256, live["kSecAttrKeySizeInBits"] as? Int)
#endif
    }
}
