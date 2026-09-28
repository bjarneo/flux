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
