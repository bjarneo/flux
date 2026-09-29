import XCTest
@testable import FluxKit

final class IdentityBackupTests: XCTestCase {
    private func makeDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("identity", isDirectory: true)
    }

    private func excluded(_ url: URL) throws -> Bool? {
        var url = url
        url.removeAllCachedResourceValues()
        return try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
    }

    func testANewIdentityStaysOutOfBackups() throws {
        let directory = makeDirectory()
        _ = try LocalCertificate.loadOrCreate(directory: directory)
        #if os(iOS)
        XCTAssertEqual(try excluded(directory), true, "a restored key gives another iPhone the same device ID")
        #else
        XCTAssertEqual(try excluded(directory), false, "the Mac keeps its backups as they were")
        #endif
    }

    func testAnExistingIdentityStaysOutOfBackups() throws {
        let directory = makeDirectory()
        let old = try LocalCertificate.generate(deviceId: "0123456789abcdef0123456789abcdef")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(old.privateKeyPEM.utf8).write(to: directory.appendingPathComponent(LocalCertificate.keyFile))
        try Data(old.certificateDER).write(to: directory.appendingPathComponent(LocalCertificate.certFile))
        let loaded = try LocalCertificate.loadOrCreate(directory: directory)
        XCTAssertEqual(loaded.deviceId, old.deviceId, "Flux keeps the identity")
        #if os(iOS)
        XCTAssertEqual(try excluded(directory), true, "a folder from before this version is excluded when Flux starts")
        #else
        XCTAssertEqual(try excluded(directory), false)
        #endif
    }

    func testAMissingFolderIsLeftAlone() throws {
        let directory = makeDirectory()
        XCTAssertNoThrow(try LocalCertificate.excludeFromBackup(directory: directory), "before the first start there is no folder to exclude")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
