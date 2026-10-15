import AppKit
import FluxKit
import SwiftUI

/// The last agent and folder of each computer in the new agent sheet.
enum NewAgentPrefs {
    private static var defaults: UserDefaults { .standard }

    static func run(_ deviceId: String) -> String? { defaults.string(forKey: "herdr.run.\(deviceId)") }

    static func folder(_ deviceId: String) -> String { defaults.string(forKey: "herdr.folder.\(deviceId)") ?? "" }

    static func save(_ deviceId: String, run: String, folder: String) {
        defaults.set(run, forKey: "herdr.run.\(deviceId)")
        defaults.set(folder, forKey: "herdr.folder.\(deviceId)")
    }
}

/// Starts a herdr agent on a computer. The user picks the agent from the
/// agents that the computer has, then a folder. The agent opens as a new tab
/// of the workspace of that folder, or in a new workspace. It can get a first
/// task, which Flux sends when the agent is ready. The Mac does not show
/// terminals, so the sheet starts agents only. The new agent is selected in
/// the window when the computer reports it.
struct NewAgentSheet: View {
    let model: AgentsWindowModel
    let name: String
    @Environment(\.tn) private var tn
    @Environment(\.dismiss) private var dismiss

    @State private var run: String?
    @State private var folder: String
    @State private var query = ""
    @State private var newWorkspace = false
    @State private var task = ""
    @State private var taskCursor: NSRange?
    @State private var lockError: String?
    /// True while the folder browser shows.
    @State private var browsing = false
    /// Only a create from this sheet counts. Its number is higher than the
    /// last action at the click.
    @State private var after = Int.max

    init(model: AgentsWindowModel, name: String) {
        self.model = model
        self.name = name
        let saved = NewPane.normalFolder(NewAgentPrefs.folder(model.deviceId))
        _run = State(initialValue: NewAgentPrefs.run(model.deviceId))
        _folder = State(initialValue: saved.isEmpty ? "~" : saved)
    }

    var body: some View {
        let herdr = model.herdr
        let action = model.plugin.model.actions[model.deviceId].flatMap { $0.action == "create" && $0.seq > after ? $0 : nil }
        VStack(spacing: 0) {
            HStack {
                Text("Start an agent on \(name)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tn.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(action?.sending == true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if model.device?.online != true {
                unavailable("\(name) is offline", "Agents start when \(name) is on the same network.")
            } else if let herdr, herdr.running, herdr.control, !herdr.kinds.isEmpty {
                form(herdr, action: action)
            } else if herdr?.running != true {
                unavailable("herdr is not running", "Start herdr on \(name). Then start agents from here.")
            } else if herdr?.control != true {
                unavailable("Control is off",
                            "To start agents from this Mac, set herdr_control = true on \(name). Then run systemctl --user reload fluxd.")
            } else {
                unavailable("No coding agent on \(name)",
                            "Install a coding agent that herdr supports, such as Claude Code or Codex, on \(name). It shows here within a minute.")
            }
        }
        .frame(width: 540, height: 620)
        .background(tn.bg)
        .onChange(of: herdr?.kinds ?? [], initial: true) { _, kinds in
            run = NewPane.pickRun(run, kinds: kinds, shell: false)
        }
        .onChange(of: action) { _, a in
            guard let a, !a.sending, a.error == nil, let pane = a.pane else { return }
            model.plugin.clearAction(model.deviceId, seq: a.seq)
            model.selection = pane
            dismiss()
        }
        .interactiveDismissDisabled(action?.sending == true)
        .sheet(isPresented: $browsing) {
            FolderBrowserSheet(app: model.app, deviceId: model.deviceId, name: name, chosen: target) { select($0) }
        }
    }

    /// The folder of the new agent. A typed path is the folder at once.
    /// Return or a click on its row keeps it after the search.
    private var target: String { NewPane.looksLikePath(query) ? NewPane.normalFolder(query) : folder }

    private func unavailable(_ title: String, _ text: String) -> some View {
        ContentUnavailableView(title, systemImage: "brain", description: Text(text))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func form(_ herdr: HerdrState, action: HerdrAction?) -> some View {
        let busy = action?.sending == true
        let match = NewPane.workspaceFor(herdr, target)
        let workspace = match != nil && !newWorkspace ? match?.id ?? "" : ""
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    SheetLabel("Run")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(herdr.kinds, id: \.self) { k in
                            RunTile(kind: k, running: herdr.agents.filter { $0.agent == k }.count, selected: k == run) { run = k }
                                .disabled(busy)
                        }
                    }
                    SheetLabel("Task").padding(.top, 8)
                    taskField(busy: busy) { start(target: target, workspace: workspace) }
                    SheetLabel("Folder").padding(.top, 8)
                    folderSearch(busy: busy)
                    folderList(NewPane.folderChoices(herdr), selected: target, busy: busy)
                }
                .padding(16)
            }
            Divider()
            startBar(match: match, target: target, busy: busy, problem: lockError ?? action?.error) {
                start(target: target, workspace: workspace)
            }
        }
    }

    // MARK: Task

    private func taskField(busy: Bool, onSubmit: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 4) {
                ReplyField(text: $task, selection: $taskCursor, placeholder: "Optional. Sent when the agent is ready.", onSubmit: onSubmit)
                ClearKey(text: $task) { taskCursor = nil }
                    .padding(.trailing, 10)
                    .padding(.bottom, 9)
            }
            .padding(.leading, 6)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tn.tile))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tn.lineHi))
            .disabled(busy)
            if task.utf8.count > HerdrWire.maxPrompt {
                Text("The task is too long. The limit is 16 KB.").font(.caption).foregroundStyle(tn.red)
            }
        }
    }

    // MARK: Folder

    private func folderSearch(busy: Bool) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(tn.sub)
                TextField("Search, or type a path such as ~/Code/app", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .autocorrectionDisabled()
                    .onSubmit { if NewPane.looksLikePath(query) { select(query) } }
                ClearKey(text: $query)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tn.tile))
            // The border takes no clicks, so the clear key under it gets them.
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tn.lineHi).allowsHitTesting(false))
            Button("Browse…") { browsing = true }
                .help("Pick a folder from the folders of \(name)")
        }
        .disabled(busy)
    }

    @ViewBuilder
    private func folderList(_ folders: [FolderChoice], selected: String, busy: Bool) -> some View {
        let typedPath = NewPane.normalFolder(query)
        let typed = NewPane.looksLikePath(query)
        if typed && !folders.contains(where: { $0.path == typedPath }) {
            FolderRow(folder: FolderChoice(path: typedPath, name: NewPane.folderName(typedPath), workspace: nil, agents: 0),
                      selected: true, typed: true) { select(typedPath) }
                .disabled(busy)
        }
        if query.isEmpty && !folders.contains(where: { $0.path == selected }) {
            FolderRow(folder: FolderChoice(path: selected, name: NewPane.folderName(selected), workspace: nil, agents: 0), selected: true) {}
        }
        let shown = NewPane.filterFolders(folders, typed ? "" : query)
        ForEach(shown) { f in
            FolderRow(folder: f, selected: f.path == selected) { select(f.path) }
                .disabled(busy)
        }
        if shown.isEmpty && !typed {
            Text("No folder has \"\(query)\". Type a path that starts with ~/ or /.")
                .font(.caption)
                .foregroundStyle(tn.sub)
        }
    }

    private func select(_ path: String) {
        folder = NewPane.normalFolder(path)
        query = ""
        newWorkspace = false
    }

    // MARK: Start

    private func startBar(match: HerdrWorkspace?, target: String, busy: Bool, problem: String?, start: @escaping () -> Void) -> some View {
        let tooLong = task.utf8.count > HerdrWire.maxPrompt
        let canStart = run != nil && !busy && !tooLong
        let label: String = {
            guard let run else { return "Select an agent" }
            if busy { return "Starting \(run). This can take 30 seconds." }
            return "Start \(run) in \(NewPane.folderName(target))"
        }()
        return VStack(alignment: .leading, spacing: 8) {
            if let match {
                Picker("Where", selection: $newWorkspace) {
                    Text("New tab in \(match.label)").tag(false)
                    Text("New workspace").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(busy)
            } else {
                Text("Opens in a new workspace, because no workspace has this folder.")
                    .font(.caption)
                    .foregroundStyle(tn.sub)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(tn.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.small) }
                Button(label, action: start)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
        .padding(16)
    }

    private func start(target: String, workspace: String) {
        guard let kind = run, task.utf8.count <= HerdrWire.maxPrompt else { return }
        lockError = nil
        let last = model.plugin.model.actions[model.deviceId]?.seq ?? 0
        ReplyLock.run(reason: "start an agent on \(name)") {
            after = last
            NewAgentPrefs.save(model.deviceId, run: kind, folder: target)
            model.plugin.create(model.deviceId, what: "agent", kind: kind, cwd: target, workspace: workspace, task: task)
        } onError: { lockError = $0 }
    }
}

/// The state of the first task of a new agent, until it went. A task that
/// did not go waits in the reply field of the agent.
struct FirstTaskNote: View {
    let model: AgentsWindowModel
    let agent: HerdrAgent
    @Environment(\.tn) private var tn

    var body: some View {
        if let task = model.plugin.model.firstTasks[model.deviceId], task.pane == agent.pane {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                switch task.phase {
                case .starting, .waiting:
                    ProgressView().controlSize(.mini)
                    Text("Flux sends your task when \(agent.agent) is ready.")
                case .answering:
                    Image(systemName: "questionmark.bubble").foregroundStyle(tn.orange)
                    Text("Answer \(agent.agent) first. Then Flux sends your task.")
                case .sending:
                    ProgressView().controlSize(.mini)
                    Text("Sending your task…")
                case .sent:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(tn.green)
                    Text("\(agent.agent) got your task.")
                case .failed(let reason):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(tn.red)
                    Text("Your task did not go: \(reason) It is in the reply field.")
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .foregroundStyle(tn.sub)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .task(id: task.phase) {
                switch task.phase {
                case .sent:
                    try? await Task.sleep(for: .seconds(4))
                    if !Task.isCancelled { model.plugin.clearFirstTask(model.deviceId) }
                case .failed:
                    if (model.drafts[agent.pane] ?? "").isEmpty { model.drafts[agent.pane] = task.text }
                    try? await Task.sleep(for: .seconds(8))
                    if !Task.isCancelled { model.plugin.clearFirstTask(model.deviceId) }
                default:
                    break
                }
            }
        }
    }
}

private struct SheetLabel: View {
    let text: String
    @Environment(\.tn) private var tn

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tn.sub)
            .padding(.leading, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One agent kind with its product name. `running` counts the agents of the kind that run now.
private struct RunTile: View {
    let kind: String
    let running: Int
    let selected: Bool
    let action: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let sub = [NewPane.agentProduct(kind), running > 0 ? "\(running) running" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "brain")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tn.magenta)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tn.text)
                        .lineLimit(1)
                    Text(sub.isEmpty ? " " : sub)
                        .font(.caption)
                        .foregroundStyle(tn.sub)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(shape.fill(selected ? tn.magenta.opacity(0.14) : tn.tile))
            .overlay(shape.strokeBorder(selected ? tn.magenta : tn.lineHi, lineWidth: selected ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// A folder: its name, its path, and the agents in its workspace. `typed`
/// marks a new path from the search field.
private struct FolderRow: View {
    let folder: FolderChoice
    let selected: Bool
    var typed = false
    let action: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: folder.path == "~" ? "house" : "folder")
                    .foregroundStyle(selected || typed ? tn.accent : tn.sub)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(tn.text).lineLimit(1)
                    Text(folder.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(tn.sub)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if typed { Text("typed").font(.caption).foregroundStyle(tn.sub) }
                if folder.agents > 0 {
                    Text(folder.agents == 1 ? "1 agent" : "\(folder.agents) agents").font(.caption).foregroundStyle(tn.sub)
                }
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(tn.accent).accessibilityLabel("Selected")
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(shape.fill(selected ? tn.accent.opacity(0.1) : tn.tile))
            .overlay(shape.strokeBorder(selected ? tn.accent : tn.lineHi, lineWidth: selected ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}
