import XCTest
@testable import FluxKit

final class CodesTests: XCTestCase {
    func testURLOpensOrCopies() {
        let sheet = Codes.sheet(ScannedCode(.qrCode, "https://omarchy.org/flux", url: "https://omarchy.org/flux"), pc: "laptop")
        XCTAssertEqual(sheet.kind, .url)
        XCTAssertEqual(sheet.title, "QR code · Link")
        XCTAssertEqual(sheet.actions.map(\.verb), ["Open on laptop", "Copy on laptop"])
        XCTAssertEqual(sheet.actions[0].body, .openURL("https://omarchy.org/flux"))
        XCTAssertEqual(sheet.actions[1].body, .copy("https://omarchy.org/flux"))
    }

    func testRawURLWithoutTypeIsALink() {
        XCTAssertEqual(Codes.kind(ScannedCode(.dataMatrix, " http://192.168.1.5:8080/x ")), .url)
        XCTAssertEqual(Codes.text(ScannedCode(.dataMatrix, " http://192.168.1.5:8080/x ")), "http://192.168.1.5:8080/x")
    }

    func testTextSavesOrCopies() {
        let sheet = Codes.sheet(ScannedCode(.aztec, "Gate B14"), pc: "pc")
        XCTAssertEqual(sheet.kind, .text)
        XCTAssertEqual(sheet.actions.map(\.body), [.save("Gate B14"), .copy("Gate B14")])
    }

    func testProductCodes() {
        XCTAssertEqual(Codes.kind(ScannedCode(.ean13, "7038010009457")), .product)
        XCTAssertEqual(Codes.kind(ScannedCode(.code128, "978020137962", product: true)), .product)
        XCTAssertEqual(Codes.kind(ScannedCode(.code128, "PKG-0925")), .text)
        XCTAssertEqual(Codes.sheet(ScannedCode(.upcA, "036000291452"), pc: "pc").title, "UPC-A · Product code")
    }

    func testWifiBecomesReadable() {
        let code = ScannedCode(.qrCode, "WIFI:S:home;T:WPA;P:secret;;", wifi: WifiInfo(ssid: "home", password: "secret", security: "WPA"))
        XCTAssertEqual(Codes.kind(code), .wifi)
        XCTAssertEqual(Codes.text(code), "Wi-Fi network: home\nPassword: secret\nSecurity: WPA")
        XCTAssertEqual(Codes.kind(ScannedCode(.qrCode, "wifi:S:open;;")), .wifi)
        XCTAssertEqual(Codes.text(ScannedCode(.qrCode, "x", wifi: WifiInfo(ssid: "open", password: "", security: ""))), "Wi-Fi network: open")
    }

    func testContactBecomesReadable() {
        let code = ScannedCode(
            .qrCode, "BEGIN:VCARD\nFN:Dan Kim\nEND:VCARD",
            contact: ContactInfo(name: "Dan Kim", phones: ["+47 400 00 000"], emails: ["dan@example.com"], organization: "Basecamp")
        )
        XCTAssertEqual(Codes.kind(code), .contact)
        XCTAssertEqual(Codes.text(code), "Dan Kim\nBasecamp\n+47 400 00 000\ndan@example.com")
        XCTAssertEqual(Codes.text(ScannedCode(.qrCode, "MECARD:N:Kim;;")), "MECARD:N:Kim;;")
    }

    func testBodies() {
        XCTAssertEqual(ShareBody.openURL("https://x.org").fields, ["url": .string("https://x.org")])
        XCTAssertEqual(ShareBody.copy("a").fields, ["text": .string("a")])
        XCTAssertEqual(ShareBody.save("a").fields, ["text": .string("a"), "scan": .bool(true)])
        XCTAssertEqual(ShareBody.save("a").packet.type, PacketType.share)
    }

    func testFileNames() {
        let t = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 10, minute: 15, second: 0))!
        XCTAssertEqual(CaptureNames.photo(t), "IMG_20260925_101500.jpg")
        XCTAssertEqual(CaptureNames.document(t), "scan-20260925-101500.pdf")
        XCTAssertEqual(CaptureNames.signature(t), "signature-20260925-101500.png")
    }

    // MARK: Content that ML Kit reads on Android

    func testWifiContent() {
        XCTAssertEqual(CodeContent.parse(.qrCode, "WIFI:T:WPA;S:my\\;net;P:p\\:w;;").wifi, WifiInfo(ssid: "my;net", password: "p:w", security: "WPA"))
        XCTAssertEqual(CodeContent.parse(.qrCode, "WIFI:S:cafe;T:nopass;;").wifi, WifiInfo(ssid: "cafe", password: "", security: "open"))
        XCTAssertEqual(CodeContent.parse(.qrCode, "WIFI:S:old;T:WEP;P:k;;").wifi?.security, "WEP")
        let code = CodeContent.parse(.qrCode, "WIFI:S:home;T:WPA;P:secret;;")
        XCTAssertEqual(Codes.text(code), "Wi-Fi network: home\nPassword: secret\nSecurity: WPA")
    }

    func testContactContent() {
        let vcard = "BEGIN:VCARD\r\nVERSION:3.0\r\nN:Kim;Dan;;;\r\nTEL;TYPE=CELL:+47 400 00 000\r\nEMAIL:dan@example.com\r\nORG:Basecamp;Ops\r\nEND:VCARD"
        XCTAssertEqual(CodeContent.parse(.qrCode, vcard).contact,
                       ContactInfo(name: "Dan Kim", phones: ["+47 400 00 000"], emails: ["dan@example.com"], organization: "Basecamp"))
        XCTAssertEqual(CodeContent.parse(.qrCode, "BEGIN:VCARD\nFN:Dan Kim\nN:Kim;Daniel\nEND:VCARD").contact?.name, "Dan Kim")
        XCTAssertEqual(CodeContent.parse(.qrCode, "MECARD:N:Kim,Dan;TEL:123;EMAIL:d@x.org;;").contact,
                       ContactInfo(name: "Dan Kim", phones: ["123"], emails: ["d@x.org"], organization: ""))
    }

    func testBookmarkAndPlainContent() {
        XCTAssertEqual(CodeContent.parse(.qrCode, "MEBKM:TITLE:Flux;URL:https://omarchy.org;;").url, "https://omarchy.org")
        XCTAssertEqual(CodeContent.parse(.code128, "PKG-0925"), ScannedCode(.code128, "PKG-0925"))
    }

    /// Only http and https links open on the computer, as fluxd opens only those.
    func testBookmarkWithAnotherSchemeIsText() {
        let web = CodeContent.parse(.qrCode, "MEBKM:TITLE:Flux;URL:https://omarchy.org;;")
        XCTAssertEqual(Codes.kind(web), .url)
        XCTAssertEqual(Codes.text(web), "https://omarchy.org")
        for raw in ["MEBKM:URL:ftp://x.org;;", "MEBKM:URL:file:///etc/passwd;;", "MEBKM:URL:javascript:alert(1);;"] {
            let code = CodeContent.parse(.qrCode, raw)
            XCTAssertEqual(Codes.kind(code), .text, raw)
            XCTAssertEqual(Codes.sheet(code, pc: "pc").actions.map(\.body), [.save(raw), .copy(raw)], raw)
        }
    }

    func testVisionUPCAIsReported() {
        XCTAssertEqual(VisionScan.code(.ean13, "0036000291452"), ScannedCode(.upcA, "036000291452"))
        XCTAssertEqual(VisionScan.code(.ean13, "7038010009457"), ScannedCode(.ean13, "7038010009457"))
    }
}
