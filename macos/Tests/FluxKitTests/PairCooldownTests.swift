import XCTest
@testable import FluxKit

/// A host whose incoming pairing request ended without a pairing waits
/// before its next request counts. Other hosts can ask at once.
final class PairCooldownTests: XCTestCase {
    func testAHostWaitsAfterItsRequestEnded() {
        var cooldown = PairCooldown()
        XCTAssertEqual(cooldown.seconds, 30)
        XCTAssertFalse(cooldown.blocks(id: "a", ip: "10.0.0.2", at: 0))
        cooldown.add(id: "a", ip: "10.0.0.2", at: 100)
        XCTAssertTrue(cooldown.blocks(id: "a", ip: "10.0.0.9", at: 120), "the same computer waits")
        XCTAssertTrue(cooldown.blocks(id: "b", ip: "10.0.0.2", at: 120), "a new device ID from the same address waits")
        XCTAssertFalse(cooldown.blocks(id: "b", ip: "10.0.0.3", at: 120), "other computers can ask")
        XCTAssertFalse(cooldown.blocks(id: "a", ip: "10.0.0.2", at: 130), "the wait ends")
        cooldown.add(id: "c", ip: "", at: 300)
        XCTAssertFalse(cooldown.blocks(id: "d", ip: "", at: 310), "an unknown address matches nothing")
    }

    /// Device A times out and asks again at once. Its request waits, so it
    /// does not hold the only open request, and device B can ask.
    func testATimedOutHostDoesNotHoldTheRequest() {
        var cooldown = PairCooldown()
        cooldown.add(id: "a", ip: "10.0.0.2", at: 25)
        XCTAssertTrue(cooldown.blocks(id: "a", ip: "10.0.0.2", at: 25))
        XCTAssertFalse(cooldown.blocks(id: "b", ip: "10.0.0.3", at: 26))
    }
}
