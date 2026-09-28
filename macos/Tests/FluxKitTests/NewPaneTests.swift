import XCTest
@testable import FluxKit

/// Ported from NewPaneTest.kt of the Android app.
final class NewPaneTests: XCTestCase {
    private let state = HerdrState(
        enabled: true,
        running: true,
        agents: [
            HerdrAgent(pane: "w2:p1", agent: "claude", status: .idle, workspace: "flux"),
            HerdrAgent(pane: "w2:p2", agent: "codex", status: .working, workspace: "flux"),
            HerdrAgent(pane: "w3:p1", agent: "claude", status: .done, workspace: "web"),
        ],
        control: true,
        workspaces: [
            HerdrWorkspace(id: "w1", label: "notes", cwd: "~"),
            HerdrWorkspace(id: "w2", label: "flux", cwd: "~/Code/flux/"),
            HerdrWorkspace(id: "w3", label: "web", cwd: "~/Code/web"),
            HerdrWorkspace(id: "w4", label: "flux 2", cwd: "~/Code/flux"),
            HerdrWorkspace(id: "w5", label: "empty", cwd: ""),
            HerdrWorkspace(id: "w6", label: "srv", cwd: "/srv/app"),
        ]
    )

    func testFoldersComeOnceAfterHome() {
        let folders = NewPane.folderChoices(state)
        XCTAssertEqual(folders.map(\.path), ["~", "~/Code/flux", "~/Code/web", "/srv/app"])
        XCTAssertEqual(folders.map(\.name), ["home", "flux", "web", "app"])
        XCTAssertEqual(folders[1].workspace?.id, "w2", "the first workspace of a folder wins")
        XCTAssertEqual(folders.map(\.agents), [0, 2, 1, 0])
        XCTAssertEqual(folders[0].workspace?.id, "w1")
    }

    func testHomeWithoutWorkspace() {
        var s = state
        s.workspaces = [HerdrWorkspace(id: "w3", label: "web", cwd: "~/Code/web")]
        let folders = NewPane.folderChoices(s)
        XCTAssertEqual(folders.map(\.path), ["~", "~/Code/web"])
        XCTAssertNil(folders[0].workspace)
    }

    func testHomeCountsTheAgentsOfItsWorkspace() {
        var s = state
        s.agents.append(HerdrAgent(pane: "w1:p1", agent: "claude", status: .idle, workspace: "notes"))
        XCTAssertEqual(NewPane.folderChoices(s)[0].agents, 1)
    }

    func testFiltersByNameOrPath() {
        let folders = NewPane.folderChoices(state)
        XCTAssertEqual(NewPane.filterFolders(folders, "FLU").map(\.path), ["~/Code/flux"])
        XCTAssertEqual(NewPane.filterFolders(folders, "code").map(\.path), ["~/Code/flux", "~/Code/web"])
        XCTAssertEqual(NewPane.filterFolders(folders, "  "), folders)
    }

    func testMatchesTheWorkspaceOfAFolder() {
        XCTAssertEqual(NewPane.workspaceFor(state, "~/Code/flux")?.id, "w2")
        XCTAssertEqual(NewPane.workspaceFor(state, "~/Code/flux/")?.id, "w2", "a slash at the end does not matter")
        XCTAssertEqual(NewPane.workspaceFor(state, "~")?.id, "w1")
        XCTAssertNil(NewPane.workspaceFor(state, "~/Code/other"))
        XCTAssertNil(NewPane.workspaceFor(state, ""), "a workspace without a folder matches nothing")
    }

    func testFolderNamesAndPaths() {
        XCTAssertEqual(NewPane.folderName("~"), "home")
        XCTAssertEqual(NewPane.folderName("~/"), "home")
        XCTAssertEqual(NewPane.folderName(""), "home")
        XCTAssertEqual(NewPane.folderName("~/Code/flux/"), "flux")
        XCTAssertEqual(NewPane.folderName("/"), "/")
        XCTAssertEqual(NewPane.normalFolder("/"), "/")
        XCTAssertEqual(NewPane.normalFolder("~"), "~")
        XCTAssertEqual(NewPane.normalFolder(" ~/a// "), "~/a")
        XCTAssertEqual(NewPane.normalFolder("//"), "/")
        XCTAssertTrue(NewPane.looksLikePath("~/Code"))
        XCTAssertTrue(NewPane.looksLikePath(" /srv"))
        XCTAssertFalse(NewPane.looksLikePath("flux"))
    }

    func testPicksTheRun() {
        let kinds = ["codex", "claude", "opencode"]
        XCTAssertEqual(NewPane.pickRun("opencode", kinds: kinds, shell: false), "opencode", "the last choice stays")
        XCTAssertEqual(NewPane.pickRun("gemini", kinds: kinds, shell: true), "claude", "a missing agent gives claude")
        XCTAssertEqual(NewPane.pickRun(nil, kinds: ["codex", "opencode"], shell: true), "codex")
        XCTAssertEqual(NewPane.pickRun(NewPane.shellChoice, kinds: kinds, shell: true), NewPane.shellChoice)
        XCTAssertEqual(NewPane.pickRun(NewPane.shellChoice, kinds: kinds, shell: false), "claude", "a terminal needs terminals")
        XCTAssertEqual(NewPane.pickRun(nil, kinds: [], shell: true), NewPane.shellChoice)
        XCTAssertNil(NewPane.pickRun("claude", kinds: [], shell: false))
    }

    func testProductNames() {
        XCTAssertEqual(NewPane.agentProduct("claude"), "Claude Code")
        XCTAssertEqual(NewPane.agentProduct("codex"), "Codex CLI")
        XCTAssertEqual(NewPane.agentProduct("agy"), "Antigravity")
        XCTAssertNil(NewPane.agentProduct("somethingnew"))
    }
}
