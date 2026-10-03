import FluxKit
import SwiftUI

/// The last run choice and folder of each computer on the new pane sheet.
enum NewPanePrefs {
    private static var defaults: UserDefaults { .standard }

    /// The last run choice, `NewPane.shellChoice` for a terminal, or nil when there is none.
    static func run(_ deviceId: String) -> String? { defaults.string(forKey: "herdr.run.\(deviceId)") }

    static func folder(_ deviceId: String) -> String { defaults.string(forKey: "herdr.folder.\(deviceId)") ?? "" }

    static func save(_ deviceId: String, run: String, folder: String) {
        defaults.set(run, forKey: "herdr.run.\(deviceId)")
        defaults.set(folder, forKey: "herdr.folder.\(deviceId)")
    }
}

/// Starts a herdr agent or opens a terminal on a computer. The user picks
/// what to run from the agents that the computer has, then a folder. The
/// pane opens as a new tab of the workspace of that folder, or in a new
/// workspace. A new agent can get a first task, which Flux sends when the
/// agent is ready. `onOpened` gets "agent" or "terminal" and the new pane.
struct NewPaneSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let deviceId: String
    let onOpened: (_ what: String, _ pane: String) -> Void

    @State private var run: String?
    @State private var folder = "~"
    @State private var query = ""
    @State private var newWorkspace = false
    @State private var task = ""
    /// True while the task shows in the large editor.
    @State private var expandedTask = false
    @State private var lockError: String?
    /// Only a create from this sheet counts. Its number is higher than the
    /// last action at the tap.
    @State private var after = Int.max
    @FocusState private var searching: Bool

    init(deviceId: String, onOpened: @escaping (_ what: String, _ pane: String) -> Void) {
        self.deviceId = deviceId
        self.onOpened = onOpened
        let saved = NewPane.normalFolder(NewPanePrefs.folder(deviceId))
        _run = State(initialValue: NewPanePrefs.run(deviceId))
        _folder = State(initialValue: saved.isEmpty ? "~" : saved)
    }

    var body: some View {
        let device = model.device(deviceId)
        let name = device?.name ?? "the computer"
        let plugin = model.core.plugin(HerdrPlugin.self)
        let herdr = plugin?.model.states[deviceId]
        let action = plugin?.model.actions[deviceId].flatMap { $0.action == "create" && $0.seq > after ? $0 : nil }
        NavigationStack {
            Group {
                if device?.online != true {
                    PaneNotReachable(name: name, what: "New agents")
                } else if let herdr, herdr.running, herdr.control, !(herdr.kinds.isEmpty && !herdr.terminals) {
                    form(herdr, name: name, action: action)
                } else if herdr == nil || herdr?.running != true {
                    ContentUnavailableView("herdr is not running", systemImage: "brain",
                                           description: Text("Start herdr on \(name). Then start agents from here."))
                } else if herdr?.control != true {
                    ContentUnavailableView("Control is off", systemImage: "brain", description: Text(.init(
                        "To start agents from this iPhone, set `herdr_control = true` on \(name). Then run `systemctl --user reload fluxd`.")))
                } else {
                    ContentUnavailableView("No coding agent on \(name)", systemImage: "brain", description: Text(
                        "Install a coding agent that herdr supports, such as Claude Code or Codex, on \(name). It shows here within a minute."))
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("New on \(name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .onChange(of: RunOffer(kinds: herdr?.kinds ?? [], shell: herdr?.terminals == true), initial: true) { _, offer in
            run = NewPane.pickRun(run, kinds: offer.kinds, shell: offer.shell)
        }
        .onChange(of: action) { _, a in
            guard let a, !a.sending, a.error == nil, let pane = a.pane else { return }
            plugin?.clearAction(deviceId, seq: a.seq)
            onOpened(a.what, pane)
        }
        .interactiveDismissDisabled(action?.sending == true)
    }

    private func form(_ herdr: HerdrState, name: String, action: HerdrAction?) -> some View {
        let busy = action?.sending == true
        let folders = NewPane.folderChoices(herdr)
        let typed = NewPane.looksLikePath(query)
        // A typed path is the folder at once. Return or a tap on its row keeps it after the search.
        let target = typed ? NewPane.normalFolder(query) : folder
        let match = NewPane.workspaceFor(herdr, target)
        let workspace = match != nil && !newWorkspace ? match?.id ?? "" : ""
        let options = herdr.kinds + (herdr.terminals ? [NewPane.shellChoice] : [])
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SheetLabel("Run")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(options, id: \.self) { k in
                        let running = k == NewPane.shellChoice ? 0 : herdr.agents.filter { $0.agent == k }.count
                        RunTile(choice: k, running: running, selected: k == run) { run = k }
                            .disabled(busy)
                    }
                }
                if herdr.kinds.isEmpty {
                    Text("No coding agent is installed on \(name).").font(.caption).foregroundStyle(.secondary)
                }
                if run != nil && run != NewPane.shellChoice {
                    SheetLabel("Task").padding(.top, 8)
                    VoiceField(enabled: !busy, onText: { task = DictationText.append(task, $0) }) {
                        HStack(alignment: .bottom, spacing: 0) {
                            TextField("Optional. Sent when the agent is ready.", text: $task, axis: .vertical)
                                .lineLimit(2...6)
                                .padding(.leading, 12)
                                .padding(.trailing, 4)
                                .padding(.vertical, 12)
                            HStack(spacing: 0) {
                                ClearKey(text: $task)
                                ExpandKey(isPresented: $expandedTask)
                            }
                            .padding(.trailing, 2)
                            .padding(.bottom, 4)
                        }
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(.separator).opacity(0.5)))
                        .disabled(busy)
                        .sheet(isPresented: $expandedTask) {
                            FieldEditor(title: "Task", text: $task)
                        }
                    }
                    if task.utf8.count > HerdrWire.maxPrompt {
                        Text("The task is too long. The limit is 16 KB.").font(.caption).foregroundStyle(.red)
                    }
                }
                SheetLabel("Folder").padding(.top, 8)
                folderPicker(folders, selected: target, busy: busy)
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            startBar(match: match, target: target, busy: busy, problem: lockError ?? action?.error) {
                start(target: target, workspace: workspace)
            }
        }
    }

    // MARK: Folder

    /// The folder search and the folders. A dictation replaces the search.
    @ViewBuilder
    private func folderPicker(_ folders: [FolderChoice], selected: String, busy: Bool) -> some View {
        VoiceField(enabled: !busy, onText: { query = DictationText.query($0) }) {
            folderSearch(busy: busy)
        }
        folderList(folders, selected: selected, busy: busy)
    }

    private func folderSearch(busy: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search, or type a path such as ~/Code/app", text: $query)
                .font(.subheadline.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($searching)
                .onSubmit { if NewPane.looksLikePath(query) { select(query) } }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(.separator).opacity(0.5)))
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
                .foregroundStyle(.secondary)
        }
    }

    private func select(_ path: String) {
        folder = NewPane.normalFolder(path)
        query = ""
        newWorkspace = false
        searching = false
    }

    // MARK: Start

    private func startBar(match: HerdrWorkspace?, target: String, busy: Bool, problem: String?, start: @escaping () -> Void) -> some View {
        let terminal = run == NewPane.shellChoice
        let tooLong = !terminal && task.utf8.count > HerdrWire.maxPrompt
        let canStart = run != nil && !busy && !tooLong
        let where_ = NewPane.folderName(target)
        let label: String = {
            guard let run else { return "Select what to run" }
            if busy && terminal { return "Opening a terminal in \(where_)" }
            if busy { return "Starting \(run). This can take 30 seconds." }
            if terminal { return "Open a terminal in \(where_)" }
            return "Start \(run) in \(where_)"
        }()
        return VStack(spacing: 8) {
            if let match {
                Picker("Where", selection: $newWorkspace) {
                    Text("New tab in \(match.label)").tag(false)
                    Text("New workspace").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(busy)
            } else {
                Text("Opens in a new workspace, because no workspace has this folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: start) {
                HStack(spacing: 10) {
                    if busy { ProgressView().tint(.white) }
                    Text(label).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .disabled(!canStart)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private func start(target: String, workspace: String) {
        guard let choice = run, let plugin = model.core.plugin(HerdrPlugin.self) else { return }
        let what = choice == NewPane.shellChoice ? "terminal" : "agent"
        lockError = nil
        searching = false
        let last = plugin.model.actions[deviceId]?.seq ?? 0
        let firstTask = what == "agent" ? task : nil
        let name = AgentsFeature.name(model, deviceId)
        ReplyLock.run(reason: what == "agent" ? "Start an agent on \(name)." : "Open a terminal on \(name).") {
            after = last
            NewPanePrefs.save(deviceId, run: choice, folder: target)
            plugin.create(deviceId, what: what, kind: choice, cwd: target, workspace: workspace, task: firstTask)
        } onError: { lockError = $0 }
    }
}

/// What the computer offers to run.
private struct RunOffer: Equatable {
    var kinds: [String]
    var shell: Bool
}

private struct SheetLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One thing to run: an agent kind with its product name, or a terminal.
/// `running` counts the agents of the kind that run now.
private struct RunTile: View {
    let choice: String
    let running: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let terminal = choice == NewPane.shellChoice
        let accent: Color = terminal ? .green : .purple
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let sub = [terminal ? "a shell" : NewPane.agentProduct(choice), running > 0 ? "\(running) running" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: terminal ? "terminal" : "brain")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(terminal ? "terminal" : choice)
                        .font(.subheadline.weight(.semibold).monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(sub.isEmpty ? " " : sub)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(shape.fill(selected ? accent.opacity(0.14) : Color(.secondarySystemGroupedBackground)))
            .overlay(shape.strokeBorder(selected ? accent : Color(.separator).opacity(0.5), lineWidth: selected ? 2 : 1))
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

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: folder.path == "~" ? "house" : "folder")
                    .foregroundStyle(selected || typed ? Color.accentColor : .secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    Text(folder.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if typed { Text("typed").font(.caption).foregroundStyle(.secondary) }
                if folder.agents > 0 {
                    Text(folder.agents == 1 ? "1 agent" : "\(folder.agents) agents").font(.caption).foregroundStyle(.secondary)
                }
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityLabel("Selected")
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(shape.fill(selected ? Color.accentColor.opacity(0.1) : Color(.secondarySystemGroupedBackground)))
            .overlay(shape.strokeBorder(selected ? Color.accentColor : Color(.separator).opacity(0.5), lineWidth: selected ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}
