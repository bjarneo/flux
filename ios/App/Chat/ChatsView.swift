import FluxKit
import SwiftUI

/// The Chats destination, the root of the first tab: 1 chat for each agent
/// and each paired computer, as in a messaging app. What needs the user is
/// on top: the approval and the pair requests as cards with their buttons,
/// and the agents that wait for input. The other agents and the computers
/// follow. A tap on an agent opens its chat, where the dock holds its
/// question. A tap on a computer opens its chat with the clipboard, the
/// photos, and the tools. The search field keeps only the chats that hold
/// its text. The + key starts an agent or a terminal. While Flux is off,
/// and before the first pairing, the large tile of `ChatEmpty` shows. It
/// follows the Chats of Flux for Android.
struct ChatsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @State private var query = ""
    /// The computer of the new pane sheet.
    @State private var newPane: NewPaneItem?

    private struct NewPaneItem: Identifiable {
        let id: String
    }

    var body: some View {
        let paired = model.state.devices.contains { $0.paired }
        let online = model.state.devices.filter { $0.paired && $0.online }.map(\.id)
        Group {
            if !model.state.enabled || !paired {
                ChatEmpty()
            } else {
                chats
            }
        }
        .destinationRoot("Chats", context: paired ? ChatTexts.context(model, needs: Inbox.needsYou(model.inboxItems())) : "")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if paired && model.state.enabled {
                    Button(action: newAgent) {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(tn.text)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New agent or terminal")
                    .accessibilityHint("Starts an agent or opens a terminal on a computer")
                }
            }
        }
        .sheet(item: $newPane) { item in
            let id = item.id
            NewPaneSheet(deviceId: id) { what, pane in
                newPane = nil
                model.chatPath.append(.feature(what == "terminal" ? .terminal(id, pane) : .agent(id, pane)))
            }
        }
        // The computers send their changes. Each visit asks again for the agents.
        .task(id: online) {
            guard !model.demo, let herdr = model.core.plugin(HerdrPlugin.self) else { return }
            for d in model.state.devices where d.paired && d.online && d.accepts(PacketType.fluxHerdr) {
                herdr.request(d.id)
            }
        }
    }

    /// The search field, the notices, and the 3 groups of chats.
    private var chats: some View {
        let list = model.chatList(query: query)
        let devices = model.state.devices
        let states = SendTools.herdrStates(model)
        // With agents on more than 1 computer, each agent row names its computer.
        let many = devices.filter { $0.paired && $0.online && states[$0.id]?.running == true }.count > 1
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return GeometryReader { geo in
            // The width of the content, inside the gutter.
            let width = max(0, min(geo.size.width, TiledMetrics.maxContentWidth) - 2 * TiledMetrics.gutter)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    // The rows of the computers show which computers are not reachable. With none online, the notice tells the next step.
                    ChatNotices(computer: nil, offline: Inbox.reach(scope: nil, devices: devices).noneOnline)
                    if !list.needs.isEmpty {
                        GroupHead(title: "Needs you", trailing: "\(list.needs.count)", color: tn.red, first: true)
                        ForEach(list.needs) { row($0, width: width, many: many) }
                    }
                    if !list.agents.isEmpty {
                        // With 1 computer, the heading names it. With more, each row names its computer.
                        let computers = Set(list.agents.compactMap { r -> String? in
                            if case .agent(_, let name, _, _, _, _) = r { return name }
                            return nil
                        })
                        GroupHead(title: "Agents", trailing: computers.count == 1 ? "on \(computers.first ?? "")" : "",
                                  first: list.needs.isEmpty)
                        ForEach(list.agents) { row($0, width: width, many: many) }
                    }
                    if !list.computers.isEmpty {
                        GroupHead(title: "Computers", first: list.needs.isEmpty && list.agents.isEmpty)
                        ForEach(list.computers) { row($0, width: width, many: many) }
                    }
                    if list.isEmpty && searching {
                        Text("No chat holds \"\(query.trimmingCharacters(in: .whitespacesAndNewlines))\".")
                            .font(.footnote)
                            .foregroundStyle(tn.sub)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                }
                .padding(.horizontal, TiledMetrics.gutter)
                .padding(.bottom, 16)
                .frame(maxWidth: TiledMetrics.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.immediately)
            .safeAreaInset(edge: .top, spacing: 0) {
                SearchPill(text: $query)
                    .padding(.horizontal, TiledMetrics.gutter)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                    .frame(maxWidth: TiledMetrics.maxContentWidth)
                    .frame(maxWidth: .infinity)
                    .background(tn.bg)
            }
        }
    }

    /// 1 row of the list: the approval or a pair request as a card, an agent, or a computer.
    @ViewBuilder
    private func row(_ r: ChatRow, width: CGFloat, many: Bool) -> some View {
        switch r {
        case .approval(let request, let at):
            ApprovalCard(item: InboxItem(.approval(request), computer: request.computerName), request: request, at: at,
                         width: width, list: true)
        case .pair(let deviceId, let computer, let at):
            PairCard(item: InboxItem(.pair(deviceId: deviceId), computer: computer), deviceId: deviceId, at: at, width: width, list: true)
        case .agent(let deviceId, let computer, let agent, _, let at, let link):
            AgentChatRow(deviceId: deviceId, computer: computer, agent: agent, at: at, link: link, many: many)
        case .computer(let device, let last):
            ComputerChatRow(device: device, last: last, at: r.at)
        }
    }

    /// Starts an agent or a terminal on a computer that lets this iPhone
    /// control herdr. With more than 1, the app asks which one first.
    private func newAgent() {
        let states = SendTools.herdrStates(model)
        let control: (DeviceSnapshot) -> Bool = { $0.accepts(PacketType.fluxHerdr) && states[$0.id]?.control == true }
        guard Inbox.hasFeature(scope: nil, devices: model.state.devices, can: control) else {
            model.show("No computer lets this iPhone start an agent. To turn on Agent control, open Flux on a computer and use the Access card.")
            return
        }
        TargetRun.run(model, can: SendTools.canCreate(model), title: "Start an agent on", allComputers: true) { d in
            newPane = NewPaneItem(id: d.id)
        }
    }
}

/// The time words of the list of chats.
enum ChatsTime {
    /// The time of day of `at` today, else the short date. The distant past gives nothing.
    static func short(_ at: Date, now: Date = Date()) -> String {
        guard at > .distantPast else { return "" }
        if Calendar.current.isDate(at, inSameDayAs: now) { return ThreadTime.clock(at) }
        return at.formatted(date: .numeric, time: .omitted)
    }
}

/// The search field of the list: a 44 pt pill on `tile` with a `line`
/// border, the accent border while it has the focus, and a clear key while
/// it holds text.
private struct SearchPill: View {
    @Binding var text: String
    @FocusState private var focused: Bool
    @Environment(\.tn) private var tn

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tn.sub)
                .accessibilityHidden(true)
            TextField("Search agents, computers, files", text: $text)
                .font(.subheadline)
                .foregroundStyle(tn.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(tn.sub)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, text.isEmpty ? 14 : 2)
        .frame(minHeight: 44)
        .background(Capsule().fill(tn.tile))
        .overlay(Capsule().strokeBorder(focused ? tn.accent : tn.line, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { focused = true }
    }
}

/// The heading of a group of chats: the `title`, and `trailing` in mono and
/// `color` at the end, such as a count. VoiceOver reads the title as a heading.
private struct GroupHead: View {
    let title: String
    var trailing = ""
    var color: Color?
    var first = false
    @Environment(\.tn) private var tn

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(tn.text)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if !trailing.isEmpty {
                Text(trailing)
                    .font(.caption2.monospaced())
                    .foregroundStyle(color ?? tn.sub)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, first ? 8 : 12)
        .padding(.bottom, 4)
    }
}

/// The frame of a chat row: the `avatar`, the `title` on 1 line, the
/// `line` under it, and the `time` at the end. A row that needs the user
/// (`ask`) takes `tile` and a red border. `dim` shows a computer that is
/// not reachable at 55%. VoiceOver reads the row as 1 button with
/// `description`.
private struct ChatRowButton<Avatar: View, Line: View, Time: View>: View {
    let title: String
    let description: String
    var ask = false
    var dim = false
    let action: () -> Void
    @ViewBuilder let avatar: Avatar
    @ViewBuilder let line: Line
    @ViewBuilder let time: Time
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = tileShape()
        Button(action: action) {
            HStack(spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tn.text)
                        .lineLimit(1)
                    line
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                time
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.vertical, ask ? 10 : 8)
            .background(shape.fill(ask ? tn.tile : Color.clear))
            .overlay(shape.strokeBorder(ask ? tn.red : Color.clear, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .opacity(dim ? TiledMetrics.disabledAlpha : 1)
        .accessibilityLabel(description)
        .accessibilityHint("Opens the chat")
    }
}

/// The time at the end of a chat row, in mono.
private struct RowTime: View {
    let text: String
    @Environment(\.tn) private var tn

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(.caption2.monospaced())
                .foregroundStyle(tn.sub)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// An agent: its task, its status word in the status color with the agent
/// and the project in mono, and the time at the end. An agent that waits
/// shows how long it waits, such as "3m", and an agent that works shows
/// how long it works, such as "2:14". Another agent shows the time of its
/// status. `at` is the start of the status. With `many` computers, the
/// line names the computer. A computer that is not reachable shows
/// `Not reachable since HH:MM` in place of the status word, dim, and the
/// row has no time.
private struct AgentChatRow: View {
    let deviceId: String
    let computer: String
    let agent: HerdrAgent
    let at: Date
    let link: AgentLink
    let many: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let a = agent
        let s = a.status
        let blocked = s == .blocked
        // The project shows in the line under the title, so an agent with no task shows its pane.
        let title = a.title.isEmpty ? a.pane : a.title
        let source = [a.agent, a.project.isEmpty ? a.workspace : a.project, many ? computer : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let word = LinkNote.rowLine(online: link.reachable, lastSeen: link.since) ?? s.label
        ChatRowButton(title: title, description: [title, word, source].filter { !$0.isEmpty }.joined(separator: ", "),
                      ask: blocked, dim: !link.reachable, action: { model.chatPath.append(.feature(.agent(deviceId, a.pane))) }) {
            AgentAvatar(status: s, accent: blocked, ground: blocked ? tn.tile : tn.bg)
        } line: {
            HStack(spacing: 0) {
                Text(word)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(link.reachable ? color(s) : tn.sub)
                    .lineLimit(1)
                    .fixedSize()
                if !source.isEmpty {
                    Text(" · " + source)
                        .font(.caption.monospaced())
                        .foregroundStyle(tn.sub)
                        .lineLimit(1)
                }
            }
        } time: {
            if !link.reachable {
                // The waiting time and the working time stop while the computer is not reachable.
                EmptyView()
            } else if blocked || s == .working {
                // A working agent counts its time each second. A waiting agent shows minutes.
                TimelineView(.periodic(from: .now, by: s == .working ? 1 : 30)) { context in
                    RowTime(text: AgentTime.when(s, since: at, now: context.date))
                }
            } else {
                RowTime(text: ChatsTime.short(at))
            }
        }
    }

    /// The color of the status word. Idle and unknown take the second ink.
    private func color(_ s: AgentStatus) -> Color {
        switch s {
        case .blocked: return tn.red
        case .working: return tn.accent
        case .done: return tn.green
        default: return tn.sub
        }
    }
}

/// A computer: its name, the newest entry of its chat, and the time of
/// that entry. A computer that is not reachable shows at 55% with
/// `Not reachable since HH:MM`, when Flux knows the time. Without entries, the line
/// shows the link and the battery. `at` is the time of the row.
private struct ComputerChatRow: View {
    let device: DeviceSnapshot
    let last: ChatEntry?
    let at: Date
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let d = device
        let seen = model.lastSeen(d.id)
        let preview = last?.preview ?? ""
        let line: String = {
            if !d.online { return LinkNote.rowLine(online: false, lastSeen: seen) ?? "" }
            if !preview.isEmpty { return preview }
            let words = ChatTexts.link(model, d)
            return words.prefix(1).uppercased() + words.dropFirst()
        }()
        let link = d.linkText(battery: model.core.plugin(BatteryPlugin.self)?.model.computers[d.id])
        let spoken = ([d.name, link] + (line == link ? [] : [line])).joined(separator: ", ")
        ChatRowButton(title: d.name, description: spoken, dim: !d.online, action: { model.chatPath.append(.feature(.chat(d.id))) }) {
            ChatAvatar(icon: d.symbol, tint: tn.text, badge: d.online ? tn.green : nil)
        } line: {
            Text(line)
                .font(.footnote)
                .foregroundStyle(tn.sub)
                .lineLimit(1)
        } time: {
            RowTime(text: !d.online && last == nil ? seen.map { ChatsTime.short($0) } ?? "" : ChatsTime.short(at))
        }
    }
}
