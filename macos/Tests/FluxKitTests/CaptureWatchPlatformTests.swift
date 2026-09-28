import XCTest
@testable import FluxKit

final class CaptureWatchPlatformTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private var candidates: [(id: String, created: Date, screenshot: Bool)] {
        [
            (id: "photo-late", created: base.addingTimeInterval(30), screenshot: false),
            (id: "shot-old", created: base.addingTimeInterval(-10), screenshot: true),
            (id: "shot-early", created: base.addingTimeInterval(5), screenshot: true),
            (id: "photo-old", created: base.addingTimeInterval(-5), screenshot: false),
            (id: "shot-late", created: base.addingTimeInterval(20), screenshot: true),
            (id: "photo-early", created: base.addingTimeInterval(10), screenshot: false),
            (id: "photo-same", created: base, screenshot: false),
        ]
    }

    func testScreenshotsAfterTheDateOldestFirst() {
        XCTAssertEqual(newAssets(after: base, candidates: candidates, kind: .screenshot), ["shot-early", "shot-late"])
    }

    func testPhotosAreImagesThatAreNotScreenshots() {
        XCTAssertEqual(newAssets(after: base, candidates: candidates, kind: .photo), ["photo-early", "photo-late"],
                       "an image from the date itself went out before")
    }

    func testNothingIsNewBeforeTheSwitchTurnsOn() {
        XCTAssertEqual(newAssets(after: nil, candidates: candidates, kind: .screenshot), [])
        XCTAssertEqual(newAssets(after: nil, candidates: candidates, kind: .photo), [])
    }

    func testSameDateKeepsTheOrderOfTheLibrary() {
        let list = [(id: "b", created: base.addingTimeInterval(1), screenshot: true),
                    (id: "a", created: base.addingTimeInterval(1), screenshot: true)]
        XCTAssertEqual(newAssets(after: base, candidates: list, kind: .screenshot), ["b", "a"])
    }
}
