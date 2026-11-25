import AppKit
import FluxKit
import SwiftUI

// The list of chats in the sidebar: 1 chat for each agent and each paired
// computer, as in a messaging app. It follows ChatsScreen.kt of the Android
// app. The Mac puts the list in the sidebar and the chat in the detail
// column, so a click on a row opens its chat next to the list.

/// The sidebar: the header with the + key, the search field, the groups
/// Needs you, Agents, and Computers, then the rows of Control and
/// Computers, and this Mac at the bottom. An approval and a pair request
/// show as cards with their buttons. The sidebar asks each computer that
/// comes online for its agents.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @State private var query = ""
    @State private var ask: TargetAsk?

    var body: some View {
        let list = model.chatList(query: query)
        let herdr = model.core.plugin(HerdrPlugin.self)
        let states = herdr?.model.states ?? [:]
        let online = model.connectedPaired.map(\.id)
        // With more than 1 computer with agents, each agent row names its computer.
        let many = model.connectedPaired.filter { states[$0.id]?.running == true }.count > 1
        let open = model.destination == .chats ? model.chat : nil
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(spacing: 0) {
            ChatsHeader(ask: $ask)
            if !model.paired.isEmpty {
                ChatSearchField(text: $query)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ChatNotices(status: ChatStatus.list(model))
                    if model.paired.isEmpty && list.isEmpty {
                        Text("No computer is paired. Pair a computer to get its chat here.")
                            .font(.system(size: 12))
                            .foregroundStyle(tn.sub)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                            .padding(.top, 8)
                        Button("Pair a Computer") { model.go(.computers) }
                            .buttonStyle(FluxButtonStyle(kind: .text))
                    }
                    if !list.needs.isEmpty {
                        ChatsSectionHead(title: "Needs you", trailing: "\(list.needs.count)", color: tn.red)
                        ForEach(list.needs) { row in
                            needsRow(row, open: open, many: many)
                        }
                    }
                    if !list.agents.isEmpty {
                        // With 1 computer, the heading names it. With more, each row names its computer.
                        let names = Set(list.agents.compactMap { row -> String? in
                            if case .agent(_, let name, _, _, _, _) = row { return name }
                            return nil
                        })
                        ChatsSectionHead(title: "Agents", trailing: names.count == 1 ? "on \(names.first ?? "")" : "", color: tn.sub)
                        ForEach(list.agents) { row in
                            if case .agent(let id, let name, let agent, _, let at, let link) = row {
                                AgentChatRow(deviceId: id, computer: name, agent: agent, at: at, link: link, many: many,
                                             selected: open == .agent(id, pane: agent.pane))
                            }
                        }
                    }
                    if !list.computers.isEmpty {
                        ChatsSectionHead(title: "Computers", trailing: "", color: tn.sub)
                        ForEach(list.computers) { row in
                            if case .computer(let d, let last) = row {
                                ComputerChatRow(device: d, last: last, at: row.at, selected: open == .computer(d.id))
                            }
                        }
                    }
                    if list.isEmpty && searching {
                        Text("No chat holds \"\(query.trimmingCharacters(in: .whitespacesAndNewlines))\".")
                            .font(.system(size: 12))
                            .foregroundStyle(tn.sub)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 20)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            SidebarFooter()
        }
        .background(tn.bg)
        .targetPicker($ask)
        // The list asks each computer that comes online for its agents.
        .task(id: online) {
            for id in online { herdr?.request(id) }
        }
    }

    /// A row of Needs you: an approval or a pair request as a card, or an agent that waits for input.
    @ViewBuilder
    private func needsRow(_ row: ChatRow, open: ChatOpen?, many: Bool) -> some View {
        switch row {
        case .approval(let request, let at):
            ApprovalCard(item: InboxItem(.approval(request), computer: request.computerName), request: request, at: at, list: true)
        case .pair(let id, let name, let at):
            PairCard(item: InboxItem(.pair(deviceId: id), computer: name), deviceId: id, at: at, list: true)
        case .agent(let id, let name, let agent, _, let at, let link):
            AgentChatRow(deviceId: id, computer: name, agent: agent, at: at, link: link, many: many, selected: open == .agent(id, pane: agent.pane))
        case .computer:
            EmptyView()
        }
    }
}

/// "1 item needs you", "<n> items need you", or "Nothing needs you".
func needsText(_ count: Int) -> String {
    switch count {
    case 0: return "Nothing needs you"
    case 1: return "1 item needs you"
    default: return "\(count) items need you"
    }
}

/// The line under the name of a computer: its link and battery, such as
/// "connected · 82%, charging", or "not reachable".
func computerContext(_ device: DeviceSnapshot, battery: BatteryState?) -> String {
    guard device.online else { return "not reachable" }
    guard let battery else { return "connected" }
    return "connected · \(battery.charge)%" + (battery.charging ? ", charging" : "")
}

/// The time of a row: the time of day today, else the short date. The distant past has no time.
func shortTime(_ date: Date) -> String {
    if date == .distantPast { return "" }
    if Calendar.current.isDateInToday(date) { return clockTime(date) }
    return date.formatted(date: .numeric, time: .omitted)
}

// MARK: Header

/// The top of the sidebar: the Flux mark, Chats, the count of what needs
/// the user and the computers online in mono, and the + key that starts an
/// agent on a computer that allows it.
private struct ChatsHeader: View {
    @Binding var ask: TargetAsk?
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let needs = Inbox.needsYou(model.inboxItems())
        let context = model.paired.isEmpty ? "" : contextLine([needs > 0 ? "\(needs) need you" : "nothing needs you", onlineText(model)])
        HStack(spacing: 10) {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .foregroundStyle(tn.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Chats")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tn.text)
                    .accessibilityAddTraits(.isHeader)
                if !context.isEmpty {
                    Text(context)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tn.sub)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !model.paired.isEmpty {
                Button(action: startAgent) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tn.text)
                        .frame(width: TiledMetrics.buttonHeight, height: TiledMetrics.buttonHeight)
                        .background(Circle().fill(tn.line))
                        .contentShape(Circle())
                }
                .buttonStyle(TilePressStyle())
                .help("Start an agent on a computer")
                .accessibilityLabel("Start an agent")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    /// Starts an agent on the computer that lets this Mac control herdr, or asks which one.
    private func startAgent() {
        let states = model.core.plugin(HerdrPlugin.self)?.model.states ?? [:]
        let target = Inbox.target(scope: nil, devices: model.state.devices) { d in
            guard let h = states[d.id] else { return false }
            return h.running && h.control
        }
        if case .unavailable = target {
            model.show("No computer lets this Mac start an agent. To turn on Agent control, open Flux on a computer and use the Access card.")
            return
        }
        ToolTarget.run(target, title: "Start an agent on", ask: $ask) { d in model.startAgent = d.id }
    }
}

/// The search field of the list: a pill on `tile` with a `line` border, and
/// the clear key while it holds text. Escape empties it.
private struct ChatSearchField: View {
    @Binding var text: String
    @Environment(\.tn) private var tn
    @FocusState private var focused: Bool

    var body: some View {
        let shape = Capsule()
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tn.sub)
                .accessibilityHidden(true)
            TextField("Search agents, computers, files", text: $text, prompt: Text("Search agents, computers, files"))
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onExitCommand { text = "" }
            ClearKey(text: $text)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(shape.fill(tn.tile))
        // The border takes no clicks, so the clear key under it gets them.
        .overlay(shape.strokeBorder(focused ? tn.accent : tn.line, lineWidth: 1).allowsHitTesting(false))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

/// The heading of a group of chats: the title, and `trailing` in mono and `color` at the end, such as a count.
private struct ChatsSectionHead: View {
    let title: String
    let trailing: String
    let color: Color
    @Environment(\.tn) private var tn

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tn.text)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if !trailing.isEmpty {
                Text(trailing)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 12)
        .padding(.bottom, 2)
    }
}

// MARK: Rows

/// The frame of a chat row: the avatar, the title in 13 pt semibold, the
/// line under it, and `trailing` at the end, such as the time. A row that
/// needs the user (`ask`) takes `tile` and a red border. The open chat
/// takes `line`. `dim` shows a computer that is not reachable at 55%.
private struct ChatRowFrame<Avatar: View, Line: View, Trailing: View>: View {
    let title: String
    /// What VoiceOver reads for the row.
    let label: String
    var selected = false
    var ask = false
    var dim = false
    let action: () -> Void
    @ViewBuilder let avatar: () -> Avatar
    @ViewBuilder let line: () -> Line
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.tn) private var tn
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TiledMetrics.tileCorner, style: .continuous)
        Button(action: action) {
            HStack(spacing: 10) {
                avatar()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tn.text)
                        .lineLimit(1)
                    line()
                }
                Spacer(minLength: 4)
                trailing()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, ask ? 8 : 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(selected ? tn.line : ask ? tn.tile : Color.clear))
            .overlay(shape.fill(tn.text.opacity(hovering && !selected ? 0.05 : 0)))
            .overlay { if ask { shape.strokeBorder(tn.red, lineWidth: 1) } }
            .opacity(dim ? TiledMetrics.disabledAlpha : 1)
            .contentShape(shape)
        }
        .buttonStyle(TilePressStyle())
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .accessibilityHint("Opens the chat")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// An agent: its task, its status word in the status color with the agent
/// and the project in mono, and the time at the end. An agent that waits
/// shows how long it waits, an agent that works shows how long it works,
/// and another agent shows the time of its status. With `many` computers
/// with agents, the line names the computer. A computer that is not
/// reachable shows `Not reachable since HH:MM` in place of the status word,
/// dim, and the row has no time.
private struct AgentChatRow: View {
    let deviceId: String
    let computer: String
    let agent: HerdrAgent
    let at: Date
    let link: AgentLink
    let many: Bool
    let selected: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let s = agent.status
        let blocked = s == .blocked
        // The project shows in the line under the title, so an agent with no task shows its pane.
        let title = agent.title.isEmpty ? agent.pane : agent.title
        let source = [agent.agent, agent.project.isEmpty ? agent.workspace : agent.project, many ? computer : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let ground = selected ? tn.line : blocked ? tn.tile : tn.bg
        let word = LinkNote.rowLine(online: link.reachable, lastSeen: link.since) ?? s.label
        ChatRowFrame(title: title, label: [title, word, source].filter { !$0.isEmpty }.joined(separator: ", "),
                     selected: selected, ask: blocked, dim: !link.reachable, action: { model.open(.agent(deviceId, pane: agent.pane)) }) {
            ChatAvatar(symbol: "brain", tint: s == .idle || s == .unknown ? tn.sub : tn.accent,
                       fill: blocked ? tn.accentTile : tn.tile, edge: !blocked,
                       badge: AgentAvatar.badge(s, tn), spinner: s == .working, ground: ground)
        } line: {
            HStack(spacing: 4) {
                Text(word)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(link.reachable ? Self.color(s, tn) : tn.sub)
                    .lineLimit(1)
                    .fixedSize()
                if !source.isEmpty {
                    Text("· " + source)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tn.sub)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        } trailing: {
            // The waiting time and the working time stop while the computer is not reachable.
            if link.reachable { AgentRowTime(status: s, at: at) }
        }
    }

    /// The color of the status word. Idle and unknown take the second ink.
    static func color(_ s: AgentStatus, _ tn: ThemeColors) -> Color {
        switch s {
        case .blocked: return tn.red
        case .working: return tn.accent
        case .done: return tn.green
        default: return tn.sub
        }
    }
}

/// The time at the end of an agent row: "3m" while it waits, "2:14" while it works, else the time of day.
private struct AgentRowTime: View {
    let status: AgentStatus
    let at: Date
    @Environment(\.tn) private var tn

    var body: some View {
        switch status {
        case .blocked:
            TimelineView(.periodic(from: .now, by: 30)) { context in
                time(AgentTime.when(.blocked, since: at, now: context.date))
            }
        case .working:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                time(AgentTime.when(.working, since: at, now: context.date))
            }
        default:
            time(shortTime(at))
        }
    }

    private func time(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(tn.sub)
            .lineLimit(1)
            .fixedSize()
    }
}

/// A computer: its name, the newest entry of its chat, and the time of that
/// entry. A computer that is not reachable shows at 55% with
/// `Not reachable since HH:MM`.
/// Without entries, the line shows the link and the battery.
private struct ComputerChatRow: View {
    let device: DeviceSnapshot
    let last: ChatEntry?
    let at: Date
    let selected: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let battery = model.core.plugin(BatteryPlugin.self)?.model.computers[device.id]
        let line: String = {
            if !device.online { return LinkNote.rowLine(online: false, lastSeen: model.lastSeen(device.id)) ?? "" }
            if let last { return last.preview }
            let context = computerContext(device, battery: battery)
            return context.prefix(1).uppercased() + context.dropFirst()
        }()
        ChatRowFrame(title: device.name, label: [device.name, linkText(device, battery: battery), line].joined(separator: ", "),
                     selected: selected, dim: !device.online, action: { model.open(.computer(device.id)) }) {
            ComputerAvatar(device: device, ground: selected ? tn.line : tn.bg)
        } line: {
            Text(line)
                .font(.system(size: 12))
                .foregroundStyle(tn.sub)
                .lineLimit(1)
                .truncationMode(.tail)
        } trailing: {
            Text(last == nil ? "" : shortTime(at))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(tn.sub)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

// MARK: Footer

/// The bottom of the sidebar: the rows of Control and Computers, and this Mac.
private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Rectangle().fill(tn.line).frame(height: 1).padding(.bottom, 6)
            ForEach([MacDestination.control, .computers]) { d in
                DestinationRow(destination: d, selected: model.destination == d) { model.go(d) }
            }
            HStack(spacing: 8) {
                Image(systemName: FluxCore.deviceType == "laptop" ? "laptopcomputer" : "desktopcomputer")
                    .accessibilityHidden(true)
                Text(model.state.deviceName).lineLimit(1)
                Spacer()
                if !model.state.enabled { Text("Off").foregroundStyle(tn.sub) }
            }
            .font(.caption)
            .foregroundStyle(tn.text)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }
}

/// A row of a destination under the chats: its symbol, its title, and its key.
private struct DestinationRow: View {
    let destination: MacDestination
    let selected: Bool
    let action: () -> Void
    @Environment(\.tn) private var tn
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TiledMetrics.smallCorner, style: .continuous)
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: destination.systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? tn.accent : tn.sub)
                    .frame(width: 20)
                Text(destination.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(tn.text)
                Spacer(minLength: 4)
                Text("⌘" + String(destination.shortcut.character))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(tn.sub)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(shape.fill(selected ? tn.line : hovering ? tn.text.opacity(0.05) : Color.clear))
            .contentShape(shape)
        }
        .buttonStyle(TilePressStyle())
        .onHover { hovering = $0 }
        .help("Open \(destination.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
