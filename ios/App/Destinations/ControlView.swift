import FluxKit
import SwiftUI
import UIKit

/// The Control destination: the agents and the terminals of the computers
/// in scope, the tools that act on the computer, and the streams of this
/// iPhone. The dock plays the media of the computer. A tool shows when a
/// computer in scope has the feature, and it is dimmed while no such
/// computer is online. The tools that send input ask for Face ID or the
/// passcode first. The approval setup is a trust setting, so it is on the
/// page of each computer under Computers.
struct ControlView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    /// The computer of the new pane sheet.
    @State private var newPane: NewPaneItem?

    private struct NewPaneItem: Identifiable {
        let id: String
    }

    var body: some View {
        let herdr = model.core.plugin(HerdrPlugin.self)
        let states = herdrStates
        let working = scoped.contains { d in states[d.id]?.agents.contains { $0.status == .working } == true }
        let player = dockPlayer
        VStack(spacing: 0) {
            ComputerStrip()
            ProgressLine { if working { SlideBar(color: tn.accent) } }
            ScrollView {
                VStack(alignment: .leading, spacing: TiledMetrics.gap) {
                    if !model.state.devices.contains(where: { $0.paired }) { TargetLine(verb: "Acts on") }
                    if TargetRun.shows(model, can: canAgents) {
                        agentList(states)
                        if TargetRun.shows(model, can: hasControl) {
                            NewAgentRow(enabled: TargetRun.enabled(model, can: canCreate)) {
                                TargetRun.run(model, can: canCreate, title: "Start an agent on") { d in
                                    newPane = NewPaneItem(id: d.id)
                                }
                            }
                        }
                    }
                    ListHeader("Tools")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(tools(showMedia: player == nil)) { k in
                            GridTool(icon: k.icon, title: k.title, line: k.line, enabled: k.enabled, action: k.action)
                        }
                    }
                    if TargetRun.shows(model, can: canMic) || TargetRun.shows(model, can: canWebcam) {
                        ListHeader("Stream")
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                            if TargetRun.shows(model, can: canMic) {
                                SmallTool(icon: "mic", title: "Mic", enabled: TargetRun.enabled(model, can: canMic)) {
                                    open(canMic, "Stream the mic to") { .mic($0) }
                                }
                            }
                            if TargetRun.shows(model, can: canWebcam) {
                                SmallTool(icon: "web.camera", title: "Webcam", enabled: TargetRun.enabled(model, can: canWebcam)) {
                                    open(canWebcam, "Stream the camera to") { .cameraMode($0, .webcam) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, TiledMetrics.gutter)
                .padding(.top, 6)
                .padding(.bottom, 28)
                .frame(maxWidth: TiledMetrics.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let player {
                    MediaDock(device: player.device, player: player.player) {
                        model.controlPath.append(.feature(.nowPlaying(player.device.id)))
                    }
                }
            }
        }
        .destinationRoot("Control", context: ScreenWords.join("on \(ScreenWords.scopeName(model))", ScreenWords.online(model)))
        // The agent lists come again each time that Control shows.
        .task(id: scoped.map(\.id)) {
            guard !model.demo, let herdr else { return }
            for d in scoped where d.accepts(PacketType.fluxHerdr) { herdr.request(d.id) }
        }
        .sheet(item: $newPane) { item in
            let id = item.id
            NewPaneSheet(deviceId: id) { what, pane in
                newPane = nil
                model.controlPath.append(.feature(what == "terminal" ? .terminal(id, pane) : .agent(id, pane)))
            }
        }
    }

    // MARK: Agents

    /// The agent lists of the computers in scope, by device ID. The demo shows its sample agents.
    private var herdrStates: [String: HerdrState] {
        if model.demo, let laptop = DemoMode.computers.first { return [laptop.id: DemoMode.herdr] }
        return model.core.plugin(HerdrPlugin.self)?.model.states ?? [:]
    }

    /// The order of the agents of Control: the agents that need the user, then the agents that work, then the rest.
    private static let order: [AgentStatus] = [.blocked, .working, .done, .idle, .unknown]

    /// The agents and the terminals of the computers in scope, with a line that tells why no agent shows.
    @ViewBuilder
    private func agentList(_ states: [String: HerdrState]) -> some View {
        let devices = scoped.filter { $0.accepts(PacketType.fluxHerdr) }
        let agents = devices.flatMap { d in (states[d.id]?.agents ?? []).map { AgentRow(device: d, agent: $0) } }
            .sorted { (Self.order.firstIndex(of: $0.agent.status) ?? 9) < (Self.order.firstIndex(of: $1.agent.status) ?? 9) }
        let terminals = devices.flatMap { d in (states[d.id]?.panes ?? []).map { TerminalRow(device: d, terminal: $0) } }
        let blocked = agents.filter { $0.agent.status == .blocked }.count
        let summary = agents.isEmpty ? "" : ScreenWords.join(
            "\(agents.count) \(agents.count == 1 ? "agent" : "agents")",
            blocked > 0 ? "\(blocked) \(blocked == 1 ? "needs" : "need") you" : "")
        ListHeader("Agents", trailing: summary)
        if let note = agentNote(devices, states, empty: agents.isEmpty && terminals.isEmpty) {
            Text(note)
                .font(.footnote)
                .foregroundStyle(tn.sub)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
        }
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: TiledMetrics.gap) {
                ForEach(agents) { row in
                    let since = model.demo ? DemoMode.since(pane: row.agent.pane, now: context.date)
                        : model.core.plugin(HerdrPlugin.self)?.model.agentSince(device: row.device.id, pane: row.agent.pane)
                    AgentCard(agent: row.agent, when: AgentTime.when(row.agent.status, since: since, now: context.date)) {
                        model.controlPath.append(.feature(.agent(row.device.id, row.agent.pane)))
                    }
                }
            }
        }
        ForEach(terminals) { row in
            TerminalCard(terminal: row.terminal) {
                model.controlPath.append(.feature(.terminal(row.device.id, row.terminal.pane)))
            }
        }
    }

    /// An agent of a computer in the list.
    private struct AgentRow: Identifiable {
        let device: DeviceSnapshot
        let agent: HerdrAgent

        var id: String { device.id + "|" + agent.pane }
    }

    /// A terminal of a computer in the list.
    private struct TerminalRow: Identifiable {
        let device: DeviceSnapshot
        let terminal: HerdrTerminal

        var id: String { device.id + "|" + terminal.pane }
    }

    /// Why no agent shows, or nil.
    private func agentNote(_ devices: [DeviceSnapshot], _ states: [String: HerdrState], empty: Bool) -> String? {
        if devices.isEmpty {
            if let d = model.paired.first(where: { $0.id == model.scope }) { return "\(d.name) is not reachable. Its agents show when it connects." }
            return model.paired.isEmpty ? nil : "No computer with herdr is online."
        }
        if devices.count == 1, let d = devices.first {
            guard let h = states[d.id] else { return "Loading the agents of \(d.name)" }
            if !h.enabled { return "Agent status is off on \(d.name). Set herdr = true in ~/.config/flux/config.toml, then run systemctl --user reload fluxd." }
            if !h.running { return "herdr is not running on \(d.name). Start herdr there, and its coding agents show here." }
        }
        return empty ? "No agents run in herdr yet." : nil
    }

    // MARK: Tools

    private struct ControlTool: Identifiable {
        let icon: String
        let title: String
        let line: String
        let enabled: Bool
        let action: () -> Void

        var id: String { title }
    }

    private func tools(showMedia: Bool) -> [ControlTool] {
        let one = TargetRun.single(model)
        let input = model.core.plugin(RemoteInputPlugin.self)
        var list: [ControlTool] = []
        if TargetRun.shows(model, can: canPanel) {
            list.append(ControlTool(icon: "square.grid.2x2", title: "Omarchy panel", line: panelLine(one),
                                    enabled: TargetRun.enabled(model, can: canPanel)) {
                open(canPanel, "Open the Omarchy panel of", lock: { "Use the Omarchy panel of \($0.name)." }) { .panel($0) }
            })
        }
        if TargetRun.shows(model, can: canTouchpad) {
            let off = one.map { input?.model.isOn($0.id) != true } ?? false
            list.append(ControlTool(icon: "hand.tap", title: "Touchpad",
                                    line: off ? "Off on \(one?.name ?? "the computer")" : "Pointer, keys, and slides",
                                    enabled: TargetRun.enabled(model, can: canTouchpad)) {
                // Remote input can type in any window of the computer, so it asks first.
                open(canTouchpad, "Use the touchpad of",
                     lock: { d in input?.model.isOn(d.id) == true ? "Use the touchpad of \(d.name)." : nil }) { .touchpad($0) }
            })
        }
        if TargetRun.shows(model, can: canDesktop) {
            list.append(ControlTool(icon: "display", title: "Remote desktop", line: desktopLine(one),
                                    enabled: TargetRun.enabled(model, can: canDesktop)) {
                // The screen of the computer can show private content, so it asks first.
                open(canDesktop, "Show the screen of",
                     lock: { d in input?.model.isDesktopOn(d.id) == true ? "Show the screen of \(d.name)." : nil }) { .desktop($0) }
            })
        }
        if TargetRun.shows(model, can: canCommands) {
            list.append(ControlTool(icon: "terminal", title: "Commands", line: "Run a command",
                                    enabled: TargetRun.enabled(model, can: canCommands)) {
                open(canCommands, "Run the commands of") { .commands($0) }
            })
        }
        // The dock opens the media, so the tool shows only while no player shows there.
        if showMedia && TargetRun.shows(model, can: canMedia) {
            list.append(ControlTool(icon: "music.note", title: "Media", line: "Play, pause, and volume",
                                    enabled: TargetRun.enabled(model, can: canMedia)) {
                open(canMedia, "Control the media of") { .nowPlaying($0) }
            })
        }
        return list
    }

    // MARK: Conditions, from the tiles of each feature

    /// See `DesktopScreen`: the computer runs the actions of the Omarchy panel.
    private var canPanel: (DeviceSnapshot) -> Bool {
        let has = model.core.plugin(DesktopPlugin.self) != nil && model.core.plugin(RemoteInputPlugin.self) != nil
        return { has && DesktopPlugin.shortcutsSupported($0) }
    }

    /// See `TouchpadTile`.
    private var canTouchpad: (DeviceSnapshot) -> Bool {
        let has = model.core.plugin(RemoteInputPlugin.self) != nil
        return { has && RemoteInputPlugin.supported($0) }
    }

    /// See `DesktopTile`.
    private var canDesktop: (DeviceSnapshot) -> Bool {
        let has = model.core.plugin(RemoteInputPlugin.self) != nil
        return { has && DesktopPlugin.supported($0) }
    }

    /// See `CommandsTile`.
    private var canCommands: (DeviceSnapshot) -> Bool {
        let has = model.core.plugin(RunCommandPlugin.self) != nil
        return { has && $0.accepts(PacketType.runCommandRequest) }
    }

    /// See `MediaTile`.
    private var canMedia: (DeviceSnapshot) -> Bool {
        let has = model.core.plugin(MprisPlugin.self) != nil
        return { has && $0.accepts(PacketType.mprisRequest) }
    }

    /// See `MicTile`.
    private var canMic: (DeviceSnapshot) -> Bool {
        let has = model.core.plugin(MicPlugin.self) != nil
        return { has && $0.isFlux && $0.accepts(PacketType.fluxMic) }
    }

    /// See `WebcamPanel`.
    private var canWebcam: (DeviceSnapshot) -> Bool {
        let has = model.core.plugin(WebcamPlugin.self) != nil
        return { has && $0.accepts(PacketType.fluxWebcam) }
    }

    /// See `AgentsTile`.
    private var canAgents: (DeviceSnapshot) -> Bool {
        let has = model.core.plugin(HerdrPlugin.self) != nil
        return { has && $0.accepts(PacketType.fluxHerdr) }
    }

    /// The computers whose herdr takes new agents and terminals, see `AgentsScreen`.
    private var hasControl: (DeviceSnapshot) -> Bool {
        let states = herdrStates
        return { $0.accepts(PacketType.fluxHerdr) && states[$0.id]?.control == true }
    }

    /// The computers that can open a new agent or terminal now.
    private var canCreate: (DeviceSnapshot) -> Bool {
        let states = herdrStates
        return { d in
            guard d.accepts(PacketType.fluxHerdr), let h = states[d.id] else { return false }
            return h.running && h.control
        }
    }

    // MARK: Lines

    private func panelLine(_ one: DeviceSnapshot?) -> String {
        guard let one, let s = model.core.plugin(DesktopPlugin.self)?.model.shortcuts[one.id], s.loaded, s.active > 0 else {
            return "Workspaces, windows, and key bindings"
        }
        let n = s.workspaces.first { $0.id == s.active }?.windows ?? 0
        return "Workspace \(s.active) · \(n) \(n == 1 ? "window" : "windows")"
    }

    private func desktopLine(_ one: DeviceSnapshot?) -> String {
        guard let one, let input = model.core.plugin(RemoteInputPlugin.self) else { return "See and use the screen" }
        if !input.model.isDesktopOn(one.id) { return "Off on \(one.name)" }
        if !input.model.isOn(one.id) { return "View only" }
        return "See and use the screen"
    }

    /// The paired, online computers in scope.
    private var scoped: [DeviceSnapshot] {
        model.state.devices.filter { $0.paired && $0.online && (model.scope == nil || $0.id == model.scope) }
    }

    /// The player of the dock: the computer in scope, or the first computer that plays.
    private var dockPlayer: DockPlayer? {
        guard let plugin = model.core.plugin(MprisPlugin.self) else { return nil }
        let list = scoped.filter { $0.accepts(PacketType.mprisRequest) }.compactMap { d in plugin.model.media(d.id).player.map { DockPlayer(device: d, player: $0) } }
        return list.first { $0.player.playing } ?? list.first
    }

    /// A computer and its player, for the dock.
    private struct DockPlayer {
        let device: DeviceSnapshot
        let player: RemotePlayer
    }

    /// Opens the screen of `route` for the computer of the tool. When
    /// `lock` gives a reason, Face ID or the passcode comes first.
    private func open(_ can: (DeviceSnapshot) -> Bool, _ title: String, lock: (@MainActor (DeviceSnapshot) -> String?)? = nil,
                      _ route: @escaping (String) -> FeatureRoute) {
        TargetRun.run(model, can: can, title: title) { d in
            let push: @MainActor () -> Void = { model.controlPath.append(.feature(route(d.id))) }
            guard let reason = lock?(d) else { return push() }
            ReplyLock.run(reason: reason, action: push, onError: { model.show($0) })
        }
    }
}

// MARK: Rows

/// An agent: its status, the agent and the project in mono, and its task.
/// At the end, the time of its status as this iPhone saw it, and a chevron.
/// An agent that needs the user has a red border.
private struct AgentCard: View {
    let agent: HerdrAgent
    let when: String
    let action: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        let a = agent
        let task = a.title.isEmpty ? (a.project.isEmpty ? a.pane : a.project) : a.title
        let place = [a.agent, a.project].filter { !$0.isEmpty && $0 != task }
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        StatusMark(status: a.status)
                        Text(a.status.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(ink(a.status))
                        if !place.isEmpty {
                            Text("· " + place.joined(separator: " · "))
                                .font(.caption.monospaced())
                                .foregroundStyle(tn.sub)
                        }
                    }
                    .lineLimit(1)
                    Text(task)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tn.text)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !when.isEmpty {
                    Text(when)
                        .font(.caption2.monospaced())
                        .foregroundStyle(tn.sub)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tn.sub)
                    .accessibilityHidden(true)
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        }
        .buttonStyle(TiledPressStyle(fill: tn.tile, border: a.status == .blocked ? tn.red : tn.line))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the agent")
    }

    private func ink(_ s: AgentStatus) -> Color {
        switch s {
        case .blocked: return tn.red
        case .working: return tn.accent
        case .done: return tn.green
        case .idle, .unknown: return tn.sub
        }
    }
}

/// A herdr terminal: its folder and pane in mono, and its title.
private struct TerminalCard: View {
    let terminal: HerdrTerminal
    let action: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        let t = terminal
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal").font(.caption).foregroundStyle(tn.green)
                        Text("Terminal").font(.caption.weight(.medium)).foregroundStyle(tn.green)
                        Text("· " + [t.project, t.pane].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption.monospaced())
                            .foregroundStyle(tn.sub)
                    }
                    .lineLimit(1)
                    Text(t.title.isEmpty ? "shell" : t.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tn.text)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tn.sub)
                    .accessibilityHidden(true)
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        }
        .buttonStyle(TiledPressStyle(fill: tn.tile, border: tn.line))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the terminal")
    }
}

/// New agent or terminal: a dashed row in the accent color.
private struct NewAgentRow: View {
    let enabled: Bool
    let action: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        Button(action: action) {
            Label("New agent or terminal", systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tn.accent)
                .frame(maxWidth: .infinity, minHeight: 48)
                .overlay(tileShape().strokeBorder(tn.lineHi, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                .contentShape(tileShape())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : TiledMetrics.disabledAlpha)
    }
}

// MARK: Media dock

/// The player of a computer in the dock: the line of the position at the
/// top, the album art, the title, the player and the time, Play or Pause,
/// and Next. A tap on the title opens Media.
private struct MediaDock: View {
    let device: DeviceSnapshot
    let player: RemotePlayer
    let open: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let plugin = model.core.plugin(MprisPlugin.self)
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let position = player.position(at: ProcessInfo.processInfo.systemUptime)
            VStack(spacing: 0) {
                ProgressLine {
                    if player.length > 0 { LineFill(fraction: Double(position) / Double(player.length), color: tn.green) }
                }
                HStack(spacing: 10) {
                    Button(action: open) {
                        HStack(spacing: 12) {
                            ArtThumb(url: player.artURL, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(player.title.isEmpty ? "Unknown title" : player.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(tn.text)
                                    .lineLimit(1)
                                Text(player.name + (player.length > 0 ? " · \(ThreadTime.position(position)) / \(ThreadTime.position(player.length))" : ""))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(tn.sub)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens Media")
                    RoundKey(icon: player.playing ? "pause.fill" : "play.fill", name: player.playing ? "Pause" : "Play",
                             fill: tn.green, ink: tn.onAccent) { plugin?.action(device.id, "PlayPause") }
                    RoundKey(icon: "forward.end.fill", name: "Next", fill: tn.line, ink: tn.text) { plugin?.action(device.id, "Next") }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .dockFrame()
    }
}

/// A round key of 48 pt with an icon.
struct RoundKey: View {
    let icon: String
    let name: String
    let fill: Color
    let ink: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: 48, height: 48)
                .background(Circle().fill(fill))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }
}

/// The album art in a rounded square, or a music note while it loads or
/// when there is none. The art loads through AlbumArtLoader, which limits
/// the scheme and the size.
struct ArtThumb: View {
    let url: URL?
    let size: CGFloat
    var corner: CGFloat = 8
    var iconSize: CGFloat = 20
    @Environment(\.tn) private var tn
    @State private var image: UIImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        ZStack {
            shape.fill(tn.tileHi)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note").font(.system(size: iconSize)).foregroundStyle(tn.sub)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .task(id: url) {
            image = nil
            guard let url, let data = await AlbumArtLoader.load(url) else { return }
            image = UIImage(data: data)
        }
        .accessibilityHidden(true)
    }
}
