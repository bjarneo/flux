import FluxKit
import SwiftUI

/// The Control destination: the tools that act on the computer in scope.
/// The Omarchy panel takes the master position. The other tools stack
/// under it in groups. A tool shows when a computer in scope has the
/// feature, and it is dimmed while no such computer is online. The tools
/// that send input ask for Face ID or the passcode first. The approval
/// setup is a trust setting, so it is on the page of each computer under
/// Computers.
struct ControlView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    /// The computer of the new pane sheet.
    @State private var newPane: NewPaneItem?

    private struct NewPaneItem: Identifiable {
        let id: String
    }

    var body: some View {
        let one = TargetRun.single(model)
        let input = model.core.plugin(RemoteInputPlugin.self)
        ScrollView {
            VStack(alignment: .leading, spacing: TiledMetrics.gap) {
                TargetLine(verb: "Acts on")
                if TargetRun.shows(model, can: canPanel) {
                    MasterTool(icon: "square.grid.3x3", title: "Omarchy panel", line: "Workspaces, windows, and key bindings",
                               enabled: TargetRun.enabled(model, can: canPanel)) {
                        open(canPanel, "Open the Omarchy panel of", lock: { "Use the Omarchy panel of \($0.name)." }) { .panel($0) }
                    }
                }
                if TargetRun.shows(model, can: canTouchpad) {
                    let off = one.map { input?.model.isOn($0.id) != true } ?? false
                    ToolRow(icon: "hand.point.up.left", title: "Touchpad and keyboard",
                            line: off ? "Off on \(one?.name ?? "the computer")" : "Pointer, keys, and slides",
                            enabled: TargetRun.enabled(model, can: canTouchpad)) {
                        // Remote input can type in any window of the computer, so it asks first.
                        open(canTouchpad, "Use the touchpad of",
                             lock: { d in input?.model.isOn(d.id) == true ? "Use the touchpad of \(d.name)." : nil }) { .touchpad($0) }
                    }
                }
                if TargetRun.shows(model, can: canDesktop) {
                    ToolRow(icon: "display", title: "Remote desktop", line: desktopLine(one),
                            enabled: TargetRun.enabled(model, can: canDesktop)) {
                        // The screen of the computer can show private content, so it asks first.
                        open(canDesktop, "Show the screen of",
                             lock: { d in input?.model.isDesktopOn(d.id) == true ? "Show the screen of \(d.name)." : nil }) { .desktop($0) }
                    }
                }
                if TargetRun.shows(model, can: canCommands) {
                    ToolRow(icon: "terminal", title: "Commands", line: "Run the commands of the computer",
                            enabled: TargetRun.enabled(model, can: canCommands)) {
                        open(canCommands, "Run the commands of") { .commands($0) }
                    }
                }
                if TargetRun.shows(model, can: canMedia) {
                    ToolRow(icon: "music.note", title: "Media", line: mediaLine(one),
                            enabled: TargetRun.enabled(model, can: canMedia)) {
                        open(canMedia, "Control the media of") { .nowPlaying($0) }
                    }
                }
                if TargetRun.shows(model, can: canMic) || TargetRun.shows(model, can: canWebcam) {
                    SectionLabel("Stream")
                }
                if TargetRun.shows(model, can: canMic) {
                    ToolRow(icon: "mic", title: "Mic", line: "Use this iPhone as a microphone",
                            enabled: TargetRun.enabled(model, can: canMic)) {
                        open(canMic, "Stream the mic to") { .mic($0) }
                    }
                }
                if TargetRun.shows(model, can: canWebcam) {
                    ToolRow(icon: "web.camera", title: "Webcam", line: "Use this iPhone as a webcam",
                            enabled: TargetRun.enabled(model, can: canWebcam)) {
                        open(canWebcam, "Stream the camera to") { .cameraMode($0, .webcam) }
                    }
                }
                if TargetRun.shows(model, can: canAgents) {
                    SectionLabel("Agents")
                    ToolRow(icon: "brain", title: "Agents and terminals", line: agentsLine, badge: blockedAgents,
                            enabled: TargetRun.enabled(model, can: canAgents)) {
                        open(canAgents, "Show the agents of") { .agents($0) }
                    }
                    if TargetRun.shows(model, can: hasControl) {
                        ToolRow(icon: "plus", title: "New agent or terminal", line: "Start it in a herdr workspace",
                                enabled: TargetRun.enabled(model, can: canCreate)) {
                            TargetRun.run(model, can: canCreate, title: "Start an agent on") { d in
                                newPane = NewPaneItem(id: d.id)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, TiledMetrics.gutter)
            .padding(.bottom, 24)
            .frame(maxWidth: TiledMetrics.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .tabRoot("Control")
        .sheet(item: $newPane) { item in
            let id = item.id
            NewPaneSheet(deviceId: id) { what, pane in
                newPane = nil
                model.controlPath.append(.feature(what == "terminal" ? .terminal(id, pane) : .agent(id, pane)))
            }
        }
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
        let states = model.core.plugin(HerdrPlugin.self)?.model.states ?? [:]
        return { $0.accepts(PacketType.fluxHerdr) && states[$0.id]?.control == true }
    }

    /// The computers that can open a new agent or terminal now.
    private var canCreate: (DeviceSnapshot) -> Bool {
        let states = model.core.plugin(HerdrPlugin.self)?.model.states ?? [:]
        return { d in
            guard d.accepts(PacketType.fluxHerdr), let h = states[d.id] else { return false }
            return h.running && h.control
        }
    }

    // MARK: Lines

    private func desktopLine(_ one: DeviceSnapshot?) -> String {
        guard let one, let input = model.core.plugin(RemoteInputPlugin.self) else { return "See and use the screen" }
        if !input.model.isDesktopOn(one.id) { return "Off on \(one.name)" }
        if !input.model.isOn(one.id) { return "View only" }
        return "See and use the screen"
    }

    private func mediaLine(_ one: DeviceSnapshot?) -> String {
        guard let one, let title = model.core.plugin(MprisPlugin.self)?.model.media(one.id).player?.title,
              !title.isEmpty else { return "Play, pause, and volume" }
        return title
    }

    /// The paired, online computers in scope.
    private var scoped: [DeviceSnapshot] {
        model.state.devices.filter { $0.paired && $0.online && (model.scope == nil || $0.id == model.scope) }
    }

    private var agentsLine: String {
        let states = model.core.plugin(HerdrPlugin.self)?.model.states ?? [:]
        let agents = scoped.reduce(0) { $0 + (states[$1.id]?.agents.count ?? 0) }
        let terminals = scoped.reduce(0) { $0 + (states[$1.id]?.panes.count ?? 0) }
        return "\(agents) \(agents == 1 ? "agent" : "agents") · \(terminals) \(terminals == 1 ? "terminal" : "terminals")"
    }

    /// The agents in scope that wait for input.
    private var blockedAgents: Int {
        let states = model.core.plugin(HerdrPlugin.self)?.model.states ?? [:]
        return scoped.reduce(0) { $0 + (states[$1.id]?.blocked ?? 0) }
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
