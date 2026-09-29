import XCTest
import Foundation
@testable import FluxUI

/// Downloads store contract: the receive folder lists newest-first,
/// subfolders are skipped, deletes stay inside the folder.
final class DownloadsStoreTests: XCTestCase {
    private func freshDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flux-downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ dir: URL, name: String, bytes: Int, date: Date) throws {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func testMissingDirListsEmpty() {
        let gone = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flux-downloads-gone-\(UUID().uuidString)")
        XCTAssertEqual([], DownloadsStore.list(directory: gone))
    }

    func testListsNewestFirstSkipsSubfolders() throws {
        let dir = try freshDir()
        try write(dir, name: "old.zip", bytes: 10, date: Date(timeIntervalSince1970: 1000))
        try write(dir, name: "new.txt", bytes: 57, date: Date(timeIntervalSince1970: 2000))
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)

        let files = DownloadsStore.list(directory: dir)
        XCTAssertEqual(["new.txt", "old.zip"], files.map(\.name))
        XCTAssertEqual(57, files.first?.size)
        XCTAssertEqual(
            dir.appendingPathComponent("new.txt").standardizedFileURL.path,
            URL(fileURLWithPath: files.first?.path ?? "").standardizedFileURL.path)
    }

    func testRemoveDeletesInsideFolderOnly() throws {
        let dir = try freshDir()
        try write(dir, name: "doomed.bin", bytes: 4, date: Date())

        var files = DownloadsStore.list(directory: dir)
        XCTAssertEqual(1, files.count)
        XCTAssertTrue(DownloadsStore.remove(files[0], in: dir))
        XCTAssertEqual([], DownloadsStore.list(directory: dir))

        // Missing file: false, no throw.
        XCTAssertFalse(DownloadsStore.remove(files[0], in: dir))

        // Outside the folder: refused even when present.
        let outsider = DownloadedFile(
            name: "precious.txt", path: "/tmp/flux-downloads-outsider.txt",
            size: 1, modified: Date())
        XCTAssertFalse(DownloadsStore.remove(outsider, in: dir))
    }
}
