import AppKit
import FluxKit
import SwiftUI

/// The reply controls of an agent: the choices of a dialog, a key bar, a
/// text field, and a mic key for dictation. Each reply asks for Touch ID or
/// the password first, see `ReplyLock`.
struct ReplyControls: View {
    @Bindable var model: AgentsWindowModel
    let agent: HerdrAgent
    let output: HerdrOutput?
    let name: String
    @State private var lockError: String?
    @State private var voiceError: String?
    @State private var picking = false
    @State private var canDictate = false

    private var plugin: HerdrPlugin { model.plugin }
    private var reply: HerdrReply? { plugin.model.reply(model.deviceId, pane: agent.pane) }
    private var dictation: Dictation { model.dictation }

    var body: some View {
        let choices = agent.status == .blocked ? output?.choices ?? [] : []
        let sendingPrompt = reply?.sending == true && reply?.action == "prompt"
        VStack(alignment: .leading, spacing: 8) {
            if !choices.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(choices) { c in ChoiceButton(choice: c) { keys(c.key) } }
                    }
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                KeyButton(label: "esc", help: "Escape") { keys("esc") }
                KeyButton(label: "tab", help: "Tab") { keys("tab") }
                KeyButton(label: "↑", help: "Up") { keys("up") }
                KeyButton(label: "↓", help: "Down") { keys("down") }
                KeyButton(label: "enter", help: "Enter", accent: agent.status == .blocked && choices.isEmpty) { keys("enter") }
            }
            DictationBar(
                dictation: dictation,
                canDictate: canDictate,
                onStart: dictate,
                onLanguage: {
                    dictation.stopNow()
                    picking = true
                },
                field: {
                    ReplyField(
                        text: Binding(get: { model.drafts[agent.pane] ?? "" }, set: { model.drafts[agent.pane] = $0 }),
                        selection: Binding(get: { model.cursors[agent.pane] }, set: { model.cursors[agent.pane] = $0 }),
                        placeholder: "Write to \(agent.agent)",
                        onSubmit: send
                    )
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                },
                send: {
                    let canSend = !(model.drafts[agent.pane] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sendingPrompt
                    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
                    Button(action: send) {
                        ZStack {
                            if sendingPrompt {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(canSend ? Color.white : Color.secondary)
                            }
                        }
                        .frame(width: DictationLayout.keySize, height: DictationLayout.keySize)
                        .background(shape.fill(canSend ? Color.accentColor : Color.primary.opacity(0.06)))
                        .contentShape(shape)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Send the text to \(agent.agent)")
                    .accessibilityLabel("Send")
                }
            )
            if let problem = lockError ?? voiceError ?? dictation.error ?? reply?.error {
                HStack(spacing: 10) {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
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
                        Button("Send as answer") { answer(text) }
                            .buttonStyle(.link)
                            .font(.caption)
                            .help("Type the text into the dialog of \(agent.agent)")
                    }
                }
            }
        }
        .onChange(of: reply) {
            // A prompt that the computer accepted leaves the field.
            if let r = reply, r.action == "prompt", !r.sending, r.error == nil {
                model.drafts[agent.pane] = nil
                model.cursors[agent.pane] = nil
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

    private func guarded(_ action: @escaping @MainActor () -> Void) {
        lockError = nil
        ReplyLock.run(reason: "answer agents on \(name)", action: action) { lockError = $0 }
    }

    private func keys(_ k: String) {
        let deviceId = model.deviceId
        let pane = agent.pane
        guarded { [plugin] in plugin.sendKeys(deviceId, pane: pane, [k]) }
    }

    private func send() {
        let text = model.drafts[agent.pane] ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reply?.sending != true || reply?.action != "prompt" else { return }
        let deviceId = model.deviceId
        let pane = agent.pane
        guarded { [plugin] in plugin.sendPrompt(deviceId, pane: pane, text) }
    }

    /// Sends the text of a refused prompt again as the answer to the dialog of the agent.
    private func answer(_ text: String) {
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

/// A numbered choice of a dialog. A click sends its digit.
private struct ChoiceButton: View {
    let choice: AgentChoice
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(choice.key)
                    .font(.body.monospaced().weight(.bold))
                    .foregroundStyle(TermColors.blue)
                Text(choice.label)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(choice.selected ? 0.1 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(choice.selected ? TermColors.blue : Color.primary.opacity(0.1)))
        .help("Send \(choice.key)")
    }
}

/// A key of the key bar, with a mono label. `accent` marks the key that the dialog needs.
private struct KeyButton: View {
    let label: String
    let help: String
    var accent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.callout.monospaced().weight(.semibold))
                .foregroundStyle(accent ? TermColors.blue : .secondary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(accent ? 0.1 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(accent ? TermColors.blue : Color.primary.opacity(0.1)))
        .help(help)
        .accessibilityLabel(help)
    }
}
