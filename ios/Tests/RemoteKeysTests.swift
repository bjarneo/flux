import FluxKit
import XCTest
@testable import Flux

@MainActor
final class RemoteKeysTests: XCTestCase {
    private var sent: [Packet] = []

    private func keys(workspaceKeys: Bool = true) -> RemoteKeys {
        sent = []
        return RemoteKeys(workspaceKeys: workspaceKeys) { [unowned self] in self.sent.append($0) }
    }

    func testModifiersHoldForOneKey() {
        let k = keys()
        k.mods.ctrl = true
        k.text("c")
        XCTAssertEqual(sent.last?.string("key"), "c")
        XCTAssertEqual(sent.last?.bool("ctrl"), true)
        XCTAssertFalse(k.mods.any, "a modifier holds for the next key only")
        k.text("c")
        XCTAssertNil(sent.last?.bool("ctrl"))
        k.mods.shift = true
        k.key(.tab)
        XCTAssertEqual(sent.last?.int("specialKey"), RemoteInput.Key.tab.rawValue)
        XCTAssertEqual(sent.last?.bool("shift"), true)
        XCTAssertFalse(k.mods.any)
    }

    func testSuperAndADigitSwitchTheWorkspace() {
        let k = keys()
        k.mods.meta = true
        k.text("3")
        XCTAssertEqual(sent.last?.type, PacketType.fluxShortcuts)
        XCTAssertEqual(sent.last?.string("action"), "workspace")
        XCTAssertEqual(sent.last?.int("workspace"), 3)
        k.text("0", held: RemoteInput.Mods(shift: true, meta: true), digit: 0)
        XCTAssertEqual(sent.last?.string("action"), "moveToWorkspace")
        XCTAssertEqual(sent.last?.int("workspace"), 10)
        let old = keys(workspaceKeys: false)
        old.mods.meta = true
        old.text("3")
        XCTAssertEqual(sent.last?.type, PacketType.mousepadRequest, "an older fluxd gets the keys")
        XCTAssertEqual(sent.last?.bool("super"), true)
    }

    func testHardwarePresses() {
        let k = keys()
        XCTAssertTrue(k.press(.key(.escape, RemoteInput.Mods()), characters: "", digit: nil))
        XCTAssertEqual(sent.last?.int("specialKey"), RemoteInput.Key.escape.rawValue)
        XCTAssertTrue(k.press(.text("w", RemoteInput.Mods(meta: true)), characters: "w", digit: nil))
        XCTAssertEqual(sent.last?.string("key"), "w")
        XCTAssertEqual(sent.last?.bool("super"), true)
        XCTAssertTrue(k.press(.text("2", RemoteInput.Mods(meta: true)), characters: "2", digit: 2))
        XCTAssertEqual(sent.last?.int("workspace"), 2)
        XCTAssertTrue(k.press(.compose, characters: "@", digit: nil), "Option types the character of the layout")
        XCTAssertEqual(sent.last?.string("key"), "@")
        let count = sent.count
        XCTAssertFalse(k.press(.compose, characters: "", digit: nil), "a modifier alone stays")
        XCTAssertFalse(k.press(.compose, characters: "\u{1B}", digit: nil))
        XCTAssertFalse(k.press(.ignore, characters: "a", digit: nil))
        XCTAssertEqual(sent.count, count)
    }

    private var backspace: Int { RemoteInput.Key.backspace.rawValue }

    func testFieldEditsAndClearSendBackspaces() {
        let k = keys()
        XCTAssertFalse(k.fieldChanged(shown: "abc", stable: "abc", composing: false))
        XCTAssertEqual(sent.last?.string("key"), "abc")
        XCTAssertEqual(k.fieldText, "abc")
        sent = []
        XCTAssertFalse(k.fieldChanged(shown: "ab", stable: "ab", composing: false))
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.last?.int("specialKey"), backspace)
        sent = []
        k.clearTyped()
        XCTAssertEqual(sent.count, 2, "a fluxd without keyRepeat gets 1 packet for each Backspace")
        XCTAssertTrue(sent.allSatisfy { $0.int("specialKey") == backspace && !$0.has("repeat") })
        XCTAssertEqual(k.fieldText, "")
        sent = []
        k.clearTyped()
        XCTAssertTrue(sent.isEmpty, "an empty field deletes nothing")
    }

    func testClearUsesRepeatWhenTheComputerCan() {
        sent = []
        let k = RemoteKeys(workspaceKeys: true, send: { [unowned self] in self.sent.append($0) }, canRepeat: { true })
        _ = k.fieldChanged(shown: "hello", stable: "hello", composing: false)
        sent = []
        k.clearTyped()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.int("specialKey"), backspace)
        XCTAssertEqual(sent.first?.int("repeat"), 5)
    }

    func testBackspaceKeyDeletesTheLastCharacterOfTheField() {
        let k = keys()
        _ = k.fieldChanged(shown: "a👍🏽", stable: "a👍🏽", composing: false)
        sent = []
        k.key(.backspace)
        XCTAssertEqual(sent.count, 2, "1 Backspace for each code point of the character")
        XCTAssertEqual(k.fieldText, "a")
        sent = []
        k.key(.backspace)
        k.key(.backspace)
        XCTAssertEqual(sent.count, 2, "an empty field sends the key as it is")
        XCTAssertEqual(k.fieldText, "")
    }

    func testOtherInputEndsTheField() {
        let k = keys()
        _ = k.fieldChanged(shown: "abc", stable: "abc", composing: false)
        k.key(.left)
        XCTAssertEqual(k.fieldText, "", "an arrow moves the cursor of the computer")
        sent = []
        k.clearTyped()
        XCTAssertTrue(sent.isEmpty, "the computer keeps the text")
        _ = k.fieldChanged(shown: "abc", stable: "abc", composing: false)
        k.endTyping()
        sent = []
        k.clearTyped()
        XCTAssertTrue(sent.isEmpty)
    }

    func testOldComputerStartsTheFieldAgainAfterAWord() {
        let k = keys()
        let long = String(repeating: "word ", count: 10)
        XCTAssertTrue(k.fieldChanged(shown: long, stable: long, composing: false), "the field empties after a word")
        XCTAssertEqual(k.fieldText, "")
        sent = []
        k.clearTyped()
        XCTAssertTrue(sent.isEmpty, "a clear never needs more than about 50 Backspace packets")
        let new = RemoteKeys(workspaceKeys: true, send: { _ in }, canRepeat: { true })
        XCTAssertFalse(new.fieldChanged(shown: long, stable: long, composing: false), "a fluxd with keyRepeat keeps the text")
    }

    func testDraftTypesLinesAndEmpties() {
        let k = keys()
        _ = k.fieldChanged(shown: "x", stable: "x", composing: false)
        k.mods.ctrl = true
        k.draft = "Hi\nthere"
        sent = []
        k.typeDraft()
        XCTAssertEqual(sent.map { $0.string("key") }, ["Hi", nil, "there"])
        XCTAssertEqual(sent[1].bool("shift"), true)
        XCTAssertNil(sent[0].bool("ctrl"), "the sticky modifiers turn off")
        XCTAssertEqual(k.draft, "")
        XCTAssertEqual(k.fieldText, "")
        sent = []
        k.draft = "  \n "
        k.typeDraft()
        XCTAssertTrue(sent.isEmpty, "a blank draft types nothing")
    }
}

@MainActor
final class DesktopViewTests: XCTestCase {
    func testTileSubtitle() {
        XCTAssertEqual(DesktopTile.subtitle(desktop: false, input: true), "Off")
        XCTAssertEqual(DesktopTile.subtitle(desktop: true, input: false), "View only")
        XCTAssertEqual(DesktopTile.subtitle(desktop: true, input: true), "Show and control the screen")
    }

    func testMaxSizeIsAndroids() {
        XCTAssertEqual(DesktopController.maxSize, 1920)
    }
}
