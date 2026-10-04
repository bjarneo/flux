import XCTest
@testable import FluxKit

final class ResumableTransferTests: XCTestCase {
    func testMetadataCannotEscapeItsFolder() {
        let id = "aabbccddeeff", hash = String(repeating: "0", count: 64)
        XCTAssertTrue(ResumableTransfer.valid(id: id, name: "empty.txt", size: 0, hash: hash))
        for name in ["../file", "folder/file", "folder\\file", ".", "..", ""] {
            XCTAssertFalse(ResumableTransfer.valid(id: id, name: name, size: 1, hash: hash))
        }
        XCTAssertFalse(ResumableTransfer.valid(id: "../bad", name: "file", size: 1, hash: hash))
        XCTAssertFalse(ResumableTransfer.valid(id: id, name: "file", size: -1, hash: hash))
    }
}
