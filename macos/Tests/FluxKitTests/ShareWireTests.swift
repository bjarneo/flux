import XCTest
@testable import FluxKit

final class ShareWireTests: XCTestCase {
    func testTextThatIsOneURLGoesAsALink() {
        let link = ShareWire.text("  https://omarchy.org/docs?a=1 \n")
        XCTAssertEqual(link.string("url"), "https://omarchy.org/docs?a=1")
        XCTAssertFalse(link.has("text"))
        XCTAssertEqual(ShareWire.text("HTTP://Omarchy.org").string("url"), "HTTP://Omarchy.org")
    }

    /// Only http and https with a host are links, like in fluxd and Flux for
    /// Android. Another scheme can start an app, so it goes as text.
    func testOnlyWebLinksAreLinks() {
        for link in ["https://omarchy.org", "http://192.168.1.5:8080/a?b=c", "HTTPS://X.ORG/"] {
            XCTAssertTrue(ShareWire.isURL(link), link)
            XCTAssertNotNil(ShareWire.webURL(link), link)
        }
        for text in ["file:///etc/passwd", "ftp://omarchy.org", "ssh+git://host/repo", "smb://host/share", "javascript:alert(1)",
                     "https://", "http:///path", "/home/me/a.txt", "~/a.txt", "omarchy.org", "https://a.org b"] {
            XCTAssertFalse(ShareWire.isURL(text), text)
            XCTAssertEqual(ShareWire.text(text).string("text"), text, text)
        }
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
        let p = Packet.parse(ShareWire.capture(name: "shot.png", extra: ["photo": .bool(true), "screenshot": .bool(true)], size: 5, port: 12070).serialize())!
        XCTAssertEqual(p.string("filename"), "shot.png")
        XCTAssertEqual(p.bool("open"), false)
        XCTAssertEqual(p.bool("photo"), true)
        XCTAssertEqual(p.bool("screenshot"), true)
        XCTAssertEqual(p.payloadSize, 5)
        XCTAssertEqual(p.payloadPort, 12070)

        let scan = ShareWire.scan("line 1\nline 2")
        XCTAssertEqual(scan.string("text"), "line 1\nline 2")
        XCTAssertEqual(scan.bool("scan"), true)
    }

    func testRequestPrefersTextThenURLThenFile() {
        let both = Packet(PacketType.share, ["text": "hi", "url": "https://x.org", "filename": "a"], payloadSize: 3, payloadPort: 12070)
        XCTAssertEqual(ShareRequest(both), .text("hi"))
        let url = Packet(PacketType.share, ["url": "https://x.org", "filename": "a"], payloadSize: 3, payloadPort: 12070)
        XCTAssertEqual(ShareRequest(url), .url(URL(string: "https://x.org")!))
        let file = Packet.parse(#"{"id":1,"type":"flux.share.request","body":{"filename":"r.txt","open":false,"lastModified":1700000000123},"payloadSize":3,"payloadTransferInfo":{"tunnel":"t1"}}"#)!
        XCTAssertEqual(ShareRequest(file), .file(name: "r.txt", lastModified: 1_700_000_000_123))
        XCTAssertNil(ShareRequest(Packet(PacketType.share, ["filename": "a"])), "a file needs a payload")
    }

    func testRequestNamesAFileWithoutName() {
        let p = Packet(PacketType.share, [:], payloadSize: 3, payloadPort: 12070)
        XCTAssertEqual(ShareRequest(p, now: 42), .file(name: "file-42", lastModified: nil))
    }

    /// A computer cannot make this device open a file or a link by itself.
    func testRequestIgnoresTheOpenFlagAndOtherSchemes() {
        let file = Packet.parse(#"{"id":1,"type":"flux.share.request","body":{"filename":"setup.terminal","open":true},"payloadSize":3,"payloadTransferInfo":{"tunnel":"t1"}}"#)!
        XCTAssertEqual(ShareRequest(file), .file(name: "setup.terminal", lastModified: nil))
        for link in ["file:///Applications/Calculator.app", "x-apple.systempreferences:com.apple.preference.security", "/etc/passwd"] {
            XCTAssertEqual(ShareRequest(Packet(PacketType.share, ["url": link])), .text(link), link)
        }
    }

    func testReceivedFileNeedsFreeSpace() {
        let gib: Int64 = 1 << 30
        XCTAssertTrue(SharePlugin.fits(100, free: gib))
        XCTAssertFalse(SharePlugin.fits(gib, free: gib), "a file leaves a reserve free")
        XCTAssertFalse(SharePlugin.fits(-1, free: gib), "a file has a size")
        XCTAssertFalse(SharePlugin.fits(Int64.max, free: gib))
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

    /// A bidirectional control can show "invoice.pdf" for a name that ends in ".exe".
    func testSafeNameDropsBidirectionalControls() {
        XCTAssertEqual(ShareWire.safeName("invoice\u{202E}fdp.exe"), "invoicefdp.exe")
        XCTAssertEqual(ShareWire.safeName("\u{2066}a\u{2069}.txt"), "a.txt")
        XCTAssertEqual(ShareWire.safeName("\u{200E}\u{200F}\u{061C}\u{202A}\u{202B}\u{202C}\u{202D}b.txt"), "b.txt")
        XCTAssertEqual(ShareWire.safeName("c\u{0085}\u{009B}.txt"), "c.txt", "C1 controls go too")
        XCTAssertEqual(ShareWire.safeName("\u{202E}"), "file")
        XCTAssertEqual(ShareWire.safeName("Ünïcødé 名前.txt"), "Ünïcødé 名前.txt")
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

    func testProgressThrottleLetsOneReportPerInterval() {
        var throttle = ProgressThrottle()
        let step = ProgressThrottle.interval
        // The first report goes at once.
        XCTAssertTrue(throttle.due(at: 5))
        XCTAssertFalse(throttle.due(at: 5 + step - 1))
        XCTAssertTrue(throttle.due(at: 5 + step))
        // The interval starts again at the last report.
        XCTAssertFalse(throttle.due(at: 5 + step + step / 2))
        XCTAssertTrue(throttle.due(at: 5 + 3 * step))
    }
}
