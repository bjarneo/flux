import AppKit
import FluxKit
import Observation
import SwiftUI

/// The fit of the master tile. It is compact in a short window and in the
/// menu bar panel: less padding, a short prompt, and Reply in the header.
/// On the Mac, the actions always sit directly under the content, because
/// a pointer has no thumb zone.
struct MasterFit: Equatable {
    let compact: Bool
    /// The number of items in the Inbox. Later shows only with more than 1.
    let count: Int

    var padding: CGFloat { compact ? 12 : 14 }
    var partGap: CGFloat { compact ? 8 : 12 }
    /// The gap between the top part and the actions.
    var actionGap: CGFloat { compact ? 8 : 12 }
    var choiceGap: CGFloat { 6 }
}

/// The master tile: the item that comes first, with its whole action. It
/// has the active border of Hyprland while it needs the user.
/// `minHeight` lets it fill the master column.
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
            .overlay(shape.strokeBorder(item.kind.needsYou ? Color.clear : tn.line, lineWidth: 1))
            .modifier(NeedsBorder(on: item.kind.needsYou))
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

/// The active border of the theme, while the master needs the user.
private struct NeedsBorder: ViewModifier {
    let on: Bool
    @Environment(\.tn) private var tn

    func body(content: Content) -> some View {
        if on { content.activeBorder(tn) } else { content }
    }
}

/// The header of the master tile: the window title, then Later when the
/// Inbox has more than 1 item, then `trailing`. With more than 1 computer
/// in scope, the window title ends with the computer.
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
        let many = model.scope == nil && model.state.devices.filter(\.paired).count > 1
        HStack(alignment: .center, spacing: 8) {
            WindowTitle(item: item, size: .master, many: many)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel((item.sourceParts + [item.computer]).joined(separator: ", "))
            .accessibilityValue(item.stateWord)
            Spacer(minLength: 8)
            if count > 1 {
                Button("Later") { model.showNext(item.key) }
                    .buttonStyle(.link)
                    .font(.system(size: 13, weight: .semibold))
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
        let working = agent.status == .working
        let out = plugin?.model.prompt(deviceId, pane: agent.pane)
        let fresh = Self.fresh(out, didRead: didRead)
        let choices = blocked ? fresh?.choices ?? [] : []
        let texts = fresh?.lines.map(\.text)
        let ask = texts.flatMap { AgentAsk.find($0, maxLines: fit.compact ? 3 : 4) }
        let thread = working ? texts.map(AgentThread.parse) : nil
        let reply = plugin?.model.reply(deviceId, pane: agent.pane)
        let sending = reply?.sending == true
        VStack(alignment: .leading, spacing: fit.partGap) {
            MasterHeader(item: item, count: fit.count) {
                if fit.compact { openThread }
            }
            Text(item.masterTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tn.text)
                .lineLimit(fit.compact ? 1 : 3)
            if working {
                MasterWork(answer: InboxAnswers.shared.answer(deviceId, pane: agent.pane), step: thread?.step ?? "", elapsed: thread?.elapsed ?? "")
            } else if !blocked {
                Text("The agent is done and waits for the next prompt.")
                    .font(.system(size: 13))
                    .foregroundStyle(tn.sub)
            } else if let error = out?.error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(tn.red)
            } else if let ask {
                // No line limit: the command that a choice approves shows in full.
                AskText(ask: ask)
            } else if let texts {
                CodeLines(lines: Inbox.agentPrompt(texts, maxLines: fit.compact ? 3 : 4).components(separatedBy: "\n"))
            } else {
                LineSkeleton(widths: [0.9, 0.7, 0.5], label: "Reading the question")
            }
            if let fresh, !choices.isEmpty {
                VStack(alignment: .leading, spacing: fit.choiceGap) {
                    ForEach(Array(choices.enumerated()), id: \.element.id) { i, choice in
                        AskChoiceButton(choice: choice, primary: i == 0, enabled: control && !sending && fresh != answered) {
                            answer(choice, fresh)
                        }
                        .frame(maxWidth: TiledMetrics.maxActionWidth, alignment: .leading)
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
            if sending {
                HStack(spacing: 8) {
                    RingSpinner(size: 14)
                    Text("Sending")
                        .font(.system(size: 12))
                        .foregroundStyle(tn.sub)
                }
            }
            if !fit.compact { openThread }
        }
        .task(id: PromptRead(item: item.key, front: activeState == .key)) {
            // A working agent shows its step from the output.
            guard blocked || working, let plugin = model.core.plugin(HerdrPlugin.self) else { return }
            // The first show reads. Later, only a window that comes to the front reads again.
            if didRead && activeState != .key { return }
            plugin.readPrompt(deviceId, pane: agent.pane)
            didRead = true
        }
        .onChange(of: agent.status, initial: true) { _, status in
            InboxAnswers.shared.status(status, deviceId, pane: agent.pane)
        }
    }

    /// Open thread: a link with an arrow that opens the agent in the agents window.
    private var openThread: some View {
        Button { openAgent() } label: {
            HStack(spacing: 6) {
                Text("Open thread")
                Image(systemName: "arrow.right")
            }
            .font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(.link)
        .help("Open the thread of the agent in the agents window")
    }

    /// The output when it came after the read of this tile, else nil.
    private static func fresh(_ out: HerdrOutput?, didRead: Bool) -> HerdrOutput? {
        guard didRead, let out, !out.loading, out.error == nil else { return nil }
        return out
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
            InboxAnswers.shared.sent(choice.label, deviceId, pane: pane)
            plugin.sendKeys(deviceId, pane: pane, [choice.key])
        }, onError: { lockError = $0 })
    }
}

/// The work of an agent on the master: the answer that the Inbox sent, a
/// moving bar, and the step of the agent with its time when the output
/// shows them.
struct MasterWork: View {
    let answer: String?
    let step: String
    let elapsed: String
    @Environment(\.tn) private var tn

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let answer {
                (Text("You answered: ").foregroundStyle(tn.sub) + Text(answer).foregroundStyle(tn.text))
                    .font(.system(size: 12))
            }
            ZStack {
                Capsule().fill(tn.line)
                SlideBar(color: tn.accent)
            }
            .frame(height: 3)
            .clipShape(Capsule())
            Text([step.isEmpty ? "Working" : step, elapsed].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(tn.sub)
                .lineLimit(2)
        }
    }
}

/// The answers that the Inbox sent to the agents, by computer and pane. An
/// answer shows on the master while the agent works on it, for 10 minutes
/// at most. The item of an agent changes when its status changes, so the
/// answers live here and not in the tile.
@MainActor
@Observable
final class InboxAnswers {
    static let shared = InboxAnswers()

    private struct Entry {
        var text: String
        var working = false
        var at = Date()
    }

    private var entries: [String: Entry] = [:]

    /// Keeps the answer `text` to the agent in `pane`.
    func sent(_ text: String, _ deviceId: String, pane: String) {
        entries[deviceId + "|" + pane] = Entry(text: text)
    }

    /// The answer to show for the agent in `pane`, or nil.
    func answer(_ deviceId: String, pane: String) -> String? {
        guard let e = entries[deviceId + "|" + pane], e.working, Date().timeIntervalSince(e.at) < 600 else { return nil }
        return e.text
    }

    /// The agent in `pane` has a new status. The answer shows while the
    /// agent works, and goes when the agent stops working.
    func status(_ status: AgentStatus, _ deviceId: String, pane: String) {
        let key = deviceId + "|" + pane
        guard let e = entries[key] else { return }
        if status == .working {
            if !e.working { entries[key]?.working = true }
        } else if e.working {
            entries[key] = nil
        }
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
