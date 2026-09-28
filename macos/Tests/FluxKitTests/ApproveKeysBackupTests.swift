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

    func testSavedKeysStayOutOfBackups() throws {
        let keys = makeKeys()
        try keys.save(blob: Data([1, 2, 3]), publicKey: Data([4, 5]), computerId: "computer_0123456789abcdef0123456789ab", host: "omarchy", user: "me")
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

    func testAMissingFolderIsLeftAlone() throws {
        let keys = makeKeys()
        XCTAssertNoThrow(try keys.excludeFromBackup(), "before the first key there is no folder to exclude")
        XCTAssertFalse(FileManager.default.fileExists(atPath: keys.directory.path))
    }
}
