import XCTest
@testable import FluxKit

final class HerdrViewReadTests: XCTestCase {
    func testResponseMustMatchRequestModeAndPath() {
        let read = HerdrViewRead(request: 3, view: "diff", path: "new.swift")
        XCTAssertTrue(read.accepts(request: 3, view: "diff", path: "new.swift", supportsReview: true))
        XCTAssertFalse(read.accepts(request: 2, view: "diff", path: "new.swift", supportsReview: true))
        XCTAssertFalse(read.accepts(request: 3, view: "ansi", path: "new.swift", supportsReview: true))
        XCTAssertFalse(read.accepts(request: 3, view: "diff", path: "old.swift", supportsReview: true))
        XCTAssertFalse(read.accepts(request: nil, view: "diff", path: "new.swift", supportsReview: true))
    }
}
