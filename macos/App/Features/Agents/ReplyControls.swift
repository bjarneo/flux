import AppKit
import FluxKit
import SwiftUI

/// The dock of an agent under its thread. A blocked agent shows its
/// question and the choices, with Write for a text answer. A working agent
/// shows its step and Interrupt. A finished agent shows the end of its
/// turn. The key row shows while `keysOpen`. Under that, the composer takes
/// a prompt as text or as dictation. Each reply asks for Touch ID or the
/// password first, see `ReplyLock`. `sentAnswer` gets each answer to a
/// choice, for the thread.
struct ReplyControls: View {
    @Bindable var model: AgentsWindowModel
    let agent: HerdrAgent
    let output: HerdrOutput?
    let thread: AgentThread?
    let ask: AgentAsk?
    let name: String
    @Binding var keysOpen: Bool
    let review: (() -> Void)?
    let sentAnswer: (SentAnswer) -> Void
    @Environment(\.tn) private var tn
    @State private var lockError: String?
    @State private var voiceError: String?
    @State private var picking = false
    @State private var canDictate = false
    @State private var editing = false
    /// True while a blocked agent shows the composer in the place of its choices.
    @State private var writing = false
    /// The output that the last answer answered.
    @State private var answered: HerdrOutput?

    private var plugin: HerdrPlugin { model.plugin }
    private var reply: HerdrReply? { plugin.model.reply(model.deviceId, pane: agent.pane) }
    private var dictation: Dictation { model.dictation }

    var body: some View {
        let blocked = agent.status == .blocked
        let choices = blocked ? output?.choices ?? [] : []
        let asking = blocked && !choices.isEmpty && !writing
        let sendingPrompt = reply?.sending == true && reply?.action == "prompt"
        VStack(alignment: .leading, spacing: 10) {
            if blocked {
                askHeader(hasChoices: !choices.isEmpty)
                if asking {
                    if let ask { AskText(ask: ask, questionFont: .system(size: 15, weight: .semibold), spacing: 6).padding(.horizontal, 4) }
                    // A choice takes no click while a reply goes, and after an answer until the next output.
                    let open = reply?.sending != true && (answered == nil || (output != answered && output?.loading == false))
                    VStack(spacing: 6) {
                        ForEach(Array(choices.enumerated()), id: \.element.id) { i, c in
                            AskChoiceButton(choice: c, primary: i == 0, enabled: open) { answer(c) }
                        }
                    }
                }
            } else if agent.status == .working {
                workingRow
            } else if agent.status == .done {
                doneRow
            }
            if keysOpen {
                HStack(spacing: 6) {
                    KeyButton(label: "esc", help: "Escape") { keys("esc") }
                    KeyButton(label: "tab", help: "Tab") { keys("tab") }
                    KeyButton(label: "↑", help: "Up") { keys("up") }
                    KeyButton(label: "↓", help: "Down") { keys("down") }
                    KeyButton(label: "enter", help: "Enter", accent: blocked && choices.isEmpty) { keys("enter") }
                }
            }
            if !asking { composer(sending: sendingPrompt) }
            if let problem = lockError ?? voiceError ?? dictation.error ?? reply?.error {
                HStack(spacing: 10) {
                    Text(problem)
                        .font(.system(size: 12))
                        .foregroundStyle(tn.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if problem == dictation.error && dictation.languageError {
                        Button("Choose a Language") { picking = true }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    if problem == DictationText.speechDenied || problem == DictationText.micDenied {
                        Button("Open Privacy Settings") { NSWorkspace.shared.open(privacyURL(problem)) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    // fluxd refused the prompt because the agent waits for a
                    // choice. The user can type the same text into the dialog.
                    if problem == reply?.error, let r = reply, r.blocked, let text = r.text {
                        Button("Send as answer") { answerText(text) }
                            .buttonStyle(.link)
                            .font(.caption)
                            .help("Type the text into the dialog of \(agent.agent)")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(DockShape().fill(tn.tile))
        .overlay(alignment: .top) {
            // The line along the top edge and the round corners.
            DockShape().stroke(tn.line, lineWidth: 1).frame(height: 40).mask(alignment: .top) { Rectangle().frame(height: 20) }
        }
        .onChange(of: reply) {
            // A prompt that the computer accepted leaves the field.
            if let r = reply, r.action == "prompt", !r.sending, r.error == nil {
                model.drafts[agent.pane] = nil
                model.cursors[agent.pane] = nil
                writing = false
            }
        }
        .task { canDictate = await Task.detached { Dictation.available }.value }
        .sheet(isPresented: $picking) {
            LanguagePicker(selected: plugin.model.dictationLanguage) { tag in
                plugin.model.dictationLanguage = tag
                picking = false
                dictate()
            } onCancel: {
                picking = false
            }
        }
    }

    /// The top row of the dock of a blocked agent: the agent asks, then
    /// Write. Write shows the composer in the place of the choices, and
    /// Choices shows the choices again.
    private func askHeader(hasChoices: Bool) -> some View {
        HStack(spacing: 8) {
            PulseDot(color: tn.red)
            Text("\(agent.agent) asks")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tn.red)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hasChoices {
                Button { writing.toggle() } label: { Label(writing ? "Choices" : "Write", systemImage: "pencil") }
                    .buttonStyle(.link)
                    .font(.system(size: 12, weight: .semibold))
                    .help(writing ? "Show the choices" : "Write an answer in the place of the choices")
            }
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 24)
    }

    /// The dock row of a working agent: its step and time, and Interrupt, which sends Escape.
    private var workingRow: some View {
        HStack(spacing: 12) {
            RingSpinner(size: 18, color: tn.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text((thread?.step).flatMap { $0.isEmpty ? nil : $0 } ?? "Working")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tn.text)
                    .lineLimit(2)
                Text([thread?.elapsed ?? "", "\(agent.agent) is working"].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(tn.sub)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { keys("esc") } label: {
                HStack(spacing: 6) {
                    Text("Interrupt").font(.system(size: 12, weight: .semibold)).foregroundStyle(tn.text)
                    Text("esc").font(.system(size: 11, design: .monospaced)).foregroundStyle(tn.sub).accessibilityHidden(true)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: TiledMetrics.buttonHeight)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tn.line))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Send Escape to \(agent.agent)")
            .accessibilityLabel("Interrupt \(agent.agent)")
        }
        .padding(.horizontal, 4)
    }

    /// The dock row of a finished agent: the end of its turn, and Review changes.
    private var doneRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle").foregroundStyle(tn.green)
            Text(doneText(thread?.worked ?? ""))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tn.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let review {
                Button("Review changes", action: review)
                    .buttonStyle(.link)
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 24)
    }

    /// The composer: the reply field, the mic key, and the send key.
    private func composer(sending: Bool) -> some View {
        let placeholder = agent.status == .blocked ? "Tell \(agent.agent) what to do differently"
            : agent.status == .working ? "Steer \(agent.agent) while it works" : "Write to \(agent.agent)"
        return DictationBar(
            dictation: dictation,
            canDictate: canDictate,
            onStart: dictate,
            onLanguage: {
                dictation.stopNow()
                picking = true
            },
            field: {
                let draft = Binding(get: { model.drafts[agent.pane] ?? "" }, set: { model.drafts[agent.pane] = $0 })
                HStack(alignment: .bottom, spacing: 4) {
                    ReplyField(
                        text: draft,
                        selection: Binding(get: { model.cursors[agent.pane] }, set: { model.cursors[agent.pane] = $0 }),
                        placeholder: placeholder,
                        onSubmit: send
                    )
                    // The keys line up with the last line of the text.
                    HStack(spacing: 6) {
                        ClearKey(text: draft) { model.cursors[agent.pane] = nil }
                        ExpandKey { editing = true }
                    }
                    .padding(.trailing, 10)
                    .padding(.bottom, 9)
                }
                .padding(.leading, 6)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(tn.bg))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(tn.lineHi))
                .sheet(isPresented: $editing) {
                    // The editor checks the text and the reply at each change.
                    let canSend = {
                        !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && !(reply?.sending == true && reply?.action == "prompt")
                    }
                    // The editor changes the text, so a dictation after it adds its words at the end.
                    FieldEditor(title: "Write to \(agent.agent)", text: draft,
                                action: FieldEditorAction(title: "Send", enabled: canSend, run: send)) {
                        editing = false
                        model.cursors[agent.pane] = nil
                    }
                }
            },
            send: {
                let canSend = !(model.drafts[agent.pane] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
                // The key keeps its color with no text, as in the design. It takes no click then.
                Button(action: send) {
                    ZStack {
                        if sending {
                            RingSpinner(size: 14, color: tn.onAccent)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(tn.onAccent)
                        }
                    }
                    .frame(width: DictationLayout.keySize, height: DictationLayout.keySize)
                    .background(Circle().fill(tn.accent))
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send the text to \(agent.agent)")
                .accessibilityLabel("Send")
            }
        )
    }

    private func guarded(_ action: @escaping @MainActor () -> Void) {
        lockError = nil
        ReplyLock.run(reason: "answer agents on \(name)", action: action) { lockError = $0 }
    }

    private func keys(_ k: String) {
        let deviceId = model.deviceId
        let pane = agent.pane
        guarded { [plugin] in plugin.sendKeys(deviceId, pane: pane, [k]) }
    }

    /// Sends the digit of a choice, and keeps the answer for the thread.
    private func answer(_ c: AgentChoice) {
        let deviceId = model.deviceId
        let pane = agent.pane
        let shown = output
        let last = thread?.blocks.last
        guarded {
            answered = shown
            sentAnswer(SentAnswer(text: c.label, meta: "Sent key \(c.key)", after: last))
            plugin.sendKeys(deviceId, pane: pane, [c.key])
        }
    }

    private func send() {
        let text = model.drafts[agent.pane] ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reply?.sending != true || reply?.action != "prompt" else { return }
        let deviceId = model.deviceId
        let pane = agent.pane
        guarded { [plugin] in plugin.sendPrompt(deviceId, pane: pane, text) }
    }

    /// Sends the text of a refused prompt again as the answer to the dialog of the agent.
    private func answerText(_ text: String) {
        guard reply?.sending != true else { return }
        let deviceId = model.deviceId
        let pane = agent.pane
        guarded { [plugin] in plugin.sendPrompt(deviceId, pane: pane, text, answer: true) }
    }

    /// Starts a dictation into the field of this agent. The text waits in the
    /// field for Send, so a prompt still needs the lock.
    private func dictate() {
        voiceError = nil
        lockError = nil
        let hints = unique([agent.agent, agent.project, agent.workspace].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        model.dictate(pane: agent.pane, language: plugin.model.dictationLanguage, hints: hints) { voiceError = $0 }
    }

    private func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    private func privacyURL(_ problem: String) -> URL {
        let pane = problem == DictationText.speechDenied ? "Privacy_SpeechRecognition" : "Privacy_Microphone"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

/// A key of the key row, with a mono label. `accent` marks the key that the dialog needs.
private struct KeyButton: View {
    let label: String
    let help: String
    var accent = false
    let action: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(accent ? tn.accent : tn.sub)
                .frame(maxWidth: .infinity, minHeight: TiledMetrics.buttonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(shape.fill(accent ? tn.accentTile : tn.bg))
        .overlay(shape.strokeBorder(accent ? tn.accent : tn.line))
        .help(help)
        .accessibilityLabel(help)
    }
}
