import AppKit
import FluxKit
import SwiftUI

/// Control: the agents and the terminals of the computers in scope, the
/// tools that act on the computer, and the streams of this Mac. The dock
/// plays the media of the computer. A click on an agent opens its chat.
/// Agents Window opens the agents of a computer in their own window. The
/// touchpad and the remote desktop ask for Touch ID first.
struct ControlView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @State private var ask: TargetAsk?

    var body: some View {
        let devices = model.state.devices
        let scope = model.scope
        let noPairing = model.paired.isEmpty
        let input = model.core.plugin(RemoteInputPlugin.self)
        let herdr = model.core.plugin(HerdrPlugin.self)
        let mpris = model.core.plugin(MprisPlugin.self)
        let hasHerdr = Inbox.hasFeature(scope: scope, devices: devices, can: { $0.accepts(PacketType.fluxHerdr) })
        let scoped = model.connectedPaired.filter { scope == nil || $0.id == scope }
        let herdrDevices = scoped.filter { $0.accepts(PacketType.fluxHerdr) }
        let working = herdrDevices.contains { d in herdr?.model.scoped(d.id)?.agents.contains { $0.status == .working } == true }
        // The dock plays the computer in scope, or the first computer that plays.
        let players = scoped.filter { $0.accepts(PacketType.mprisRequest) && mpris?.model.media($0.id).player != nil }
        let player = players.first { mpris?.model.media($0.id).player?.playing == true } ?? players.first
        VStack(spacing: 0) {
            ComputerPills()
            ProgressLine { if working { SlideBar(color: tn.accent) } }
            ScrollView {
                VStack(alignment: .leading, spacing: TiledMetrics.gap) {
                    if noPairing { TargetLine(verb: "Acts on") }
                    if let herdr, noPairing || hasHerdr {
                        let agents = ToolTarget.of(model, can: { $0.accepts(PacketType.fluxHerdr) })
                        AgentList(herdr: herdr, devices: herdrDevices, canOpen: ToolTarget.ready(agents)) {
                            ToolTarget.run(agents, title: "Open the agents of", ask: $ask) { d in AgentsWindows.shared.show(d.id, app: model) }
                        } startAgent: {
                            ToolTarget.run(agents, title: "Start an agent on", ask: $ask) { d in model.startAgent = d.id }
                        }
                    }
                    ListHeading("Tools")
                    GridRows(items: tools(input: input, mpris: mpris, dock: player != nil), columns: 2) { $0 }
                    let streams = streamTools()
                    if !streams.isEmpty {
                        ListHeading("Stream")
                        GridRows(items: streams, columns: 3) { $0 }
                    }
                }
                .pageColumn()
            }
            if let player, let mpris {
                MediaDock(device: player, plugin: mpris) { model.push(.card(.media, player.id)) }
            }
        }
        .task(id: herdrDevices.map(\.id)) {
            // The agent lists come again each time that Control shows.
            for d in herdrDevices { herdr?.request(d.id) }
        }
        .targetPicker($ask)
        .navigationSubtitle(contextLine(["on \(scopeName(model))", onlineText(model)]))
        .destinationRoot(.control)
    }

    /// The tools of the computer: the Omarchy panel, the remote desktop, the
    /// touchpad, the commands, and the media while the dock shows no player.
    private func tools(input: RemoteInputPlugin?, mpris: MprisPlugin?, dock: Bool) -> [GridTool] {
        let devices = model.state.devices
        let scope = model.scope
        let noPairing = model.paired.isEmpty
        let desktop = ToolTarget.of(model, can: { DesktopPlugin.supported($0) && input?.model.isDesktopOn($0.id) == true })
        let omarchy = ToolTarget.of(model, can: {
            DesktopPlugin.supported($0) && DesktopPlugin.shortcutsSupported($0) && input?.model.isDesktopOn($0.id) == true && input?.model.isOn($0.id) == true
        })
        let touchpad = ToolTarget.of(model, can: { RemoteInputPlugin.supported($0) && input?.model.isOn($0.id) == true })
        let commands = ToolTarget.of(model, can: { $0.accepts(PacketType.runCommandRequest) })
        let media = ToolTarget.of(model, can: { $0.accepts(PacketType.mprisRequest) })
        let hasDesktop = Inbox.hasFeature(scope: scope, devices: devices, can: { DesktopPlugin.supported($0) })
        let hasShortcuts = Inbox.hasFeature(scope: scope, devices: devices, can: { DesktopPlugin.supported($0) && DesktopPlugin.shortcutsSupported($0) })
        let hasInput = Inbox.hasFeature(scope: scope, devices: devices, can: { RemoteInputPlugin.supported($0) })
        var list: [GridTool] = []
        if input != nil && (noPairing || hasShortcuts) {
            list.append(GridTool(id: "omarchy", icon: "square.grid.2x2", title: "Omarchy panel", line: omarchyLine(),
                                 enabled: ToolTarget.ready(omarchy)) {
                // The panel shows at the side of the screen of the computer.
                ToolTarget.run(omarchy, title: "Open the Omarchy panel of", ask: $ask) { d in
                    DesktopWindows.shared.open(d, panel: .omarchy, app: model)
                }
            })
        }
        if input != nil && (noPairing || hasDesktop) {
            list.append(GridTool(id: "desktop", icon: "display", title: "Remote desktop", line: desktopLine(desktop, input: input),
                                 enabled: ToolTarget.ready(desktop)) {
                ToolTarget.run(desktop, title: "Show the screen of", ask: $ask) { d in DesktopWindows.shared.open(d, app: model) }
            })
        }
        if input != nil && (noPairing || hasInput) {
            list.append(GridTool(id: "touchpad", icon: "cursorarrow.motionlines", title: "Touchpad",
                                 line: offLine(touchpad, supported: RemoteInputPlugin.supported) ?? "Pointer, keys, and slides",
                                 enabled: ToolTarget.ready(touchpad)) {
                ToolTarget.run(touchpad, title: "Control the pointer of", ask: $ask) { d in TouchpadWindows.shared.open(d, app: model) }
            })
        }
        if model.core.plugin(RunCommandPlugin.self) != nil {
            list.append(GridTool(id: "commands", icon: "terminal", title: "Commands", line: "Run a command", enabled: ToolTarget.ready(commands)) {
                ToolTarget.run(commands, title: "Run the commands of", ask: $ask) { d in model.push(.card(.commands, d.id)) }
            })
        }
        // The dock opens the media, so the tool shows only while no player shows there.
        if mpris != nil && !dock {
            list.append(GridTool(id: "media", icon: "music.note", title: "Media", line: "Play, pause, and volume", enabled: ToolTarget.ready(media)) {
                ToolTarget.run(media, title: "Control the media of", ask: $ask) { d in model.push(.card(.media, d.id)) }
            })
        }
        return list
    }

    /// The streams of this Mac: the microphone, the webcam, and the screen
    /// mirror. The webcam and the mirror share 1 page.
    private func streamTools() -> [GridTool] {
        let mic = ToolTarget.of(model, can: { $0.isFlux })
        let stream = ToolTarget.of(model)
        var list: [GridTool] = []
        if model.core.plugin(MicPlugin.self) != nil {
            list.append(GridTool(id: "mic", icon: "mic", title: "Mic", line: "Use this Mac as a microphone", enabled: ToolTarget.ready(mic), small: true) {
                ToolTarget.run(mic, title: "Use the microphone of this Mac on", ask: $ask) { d in model.push(.card(.mic, d.id)) }
            })
        }
        if model.core.plugin(WebcamPlugin.self) != nil {
            list.append(GridTool(id: "webcam", icon: "web.camera", title: "Webcam", line: "Use the camera of this Mac", enabled: ToolTarget.ready(stream), small: true) {
                ToolTarget.run(stream, title: "Stream to", ask: $ask) { d in model.push(.card(.stream, d.id)) }
            })
        }
        if model.core.plugin(ScreenPlugin.self) != nil {
            list.append(GridTool(id: "mirror", icon: "rectangle.on.rectangle", title: "Mirror", line: "Show a display of this Mac", enabled: ToolTarget.ready(stream), small: true) {
                ToolTarget.run(stream, title: "Stream to", ask: $ask) { d in model.push(.card(.stream, d.id)) }
            })
        }
        return list
    }

    /// "Off on <computer>" when the 1 online computer in scope that has the
    /// feature turned it off, else nil.
    private func offLine(_ target: ActionTarget, supported: (DeviceSnapshot) -> Bool) -> String? {
        guard !ToolTarget.ready(target) else { return nil }
        let off = model.connectedPaired.filter { (model.scope == nil || $0.id == model.scope) && supported($0) }
        return off.count == 1 ? "Off on \(off[0].name)" : nil
    }

    private func desktopLine(_ target: ActionTarget, input: RemoteInputPlugin?) -> String {
        if let off = offLine(target, supported: DesktopPlugin.supported) { return off }
        if let d = ToolTarget.single(target), input?.model.isOn(d.id) != true { return "View only" }
        return "See and use the screen"
    }

    /// "Workspace 2 · 3 windows" of the computer in scope while the panel knows it, else the default line.
    private func omarchyLine() -> String {
        guard let id = model.scope, let s = model.core.plugin(DesktopPlugin.self)?.model.shortcuts[id], s.loaded, s.active > 0 else {
            return "Workspaces, windows, and key bindings"
        }
        let n = s.windows.map { _ in s.activeWindows.count } ?? s.workspaces.first { $0.id == s.active }?.windows ?? 0
        return "Workspace \(s.active) · \(n) \(n == 1 ? "window" : "windows")"
    }
}

// MARK: Agents

/// The order of the agents of Control: the agents that need the user, then
/// the agents that work, then the rest.
private let controlOrder: [AgentStatus] = [.blocked, .working, .done, .idle, .unknown]

/// The agents and the terminals of the computers in `devices`, with the
/// agents that need the user first. A line tells why no agent shows. A
/// computer with more than 1 herdr session shows the agents of the session
/// that the user picks in its pills.
private struct AgentList: View {
    let herdr: HerdrPlugin
    let devices: [DeviceSnapshot]
    /// True when a computer can show its agents window.
    let canOpen: Bool
    /// Opens the agents window, which also reads the agents again.
    let openWindow: () -> Void
    /// Opens the sheet that starts an agent.
    let startAgent: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    private struct Row: Identifiable {
        let device: DeviceSnapshot
        let agent: HerdrAgent
        var id: String { device.id + "|" + agent.pane }
    }

    private struct TermRow: Identifiable {
        let device: DeviceSnapshot
        let terminal: HerdrTerminal
        var id: String { device.id + "|" + terminal.pane }
    }

    var body: some View {
        let rows = devices.flatMap { d in (herdr.model.scoped(d.id)?.agents ?? []).map { Row(device: d, agent: $0) } }
            .sorted { (controlOrder.firstIndex(of: $0.agent.status) ?? 9) < (controlOrder.firstIndex(of: $1.agent.status) ?? 9) }
        let terms = devices.flatMap { d in (herdr.model.scoped(d.id)?.panes ?? []).map { TermRow(device: d, terminal: $0) } }
        let blocked = rows.filter { $0.agent.status == .blocked }.count
        let summary = rows.isEmpty ? "" : contextLine([
            "\(rows.count) \(rows.count == 1 ? "agent" : "agents")",
            blocked > 0 ? "\(blocked) \(blocked == 1 ? "needs" : "need") you" : "",
        ])
        ListHeading("Agents", trailing: summary) {
            HStack(spacing: 12) {
                Button("Start Agent", action: startAgent)
                    .help("Start a coding agent on the computer")
                Button("Agents Window", action: openWindow)
                    .help("Open the agents of the computer in their own window")
            }
            .buttonStyle(.link)
            .font(.system(size: 11.5))
            .disabled(!canOpen)
        }
        ForEach(devices) { d in
            if let all = herdr.model.states[d.id], all.sessions.count > 1, let shown = herdr.model.session(d.id) {
                SessionPills(state: all, selected: shown, computer: devices.count > 1 ? d.name : nil) { herdr.model.selectSession(d.id, $0) }
            }
        }
        note(rows: rows.count, terminals: terms.count)
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: TiledMetrics.gap) {
                ForEach(rows) { r in
                    AgentCard(agent: r.agent, since: herdr.model.agentSince(device: r.device.id, pane: r.agent.pane), now: context.date) {
                        model.open(.agent(r.device.id, pane: r.agent.pane))
                    }
                }
            }
        }
        ForEach(terms) { t in TerminalCard(terminal: t.terminal) }
    }

    /// The line under the heading that tells why no agent shows, or nothing.
    @ViewBuilder
    private func note(rows: Int, terminals: Int) -> some View {
        let single = devices.count == 1 ? devices[0] : nil
        let state = single.flatMap { herdr.model.scoped($0.id) }
        if devices.isEmpty {
            let d = model.pairedDevice(model.scope)
            AgentNote(text: d.map { "\($0.name) is not reachable. Its agents show when it connects." } ?? "No computer with herdr is online.")
        } else if let single, state == nil {
            LineSkeleton(widths: [0.7, 0.5], label: "Loading the agents of \(single.name)")
                .padding(4)
        } else if let single, state?.enabled == false {
            AgentNote(text: "Agent status is off on \(single.name). Set herdr = true in ~/.config/flux/config.toml, then run systemctl --user reload fluxd.")
        } else if let single, state?.running == false {
            AgentNote(text: "herdr is not running on \(single.name). Start herdr there, and its coding agents show here.")
        } else if rows == 0 && terminals == 0 {
            AgentNote(text: "No agents run in herdr yet.")
        }
    }
}

/// The herdr sessions of a computer as pills. The pill of the shown session
/// has the accent, and each pill counts the agents of its session that need
/// the user. `computer` names the computer when the list shows more than 1.
struct SessionPills: View {
    /// The agents of all sessions of the computer.
    let state: HerdrState
    let selected: HerdrSession
    var computer: String?
    let select: (String) -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let computer {
                    Text(computer)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(tn.sub)
                        .lineLimit(1)
                }
                ForEach(state.sessions) { s in
                    let n = state.blockedCount(in: s.name)
                    StripPill(label: s.label, selected: s.name == selected.name, meta: n > 0 ? "\(n) \(n == 1 ? "needs" : "need") you" : "",
                              help: "Show the agents of the session \(s.label)") {
                        select(s.name)
                    } mark: {
                        if n > 0 { Circle().fill(tn.red).frame(width: 7, height: 7) }
                    }
                    .accessibilityLabel("Session \(s.label)" + (n > 0 ? ", \(n) \(n == 1 ? "needs" : "need") you" : ""))
                }
            }
            .padding(.vertical, 4)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}

/// A line under the Agents heading.
private struct AgentNote: View {
    let text: String
    @Environment(\.tn) private var tn

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(tn.sub)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
    }
}

/// An agent: its status, the agent and the project in mono, and its task.
/// At the end, the time of its status as this Mac saw it, and a chevron.
/// An agent that needs the user has a red border.
private struct AgentCard: View {
    let agent: HerdrAgent
    let since: Date?
    let now: Date
    let action: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = tileShape()
        let blocked = agent.status == .blocked
        let task = agent.title.isEmpty ? (agent.project.isEmpty ? agent.pane : agent.project) : agent.title
        let place = [agent.agent, agent.project].filter { !$0.isEmpty && $0 != task }
        let when = AgentTime.when(agent.status, since: since, now: now)
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        StatusMark(status: agent.status)
                        Text(agent.status.label)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(ink)
                        if !place.isEmpty {
                            Text("· " + place.joined(separator: " · "))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(tn.sub)
                                .lineLimit(1)
                        }
                    }
                    Text(task)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tn.text)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if !when.isEmpty {
                    Text(when)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(tn.sub)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tn.sub)
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background(shape.fill(tn.tile))
            .overlay(shape.strokeBorder(blocked ? tn.red : tn.line, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(TilePressStyle())
        .help("Open \(task) in the agents window")
        .accessibilityLabel("\(agent.status.label), \(task)")
    }

    /// The color of the status word. An idle or unknown status takes the second ink.
    private var ink: Color {
        switch agent.status {
        case .blocked: return tn.red
        case .working: return tn.accent
        case .done: return tn.green
        default: return tn.sub
        }
    }
}

/// A herdr terminal: its folder and pane in mono, and its title. The Mac
/// app shows no terminal, so the card takes no click.
private struct TerminalCard: View {
    let terminal: HerdrTerminal
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = tileShape()
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                    .foregroundStyle(tn.green)
                Text("Terminal")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(tn.green)
                Text("· " + contextLine([terminal.project, terminal.pane]))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(tn.sub)
                    .lineLimit(1)
            }
            Text(terminal.title.isEmpty ? "shell" : terminal.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tn.text)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .background(shape.fill(tn.tile))
        .overlay(shape.strokeBorder(tn.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Media

/// The player of the computer in the dock: the line of the position at the
/// top, the album art, the title, the player and the time, Play or Pause,
/// and Next. A click on the title opens the media page.
private struct MediaDock: View {
    let device: DeviceSnapshot
    let plugin: MprisPlugin
    let open: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        let media = plugin.model.media(device.id)
        if let p = media.player {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let position = p.position(at: ProcessInfo.processInfo.systemUptime)
                VStack(spacing: 0) {
                    ProgressLine { if p.length > 0 { LineFill(fraction: Double(position) / Double(p.length), color: tn.green) } }
                        .padding(.horizontal, -TiledMetrics.gutter)
                    HStack(spacing: 10) {
                        Button(action: open) {
                            HStack(spacing: 12) {
                                ArtThumb(url: p.artURL, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.title.isEmpty ? "Unknown title" : p.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(tn.text)
                                        .lineLimit(1)
                                    Text(contextLine([p.name, p.length > 0 ? "\(mediaClock(position)) / \(mediaClock(p.length))" : ""]))
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(tn.sub)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(TilePressStyle())
                        .help("Open the media of \(device.name)")
                        RoundKey(symbol: p.playing ? "pause.fill" : "play.fill", help: p.playing ? "Pause" : "Play", fill: tn.green, ink: tn.onAccent) {
                            plugin.action(device.id, "PlayPause")
                        }
                        RoundKey(symbol: "forward.end.fill", help: "Next", fill: tn.line, ink: tn.text) { plugin.action(device.id, "Next") }
                    }
                    .padding(.top, 10)
                }
            }
            .pageDock(top: 0)
        }
    }
}

/// A round key of 40 pt with a symbol.
struct RoundKey: View {
    let symbol: String
    let help: String
    let fill: Color
    let ink: Color
    var size: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: size, height: size)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(TilePressStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The album art at `url` in a rounded square, or a music note while there is none.
struct ArtThumb: View {
    let url: URL?
    var size: CGFloat = 40
    var corner: CGFloat = 8
    @Environment(\.tn) private var tn
    @State private var image: NSImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        ZStack {
            shape.fill(tn.tileHi)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(tn.sub)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .task(id: url) {
            image = nil
            guard let url, let data = await AlbumArtLoader.load(url) else { return }
            image = NSImage(data: data)
        }
        .accessibilityHidden(true)
    }
}
