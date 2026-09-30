import XCTest
@testable import FluxKit

final class BrowseTests: XCTestCase {
    private func offer(_ line: String) -> SftpOffer? { SftpOffer.parse(Packet.parse(line)!) }

    func testTunnelOfferFromFluxd() throws {
        let o = try XCTUnwrap(offer(#"{"id":1,"type":"flux.sftp","body":{"tunnel":"s1","user":"flux","password":"pw","path":"/home/u","multiPaths":["/home/u","/home/u/Pictures"],"pathNames":["Home","Pictures"]}}"#))
        XCTAssertEqual(o.tunnel, "s1")
        XCTAssertEqual(o.user, "flux")
        XCTAssertEqual(o.password, "pw")
        XCTAssertEqual(o.roots, [BrowseRoot(name: "Home", path: "/home/u"), BrowseRoot(name: "Pictures", path: "/home/u/Pictures")])
    }

    func testBadRootListsAreRejected() {
        XCTAssertNil(offer(#"{"id":1,"type":"flux.sftp","body":{"tunnel":"t","user":"k","password":"p","path":"/home/u","multiPaths":["/home/u","/srv"],"pathNames":["Home"]}}"#), "the lists differ in length")
        XCTAssertNil(offer(#"{"id":1,"type":"flux.sftp","body":{"tunnel":"t","user":"k","password":"p","path":"/home/u"}}"#), "no lists")
        XCTAssertNil(offer(#"{"id":1,"type":"flux.sftp","body":{"tunnel":"t","user":"k","password":"p","multiPaths":[],"pathNames":[]}}"#), "empty lists")
    }

    func testRejectedOffers() {
        XCTAssertNil(offer(#"{"id":1,"type":"flux.sftp","body":{"errorMessage":"no"}}"#))
        XCTAssertNil(offer(#"{"id":1,"type":"flux.sftp","body":{"errorMessage":"","tunnel":"t","user":"k","password":"p","multiPaths":["/h"],"pathNames":["Home"]}}"#))
        XCTAssertNil(offer(#"{"id":1,"type":"flux.sftp","body":{"user":"k","password":"p","multiPaths":["/h"],"pathNames":["Home"]}}"#))
        XCTAssertNil(offer(#"{"id":1,"type":"flux.sftp","body":{"ip":"10.0.0.2","port":1740,"user":"k","password":"p","multiPaths":["/h"],"pathNames":["Home"]}}"#), "an address is not a tunnel")
        XCTAssertNil(offer(#"{"id":1,"type":"flux.sftp","body":{"tunnel":"","user":"k","password":"p","multiPaths":["/h"],"pathNames":["Home"]}}"#))
        XCTAssertNil(offer(#"{"id":1,"type":"flux.sftp","body":{"tunnel":"t","password":"p","multiPaths":["/h"],"pathNames":["Home"]}}"#))
        XCTAssertNil(offer(#"{"id":1,"type":"flux.sftp.request","body":{"tunnel":"t","user":"k","password":"p","multiPaths":["/h"],"pathNames":["Home"]}}"#))
    }

    func testListingHidesDotFilesAndSortsFoldersFirst() {
        let raw = [
            BrowseEntry(name: "b.txt", path: "/h/b.txt", dir: false, size: 1),
            BrowseEntry(name: ".config", path: "/h/.config", dir: true, size: 0),
            BrowseEntry(name: "Zeta", path: "/h/Zeta", dir: true, size: 0),
            BrowseEntry(name: "A.txt", path: "/h/A.txt", dir: false, size: 2),
            BrowseEntry(name: "alpha", path: "/h/alpha", dir: true, size: 0),
        ]
        XCTAssertEqual(BrowseEntry.listing(raw).map(\.name), ["alpha", "Zeta", "A.txt", "b.txt"])
    }

    func testEntryFromTheAttributes() {
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        let file = BrowseEntry(folder: "/home/u/", name: "notes.txt", permissions: 0o100644, size: 12, modified: when)
        XCTAssertEqual(file, BrowseEntry(name: "notes.txt", path: "/home/u/notes.txt", dir: false, size: 12, modified: when))
        let dir = BrowseEntry(folder: "/home/u", name: "Code", permissions: 0o040755, size: nil, modified: nil)
        XCTAssertEqual(dir, BrowseEntry(name: "Code", path: "/home/u/Code", dir: true, size: 0))
        XCTAssertNil(dir.modified, "a server without times gives no date")
        XCTAssertEqual(BrowseEntry(folder: "/", name: "big", permissions: nil, size: UInt64.max, modified: nil).size, Int64.max)
    }

    func testDirectoryBits() {
        XCTAssertTrue(BrowseEntry.isDirectory(permissions: 0o040755))
        XCTAssertFalse(BrowseEntry.isDirectory(permissions: 0o100644))
        // A symbolic link is not a folder, even when its target is one.
        XCTAssertFalse(BrowseEntry.isDirectory(permissions: 0o120777))
        XCTAssertFalse(BrowseEntry.isDirectory(permissions: nil))
    }

    func testParentPath() {
        XCTAssertEqual(BrowsePath.parent("/home/u/Documents"), "/home/u")
        XCTAssertEqual(BrowsePath.parent("/home/u/Documents/"), "/home/u")
        XCTAssertEqual(BrowsePath.parent("/home"), "/")
        XCTAssertEqual(BrowsePath.parent("/"), "/")
        XCTAssertEqual(BrowsePath.join("/", "etc"), "/etc")
        XCTAssertEqual(BrowsePath.join("/home/u", "a"), "/home/u/a")
    }

    func testDeepestRootAndComponentBoundary() {
        let roots = [BrowseRoot(name: "Home", path: "/home/u"), BrowseRoot(name: "Downloads", path: "/home/u/Downloads/")]
        XCTAssertEqual(BrowsePath.root(of: "/home/u/Downloads/x", in: roots)?.name, "Downloads")
        XCTAssertEqual(BrowsePath.root(of: "/home/u/Documents", in: roots)?.name, "Home")
        XCTAssertNil(BrowsePath.root(of: "/home/user2", in: roots))
        XCTAssertTrue(BrowsePath.isRoot("/home/u/Downloads", in: roots))
        XCTAssertFalse(BrowsePath.isRoot("/home/u/Documents", in: roots))
    }

    func testCrumbsStartAtTheRootName() {
        let roots = [BrowseRoot(name: "Home", path: "/home/u"), BrowseRoot(name: "Downloads", path: "/home/u/Downloads")]
        XCTAssertEqual(BrowsePath.crumbs("/home/u/Documents/Work", roots: roots), [
            BrowseRoot(name: "Home", path: "/home/u"),
            BrowseRoot(name: "Documents", path: "/home/u/Documents"),
            BrowseRoot(name: "Work", path: "/home/u/Documents/Work"),
        ])
        XCTAssertEqual(BrowsePath.crumbs("/home/u/Downloads", roots: roots), [BrowseRoot(name: "Downloads", path: "/home/u/Downloads")])
        XCTAssertEqual(BrowsePath.crumbs("/srv/x", roots: roots), [BrowseRoot(name: "/", path: "/"), BrowseRoot(name: "srv", path: "/srv"), BrowseRoot(name: "x", path: "/srv/x")])
    }

    func testDownloadNames() {
        XCTAssertEqual(BrowseDownload.safeName("report.pdf"), "report.pdf")
        XCTAssertEqual(BrowseDownload.safeName("../../etc/passwd"), "passwd")
        XCTAssertEqual(BrowseDownload.safeName("a\\b.txt"), "b.txt")
        XCTAssertEqual(BrowseDownload.safeName(".."), "download")
        XCTAssertEqual(BrowseDownload.safeName(""), "download")
        XCTAssertEqual(BrowseDownload.safeName("photo\u{202E}gpj.exe"), "photogpj.exe", "no bidirectional control")
        XCTAssertEqual(BrowseDownload.safeName("a\nb\u{0}.txt"), "ab.txt", "no control character")
        XCTAssertEqual(BrowseDownload.safeName("\u{202E}\u{2066}"), "download")

        let folder = URL(fileURLWithPath: "/tmp/dl")
        let taken: Set<String> = ["/tmp/dl/a.txt", "/tmp/dl/a (2).txt", "/tmp/dl/notes"]
        let exists = { (u: URL) in taken.contains(u.path) }
        XCTAssertEqual(BrowseDownload.uniqueURL(for: "b.txt", in: folder, exists: exists).path, "/tmp/dl/b.txt")
        XCTAssertEqual(BrowseDownload.uniqueURL(for: "a.txt", in: folder, exists: exists).path, "/tmp/dl/a (3).txt")
        XCTAssertEqual(BrowseDownload.uniqueURL(for: "notes", in: folder, exists: exists).path, "/tmp/dl/notes (2)")
        XCTAssertEqual(BrowseDownload.uniqueURL(for: "a.tar.gz", in: folder, exists: { $0.lastPathComponent == "a.tar.gz" }).lastPathComponent, "a.tar (2).gz")
    }
}
