import Foundation

/// A folder where a new pane can open. `path` is the folder as the
/// computer sends it, often with `~/`. `workspace` is the first workspace
/// in that folder, or nil. `agents` counts the agents in that workspace.
public struct FolderChoice: Sendable, Hashable, Identifiable {
    public var path: String
    public var name: String
    public var workspace: HerdrWorkspace?
    public var agents: Int

    public init(path: String, name: String, workspace: HerdrWorkspace?, agents: Int) {
        self.path = path
        self.name = name
        self.workspace = workspace
        self.agents = agents
    }

    public var id: String { path }
}

/// The choices of the screen that starts a herdr agent or opens a
/// terminal, like NewPane.kt of the Android app.
public enum NewPane {
    /// The run choice for a plain terminal. Agent kinds are never empty.
    public static let shellChoice = ""

    /// Returns the folder without a slash at its end. `/` and `~` stay.
    public static func normalFolder(_ path: String) -> String {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.count > 1 else { return p }
        var t = Substring(p)
        while t.hasSuffix("/") { t = t.dropLast() }
        return t.isEmpty ? "/" : String(t)
    }

    /// The last part of a folder, or "home" for the home folder.
    public static func folderName(_ path: String) -> String {
        let p = normalFolder(path)
        switch p {
        case "", "~": return "home"
        case "/": return "/"
        default: return p.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? p
        }
    }

    /// True when `text` is a folder path and not a search: it starts with `/` or `~`.
    public static func looksLikePath(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("/") || t.hasPrefix("~")
    }

    /// The folders of the workspaces in sidebar order, each once, after the
    /// home folder. A workspace without a folder is left out.
    public static func folderChoices(_ state: HerdrState) -> [FolderChoice] {
        let homeWorkspace = workspaceFor(state, "~")
        var out = [FolderChoice(path: "~", name: "home", workspace: homeWorkspace,
                                agents: homeWorkspace.map { w in state.agents.filter { $0.workspace == w.label }.count } ?? 0)]
        var seen: Set<String> = ["~"]
        for w in state.workspaces {
            let path = normalFolder(w.cwd)
            if path.isEmpty || seen.contains(path) { continue }
            seen.insert(path)
            out.append(FolderChoice(path: path, name: folderName(path), workspace: w, agents: state.agents.filter { $0.workspace == w.label }.count))
        }
        return out
    }

    /// The folders whose name or path has `query`, without regard to case.
    /// An empty query keeps all.
    public static func filterFolders(_ folders: [FolderChoice], _ query: String) -> [FolderChoice] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return folders }
        return folders.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.path.localizedCaseInsensitiveContains(q) }
    }

    /// The first workspace in sidebar order whose folder is `folder`, or nil.
    public static func workspaceFor(_ state: HerdrState, _ folder: String) -> HerdrWorkspace? {
        let f = normalFolder(folder)
        return state.workspaces.first { !$0.cwd.isEmpty && normalFolder($0.cwd) == f }
    }

    /// The product name of an agent kind, or nil when Flux does not know it.
    public static func agentProduct(_ kind: String) -> String? {
        switch kind {
        case "claude": return "Claude Code"
        case "codex": return "Codex CLI"
        case "opencode": return "OpenCode"
        case "gemini": return "Gemini CLI"
        case "copilot": return "GitHub Copilot"
        case "cursor": return "Cursor Agent"
        case "amp": return "Amp"
        case "qwen": return "Qwen Code"
        case "kimi": return "Kimi CLI"
        case "muse": return "Muse Code"
        case "grok": return "Grok CLI"
        case "agy": return "Antigravity"
        case "cline": return "Cline"
        default: return nil
        }
    }

    /// The run choice to select: `last` when the computer still offers it,
    /// then claude, then the first agent, then a terminal. Nil when the
    /// computer offers nothing.
    public static func pickRun(_ last: String?, kinds: [String], shell: Bool) -> String? {
        if let last, last != shellChoice, kinds.contains(last) { return last }
        if last == shellChoice && shell { return shellChoice }
        if kinds.contains("claude") { return "claude" }
        if let first = kinds.first { return first }
        if shell { return shellChoice }
        return nil
    }
}
