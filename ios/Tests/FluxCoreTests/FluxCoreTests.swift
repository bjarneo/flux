import XCTest
import Foundation
@testable import FluxCore
@testable import FluxProto

final class FluxCoreTests: XCTestCase {
    func testTrustStoreRoundTrip() async {
        let store: any TrustStore = InMemoryTrustStore()
        let id = "0123456789abcdef0123456789abcdef"
        let initial = await store.isTrusted(deviceId: id)
        XCTAssertFalse(initial)
        await store.setTrusted(deviceId: id, certificateDER: Data([1, 2, 3]))
        let trusted = await store.isTrusted(deviceId: id)
        XCTAssertTrue(trusted)
        let der = await store.certificateDER(for: id)
        XCTAssertEqual(Data([1, 2, 3]), der)
        await store.remove(deviceId: id)
        let gone = await store.isTrusted(deviceId: id)
        XCTAssertFalse(gone)
    }

    func testSettingsDefaultsAreIOSSafe() {
        // UIPasteboard is foreground-only: no background clipboard daemon.
        XCTAssertFalse(FluxSettings().autoClipboard)
    }
}
