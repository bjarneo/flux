import XCTest
@testable import FluxKit

final class ApproveKeysBackupTests: XCTestCase {
    private func makeKeys() -> ApproveKeys {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ApproveKeys(directory: root.appendingPathComponent("approve", isDirectory: true))
    }

    private func excluded(_ url: URL) throws -> Bool? {
        var url = url
        url.removeAllCachedResourceValues()
        return try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
    }

    private let computer = "computer_0123456789abcdef0123456789ab"

    func testSavedKeysStayOutOfBackups() throws {
        let keys = makeKeys()
        try keys.stage(blob: Data([1, 2, 3]), publicKey: Data([4, 5]), computerId: computer, host: "omarchy", user: "me")
        try keys.commit(computer)
        #if os(iOS)
        XCTAssertEqual(try excluded(keys.directory), true, "a restored blob fails in the Secure Enclave of another iPhone")
        #else
        XCTAssertEqual(try excluded(keys.directory), false, "the Mac keeps its backups as they were")
        #endif
    }

    func testAnExistingFolderStaysOutOfBackups() throws {
        let keys = makeKeys()
        try FileManager.default.createDirectory(at: keys.directory, withIntermediateDirectories: true)
        try keys.excludeFromBackup()
        #if os(iOS)
        XCTAssertEqual(try excluded(keys.directory), true, "a folder from before this version is excluded when Flux starts")
        #else
        XCTAssertEqual(try excluded(keys.directory), false)
        #endif
    }

    /// An enrollment keeps the old key until the new key reached the
    /// computer, as in the Android app.
    func testTheOldKeyStaysUntilTheCommit() throws {
        let keys = makeKeys()
        try keys.stage(blob: Data([1]), publicKey: Data([10]), computerId: computer, host: "omarchy", user: "me")
        XCTAssertFalse(keys.has(computer), "a staged key is not a key yet")
        try keys.commit(computer)
        XCTAssertEqual(keys.all()[computer]?.publicKey, Data([10]))

        try keys.stage(blob: Data([2]), publicKey: Data([20]), computerId: computer, host: "omarchy", user: "me")
        XCTAssertEqual(keys.all()[computer]?.publicKey, Data([10]), "the old key works until the computer got the new key")
        keys.discard(computer)
        XCTAssertEqual(keys.all()[computer]?.publicKey, Data([10]), "a failed enrollment keeps the old key")
        XCTAssertThrowsError(try keys.commit(computer), "nothing waits after a discard")

        try keys.stage(blob: Data([3]), publicKey: Data([30]), computerId: computer, host: "omarchy", user: "me")
        try keys.commit(computer)
        XCTAssertEqual(keys.all()[computer]?.publicKey, Data([30]))
        XCTAssertEqual(keys.all().count, 1)

        try keys.stage(blob: Data([4]), publicKey: Data([40]), computerId: computer, host: "omarchy", user: "me")
        keys.delete(computer)
        XCTAssertFalse(keys.has(computer))
        XCTAssertThrowsError(try keys.commit(computer), "a delete also removes the staged key")
    }

    func testAMissingFolderIsLeftAlone() throws {
        let keys = makeKeys()
        XCTAssertNoThrow(try keys.excludeFromBackup(), "before the first key there is no folder to exclude")
        XCTAssertFalse(FileManager.default.fileExists(atPath: keys.directory.path))
    }
}
