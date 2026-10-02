import XCTest
@testable import FluxKit

/// The plugin saves the theme book, loads it for the paired computers, and
/// forgets the theme of a computer that is no longer paired.
final class ThemePluginTests: XCTestCase {
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

    @MainActor
    func testAThemeIsSavedOnce() throws {
        let plugin = ThemePlugin()
        let core = try makeCore(plugins: [plugin])
        XCTAssertNil(core.defaults.data(forKey: ThemePlugin.defaultsKey))
        XCTAssertNil(plugin.model.current(scope: nil), "a new install has no theme")

        plugin.receive(SampleThemes.neon, from: "A")
        let saved = try XCTUnwrap(core.defaults.data(forKey: ThemePlugin.defaultsKey))
        XCTAssertEqual(plugin.model.current(scope: nil)?.theme, SampleThemes.neon)
        XCTAssertEqual(plugin.model.names(), ["A": "neon"])

        // A reconnect sends the same theme again, which changes nothing.
        plugin.receive(SampleThemes.neon, from: "A")
        XCTAssertEqual(core.defaults.data(forKey: ThemePlugin.defaultsKey), saved)

        plugin.receive(SampleThemes.catppuccinLatte, from: "B")
        XCTAssertNotEqual(core.defaults.data(forKey: ThemePlugin.defaultsKey), saved)
    }

    @MainActor
    func testALoadKeepsOnlyThePairedComputers() throws {
        let plugin = ThemePlugin()
        let core = try makeCore(plugins: [plugin])
        plugin.receive(SampleThemes.neon, from: "A")
        plugin.receive(SampleThemes.catppuccinLatte, from: "B")
        let data = try XCTUnwrap(core.defaults.data(forKey: ThemePlugin.defaultsKey))

        let next = ThemePlugin()
        next.load(data, paired: ["A"])
        XCTAssertEqual(next.model.current(scope: "A")?.theme, SampleThemes.neon)
        XCTAssertNil(next.model.current(scope: "B"))
        XCTAssertEqual(next.model.current(scope: nil)?.deviceId, "A")
        XCTAssertEqual(Set(next.model.names().keys), ["A"])

        next.load(nil, paired: ["A"])
        XCTAssertNil(next.model.current(scope: nil), "no saved book gives no theme")
    }

    @MainActor
    func testAnUnpairForgetsTheThemeAndSaves() throws {
        let plugin = ThemePlugin()
        let core = try makeCore(plugins: [plugin])
        plugin.receive(SampleThemes.neon, from: "A")
        plugin.forget("B")
        XCTAssertEqual(plugin.model.current(scope: nil)?.theme, SampleThemes.neon, "a computer without a theme changes nothing")
        plugin.forget("A")
        XCTAssertNil(plugin.model.current(scope: nil))
        let data = try XCTUnwrap(core.defaults.data(forKey: ThemePlugin.defaultsKey))
        let saved = JSONValue.parse(data)
        XCTAssertEqual(saved?["computers"]?.array?.count, 0)
        XCTAssertNil(saved?["last"])
    }
}
