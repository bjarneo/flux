import XCTest
import Foundation
import Darwin
@testable import FluxCore

/// D1 session unit tests: fail-closed paths without any server (the live
/// SSH bytes are E2E-held through `test_peer.py --browse-ssh`).
final class BrowseSessionTests: XCTestCase {
    func testListWithoutConnect() async {
        let session = BrowseSession()
        do {
            _ = try await session.list(path: "/home/ed")
            XCTFail("list without connect must throw")
        } catch let e as BrowseError {
            XCTAssertEqual(.noSession, e)
        } catch {
            XCTFail("wrong error: \(error)")
        }
        await session.close()
    }

    func testDownloadWithoutConnect() async {
        let session = BrowseSession()
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flux-browse-nosession-\(UUID().uuidString)")
        do {
            _ = try await session.download(remotePath: "/home/ed/nope.txt", to: dest)
            XCTFail("download without connect must throw")
        } catch let e as BrowseError {
            XCTAssertEqual(.noSession, e)
        } catch {
            XCTFail("wrong error: \(error)")
        }
        // Nothing staged the destination: the guard fires first.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        await session.close()
    }

    func testTunnelKeepaliveArmsSocket() throws {
        // provider.go parity lands on the taken tunnel socket: off by
        // default, on after enable. Plain TCP socket (TCP_* options are
        // meaningless on AF_UNIX) — no Keychain, runs on sims too.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrowseError.bridgeFailed("socket: errno \(errno)") }
        defer { Darwin.close(fd) }
        XCTAssertFalse(TunnelKeepalive.isEnabled(fd: fd))
        try TunnelKeepalive.enable(fd: fd)
        XCTAssertTrue(TunnelKeepalive.isEnabled(fd: fd))
    }

    func testSessionDeadClassifier() {
        // Never-connected paths are always dead: nothing to reuse.
        XCTAssertTrue(BrowseError.noSession.isSessionDead)
        XCTAssertTrue(BrowseError.bridgeFailed("socket: errno 1").isSessionDead)
        XCTAssertTrue(BrowseError.connectFailed("auth").isSessionDead)
        // A dead SSH channel (Citadel `SFTPError.connectionClosed`, the
        // device download signature) ends the session; file-level
        // failures leave a live session alone.
        XCTAssertTrue(BrowseError.downloadFailed("connectionClosed").isSessionDead)
        XCTAssertTrue(BrowseError.listFailed("connectionClosed").isSessionDead)
        XCTAssertFalse(BrowseError.downloadFailed("SSH_FXP_STATUS { status-code: failure }").isSessionDead)
        XCTAssertFalse(BrowseError.listFailed("no such file").isSessionDead)
    }
}
