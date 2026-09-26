import XCTest
@testable import FluxKit

final class ShareWireTests: XCTestCase {
    func testTextThatIsOneURLGoesAsALink() {
        let link = ShareWire.text("  https://omarchy.org/docs?a=1 \n")
        XCTAssertEqual(link.string("url"), "https://omarchy.org/docs?a=1")
        XCTAssertFalse(link.has("text"))
        XCTAssertEqual(ShareWire.text("ssh+git://host/repo").string("url"), "ssh+git://host/repo")
    }

    func testOtherTextGoesAsText() {
        for text in ["see https://omarchy.org", "https://a.org https://b.org", "omarchy.org", "mailto:me@omarchy.org", "1http://x"] {
            let p = ShareWire.text(text)
            XCTAssertEqual(p.string("text"), text, text)
            XCTAssertFalse(p.has("url"), text)
        }
    }

    func testFileFieldsMatchTheAndroidApp() {
        let p = Packet.parse(ShareWire.file(name: "a b.jpg", count: 2, total: 300, size: 100, port: 1741).serialize())!
        XCTAssertEqual(p.type, PacketType.share)
        XCTAssertEqual(Set(p.body.keys), ["filename", "open", "numberOfFiles", "totalPayloadSize"])
        XCTAssertEqual(p.string("filename"), "a b.jpg")
        XCTAssertEqual(p.bool("open"), false)
        XCTAssertEqual(p.int("numberOfFiles"), 2)
        XCTAssertEqual(p.long("totalPayloadSize"), 300)
        XCTAssertEqual(p.payloadSize, 100)
        XCTAssertEqual(p.payloadPort, 1741)

        let update = Packet.parse(ShareWire.update(count: 2, total: 300).serialize())!
        XCTAssertEqual(update.type, PacketType.shareUpdate)
        XCTAssertEqual(update.int("numberOfFiles"), 2)
        XCTAssertEqual(update.long("totalPayloadSize"), 300)
    }

    func testCaptureCarriesTheExtraFields() {
        let p = Packet.parse(ShareWire.capture(name: "shot.png", extra: ["photo": .bool(true), "screenshot": .bool(true)], size: 5, port: 1739).serialize())!
        XCTAssertEqual(p.string("filename"), "shot.png")
        XCTAssertEqual(p.bool("open"), false)
        XCTAssertEqual(p.bool("photo"), true)
        XCTAssertEqual(p.bool("screenshot"), true)
        XCTAssertEqual(p.payloadSize, 5)
        XCTAssertEqual(p.payloadPort, 1739)

        let scan = ShareWire.scan("line 1\nline 2")
        XCTAssertEqual(scan.string("text"), "line 1\nline 2")
        XCTAssertEqual(scan.bool("scan"), true)
    }

    func testRequestPrefersTextThenURLThenFile() {
        let both = Packet(PacketType.share, ["text": "hi", "url": "https://x.org", "filename": "a"], payloadSize: 3, payloadPort: 1739)
        XCTAssertEqual(ShareRequest(both), .text("hi"))
        let url = Packet(PacketType.share, ["url": "https://x.org", "filename": "a"], payloadSize: 3, payloadPort: 1739)
        XCTAssertEqual(ShareRequest(url), .url("https://x.org"))
        let file = Packet.parse(#"{"id":1,"type":"kdeconnect.share.request","body":{"filename":"r.txt","open":false,"lastModified":1700000000123},"payloadSize":3,"payloadTransferInfo":{"tunnel":"t1"}}"#)!
        XCTAssertEqual(ShareRequest(file), .file(name: "r.txt", open: false, lastModified: 1_700_000_000_123))
        XCTAssertNil(ShareRequest(Packet(PacketType.share, ["filename": "a"])), "a file needs a payload")
    }

    func testRequestNamesAFileWithoutName() {
        let p = Packet(PacketType.share, [:], payloadSize: 3, payloadPort: 1739)
        XCTAssertEqual(ShareRequest(p, now: 42), .file(name: "file-42", open: false, lastModified: nil))
    }

    func testSafeNameStaysInTheFolder() {
        XCTAssertEqual(ShareWire.safeName("../../etc/passwd"), "passwd")
        XCTAssertEqual(ShareWire.safeName("C:\\Users\\me\\report.pdf"), "report.pdf")
        XCTAssertEqual(ShareWire.safeName("a\u{0}b\nc.txt"), "abc.txt")
        XCTAssertEqual(ShareWire.safeName(".."), "file")
        XCTAssertEqual(ShareWire.safeName("dir/"), "file")
        XCTAssertEqual(ShareWire.safeName("   "), "file")
        XCTAssertEqual(ShareWire.safeName("Screenshot at 10.00\u{202F}AM.png"), "Screenshot at 10.00\u{202F}AM.png")
    }

    func testUniqueURLNeverReusesAName() {
        let dir = URL(fileURLWithPath: "/d", isDirectory: true)
        let taken: Set<String> = ["/d/a.txt", "/d/a (2).txt", "/d/notes", "/d/.env", "/d/x.tar.gz"]
        let exists: (URL) -> Bool = { taken.contains($0.path) }
        XCTAssertEqual(ShareWire.uniqueURL(in: dir, name: "b.txt", exists: exists).path, "/d/b.txt")
        XCTAssertEqual(ShareWire.uniqueURL(in: dir, name: "a.txt", exists: exists).path, "/d/a (3).txt")
        XCTAssertEqual(ShareWire.uniqueURL(in: dir, name: "notes", exists: exists).path, "/d/notes (2)")
        XCTAssertEqual(ShareWire.uniqueURL(in: dir, name: ".env", exists: exists).path, "/d/.env (2)")
        XCTAssertEqual(ShareWire.uniqueURL(in: dir, name: "x.tar.gz", exists: exists).path, "/d/x.tar (2).gz")
    }
}
