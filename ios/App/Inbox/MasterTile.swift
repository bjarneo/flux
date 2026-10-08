import FluxKit
import Observation
import SwiftUI

/// How the master tile fills its place. `push` moves the actions to the
/// bottom of the tile, at thumb height, as on an iPhone in portrait.
/// Without it, the actions follow the top part directly. `compact` is for a
/// window of little height, such as an iPhone in landscape: the tile takes
/// less space, the prompt is short, and Reply moves to the top row.
struct MasterFit: Equatable {
    var push: Bool
    var compact: Bool

    /// The space inside the border of the tile.
    var padding: CGFloat { compact ? 12 : 14 }
    /// The space between the lines of the top part.
    var gap: CGFloat { compact ? 8 : 12 }
    /// The space between the top part and the actions.
    var partGap: CGFloat { compact ? 8 : 12 }
    /// The space between the choices.
    var choiceGap: CGFloat { 6 }
}

/// The master tile: the first item of the Inbox with its whole action. It
/// has the active border while it needs the user. A swipe to the side, Later, or the
/// VoiceOver action moves it to the end of the stack. `count` is the number
/// of items in the Inbox. `minHeight` is the least height of the tile.
struct MasterTile: View {
    let item: InboxItem
    let compact: Bool
    let push: Bool
    let count: Int
    var minHeight: CGFloat = 0
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 1

    var body: some View {
        let fit = MasterFit(push: push, compact: compact)
        content(fit)
            .frame(maxWidth: .infinity, minHeight: max(0, minHeight - 2 * fit.padding), alignment: .topLeading)
            .tiledTile(fill: tn.tile, border: item.kind.needsYou ? .clear : tn.line, padding: fit.padding)
            .modifier(NeedsBorder(on: item.kind.needsYou))
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { width = max(1, geo.size.width) }
                        .onChange(of: geo.size.width) { _, w in width = max(1, w) }
                }
            }
            .offset(x: offset)
            .opacity(Double(1 - 0.6 * min(abs(offset) / width, 1)))
            .simultaneousGesture(swipe, including: count > 1 ? .all : .subviews)
            .id(item.key)
    }

    @ViewBuilder
    private func content(_ fit: MasterFit) -> some View {
        switch item.content {
        case .agent(let deviceId, let agent, let control):
            AgentMaster(item: item, deviceId: deviceId, agent: agent, control: control, fit: fit, count: count)
        case .approval(let r):
            ApprovalMaster(item: item, request: r, fit: fit, count: count)
        case .pair(let deviceId):
            PairMaster(item: item, deviceId: deviceId, fit: fit, count: count)
        case .transfer(let t):
            TransferMaster(item: item, transfer: t, fit: fit, count: count)
        case .clip(let c):
            ClipMaster(item: item, clip: c, fit: fit, count: count)
        case .media(let deviceId, let player):
            MediaMaster(item: item, deviceId: deviceId, player: player, fit: fit, count: count)
        }
    }

    /// A horizontal drag moves the tile. A drag past 30% of the width, or a
    /// fast one, moves the item to the end of the stack. Else the tile goes
    /// back. With Reduce Motion, the swipe runs at once.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { v in
                guard abs(v.translation.width) > abs(v.translation.height) else { return }
                offset = v.translation.width
            }
            .onEnded { v in
                let w = width
                let velocity = v.velocity.width
                guard offset != 0 else { return }
                if abs(offset) > w * 0.3 || abs(velocity) > 1000 {
                    let key = item.key
                    if reduceMotion {
                        model.showNext(key)
                        return
                    }
                    let to: CGFloat = offset + velocity * 0.05 >= 0 ? w : -w
                    withAnimation(Motion.standard(false)) { offset = to }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(200))
                        model.showNext(key)
                    }
                } else if reduceMotion {
                    offset = 0
                } else {
                    withAnimation(Motion.standard(false)) { offset = 0 }
                }
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

/// The top row of the master tile: the window title and Later. With more
/// than 1 computer in scope, the window title ends with the computer.
/// `trailing` adds actions after Later. VoiceOver reads the source and the
/// computer, with the state word as the value, and offers "Show the next
/// item".
struct MasterHeader<Trailing: View>: View {
    let item: InboxItem
    let count: Int
    @ViewBuilder let trailing: Trailing
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let many = model.scope == nil && model.state.devices.filter(\.paired).count > 1
        HStack(spacing: 8) {
            WindowTitle(item: item, size: .master, many: many)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel((item.sourceParts + [item.computer]).joined(separator: ", "))
            .accessibilityValue(item.stateWord)
            .modifier(NextItemAction(enabled: count > 1) { model.showNext(item.key) })
            if count > 1 {
                Button("Later") { model.showNext(item.key) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tn.accent)
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
                    .accessibilityHint("Moves this item to the end of the stack")
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

/// The VoiceOver action "Show the next item", while the Inbox has more than 1 item.
private struct NextItemAction: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.accessibilityAction(named: "Show the next item", action)
        } else {
            content
        }
    }
}

// MARK: Agent

/// An agent that waits for input, is done, or works. A waiting agent shows
/// its question and the choices of the dialog.
///
/// The one-tap rule: a choice never answers a question that the user did
/// not see. The tile reads the output when it shows, and only an output
/// that came after that read shows choices. The prompt keeps the lines
/// nearest the choices, because they hold the command that a choice
/// approves, and it is never cut on screen. Each answer asks for Face ID or
/// the passcode first. After an answer, the choices stay disabled until a
/// new output comes, so that a second tap does not answer the next question.
struct AgentMaster: View {
    let item: InboxItem
    let deviceId: String
    let agent: HerdrAgent
    let control: Bool
    let fit: MasterFit
    let count: Int
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    /// True after this tile asked the computer for the output.
    @State private var didRead = false
    /// The output that the last answer answered.
    @State private var answered: HerdrOutput?
    @State private var lockError: String?
    /// The number of the last reply before this tile answered. The tile
    /// shows only the replies that it sent.
    @State private var sentAfter: Int?
    /// True after Flux left the screen, until it comes back. The Face ID
    /// prompt makes Flux inactive, so only the background counts.
    @State private var wasAway = false
    /// Counts the returns of Flux to the screen.
    @State private var visit = 0

    private struct ReadKey: Equatable {
        var key: String
        var visit: Int
    }

    var body: some View {
        let plugin = model.core.plugin(HerdrPlugin.self)
        let out: HerdrOutput? = model.demo ? DemoMode.output(pane: agent.pane, review: false) : plugin?.model.prompt(deviceId, pane: agent.pane)
        let blocked = agent.status == .blocked
        let working = agent.status == .working
        let fresh = model.demo || (didRead && out?.loading == false && out?.error == nil)
        let choices: [AgentChoice] = blocked && fresh ? out?.choices ?? [] : []
        let short = fit.compact || typeSize >= .xxLarge
        let texts = out?.lines.map(\.text)
        let ask = texts.flatMap { AgentAsk.find($0, maxLines: short ? 3 : 4) }
        let prompt = ask == nil ? texts.map { Inbox.agentPrompt($0, maxLines: short ? 3 : 4) } ?? "" : ""
        let thread = working && fresh ? texts.map(AgentThread.parse) : nil
        let reply = ownReply(plugin)
        let sending = reply?.sending == true
        let sentAnswer = InboxAnswers.shared.answer(deviceId, pane: agent.pane)
        VStack(alignment: .leading, spacing: fit.partGap) {
            VStack(alignment: .leading, spacing: fit.gap) {
                MasterHeader(item: item, count: count) {
                    if fit.compact { openThread }
                }
                Text(item.masterTitle)
                    .font(.headline)
                    .foregroundStyle(tn.text)
                    .lineLimit(fit.compact ? 1 : (typeSize >= .accessibility1 ? 2 : 3))
                    .accessibilityAddTraits(.isHeader)
                if blocked, let error = out?.error, out?.loading == false {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(tn.red)
                } else if blocked && !fresh {
                    LineSkeleton(label: "Reading the question")
                } else if blocked, let ask {
                    // No line limit: the command that a choice approves shows in full.
                    AskText(ask: ask)
                } else if blocked && !prompt.isEmpty {
                    CodeLines(lines: prompt.components(separatedBy: "\n"))
                } else if working {
                    MasterWork(answer: sentAnswer, step: thread?.step ?? "", elapsed: thread?.elapsed ?? "")
                } else if agent.status == .done {
                    Text("The agent is done and waits for the next prompt.")
                        .font(.subheadline)
                        .foregroundStyle(tn.sub)
                }
            }
            if fit.push { Spacer(minLength: 0) }
            if !choices.isEmpty || lockError != nil || reply?.error != nil || (blocked && !control) || sending {
                VStack(alignment: .leading, spacing: fit.choiceGap) {
                    ForEach(Array(choices.enumerated()), id: \.element.id) { i, c in
                        AskChoiceButton(choice: c, primary: i == 0, enabled: control && !sending && out != answered, minHeight: 44) {
                            answer(c, out: out)
                        }
                    }
                    if let problem = lockError ?? reply?.error {
                        Text(problem)
                            .font(.footnote)
                            .foregroundStyle(tn.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if blocked && !control {
                        Text("To answer from this iPhone, set herdr_control = true on \(item.computer).")
                            .font(.footnote)
                            .foregroundStyle(tn.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if sending {
                        HStack(spacing: 8) {
                            RingSpinner(size: 16)
                            Text("Sending")
                                .font(.footnote)
                                .foregroundStyle(tn.sub)
                        }
                    }
                }
                .frame(maxWidth: TiledMetrics.maxActionWidth, alignment: .leading)
            }
            if !fit.compact { openThread }
        }
        // The tile reads the output when it shows, and again when Flux
        // comes back from the background, because the question can change.
        // A working agent shows its step from the output.
        .task(id: ReadKey(key: item.key, visit: visit)) {
            guard blocked || working, !model.demo else { return }
            model.core.plugin(HerdrPlugin.self)?.readPrompt(deviceId, pane: agent.pane)
            didRead = true
        }
        .onChange(of: agent.status, initial: true) { _, status in
            InboxAnswers.shared.status(status, deviceId, pane: agent.pane)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { wasAway = true }
            if phase == .active, wasAway {
                wasAway = false
                visit += 1
            }
        }
    }

    /// Open thread: a text action with an arrow that opens the agent screen.
    private var openThread: some View {
        Button {
            model.inboxPath.append(.feature(.agent(deviceId, agent.pane)))
        } label: {
            HStack(spacing: 6) {
                Text("Open thread")
                Image(systemName: "arrow.right")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tn.accent)
            .padding(.horizontal, 4)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the thread of the agent")
    }

    /// The last reply to the agent, when this tile sent it.
    private func ownReply(_ plugin: HerdrPlugin?) -> HerdrReply? {
        guard let after = sentAfter, let r = plugin?.model.reply(deviceId, pane: agent.pane), r.seq > after else { return nil }
        return r
    }

    /// Sends the digit of the choice as 1 key, after Face ID or the passcode.
    private func answer(_ choice: AgentChoice, out: HerdrOutput?) {
        if model.demo {
            model.show(DemoMode.sendsNothing)
            return
        }
        lockError = nil
        let pane = agent.pane
        let id = deviceId
        ReplyLock.run(reason: "Answer agents on \(item.computer).", action: {
            guard let plugin = model.core.plugin(HerdrPlugin.self) else { return }
            // The check can take some seconds. A new question in that time
            // takes no answer that the user gave to the old one.
            guard let shown = out, plugin.model.prompt(id, pane: pane)?.lines == shown.lines else {
                lockError = "The question changed. Read it, then answer again."
                return
            }
            answered = out
            sentAfter = plugin.model.replies[id]?.seq ?? 0
            InboxAnswers.shared.sent(choice.label, id, pane: pane)
            plugin.sendKeys(id, pane: pane, [choice.key])
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
                    .font(.footnote)
            }
            ZStack {
                Capsule().fill(tn.line)
                SlideBar(color: tn.accent)
            }
            .frame(height: 3)
            .clipShape(Capsule())
            Text([step.isEmpty ? "Working" : step, elapsed].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption.monospaced())
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

// MARK: Other items

/// A sudo, polkit, or enrollment request. Review opens the approval sheet.
/// It never approves by itself.
struct ApprovalMaster: View {
    let item: InboxItem
    let request: ApproveRequest
    let fit: MasterFit
    let count: Int
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let r = request
        let data = ["user \(r.user)", r.tty, r.host]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " · ")
        VStack(alignment: .leading, spacing: fit.partGap) {
            VStack(alignment: .leading, spacing: fit.gap) {
                MasterHeader(item: item, count: count)
                Text(item.masterTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tn.text)
                    .lineLimit(3)
                    .accessibilityAddTraits(.isHeader)
                Text(ApproveMessage.question(r))
                    .font(.subheadline)
                    .foregroundStyle(tn.sub)
                Text(data)
                    .font(.footnote.monospaced())
                    .foregroundStyle(tn.sub)
                    .lineLimit(2)
            }
            if fit.push { Spacer(minLength: 0) }
            Button {
                if model.demo {
                    model.show(DemoMode.sendsNothing)
                } else {
                    ApprovePresenter.shared.state.present()
                }
            } label: {
                Label("Review", systemImage: "key")
            }
            .buttonStyle(FluxButtonStyle(kind: .filled, fullWidth: true))
            .frame(maxWidth: TiledMetrics.maxActionWidth)
            .accessibilityHint("Opens the approval")
        }
    }
}

/// A computer that asks to pair. Compare the key opens the pairing sheet
/// with the full key. It never pairs by itself.
struct PairMaster: View {
    let item: InboxItem
    let deviceId: String
    let fit: MasterFit
    let count: Int
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        VStack(alignment: .leading, spacing: fit.partGap) {
            VStack(alignment: .leading, spacing: fit.gap) {
                MasterHeader(item: item, count: count)
                Text(item.masterTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tn.text)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                Text("\(item.computer) asks to pair with this iPhone. Compare the key on both screens.")
                    .font(.subheadline)
                    .foregroundStyle(tn.sub)
            }
            if fit.push { Spacer(minLength: 0) }
            Button("Compare the key") { model.pairingSheet = deviceId }
                .buttonStyle(FluxButtonStyle(kind: .filled, fullWidth: true))
                .frame(maxWidth: TiledMetrics.maxActionWidth)
        }
    }
}

/// A file that goes to or comes from a computer.
struct TransferMaster: View {
    let item: InboxItem
    let transfer: FileTransfer
    let fit: MasterFit
    let count: Int
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let t = transfer
        VStack(alignment: .leading, spacing: fit.partGap) {
            VStack(alignment: .leading, spacing: fit.gap) {
                MasterHeader(item: item, count: count)
                Text(t.name)
                    .font(.headline.monospaced())
                    .foregroundStyle(tn.text)
                    .lineLimit(3)
                    .accessibilityAddTraits(.isHeader)
                Text(item.stackLine)
                    .font(.subheadline)
                    .foregroundStyle(tn.sub)
                switch t.state {
                case .running:
                    if let fraction = t.fraction {
                        ProgressView(value: fraction)
                            .tint(tn.accent)
                    } else {
                        HStack(spacing: 8) {
                            FluxSpinner()
                            Text("\(TransferRow.bytes(t.bytes)) so far")
                                .font(.footnote)
                                .foregroundStyle(tn.sub)
                        }
                    }
                case .done:
                    EmptyView()
                case .failed:
                    Text(t.incoming ? "Send the file again from \(item.computer)." : "Send the file again.")
                        .font(.subheadline)
                        .foregroundStyle(tn.sub)
                }
            }
            if fit.push { Spacer(minLength: 0) }
            if t.incoming, t.state == .done {
                HStack(spacing: 8) {
                    if let file = t.file {
                        Button("Open") { ShareFeature.shared.preview = file }
                            .buttonStyle(FluxButtonStyle(kind: .outlined))
                            .accessibilityHint("Opens the file with Quick Look")
                    }
                    Button("All transfers") { model.inboxPath.append(.feature(.share(t.deviceId))) }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                }
            }
        }
    }
}

/// The last clip that this iPhone sent or received.
struct ClipMaster: View {
    let item: InboxItem
    let clip: ClipEvent
    let fit: MasterFit
    let count: Int
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let c = clip
        VStack(alignment: .leading, spacing: fit.partGap) {
            VStack(alignment: .leading, spacing: fit.gap) {
                MasterHeader(item: item, count: count)
                Text(item.masterTitle)
                    .font(.headline)
                    .foregroundStyle(tn.text)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                if c.image || c.secret {
                    // A secret shows only a fixed text, in the body face.
                    Text(c.image ? "An image" : ClipEvent.hiddenText)
                        .font(.subheadline)
                        .foregroundStyle(tn.text)
                } else {
                    Text(c.preview)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(tn.text)
                        .lineLimit(6)
                }
                Text(c.at, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(tn.sub)
            }
            if fit.push { Spacer(minLength: 0) }
            Button("Send the clipboard") { SendTools.sendClipboard(model) }
                .buttonStyle(FluxButtonStyle(kind: .outlined, fullWidth: true))
                .frame(maxWidth: TiledMetrics.maxActionWidth)
                .disabled(!TargetRun.enabled(model, can: SendTools.canClipboard(model)))
        }
    }
}

/// What a player on a computer plays now.
struct MediaMaster: View {
    let item: InboxItem
    let deviceId: String
    let player: RemotePlayer
    let fit: MasterFit
    let count: Int
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let p = player
        let by = [p.artist, p.album].filter { !$0.isEmpty }.joined(separator: " · ")
        let online = model.device(deviceId)?.online == true
        VStack(alignment: .leading, spacing: fit.partGap) {
            VStack(alignment: .leading, spacing: fit.gap) {
                MasterHeader(item: item, count: count)
                Text(item.masterTitle)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(tn.text)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                if !by.isEmpty {
                    Text(by)
                        .font(.subheadline)
                        .foregroundStyle(tn.sub)
                        .lineLimit(2)
                }
            }
            if fit.push { Spacer(minLength: 0) }
            HStack(spacing: 8) {
                RoundButton(icon: "backward.fill", name: "Previous", filled: false, enabled: online) { send("Previous") }
                RoundButton(icon: p.playing ? "pause.fill" : "play.fill", name: p.playing ? "Pause" : "Play",
                            filled: true, enabled: online) { send("PlayPause") }
                RoundButton(icon: "forward.fill", name: "Next", filled: false, enabled: online) { send("Next") }
                Spacer(minLength: 0)
                Button("Open") { model.inboxPath.append(.feature(.nowPlaying(deviceId))) }
                    .buttonStyle(FluxButtonStyle(kind: .outlined))
                    .accessibilityHint("Opens the player controls")
            }
            .frame(maxWidth: TiledMetrics.maxActionWidth)
        }
    }

    private func send(_ action: String) {
        if model.demo {
            model.show(DemoMode.sendsNothing)
            return
        }
        model.core.plugin(MprisPlugin.self)?.action(deviceId, action)
    }
}

/// A round media button. `filled` marks the main control: a 56 pt circle
/// on `green`. The others are 48 pt circles on `bg`.
private struct RoundButton: View {
    let icon: String
    let name: String
    let filled: Bool
    let enabled: Bool
    let action: () -> Void
    @Environment(\.tn) private var tn
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 22

    var body: some View {
        let size: CGFloat = filled ? 56 : 48
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: filled ? iconSize + 4 : iconSize))
                .foregroundStyle(filled ? tn.onAccent : (enabled ? tn.text : tn.sub))
                .frame(width: size, height: size)
                .background(Circle().fill(filled ? tn.green : tn.bg))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : TiledMetrics.disabledAlpha)
        .accessibilityLabel(name)
    }
}
