import XCTest
@testable import FluxKit

/// The prompt slot of the Inbox. It reads the output of an agent apart from
/// the output of the agents window.
final class HerdrPromptTests: XCTestCase {
    private func packet(_ json: String) -> Packet { Packet.parse(#"{"id":1,"type":"flux.herdr","body":\#(json)}"#)! }

    private let dialog = [
        "● I will run the migration.",
        String(repeating: "─", count: 32),
        " Bash command",
        "",
        "   bin/migrate --apply",
        "",
        " Do you want to proceed?",
        " ❯ 1. Yes",
        "   2. Yes, and don't ask again for bin/migrate commands",
        "   3. No, and tell Claude what to do differently (esc)",
    ]

    @MainActor
    func testAReadWithoutALinkFailsAndKeepDropsIt() {
        let plugin = HerdrPlugin()
        let key = HerdrModel.promptKey("pc", pane: "w1:p1")
        XCTAssertEqual(key, "pc|w1:p1")
        plugin.readPrompt("pc", pane: "w1:p1")
        XCTAssertEqual(plugin.model.prompts[key]?.loading, false)
        XCTAssertTrue(plugin.model.prompts[key]?.error?.hasSuffix("is not reachable") ?? false)
        XCTAssertEqual(plugin.model.prompt("pc", pane: "w1:p1")?.pane, "w1:p1")
        XCTAssertTrue(plugin.model.outputs.isEmpty, "the prompt does not use the output of the window")
        plugin.keepPrompts([key])
        XCTAssertNotNil(plugin.model.prompts[key])
        plugin.keepPrompts([])
        XCTAssertNil(plugin.model.prompts[key])
    }

    @MainActor
    func testAnOutputFillsThePromptAndNotTheWindow() async throws {
        let plugin = HerdrPlugin()
        let key = HerdrModel.promptKey("pc", pane: "w5:p1")
        plugin.readPrompt("pc", pane: "w5:p1")
        let json = String(decoding: JSONValue.string(dialog.joined(separator: "\n")).serialized(), as: UTF8.self)
        plugin.receive(packet(#"{"kind":"output","pane":"w5:p1","format":"ansi","text":\#(json)}"#), deviceId: "pc", computer: "desk")
        // The parse runs in a detached task.
        var waited = 0
        while plugin.model.prompts[key]?.lines.isEmpty ?? true, waited < 40 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        let out = try XCTUnwrap(plugin.model.prompts[key])
        XCTAssertFalse(out.loading)
        XCTAssertNil(out.error)
        XCTAssertEqual(out.choices.count, 3)
        XCTAssertEqual(Inbox.agentPrompt(out.lines.map { $0.text }), "Bash command\nbin/migrate --apply\nDo you want to proceed?")
        XCTAssertNil(plugin.model.outputs["pc"], "the window shows no output")
    }

    @MainActor
    func testAParseFromBeforeADropDoesNotFillTheNewPrompt() async throws {
        let plugin = HerdrPlugin()
        let key = HerdrModel.promptKey("pc", pane: "w5:p1")
        plugin.readPrompt("pc", pane: "w5:p1")
        plugin.receive(packet(#"{"kind":"output","pane":"w5:p1","text":"old"}"#), deviceId: "pc", computer: "desk")
        let old = try XCTUnwrap(plugin.promptParses[key])
        // The agent works, so the Inbox drops its prompt. Then the agent waits again.
        plugin.keepPrompts([])
        XCTAssertNil(plugin.model.prompts[key])
        plugin.readPrompt("pc", pane: "w5:p1")
        plugin.receive(packet(#"{"kind":"output","pane":"w5:p1","text":"new"}"#), deviceId: "pc", computer: "desk")
        let new = try XCTUnwrap(plugin.promptParses[key])
        XCTAssertNotEqual(old, new, "a parse number is not used again after a drop")
        // The parses run in detached tasks.
        var waited = 0
        while plugin.model.prompts[key]?.lines.isEmpty ?? true, waited < 40 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        XCTAssertEqual(plugin.model.prompts[key]?.lines.map { $0.text }, ["new"])
        plugin.show(HerdrOutput(pane: "w5:p1"), deviceId: "pc", window: nil, prompt: old)
        XCTAssertEqual(plugin.model.prompts[key]?.lines.map { $0.text }, ["new"], "a late parse of the old prompt changes nothing")
    }

    @MainActor
    func testAnOutputThatNobodyAskedForIsDropped() async throws {
        let plugin = HerdrPlugin()
        plugin.receive(packet(#"{"kind":"output","pane":"w5:p1","text":"x"}"#), deviceId: "pc", computer: "desk")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(plugin.model.prompts.isEmpty)
        XCTAssertTrue(plugin.model.outputs.isEmpty)
    }
}
