import AppKit
import FluxKit
import SwiftUI

/// The fit of the master tile. It is compact in a short window and in the
/// menu bar panel: less padding, a short prompt, and Reply in the header.
/// On the Mac, the actions always sit directly under the content, because
/// a pointer has no thumb zone.
struct MasterFit: Equatable {
    let compact: Bool
    /// The number of items in the Inbox. Later shows only with more than 1.
    let count: Int

    var padding: CGFloat { compact ? 12 : 16 }
    var partGap: CGFloat { compact ? 6 : 10 }
    /// The gap between the top part and the actions.
    var actionGap: CGFloat { compact ? 10 : 16 }
    var choiceGap: CGFloat { compact ? 6 : 8 }
}

/// The master tile: the item that comes first, with its whole action, in
/// the active border of Hyprland. `minHeight` lets it fill the master column.
struct MasterTile: View {
    let item: InboxItem
    let fit: MasterFit
    let minHeight: CGFloat
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    init(item: InboxItem, compact: Bool, count: Int, minHeight: CGFloat = 0) {
        self.item = item
        self.fit = MasterFit(compact: compact, count: count)
        self.minHeight = minHeight
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TiledMetrics.tileCorner, style: .continuous)
        content
            .padding(fit.padding)
            .frame(maxWidth: .infinity, minHeight: max(0, minHeight), alignment: .topLeading)
            .background(shape.fill(tn.tile))
            .activeBorder(tn)
            .contextMenu {
                if fit.count > 1 {
                    Button("Show the next item") { model.showNext(item.key) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Show the next item") { model.showNext(item.key) }
    }

    @ViewBuilder
    private var content: some View {
        switch item.content {
        case .agent(let deviceId, let agent, let control):
            AgentMaster(item: item, deviceId: deviceId, agent: agent, control: control, fit: fit)
        case .approval(let request):
            ApprovalMaster(item: item, request: request, fit: fit)
        case .pair(let deviceId):
            PairMaster(item: item, deviceId: deviceId, fit: fit)
        case .transfer(let transfer):
            TransferMaster(item: item, transfer: transfer, fit: fit)
        case .clip(let clip):
            ClipMaster(item: item, clip: clip, fit: fit)
        case .media(let deviceId, let player):
            MediaMaster(item: item, deviceId: deviceId, player: player, fit: fit)
        }
    }
}

/// The header of the master tile: the window title and the computer, then
/// Later when the Inbox has more than 1 item, then `trailing`.
struct MasterHeader<Trailing: View>: View {
    let item: InboxItem
    let count: Int
    let trailing: Trailing
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    init(item: InboxItem, count: Int, @ViewBuilder trailing: () -> Trailing) {
        self.item = item
        self.count = count
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                WindowTitle(item: item, size: .master)
                Text(item.computer)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(tn.sub)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel((item.sourceParts + [item.computer]).joined(separator: ", "))
            .accessibilityValue(item.stateWord)
            Spacer(minLength: 8)
            if count > 1 {
                Button("Later") { model.showNext(item.key) }
                    .buttonStyle(FluxButtonStyle(kind: .text))
                    .help("Show the next item. The key is Command-].")
            }
            trailing
        }
    }
}

extension MasterHeader where Trailing == EmptyView {
    init(item: InboxItem, count: Int) {
        self.init(item: item, count: count) { EmptyView() }
    }
}

/// A numbered choice of the question of an agent. A click sends its digit.
struct InboxChoiceRow: View {
    let choice: AgentChoice
    let enabled: Bool
    let action: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TiledMetrics.smallCorner, style: .continuous)
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(choice.key)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(tn.accent)
                Text(choice.label)
                    .font(.system(size: 13))
                    .foregroundStyle(tn.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: TiledMetrics.maxActionWidth, minHeight: TiledMetrics.rowHeight, alignment: .leading)
            .background(shape.fill(choice.selected ? tn.accentTile : tn.bg))
            .overlay(shape.strokeBorder(choice.selected ? tn.accent : tn.line, lineWidth: choice.selected ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(TilePressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : TiledMetrics.disabledAlpha)
        .help("Answer \(choice.key)")
        .accessibilityLabel("\(choice.key). \(choice.label)")
        .accessibilityHint("Answer \(choice.key)")
    }
}

/// The key of a read of the question: the item, and whether its window is the key window.
private struct PromptRead: Equatable {
    let item: String
    let front: Bool
}

/// The master of an agent. For an agent that waits, it shows the question
/// with its one-tap choices. The rules:
/// - The tile reads the output when it shows and when its window comes to
///   the front. Only an output that comes after that read is fresh, and
///   only a fresh output gives choices.
/// - The prompt keeps the lines nearest the choices, and it is never cut.
/// - Each answer asks for Touch ID or the password first, see `ReplyLock`.
/// - After an answer, the choices stay off until a new output comes.
private struct AgentMaster: View {
    let item: InboxItem
    let deviceId: String
    let agent: HerdrAgent
    let control: Bool
    let fit: MasterFit
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @Environment(\.controlActiveState) private var activeState
    /// True after this tile asked for the output.
    @State private var didRead = false
    /// The output that the user answered.
    @State private var answered: HerdrOutput?
    @State private var lockError: String?

    var body: some View {
        let plugin = model.core.plugin(HerdrPlugin.self)
        let blocked = agent.status == .blocked
        let out = plugin?.model.prompt(deviceId, pane: agent.pane)
        let fresh = Self.fresh(out, didRead: didRead)
        let choices = blocked ? fresh?.choices ?? [] : []
        let reply = plugin?.model.reply(deviceId, pane: agent.pane)
        let sending = reply?.sending == true
        VStack(alignment: .leading, spacing: fit.partGap) {
            MasterHeader(item: item, count: fit.count) {
                if fit.compact {
                    replyButton(blocked: blocked, fresh: fresh != nil, hasChoices: !choices.isEmpty)
                }
            }
            Text(item.masterTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tn.text)
                .lineLimit(fit.compact ? 1 : 3)
            if !blocked {
                Text(agent.status == .done ? "The agent is done and waits for the next prompt." : "The agent works. Open it to read the output.")
                    .font(.system(size: 13))
                    .foregroundStyle(tn.sub)
            } else if let error = out?.error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(tn.red)
            } else if let fresh {
                // No line limit: the command that a choice approves shows in full.
                Text(Inbox.agentPrompt(fresh.lines.map(\.text), maxLines: fit.compact ? 3 : 4, dropAsk: fit.compact))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(tn.text)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                LineSkeleton(widths: [0.9, 0.7, 0.5], label: "Reading the question")
            }
            if let fresh, !choices.isEmpty {
                VStack(alignment: .leading, spacing: fit.choiceGap) {
                    ForEach(choices) { choice in
                        InboxChoiceRow(choice: choice, enabled: control && !sending && fresh != answered) {
                            answer(choice, fresh)
                        }
                    }
                }
                .padding(.top, fit.actionGap - fit.partGap)
            }
            if let problem = lockError ?? reply?.error {
                Text(problem)
                    .font(.system(size: 12))
                    .foregroundStyle(tn.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if blocked && !control {
                Text("To answer from this Mac, set herdr_control = true on \(item.computer).")
                    .font(.system(size: 12))
                    .foregroundStyle(tn.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if sending || !fit.compact {
                HStack(spacing: 8) {
                    if sending {
                        FluxSpinner()
                        Text("Sending")
                            .font(.system(size: 12))
                            .foregroundStyle(tn.sub)
                    }
                    Spacer(minLength: 0)
                    if !fit.compact {
                        replyButton(blocked: blocked, fresh: fresh != nil, hasChoices: !choices.isEmpty)
                    }
                }
                .padding(.top, fit.actionGap - fit.partGap)
            }
        }
        .task(id: PromptRead(item: item.key, front: activeState == .key)) {
            guard agent.status == .blocked, let plugin = model.core.plugin(HerdrPlugin.self) else { return }
            // The first show reads. Later, only a window that comes to the front reads again.
            if didRead && activeState != .key { return }
            plugin.readPrompt(deviceId, pane: agent.pane)
            didRead = true
        }
    }

    /// The output when it came after the read of this tile, else nil.
    private static func fresh(_ out: HerdrOutput?, didRead: Bool) -> HerdrOutput? {
        guard didRead, let out, !out.loading, out.error == nil else { return nil }
        return out
    }

    /// Reply opens the agent. It is filled when the agent waits for text:
    /// the output is fresh, it has no choices, and the computer takes replies.
    @ViewBuilder
    private func replyButton(blocked: Bool, fresh: Bool, hasChoices: Bool) -> some View {
        let filled = blocked && fresh && !hasChoices && control
        Button(blocked ? "Reply" : "Open") { openAgent() }
            .buttonStyle(FluxButtonStyle(kind: filled ? .filled : .outlined))
            .help("Open the agent in the agents window")
    }

    private func openAgent() {
        AgentsWindows.shared.show(deviceId, pane: agent.pane, app: model)
    }

    /// Sends the digit of the choice after Touch ID or the password. The
    /// question on screen must still be the question that the user read.
    private func answer(_ choice: AgentChoice, _ out: HerdrOutput) {
        guard answered != out else { return }
        lockError = nil
        let deviceId = deviceId
        let pane = agent.pane
        let model = model
        ReplyLock.run(reason: "answer agents on \(item.computer)", action: {
            guard let plugin = model.core.plugin(HerdrPlugin.self), answered != out else { return }
            guard plugin.model.prompt(deviceId, pane: pane)?.lines == out.lines else {
                lockError = "The question changed. Read it, then answer again."
                return
            }
            answered = out
            plugin.sendKeys(deviceId, pane: pane, [choice.key])
        }, onError: { lockError = $0 })
    }
}

/// The master of an approval. Review opens the approval prompt, which
/// asks for Touch ID. The tile never approves by itself.
private struct ApprovalMaster: View {
    let item: InboxItem
    let request: ApproveRequest
    let fit: MasterFit
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        VStack(alignment: .leading, spacing: fit.partGap) {
            MasterHeader(item: item, count: fit.count)
            Text(item.masterTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tn.text)
                .lineLimit(3)
            Text(ApproveMessage.question(request))
                .font(.system(size: 13))
                .foregroundStyle(tn.sub)
                .fixedSize(horizontal: false, vertical: true)
            if !dataLine.isEmpty {
                Text(dataLine)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(tn.sub)
                    .lineLimit(2)
            }
            Button(action: review) {
                Label("Review", systemImage: ApproveTexts.current.symbol)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(FluxButtonStyle(kind: .filled))
            .frame(maxWidth: TiledMetrics.maxActionWidth)
            .padding(.top, fit.actionGap - fit.partGap)
            .help("Open the approval prompt. It asks for Touch ID before it approves.")
        }
    }

    /// "user alice · pts/1 · omarchy", without the blank parts.
    private var dataLine: String {
        [request.user.isEmpty ? "" : "user \(request.user)", request.tty, request.host]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func review() {
        guard let plugin = model.core.plugin(ApprovePlugin.self) else { return }
        ApprovePromptWindow.show(plugin)
    }
}

/// The master of a pair request. Compare the key opens the pairing page
/// with the full key. The tile never pairs by itself.
private struct PairMaster: View {
    let item: InboxItem
    let deviceId: String
    let fit: MasterFit
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: fit.partGap) {
            MasterHeader(item: item, count: fit.count)
            Text(item.masterTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tn.text)
                .lineLimit(2)
            Text("\(item.computer) asks to pair with this Mac. Compare the key on both screens.")
                .font(.system(size: 13))
                .foregroundStyle(tn.sub)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: compare) {
                Text("Compare the key")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(FluxButtonStyle(kind: .filled))
            .frame(maxWidth: TiledMetrics.maxActionWidth)
            .padding(.top, fit.actionGap - fit.partGap)
        }
    }

    private func compare() {
        model.destination = .computers
        model.computersPath = [.pairing(deviceId)]
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The master of a file transfer.
private struct TransferMaster: View {
    let item: InboxItem
    let transfer: FileTransfer
    let fit: MasterFit
    @Environment(\.tn) private var tn

    var body: some View {
        VStack(alignment: .leading, spacing: fit.partGap) {
            MasterHeader(item: item, count: fit.count)
            Text(transfer.name)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(tn.text)
                .lineLimit(3)
            Text(item.stackLine)
                .font(.system(size: 13))
                .foregroundStyle(tn.sub)
            switch transfer.state {
            case .running:
                if let fraction = transfer.fraction {
                    ProgressView(value: fraction)
                        .tint(tn.accent)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(tn.accent)
                }
            case .failed:
                Text(transfer.incoming ? "Send the file again from \(item.computer)." : "Send the file again.")
                    .font(.system(size: 13))
                    .foregroundStyle(tn.sub)
            case .done:
                EmptyView()
            }
            if transfer.incoming, transfer.state == .done, let file = transfer.file {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    .buttonStyle(FluxButtonStyle(kind: .outlined))
                    .padding(.top, fit.actionGap - fit.partGap)
            }
        }
    }
}

/// The master of the last clip.
private struct ClipMaster: View {
    let item: InboxItem
    let clip: ClipEvent
    let fit: MasterFit
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @State private var ask: TargetAsk?

    var body: some View {
        let target = ToolTarget.of(model, can: { _ in model.core.plugin(ClipboardPlugin.self) != nil })
        VStack(alignment: .leading, spacing: fit.partGap) {
            MasterHeader(item: item, count: fit.count)
            Text(item.masterTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tn.text)
                .lineLimit(2)
            if clip.image || clip.secret {
                // A secret shows only a fixed text, in the body face, and the user cannot select it.
                Text(clip.image ? "An image" : ClipEvent.hiddenText)
                    .font(.system(size: 13))
                    .foregroundStyle(tn.text)
            } else {
                Text(clip.preview)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(tn.text)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
            Text(clip.at, format: .relative(presentation: .named))
                .font(.system(size: 11))
                .foregroundStyle(tn.sub)
            Button("Send the clipboard") { sendClip(target) }
                .buttonStyle(FluxButtonStyle(kind: .outlined))
                .disabled(!ToolTarget.ready(target))
                .padding(.top, fit.actionGap - fit.partGap)
        }
        .targetPicker($ask)
    }

    private func sendClip(_ target: ActionTarget) {
        guard let clipboard = model.core.plugin(ClipboardPlugin.self) else { return }
        ToolTarget.run(target, title: "Send the clipboard to", ask: $ask) { d in
            _ = clipboard.sendClipboard(to: d.id)
        }
    }
}

/// The master of what plays now on a computer.
private struct MediaMaster: View {
    let item: InboxItem
    let deviceId: String
    let player: RemotePlayer
    let fit: MasterFit
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let mpris = model.core.plugin(MprisPlugin.self)
        let detail = [player.artist, player.album].filter { !$0.isEmpty }.joined(separator: " · ")
        VStack(alignment: .leading, spacing: fit.partGap) {
            MasterHeader(item: item, count: fit.count)
            Text(item.masterTitle)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tn.text)
                .lineLimit(2)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(tn.sub)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                RoundButton(icon: "backward.fill", label: "Previous", size: 32, fill: tn.bg, ink: tn.text) {
                    mpris?.action(deviceId, "Previous")
                }
                RoundButton(icon: player.playing ? "pause.fill" : "play.fill", label: player.playing ? "Pause" : "Play",
                            size: 40, fill: tn.green, ink: tn.onAccent) {
                    mpris?.action(deviceId, "PlayPause")
                }
                RoundButton(icon: "forward.fill", label: "Next", size: 32, fill: tn.bg, ink: tn.text) {
                    mpris?.action(deviceId, "Next")
                }
                Spacer(minLength: 8)
                Button("Open", action: openPage)
                    .buttonStyle(FluxButtonStyle(kind: .outlined))
            }
            .frame(maxWidth: TiledMetrics.maxActionWidth)
            .padding(.top, fit.actionGap - fit.partGap)
        }
    }

    private func openPage() {
        model.destination = .inbox
        model.inboxPath.append(.card(.media, deviceId))
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// A round media button with an icon.
private struct RoundButton: View {
    let icon: String
    let label: String
    let size: CGFloat
    let fill: Color
    let ink: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: size, height: size)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(TilePressStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}
