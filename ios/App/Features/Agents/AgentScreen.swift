import FluxKit
import SwiftUI

/// How often the agent screen reads the output again while the agent works.
private let workingRefresh: Duration = .seconds(5)

/// The recent output of one herdr agent in terminal colors, with the newest
/// lines at the bottom. The screen reads the output on open, when the
/// status changes, and every 5 seconds while the agent works. When the
/// computer allows it, the screen also sends keys and text to the agent.
struct AgentScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let deviceId: String
    let pane: String
    @State private var asking = false
    @State private var closeError: String?

    private struct Refresh: Equatable {
        var online: Bool
        var active: Bool
        var status: AgentStatus?
    }

    var body: some View {
        let device = model.device(deviceId)
        let online = device?.online == true
        let name = device?.name ?? "the computer"
        if let plugin = model.core.plugin(HerdrPlugin.self) {
            let herdr = plugin.model.states[deviceId]
            let agent = herdr?.agent(pane)
            let out = plugin.model.output(deviceId, pane: pane)
            let closing = plugin.model.actions[deviceId].map { $0.action == "close" && $0.pane == pane && $0.sending } ?? false
            VStack(spacing: 10) {
                if !online {
                    PaneNotReachable(name: name, what: "The agent output")
                } else if agent == nil && herdr != nil {
                    ContentUnavailableView("The agent is gone", systemImage: "brain",
                                           description: Text("The agent in \(pane) on \(name) stopped or moved to another pane."))
                } else {
                    if let agent {
                        AgentHeader(agent: agent, control: herdr?.control == true, closing: closing, error: closeError) { asking = true }
                    }
                    PaneOutput(output: out)
                    if let agent {
                        FirstTaskNote(deviceId: deviceId, agent: agent)
                        if herdr?.control == true {
                            AgentReplyControls(deviceId: deviceId, agent: agent, output: out)
                        } else {
                            Text(.init("To answer from this iPhone, set `herdr_control = true` on \(name)."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(agent.map { "\($0.agent) · \($0.project.isEmpty ? pane : $0.project)" } ?? pane)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if out?.loading == true && !(out?.lines.isEmpty ?? true) {
                        ProgressView()
                    } else if online && agent != nil {
                        Button { plugin.read(deviceId, pane: pane) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    }
                }
            }
            .task(id: Refresh(online: online, active: scenePhase == .active, status: agent?.status)) {
                guard online, scenePhase == .active, agent != nil else { return }
                // A new status reads at once. Only the polls wait for the last read.
                plugin.read(deviceId, pane: pane)
                while agent?.status == .working {
                    try? await Task.sleep(for: workingRefresh)
                    if Task.isCancelled { return }
                    plugin.poll(deviceId, pane: pane)
                }
            }
            .onDisappear { plugin.closeOutput(deviceId, pane: pane) }
            .modifier(PaneCloser(deviceId: deviceId, pane: pane, title: "Close \(agent?.agent ?? "the agent")?",
                                 message: "herdr closes \(pane) on \(name), and the agent in it stops.",
                                 asking: $asking, error: $closeError))
        }
    }
}

private struct AgentHeader: View {
    let agent: HerdrAgent
    let control: Bool
    let closing: Bool
    let error: String?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                AgentStatusLabel(status: agent.status)
                Spacer()
                Text(agent.pane)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                if control { PaneCloseButton(closing: closing, action: close) }
            }
            if !agent.title.isEmpty {
                Text(agent.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

/// The state of the first task of a new agent, until it went.
private struct FirstTaskNote: View {
    @Environment(AppModel.self) private var model
    let deviceId: String
    let agent: HerdrAgent

    var body: some View {
        if let plugin = model.core.plugin(HerdrPlugin.self), let task = plugin.model.firstTasks[deviceId], task.pane == agent.pane {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                switch task.phase {
                case .starting, .waiting:
                    ProgressView().controlSize(.small)
                    Text("Flux sends your task when \(agent.agent) is ready.")
                case .answering:
                    Image(systemName: "questionmark.bubble").foregroundStyle(.orange)
                    Text("Answer \(agent.agent) first. Then Flux sends your task.")
                case .sending:
                    ProgressView().controlSize(.small)
                    Text("Sending your task…")
                case .sent:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("\(agent.agent) got your task.")
                case .failed(let reason):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text("Your task did not go: \(reason) It is in the reply field.")
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .task(id: task.phase) {
                guard task.phase == .sent else { return }
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { plugin.clearFirstTask(deviceId) }
            }
        }
    }
}

/// The highest part of the screen that the choices of a dialog can take.
private let choicesMaxHeight: CGFloat = 196

/// The reply controls of an agent: the choices of a dialog, a key bar, a
/// text field, and a mic key for dictation. Each reply asks for Face ID or
/// the passcode first, see `ReplyLock`.
private struct AgentReplyControls: View {
    @Environment(AppModel.self) private var model
    let deviceId: String
    let agent: HerdrAgent
    let output: HerdrOutput?
    @State private var text = ""
    @State private var lockError: String?
    @State private var voiceError: String?
    @State private var dictation = Dictation()
    /// True while the prompt shows in the large editor.
    @State private var expanded = false
    @FocusState private var focused: Bool

    private var plugin: HerdrPlugin? { model.core.plugin(HerdrPlugin.self) }

    var body: some View {
        let reply = plugin?.model.reply(deviceId, pane: agent.pane)
        let choices = agent.status == .blocked ? output?.choices ?? [] : []
        let sendingPrompt = reply?.sending == true && reply?.action == "prompt"
        let dictating = dictation.phase != .idle
        VStack(alignment: .leading, spacing: 8) {
            if !choices.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(choices) { c in ChoiceButton(choice: c) { keys(c.key) } }
                    }
                }
                .frame(maxHeight: choicesMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                PaneKey(label: "esc", name: "Escape") { keys("esc") }
                PaneKey(label: "tab", name: "Tab") { keys("tab") }
                PaneKey(label: "↑", name: "Up") { keys("up") }
                PaneKey(label: "↓", name: "Down") { keys("down") }
                PaneKey(label: "enter", name: "Enter", accent: agent.status == .blocked && choices.isEmpty) { keys("enter") }
            }
            HStack(alignment: .bottom, spacing: 6) {
                HStack(alignment: .bottom, spacing: 0) {
                    TextField("Write to \(agent.agent)", text: $text, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($focused)
                        .padding(.leading, 12)
                        .padding(.trailing, 4)
                        .padding(.vertical, 11)
                    HStack(spacing: 0) {
                        ClearKey(text: $text)
                        ExpandKey(isPresented: $expanded)
                    }
                    .padding(.trailing, 2)
                    .padding(.bottom, 4)
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(.separator).opacity(0.5)))
                if Dictation.available {
                    Button {
                        if dictating { dictation.stop() } else { dictate() }
                    } label: {
                        Image(systemName: dictating ? "stop.fill" : "mic")
                            .foregroundStyle(dictating ? .red : .secondary)
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(dictating ? "Stop the dictation" : "Dictate")
                }
                let canSend = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sendingPrompt
                Button(action: send) {
                    Group {
                        if sendingPrompt {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "paperplane.fill").font(.system(size: 16, weight: .semibold))
                        }
                    }
                    .foregroundStyle(canSend ? Color.white : Color.secondary)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(canSend ? Color.accentColor : Color(.tertiarySystemFill)))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
            if dictating {
                Text(dictation.pending.isEmpty && dictation.settled.isEmpty ? "Listening…" : dictation.settled + " " + dictation.pending)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let problem = lockError ?? voiceError ?? dictation.error ?? reply?.error {
                Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                // fluxd refused the prompt because the agent waits for a
                // choice. The user can type the same text into the dialog.
                if problem == reply?.error, let r = reply, r.blocked, let blocked = r.text {
                    Button("Send as answer") { answer(blocked) }
                        .font(.caption.weight(.semibold))
                        .accessibilityHint("Types the text into the dialog of \(agent.agent)")
                }
            }
        }
        .sheet(isPresented: $expanded) {
            FieldEditor(title: "Write to \(agent.agent)", text: $text, actionLabel: "Send",
                        actionEnabled: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, onAction: send)
        }
        // A prompt that the computer accepted leaves the field.
        .onChange(of: reply) { _, r in
            if let r, r.action == "prompt", !r.sending, r.error == nil, r.seq == sentSeq { text = "" }
        }
        // A first task that did not go waits in the field.
        .onChange(of: failedTask, initial: true) { _, failed in
            guard let failed, let plugin else { return }
            if text.isEmpty { text = failed }
            plugin.clearFirstTask(deviceId)
        }
        .onDisappear { dictation.cancel() }
    }

    /// The number of the last prompt from the field.
    @State private var sentSeq = -1

    /// The text of the first task of this agent when it failed.
    private var failedTask: String? {
        guard let task = plugin?.model.firstTasks[deviceId], task.pane == agent.pane, case .failed = task.phase else { return nil }
        return task.text
    }

    private func guarded(_ action: @escaping @MainActor () -> Void) {
        lockError = nil
        ReplyLock.run(reason: "Answer agents on \(AgentsFeature.name(model, deviceId)).", action: action) { lockError = $0 }
    }

    private func keys(_ k: String...) {
        guarded { plugin?.sendKeys(deviceId, pane: agent.pane, k) }
    }

    private func send() {
        let t = text
        guarded {
            guard let plugin else { return }
            plugin.sendPrompt(deviceId, pane: agent.pane, t)
            sentSeq = plugin.model.reply(deviceId, pane: agent.pane)?.seq ?? -1
        }
    }

    /// Sends the text of a refused prompt again as the answer to the dialog of the agent.
    private func answer(_ t: String) {
        guard plugin?.model.reply(deviceId, pane: agent.pane)?.sending != true else { return }
        guarded {
            guard let plugin else { return }
            plugin.sendPrompt(deviceId, pane: agent.pane, t, answer: true)
            sentSeq = plugin.model.reply(deviceId, pane: agent.pane)?.seq ?? -1
        }
    }

    /// Dictates on the iPhone. The words go into the field and wait for Send.
    private func dictate() {
        voiceError = nil
        lockError = nil
        if let problem = MicFeature.dictationProblem(model.core) {
            voiceError = problem
            return
        }
        Task { @MainActor in
            if let problem = await Dictation.authorize() {
                voiceError = problem
                return
            }
            let hints = [agent.agent, agent.project, agent.workspace].filter { !$0.isEmpty }
            // The dictation uses the languages of the iPhone.
            dictation.start(language: "", hints: hints) { spoken in
                let edit = DictationText.insert(text, start: text.utf16.count, end: text.utf16.count, spoken: spoken)
                text = edit.text
            }
        }
    }
}

/// A numbered choice of a dialog. A tap sends its digit.
private struct ChoiceButton: View {
    let choice: AgentChoice
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(choice.key)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                Text(choice.label)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(shape.fill(choice.selected ? Color.accentColor.opacity(0.12) : Color(.secondarySystemGroupedBackground)))
            .overlay(shape.strokeBorder(choice.selected ? Color.accentColor : Color(.separator).opacity(0.5)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(choice.key). \(choice.label)")
    }
}
