import XCTest
@testable import FluxKit

/// The users of the iPhone audio session: the microphone stream, dictation, and the ring.
final class AudioSessionTests: XCTestCase {
    func testTheFirstUserSetsTheCategoryAndTheLastOneDeactivates() {
        var users = AudioUsers()
        XCTAssertEqual(users.add(.mic), .playAndRecord)
        XCTAssertTrue(users.active)
        XCTAssertTrue(users.remove(.mic))
        XCTAssertFalse(users.active)
        XCTAssertNil(users.category)
    }

    func testTheRingPlaysThroughTheMicrophoneStream() {
        var users = AudioUsers()
        XCTAssertEqual(users.add(.mic), .playAndRecord)
        XCTAssertNil(users.add(.ring), "the stream category plays too")
        XCTAssertFalse(users.remove(.ring), "the ring must not deactivate the stream")
        XCTAssertTrue(users.active)
        XCTAssertTrue(users.remove(.mic))
    }

    func testARingDuringADictationPlaysAndRecords() {
        var users = AudioUsers()
        XCTAssertEqual(users.add(.dictation), .record)
        XCTAssertEqual(users.add(.ring), .playAndRecord)
        XCTAssertFalse(users.remove(.ring))
        XCTAssertEqual(users.category, .playAndRecord, "the dictation keeps a category that works")
        XCTAssertTrue(users.remove(.dictation))
    }

    func testTheRingAloneOnlyPlays() {
        var users = AudioUsers()
        XCTAssertEqual(users.add(.ring), .playback)
        XCTAssertEqual(users.add(.mic), .playAndRecord, "the stream needs a category that records")
        XCTAssertFalse(users.remove(.mic))
        XCTAssertTrue(users.remove(.ring))
    }

    func testUsersCount() {
        var users = AudioUsers()
        XCTAssertEqual(users.add(.dictation), .record)
        XCTAssertNil(users.add(.dictation))
        XCTAssertFalse(users.remove(.dictation), "1 dictation still holds it")
        XCTAssertTrue(users.remove(.dictation))
    }

    func testAnEndWithoutAStartChangesNothing() {
        var users = AudioUsers()
        XCTAssertFalse(users.remove(.mic))
        _ = users.add(.ring)
        XCTAssertFalse(users.remove(.mic))
        XCTAssertTrue(users.active)
    }

    func testCategories() {
        XCTAssertEqual(AudioCategory.needed(for: [.dictation]), .record)
        XCTAssertEqual(AudioCategory.needed(for: [.ring]), .playback)
        XCTAssertEqual(AudioCategory.needed(for: [.mic, .dictation]), .playAndRecord)
        XCTAssertFalse(AudioCategory.record.serves([.dictation, .ring]))
        XCTAssertFalse(AudioCategory.playback.serves([.mic]))
        XCTAssertTrue(AudioCategory.playAndRecord.serves([.mic, .dictation, .ring]))
    }
}
