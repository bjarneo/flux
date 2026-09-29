import XCTest
@testable import FluxKit

final class PlatformIdentityTests: XCTestCase {
    func testDeviceType() {
        #if os(iOS)
        XCTAssertEqual(FluxCore.deviceType, "phone")
        #else
        XCTAssertTrue(["laptop", "desktop"].contains(FluxCore.deviceType))
        #endif
    }

    func testBroadcastSetting() {
        #if os(iOS)
        XCTAssertFalse(LanConfig().sendsBroadcast, "iOS needs the multicast entitlement for broadcasts")
        #else
        XCTAssertTrue(LanConfig().sendsBroadcast)
        #endif
    }

    func testBroadcastTargetsWithBroadcast() {
        let targets = LanBackend.broadcastTargets(loopbackOnly: false, sendsBroadcast: true,
                                                  interfaces: ["192.168.1.255", "10.0.0.255"],
                                                  known: ["192.168.1.20", "192.168.1.255"])
        XCTAssertEqual(targets, ["255.255.255.255", "192.168.1.255", "10.0.0.255", "192.168.1.20"])
    }

    func testBroadcastTargetsWithoutBroadcast() {
        let targets = LanBackend.broadcastTargets(loopbackOnly: false, sendsBroadcast: false,
                                                  interfaces: ["192.168.1.255"],
                                                  known: ["192.168.1.20", "192.168.1.21", "192.168.1.20"])
        XCTAssertEqual(targets, ["192.168.1.20", "192.168.1.21"], "only known computers, once each")
    }

    func testBroadcastTargetsLoopback() {
        for sends in [true, false] {
            let targets = LanBackend.broadcastTargets(loopbackOnly: true, sendsBroadcast: sends,
                                                      interfaces: ["192.168.1.255"], known: ["192.168.1.20"])
            XCTAssertEqual(targets, ["127.0.0.1"])
        }
    }

    /// A UDP identity names the port, and a LAN host can fake its source
    /// address. This device dials only the ports of fluxd.
    func testUDPDialsOnlyFluxPorts() {
        let config = LanConfig()
        XCTAssertTrue(LanBackend.dialAllowed(ip: "192.168.1.20", port: 1716, config: config))
        XCTAssertTrue(LanBackend.dialAllowed(ip: "192.168.1.20", port: 1764, config: config))
        for port in [0, 22, 443, 1715, 1765, 65535, 70000, -1, Int.max] {
            XCTAssertFalse(LanBackend.dialAllowed(ip: "192.168.1.20", port: port, config: config), "\(port)")
        }
        var loopback = LanConfig()
        loopback.loopbackOnly = true
        XCTAssertTrue(LanBackend.dialAllowed(ip: "127.0.0.1", port: 41716, config: loopback), "a test fluxd uses any port")
        XCTAssertFalse(LanBackend.dialAllowed(ip: "192.168.1.20", port: 1716, config: loopback))
        XCTAssertFalse(LanBackend.dialAllowed(ip: "127.0.0.1", port: 70000, config: loopback))
    }

    #if os(iOS)
    private func makeCore() throws -> FluxCore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suite = "org.omarchy.flux.test." + UUID().uuidString
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        var config = LanConfig()
        config.loopbackOnly = true
        return try FluxCore(paths: FluxPaths(data: dir, suite: suite), lanConfig: config, plugins: [])
    }

    func testDeviceNameDefaultsToIPhone() throws {
        let core = try makeCore()
        XCTAssertEqual(core.deviceName, "iPhone")
    }

    func testDeviceNameIsTheCleanedStoredName() throws {
        let core = try makeCore()
        core.defaults.set("  Anna's (phone)!  ", forKey: FluxCore.deviceNameKey)
        XCTAssertEqual(core.deviceName, "Annas phone")
    }

    @MainActor
    func testSetDeviceName() throws {
        let core = try makeCore()
        core.setDeviceName("Work phone")
        XCTAssertEqual(core.deviceName, "Work phone")
        XCTAssertEqual(core.defaults.string(forKey: FluxCore.deviceNameKey), "Work phone")
        core.setDeviceName("   ")
        XCTAssertNil(core.defaults.string(forKey: FluxCore.deviceNameKey), "an empty name removes the stored name")
        XCTAssertEqual(core.deviceName, "iPhone")
    }
    #endif
}
