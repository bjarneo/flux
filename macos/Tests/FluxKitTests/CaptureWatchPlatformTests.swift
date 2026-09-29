import XCTest
@testable import FluxKit

final class CaptureWatchPlatformTests: XCTestCase {
    private let switchedOn = Date(timeIntervalSince1970: 1_800_000_000)
    private var start: Int64 { Int64(switchedOn.timeIntervalSince1970 * 1_000_000) }

    private func asset(screenshot: Bool = false, image: Bool = true, created: TimeInterval) -> LibraryAsset {
        LibraryAsset(image: image, screenshot: screenshot, created: switchedOn.addingTimeInterval(created))
    }

    func testAVideoOrAGoneAssetStaysHome() {
        let from: [CaptureKind: Int64] = [.photo: start, .screenshot: start]
        XCTAssertNil(libraryKind(asset(image: false, created: 10), from: from))
        XCTAssertNil(libraryKind(nil, from: from))
    }

    #if os(macOS)
    func testOnMacAPhotoIsACameraImageTakenAfterTheSwitch() {
        let from: [CaptureKind: Int64] = [.photo: start]
        XCTAssertEqual(libraryKind(asset(created: 10), from: from), .photo)
        XCTAssertNil(libraryKind(asset(created: -10), from: from), "taken before the switch turned on")
        XCTAssertNil(libraryKind(asset(screenshot: true, created: 10), from: from), "screenshots come from the folder")
        XCTAssertNil(libraryKind(asset(created: 10), from: [:]), "the photo switch is off")
    }
    #else
    func testOnIOSScreenshotsAreImagesWithTheScreenshotSubtype() {
        let from: [CaptureKind: Int64] = [.photo: start, .screenshot: start]
        XCTAssertEqual(libraryKind(asset(screenshot: true, created: 10), from: from), .screenshot)
        XCTAssertEqual(libraryKind(asset(created: 10), from: from), .photo)
    }

    func testOnIOSAnOlderImageThatArrivesAfterTheSwitchGoesOut() {
        // A photo from AirDrop keeps the date that it was taken.
        let kind = libraryKind(asset(created: -86_400), from: [.photo: start])
        XCTAssertEqual(kind, .photo)
        let item = CaptureItem(id: start + 5, kind: kind, name: "IMG_1.jpg", dateAdded: 0)
        let plan = planCapture(CaptureState().enable(.photo, newest: start), items: [item], now: 0)
        XCTAssertEqual(plan.send.map(\.item.id), [start + 5])
    }

    func testOnIOSImagesWithTheSameDateGoOutOnceEach() {
        // 2 images arrive in 1 change with the same creation date; the first fails.
        let state = CaptureState().enable(.screenshot, newest: start)
        let items = [start + 1, start + 2].map {
            CaptureItem(id: $0, kind: libraryKind(asset(screenshot: true, created: 3), from: state.from), name: "\($0).png", dateAdded: 0)
        }
        let first = planCapture(state, items: items, now: 0)
        XCTAssertEqual(first.send.map(\.item.id), [start + 1, start + 2])
        let afterSend = first.state.markSent(start + 2)
        let second = planCapture(afterSend, items: items, now: 0)
        XCTAssertEqual(second.send.map(\.item.id), [start + 1], "the image that failed goes out again, the other does not")
    }

    func testOnIOSAnImageFromBeforeTheSwitchStaysHome() {
        let state = CaptureState().enable(.photo, newest: start)
        let item = CaptureItem(id: start - 1, kind: .photo, name: "IMG_0.jpg", dateAdded: 0)
        XCTAssertTrue(planCapture(state, items: [item], now: 0).send.isEmpty)
    }
    #endif
}
