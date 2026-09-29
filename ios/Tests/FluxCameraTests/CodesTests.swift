import XCTest
@testable import FluxCamera

/// `Codes` vectors. Ports Android `CodesTest` verbatim (sheet verbs, kinds,
/// desktop text, share bodies, capture file names).
final class CodesTests: XCTestCase {
    private func shown(_ fields: [(String, Any?)]) -> [String] {
        fields.map { "\($0.0)=\($0.1 ?? "nil")" }
    }

    func testUrlOpensOrCopies() {
        let sheet = Codes.sheet(
            ScannedCode(format: .qrCode, raw: "https://omarchy.org/flux", url: "https://omarchy.org/flux"), pc: "laptop")
        XCTAssertEqual(.url, sheet.kind)
        XCTAssertEqual("QR code · Link", sheet.title)
        XCTAssertEqual(["Open on laptop", "Copy on laptop"], sheet.actions.map(\.verb))
        XCTAssertEqual(ShareBody.openURL("https://omarchy.org/flux"), sheet.actions[0].body)
        XCTAssertEqual(ShareBody.copy("https://omarchy.org/flux"), sheet.actions[1].body)
    }

    func testRawUrlWithoutTypeIsALink() {
        XCTAssertEqual(CodeKind.url, Codes.kind(ScannedCode(format: .dataMatrix, raw: " http://192.168.1.5:8080/x ")))
        XCTAssertEqual("http://192.168.1.5:8080/x", Codes.text(ScannedCode(format: .dataMatrix, raw: " http://192.168.1.5:8080/x ")))
    }

    func testTextSavesOrCopies() {
        let sheet = Codes.sheet(ScannedCode(format: .aztec, raw: "Gate B14"), pc: "pc")
        XCTAssertEqual(.text, sheet.kind)
        XCTAssertEqual([ShareBody.save("Gate B14"), ShareBody.copy("Gate B14")], sheet.actions.map(\.body))
    }

    func testProductCodes() {
        XCTAssertEqual(CodeKind.product, Codes.kind(ScannedCode(format: .ean13, raw: "7038010009457")))
        XCTAssertEqual(CodeKind.product, Codes.kind(ScannedCode(format: .code128, raw: "978020137962", product: true)))
        XCTAssertEqual(CodeKind.text, Codes.kind(ScannedCode(format: .code128, raw: "PKG-0925")))
        XCTAssertEqual("UPC-A · Product code", Codes.sheet(ScannedCode(format: .upcA, raw: "036000291452"), pc: "pc").title)
    }

    func testWifiBecomesReadable() {
        let code = ScannedCode(format: .qrCode, raw: "WIFI:S:home;T:WPA;P:secret;;",
                               wifi: WifiInfo(ssid: "home", password: "secret", security: "WPA"))
        XCTAssertEqual(CodeKind.wifi, Codes.kind(code))
        XCTAssertEqual("Wi-Fi network: home\nPassword: secret\nSecurity: WPA", Codes.text(code))
        XCTAssertEqual(CodeKind.wifi, Codes.kind(ScannedCode(format: .qrCode, raw: "wifi:S:open;;")))
        XCTAssertEqual("Wi-Fi network: open",
                       Codes.text(ScannedCode(format: .qrCode, raw: "x", wifi: WifiInfo(ssid: "open", password: "", security: ""))))
    }

    func testContactBecomesReadable() {
        let code = ScannedCode(
            format: .qrCode, raw: "BEGIN:VCARD\nFN:Dan Kim\nEND:VCARD",
            contact: ContactInfo(name: "Dan Kim", phones: ["+47 400 00 000"], emails: ["dan@example.com"], organization: "Basecamp"))
        XCTAssertEqual(CodeKind.contact, Codes.kind(code))
        XCTAssertEqual("Dan Kim\nBasecamp\n+47 400 00 000\ndan@example.com", Codes.text(code))
        XCTAssertEqual("MECARD:N:Kim;;", Codes.text(ScannedCode(format: .qrCode, raw: "MECARD:N:Kim;;")))
    }

    func testBodies() {
        XCTAssertEqual(["url=https://x.org"], shown(ShareBody.openURL("https://x.org").fields()))
        XCTAssertEqual(["text=a"], shown(ShareBody.copy("a").fields()))
        XCTAssertEqual(["text=a", "scan=true"], shown(ShareBody.save("a").fields()))
    }

    func testFileNames() {
        let t = DateComponents(year: 2026, month: 9, day: 25, hour: 10, minute: 15, second: 0)
        XCTAssertEqual("IMG_20260925_101500.jpg", CaptureNames.photo(t))
        XCTAssertEqual("scan-20260925-101500.pdf", CaptureNames.document(t))
    }
}
