import XCTest
@testable import FluxKit

final class TrustStoreTests: XCTestCase {
    /// A small DER value in base64. The store keeps any bytes that decode.
    private let cert = Data([0x30, 0x03, 0x02, 0x01, 0x01]).base64EncodedString()

    private func file() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("trusted.json")
    }

    /// An entry whose certificate does not decode must not keep a device
    /// paired without a pin.
    func testAnEntryThatDoesNotReadIsNotPaired() throws {
        let url = try file()
        let json = """
        [{"id":"a","name":"A","type":"desktop","certificate":"\(cert)","lastIp":"10.0.0.2","isFlux":true},
         {"id":"b","name":"B","type":"desktop","certificate":"!","isFlux":true},
         {"id":"c","name":"C"},
         {"id":"d","name":"D","type":"laptop","certificate":"\(cert)"}]
        """
        try Data(json.utf8).write(to: url)
        let store = TrustStore(url: url)
        XCTAssertEqual(Set(store.all().map(\.id)), ["a", "d"])
        XCTAssertEqual(store.get("a")?.lastIp, "10.0.0.2")
        XCTAssertEqual(store.get("d")?.lastIp, "", "a field with a default can be missing")
        XCTAssertEqual(store.get("d")?.isFlux, false)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("bad")), Data(json.utf8), "a copy keeps the entries that did not read")
    }

    func testAFileThatIsNotAListKeepsACopy() throws {
        let url = try file()
        let text = Data(#"{"not":"a list"}"#.utf8)
        try text.write(to: url)
        XCTAssertTrue(TrustStore(url: url).all().isEmpty)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("bad")), text)
    }

    func testAFileThatDoesNotReadIsNotReplaced() throws {
        let url = try file()
        try Data("[]".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: url.path), "the test runs as root")
        let store = TrustStore(url: url)
        XCTAssertFalse(store.put(TrustedDevice(id: "a", name: "A", type: "desktop", certificate: cert)))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), Data("[]".utf8), "the pairings in the file stay")
    }

    func testPutSavesTheFileForTheUserOnly() throws {
        let url = try file()
        XCTAssertTrue(TrustStore(url: url).put(TrustedDevice(id: "a", name: "A", type: "desktop", certificate: cert, isFlux: true)))
        XCTAssertEqual(TrustStore(url: url).get("a")?.certificateDER, [0x30, 0x03, 0x02, 0x01, 0x01])
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }
}
