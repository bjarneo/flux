import XCTest
@testable import FluxKit

/// Ported from OmarchyThemeTest.kt of the Android app.
final class OmarchyThemeTests: XCTestCase {
    private func body(_ json: String) -> [String: JSONValue] {
        JSONValue.parse(Data(json.utf8))?.object ?? [:]
    }

    private func makeCore(plugins: [FluxPlugin] = []) throws -> FluxCore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suite = "org.omarchy.flux.test." + UUID().uuidString
        var config = LanConfig()
        config.loopbackOnly = true
        config.udpPort = 0
        config.tcpPorts = 0...0
        let core = try FluxCore(paths: FluxPaths(data: dir, suite: suite), lanConfig: config, plugins: plugins)
        addTeardownBlock {
            core.stop()
            try? FileManager.default.removeItem(at: dir)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        return core
    }

    func testReadsTheThemePacket() throws {
        let line = ##"{"id":1,"type":"flux.theme","body":{"name":"synthwave","mode":"dark","colors":{"background":"#0c031f","foreground":"#E8E6EF","accent":"#d563fe","bright_red":"#fe83af"},"border":{"colors":["#21e4f8ee","#d563feee"],"angle":45}}}"##
        let p = try XCTUnwrap(Packet.parse(line))
        XCTAssertEqual(p.type, PacketType.fluxTheme)
        let t = try XCTUnwrap(OmarchyTheme.parse(p.body))
        XCTAssertEqual(t.name, "synthwave")
        XCTAssertEqual(t.dark, true)
        XCTAssertEqual(t["background"], 0x0C031F)
        XCTAssertEqual(t["foreground"], 0xE8E6EF)
        XCTAssertEqual(t["bright_red"], 0xFE83AF)
        // The border drops the alpha of Hyprland.
        XCTAssertEqual(t.border, [0x21E4F8, 0xD563FE])
        XCTAssertEqual(t.borderAngle, 45)
    }

    func testEachKeyCanBeMissing() throws {
        let t = try XCTUnwrap(OmarchyTheme.parse(body(##"{"colors":{"background":"#fdf6e3"}}"##)))
        XCTAssertEqual(t.name, "")
        XCTAssertNil(t.dark)
        XCTAssertTrue(t.border.isEmpty)
        XCTAssertNil(t.borderAngle)
        let light = try XCTUnwrap(OmarchyTheme.parse(body(##"{"mode":"light","border":{"colors":["#ffffff"]}}"##)))
        XCTAssertEqual(light.dark, false)
        XCTAssertTrue(light.colors.isEmpty)
    }

    func testIgnoresWhatItCannotRead() throws {
        let json = ##"{"mode":"sepia","colors":{"background":"#12345","foreground":"rgb(1,2,3)","Accent":"#ffffff","red":7,"green":"#00ff00"},"border":{"colors":["#zzzzzz",3,"#00ff00"],"angle":"-90deg"}}"##
        let t = try XCTUnwrap(OmarchyTheme.parse(body(json)))
        XCTAssertNil(t.dark)
        XCTAssertEqual(t.colors, ["green": 0x00FF00])
        XCTAssertEqual(t.border, [0x00FF00])
        XCTAssertEqual(t.borderAngle, 270)
    }

    func testABodyWithoutColorsIsNoTheme() {
        XCTAssertNil(OmarchyTheme.parse(body(##"{"name":"empty"}"##)))
        XCTAssertNil(OmarchyTheme.parse(body(##"{"colors":{"background":"blue"}}"##)))
    }

    func testLimitsTheSizes() throws {
        let colors = (0..<100).map { "\"c\($0)\":\"#010203\"" }.joined(separator: ",")
        let border = Array(repeating: "\"#ffffff\"", count: 20).joined(separator: ",")
        let name = String(repeating: "x", count: 200)
        let json = "{\"name\":\"\(name)\",\"colors\":{\(colors)},\"border\":{\"colors\":[\(border)]}}"
        let t = try XCTUnwrap(OmarchyTheme.parse(body(json)))
        XCTAssertEqual(t.colors.count, OmarchyTheme.maxColors)
        XCTAssertEqual(t.border.count, OmarchyTheme.maxBorder)
        XCTAssertEqual(t.name.count, OmarchyTheme.maxName)
    }

    func testTheSavedFormReadsBackTheSame() {
        for t in SampleThemes.all { XCTAssertEqual(OmarchyTheme.parse(t.json()), t, t.name) }
        XCTAssertEqual(ColorMath.hex(0x0C031F), "#0c031f")
        XCTAssertEqual(ColorMath.parseColor(" #0C031Fee "), 0x0C031F)
        XCTAssertNil(ColorMath.parseColor("#0c031"))
        XCTAssertNil(ColorMath.parseColor("#０c031f"), "a fullwidth digit is not a hex digit")
    }

    @MainActor
    func testTheDeviceAsksForTheTheme() throws {
        XCTAssertEqual(PacketType.fluxTheme, "flux.theme")
        XCTAssertEqual(ThemePlugin().incoming, [PacketType.fluxTheme])
        XCTAssertTrue(ThemePlugin().outgoing.isEmpty, "the device never sends a theme")
        let core = try makeCore(plugins: [ThemePlugin()])
        XCTAssertTrue(core.incomingCapabilities.contains(PacketType.fluxTheme))
        XCTAssertFalse(core.outgoingCapabilities.contains(PacketType.fluxTheme))
    }
}
