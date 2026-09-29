import XCTest
@testable import FluxKit

final class CommandsTests: XCTestCase {
    private func list(_ commandList: Any?) -> [RemoteCommand] {
        RemoteCommand.list(from: Packet(PacketType.runCommand, ["commandList": commandList, "canAddCommand": false]))
    }

    func testStringListKeepsTheOrderOfTheComputer() {
        let text = #"{"zz9":{"name":"Lock screen","command":"omarchy-system-lock"},"a1":{"name":"Suspend","command":"systemctl suspend"},"m5":{"name":"Echo","command":"touch /tmp/ran"}}"#
        XCTAssertEqual(list(text), [
            RemoteCommand(key: "zz9", name: "Lock screen", command: "omarchy-system-lock"),
            RemoteCommand(key: "a1", name: "Suspend", command: "systemctl suspend"),
            RemoteCommand(key: "m5", name: "Echo", command: "touch /tmp/ran"),
        ])
    }

    func testObjectListGivesNoCommands() {
        // fluxd sends commandList as a JSON string.
        let obj: [String: Any?] = [
            "k1": ["name": "Suspend", "command": "systemctl suspend"],
            "k2": ["command": "omarchy-system-lock"],
        ]
        XCTAssertEqual(list(obj), [])
    }

    func testBadListsGiveNoCommands() {
        XCTAssertEqual(list("not json"), [])
        XCTAssertEqual(list(#"["a"]"#), [])
        XCTAssertEqual(list(nil), [])
        XCTAssertEqual(list(#"{"a":"not an object","b":{"name":"B"}}"#), [RemoteCommand(key: "b", name: "B", command: "")])
    }

    func testKeyOrderSkipsNestedValuesAndEscapes() {
        let text = #" { "b\"q" : {"name":"x,}{","list":[1,{"k":"]"}]} , "a":"\\" ,"c":null, "b\"q":1 } "#
        XCTAssertEqual(JSONKeys.ordered(text), ["b\"q", "a", "c"])
        XCTAssertEqual(JSONKeys.ordered("[]"), [])
    }
}
