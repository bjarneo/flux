import XCTest
@testable import FluxKit

final class SharePlatformTests: XCTestCase {
    func testDownloadsIsAFolder() {
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: FluxFolders.downloads.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testDownloadsPerPlatform() {
        #if os(iOS)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        XCTAssertEqual(FluxFolders.downloads.standardizedFileURL, documents.standardizedFileURL, "the Files app shows Documents")
        XCTAssertEqual(FluxFolders.downloadsName, "Files")
        #else
        XCTAssertEqual(FluxFolders.downloads.lastPathComponent, "Downloads")
        XCTAssertEqual(FluxFolders.downloadsName, "Downloads")
        #endif
    }

    func testShareSavesInDownloads() {
        XCTAssertEqual(SharePlugin.defaultFolder, FluxFolders.downloads)
    }
}
