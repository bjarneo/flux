import XCTest
@testable import FluxKit

final class ShareSendTests: XCTestCase {
    @MainActor
    private func makeShare() throws -> SharePlugin {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suite = "org.omarchy.flux.test." + UUID().uuidString
        var config = LanConfig()
        config.loopbackOnly = true
        config.udpPort = 0
        config.tcpPorts = 0...0
        let share = SharePlugin()
        let core = try FluxCore(paths: FluxPaths(data: dir, suite: suite), lanConfig: config, plugins: [share])
        addTeardownBlock {
            core.stop()
            try? FileManager.default.removeItem(at: dir)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        return share
    }

    @MainActor
    func testTextToAComputerThatIsNotConnectedFails() throws {
        let share = try makeShare()
        XCTAssertFalse(share.send(text: "hello", to: "nobody"), "the caller keeps text that did not go out")
    }

    @MainActor
    func testWaitedFilesToAComputerThatIsNotConnectedThrow() async throws {
        let share = try makeShare()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try await share.sendAndWait(files: [file], to: "nobody") { _, _ in XCTFail("no file goes out") }
            XCTFail("a computer that is not connected fails the batch")
        } catch {}
    }
}
