import FluxKit
import SwiftUI

/// How often the terminal screen reads the output again.
private let terminalRefresh: Duration = .seconds(3)

/// A herdr terminal: its recent output in terminal colors, a key bar, and
/// a command field. The screen reads the output again every 3 seconds
/// while it is on the screen. Each input asks for Face ID or the passcode
/// first, see `ReplyLock`.
struct TerminalScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let deviceId: String
    let pane: String
    @State private var asking = false
    @State private var closeError: String?

    private struct Refresh: Equatable {
        var online: Bool
        var active: Bool
    }

    var body: some View {
        let device = model.device(deviceId)
        let online = device?.online == true
        let name = device?.name ?? "the computer"
        if let plugin = model.core.plugin(HerdrPlugin.self) {
            let herdr = plugin.model.states[deviceId]
            let term = herdr?.terminal(pane)
            let out = plugin.model.output(deviceId, pane: pane)
            let closing = plugin.model.actions[deviceId].map { $0.action == "close" && $0.pane == pane && $0.sending } ?? false
            VStack(spacing: 10) {
                if !online {
                    PaneNotReachable(name: name, what: "The terminal")
                } else if let herdr, !herdr.terminals {
                    ContentUnavailableView("Terminals are off", systemImage: "terminal", description: Text(.init(
                        "To use herdr terminals from this iPhone, set `herdr_terminals = true` on \(name). It needs `herdr_control = true` too.")))
                } else if term == nil && herdr != nil {
                    ContentUnavailableView("The terminal is gone", systemImage: "terminal",
                                           description: Text("The terminal \(pane) on \(name) closed."))
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Image(systemName: "terminal").foregroundStyle(.green).accessibilityHidden(true)
                            Text(term.map { $0.title.isEmpty ? "shell" : $0.title } ?? "shell")
                                .font(.subheadline.weight(.semibold).monospaced())
                                .lineLimit(1)
                            Spacer()
                            Text(pane).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            PaneCloseButton(closing: closing) { asking = true }
                        }
                        if let closeError {
                            Text(closeError).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardBackground()
                    PaneOutput(output: out)
                    TerminalControls(deviceId: deviceId, pane: pane)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("terminal · \(term.flatMap { $0.project.isEmpty ? nil : $0.project } ?? pane)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if out?.loading == true && !(out?.lines.isEmpty ?? true) {
                        ProgressView()
                    } else if online && term != nil {
                        Button { plugin.read(deviceId, pane: pane) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    }
                }
            }
            .task(id: Refresh(online: online, active: scenePhase == .active)) {
                guard online, scenePhase == .active else { return }
                while !Task.isCancelled {
                    plugin.read(deviceId, pane: pane)
                    try? await Task.sleep(for: terminalRefresh)
                }
            }
            .onDisappear { plugin.closeOutput(deviceId, pane: pane) }
            .modifier(PaneCloser(deviceId: deviceId, pane: pane, title: "Close this terminal?",
                                 message: "herdr closes \(pane) on \(name). The shell and its command stop.",
                                 asking: $asking, error: $closeError))
        }
    }
}

/// The key bar and the command field of a terminal. Run types the command
/// and presses Enter.
private struct TerminalControls: View {
    @Environment(AppModel.self) private var model
    let deviceId: String
    let pane: String
    @State private var text = ""
    @State private var lockError: String?
    /// The number of the last input with the text of the field. Only its
    /// answer empties the field.
    @State private var sentSeq = -1

    private var plugin: HerdrPlugin? { model.core.plugin(HerdrPlugin.self) }

    var body: some View {
        let reply = plugin?.model.reply(deviceId, pane: pane)
        let sending = reply?.sending == true && reply?.seq == sentSeq
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                PaneKey(label: "esc", name: "Escape") { keys("esc") }
                PaneKey(label: "tab", name: "Tab") { keys("tab") }
                PaneKey(label: "^C", name: "Control C") { keys("ctrl+c") }
                PaneKey(label: "^D", name: "Control D") { keys("ctrl+d") }
                PaneKey(label: "↑", name: "Up") { keys("up") }
                PaneKey(label: "↓", name: "Down") { keys("down") }
                PaneKey(label: "enter", name: "Enter") { keys("enter") }
            }
            HStack(alignment: .top, spacing: 6) {
                // A dictation puts a command in the field. It waits there for Run, so a command still needs Face ID.
                VoiceField(onText: { text = DictationText.append(text, DictationText.command($0), sentences: false) }) {
                    TextField("Type a command", text: $text)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.send)
                        .onSubmit(run)
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(.separator).opacity(0.5)))
                }
                Button(action: run) {
                    Group {
                        if sending {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "return").font(.system(size: 16, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .disabled(sending)
                .accessibilityLabel("Run")
            }
            if let problem = lockError ?? reply?.error {
                Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: reply) { _, r in
            if let r, r.seq == sentSeq, !r.sending, r.error == nil { text = "" }
        }
    }

    private func guarded(_ action: @escaping @MainActor () -> Void) {
        lockError = nil
        ReplyLock.run(reason: "Type in terminals on \(AgentsFeature.name(model, deviceId)).", action: action) { lockError = $0 }
    }

    private func keys(_ k: String...) {
        guarded { plugin?.sendInput(deviceId, pane: pane, text: "", keys: k) }
    }

    /// Types the command and presses Enter. An empty field presses Enter.
    private func run() {
        let t = text
        guard !t.isEmpty else { return keys("enter") }
        guarded {
            guard let plugin else { return }
            plugin.sendInput(deviceId, pane: pane, text: t, keys: ["enter"])
            sentSeq = plugin.model.reply(deviceId, pane: pane)?.seq ?? -1
        }
    }
}
