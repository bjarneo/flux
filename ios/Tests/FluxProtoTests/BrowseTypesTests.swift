import XCTest
@testable import FluxProto

/// D1 browse-type vectors: Android `Browse.list` mapping + Go `fileKind`
/// parity. The SSH session feeds Citadel attrs through `buildBrowseList`;
/// these tests pin the mapping without any server.
final class BrowseTypesTests: XCTestCase {
    // MARK: - Folder detection (no file-type field in SFTP v3 attrs)

    func testDirFromPermissions() {
        // S_IFDIR (0o040000) set → folder, whatever the longname says.
        XCTAssertTrue(isBrowseDir(permissions: 0o040755, longname: "-rwxr-xr-x"))
        // S_IFREG (0o100000) → file.
        XCTAssertFalse(isBrowseDir(permissions: 0o100644, longname: "drwxr-xr-x"))
    }

    func testDirFromLongnameFallback() {
        // Server omitted permissions: the ls -l leading char decides.
        XCTAssertTrue(isBrowseDir(permissions: nil, longname: "drwxr-xr-x 2 ed ed 96 Sep 28 docs"))
        XCTAssertFalse(isBrowseDir(permissions: nil, longname: "-rw-r--r-- 1 ed ed 28 Sep 28 hello.txt"))
        // Neither signal → plain file (fail-closed, never a phantom folder).
        XCTAssertFalse(isBrowseDir(permissions: nil, longname: nil))
        XCTAssertFalse(isBrowseDir(permissions: 0, longname: nil))
    }

    // MARK: - List mapping (filter + map + sort)

    func testBuildBrowseListFiltersAndSorts() {
        let raw = [
            RawBrowseEntry(name: ".", path: "/h/.", permissions: 0o040755, longname: "d", size: 128),
            RawBrowseEntry(name: "..", path: "/h/..", permissions: 0o040755, longname: "d", size: 384),
            RawBrowseEntry(name: ".hidden", path: "/h/.hidden", permissions: 0o100644, longname: "-", size: 10),
            RawBrowseEntry(name: "b.txt", path: "/h/b.txt", permissions: 0o100644, longname: "-", size: 20),
            RawBrowseEntry(name: "A.txt", path: "/h/A.txt", permissions: 0o100644, longname: "-", size: 30),
            RawBrowseEntry(name: "sub", path: "/h/sub", permissions: 0o040755, longname: "d", size: 96),
            RawBrowseEntry(name: "Docs", path: "/h/Docs", permissions: nil, longname: "drwxr-xr-x", size: 64),
        ]
        let list = buildBrowseList(raw)
        // Dotfiles gone (incl . and ..), folders first, names case-insensitive.
        XCTAssertEqual(["Docs", "sub", "A.txt", "b.txt"], list.map(\.name))
        XCTAssertEqual([true, true, false, false], list.map(\.dir))
        XCTAssertEqual("/h/A.txt", list[2].path)
        XCTAssertEqual(30, list[2].size)
    }

    func testHugeSizeClamps() {
        let raw = [RawBrowseEntry(name: "big", path: "/h/big", permissions: 0o100644, longname: "-", size: .max)]
        XCTAssertEqual(Int64.max, buildBrowseList(raw)[0].size)
    }

    // MARK: - Up-navigation

    func testBrowseParentPath() {
        XCTAssertEqual("/home/ed", browseParentPath("/home/ed/Downloads"))
        XCTAssertEqual("/home", browseParentPath("/home/ed"))
        XCTAssertEqual("/", browseParentPath("/home"))
        XCTAssertEqual("/", browseParentPath("/"))
        XCTAssertEqual("/home/ed", browseParentPath("/home/ed/Downloads/"))
        XCTAssertEqual("/", browseParentPath("relative"))
        XCTAssertEqual("/", browseParentPath(""))
    }

    // MARK: - Kind mapping (Go fileKind parity)

    func testBrowseKind() {
        XCTAssertEqual(.folder, browseKind(name: "anything", dir: true))
        XCTAssertEqual(.image, browseKind(name: "IMG_9056.jpg", dir: false))
        XCTAssertEqual(.image, browseKind(name: "shot.HEIC", dir: false))
        XCTAssertEqual(.video, browseKind(name: "clip.MOV", dir: false))
        XCTAssertEqual(.audio, browseKind(name: "tone.Mp3", dir: false))
        XCTAssertEqual(.pdf, browseKind(name: "scan.pdf", dir: false))
        XCTAssertEqual(.text, browseKind(name: "notes.MD", dir: false))
        XCTAssertEqual(.archive, browseKind(name: "backup.tar.gz", dir: false))
        XCTAssertEqual(.apk, browseKind(name: "app.apk", dir: false))
        XCTAssertEqual(.iso, browseKind(name: "disk.IMG", dir: false))
        XCTAssertEqual(.file, browseKind(name: "Makefile", dir: false))
        XCTAssertEqual(.file, browseKind(name: "weird.xyz", dir: false))
    }
}
