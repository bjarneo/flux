import XCTest
import Foundation
@testable import FluxCore

/// Trust persistence: JSON round-trip, CRUD + index bookkeeping, and the
/// `KeychainClient` contract (upsert on save, missing delete is a no-op).
final class TrustStoreTests: XCTestCase {
    private func keychain(service: String = "org.omarchy.flux.test.\(UUID().uuidString)") -> KeychainClient {
        .inMemory()
    }

    func testTrustedDeviceJSON() throws {
        let d = TrustedDevice(id: "abc", name: "pc", type: "laptop", certificateDER: Data([1, 2, 3]), lastIP: "1.2.3.4", isFlux: true)
        let back = try TrustService.decode(try TrustService.encode(d))
        XCTAssertEqual(d, back)
    }

    func testInMemoryCRUD() async {
        let store = InMemoryTrustStore()
        let id = "0123456789abcdef0123456789abcdef"
        let d = TrustedDevice(id: id, name: "pc", type: "laptop", certificateDER: Data([9]))
        await store.put(d)
        let got = await store.trustedDevice(id: id)
        XCTAssertEqual(d, got)
        let all = await store.allDevices()
        XCTAssertEqual([d], all)
        await store.update(id: id) { var n = $0; n.name = "renamed"; return n }
        let renamed = await store.trustedDevice(id: id)?.name
        XCTAssertEqual("renamed", renamed)
        await store.remove(deviceId: id)
        let gone = await store.trustedDevice(id: id)
        XCTAssertNil(gone)
        let rest = await store.allDevices()
        XCTAssertTrue(rest.isEmpty)
        // Missing update/remove are no-ops.
        await store.update(id: id) { $0 }
        await store.remove(deviceId: id)
    }

    func testKeychainCRUDWithIndex() async {
        let kc = keychain()
        let store = KeychainTrustStore(keychain: kc, service: "svc")
        let empty = await store.allDevices()
        XCTAssertTrue(empty.isEmpty)

        let a = TrustedDevice(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", name: "a", type: "laptop", certificateDER: Data([1]))
        let b = TrustedDevice(id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", name: "b", type: "desktop", certificateDER: Data([2]))
        await store.put(a)
        await store.put(b)
        let both = await store.allDevices()
        XCTAssertEqual([a, b], both)
        // Upsert overwrites.
        var a2 = a
        a2.certificateDER = Data([3])
        await store.put(a2)
        let der = await store.certificateDER(for: a.id)
        XCTAssertEqual(Data([3]), der)

        await store.remove(deviceId: a.id)
        let rest = await store.allDevices()
        XCTAssertEqual([b], rest)
        // Corrupt entry decodes as missing.
        kc.save("svc", b.id, Data("not json".utf8))
        let corrupt = await store.trustedDevice(id: b.id)
        XCTAssertNil(corrupt)
    }

    func testKeychainClientSemantics() {
        let kc = KeychainClient.inMemory()
        XCTAssertNil(kc.load("s", "a"))
        kc.delete("s", "a") // no-op, no crash
        kc.save("s", "a", Data([1]))
        XCTAssertEqual(Data([1]), kc.load("s", "a"))
        kc.save("s", "a", Data([2])) // upsert
        XCTAssertEqual(Data([2]), kc.load("s", "a"))
        kc.save("s2", "a", Data([3])) // service isolation
        XCTAssertEqual(Data([2]), kc.load("s", "a"))
        kc.delete("s", "a")
        XCTAssertNil(kc.load("s", "a"))
    }

    func testIndexRoundTrip() throws {
        let data = try TrustService.encodeIndex(["b", "a"])
        XCTAssertEqual(["a", "b"], TrustService.decodeIndex(data))
        XCTAssertEqual([], TrustService.decodeIndex(Data("garbage".utf8)))
    }
}
