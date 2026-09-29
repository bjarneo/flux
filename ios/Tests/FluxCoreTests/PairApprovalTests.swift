import XCTest
@testable import FluxCore

/// `PairApproval`: the session thread blocks in `decide` until `PairView`
/// resolves it from `onAccept`/`onDecline`; a timeout declines silently.
final class PairApprovalTests: XCTestCase {
    func testResolveAccept() {
        let approval = PairApproval()
        let decided = expectation(description: "decided")
        var result: Bool??
        Thread.detachNewThread {
            result = approval.decide(peerId: "peer", timeout: 5)
            decided.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)
        approval.resolve(peerId: "peer", accept: true)
        wait(for: [decided], timeout: 6)
        XCTAssertEqual(true, result ?? nil)
    }

    func testResolveDecline() {
        let approval = PairApproval()
        let decided = expectation(description: "decided")
        var result: Bool??
        Thread.detachNewThread {
            result = approval.decide(peerId: "peer", timeout: 5)
            decided.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)
        approval.resolve(peerId: "peer", accept: false)
        wait(for: [decided], timeout: 6)
        XCTAssertEqual(false, result ?? nil)
    }

    func testTimeoutDeclinesSilently() {
        let approval = PairApproval()
        XCTAssertNil(approval.decide(peerId: "nobody-waits", timeout: 0.1))
    }

    func testEarlyResolveCollected() {
        // A verdict with nobody waiting is kept until collected.
        let approval = PairApproval()
        approval.resolve(peerId: "early", accept: true)
        XCTAssertEqual(true, approval.decide(peerId: "early", timeout: 1))
    }
}
