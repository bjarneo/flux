import XCTest
@testable import FluxUI

/// M7 background-reconnect UX contract: only `connected` hides the banner,
/// and the suspended copy stays honest (open Flux; the desktop shows
/// offline). Rendering itself is covered by `#Preview`s in
/// `ConnectionBanner.swift` (Xcode target).
final class LinkPresenceTests: XCTestCase {
    func testOnlyConnectedHidesBanner() {
        XCTAssertFalse(LinkPresence.connected.showsBanner)
        for presence in LinkPresence.allCases where presence != .connected {
            XCTAssertTrue(presence.showsBanner, "\(presence)")
        }
    }

    func testConnectedHasNoCopy() {
        XCTAssertEqual("", LinkPresence.connected.bannerTitle)
        XCTAssertEqual("", LinkPresence.connected.bannerMessage)
    }

    func testSuspendedCopyIsHonest() {
        // Plan §3.2 UX contract, verbatim: no fake presence.
        XCTAssertEqual("Background suspended", LinkPresence.suspended.bannerTitle)
        XCTAssertTrue(LinkPresence.suspended.bannerMessage.contains("Open Flux to stay connected"))
        XCTAssertTrue(LinkPresence.suspended.bannerMessage.contains("offline"))
    }

    func testReconnectingAndOfflineCopy() {
        XCTAssertEqual("Reconnecting…", LinkPresence.reconnecting.bannerTitle)
        XCTAssertFalse(LinkPresence.reconnecting.bannerMessage.isEmpty)
        XCTAssertEqual("No computers online", LinkPresence.offline.bannerTitle)
        XCTAssertFalse(LinkPresence.offline.bannerMessage.isEmpty)
    }

    func testAllCasesHaveCopyWhenShown() {
        for presence in LinkPresence.allCases where presence.showsBanner {
            XCTAssertFalse(presence.bannerTitle.isEmpty, "\(presence)")
            XCTAssertFalse(presence.bannerMessage.isEmpty, "\(presence)")
        }
    }
}
