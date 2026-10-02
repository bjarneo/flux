import AppKit
import FluxKit
import SwiftUI

/// Control: the tools that act on the computer in scope. Remote desktop is
/// the master tool, because the Omarchy panel needs the desktop window on
/// the Mac. The touchpad and the remote desktop ask for Touch ID first.
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
        let desktop = ToolTarget.of(model, can: { DesktopPlugin.supported($0) && input?.model.isDesktopOn($0.id) == true })
        let touchpad = ToolTarget.of(model, can: { RemoteInputPlugin.supported($0) && input?.model.isOn($0.id) == true })
        let commands = ToolTarget.of(model, can: { $0.accepts(PacketType.runCommandRequest) })
        let media = ToolTarget.of(model, can: { $0.accepts(PacketType.mprisRequest) })
        let mic = ToolTarget.of(model, can: { $0.isFlux })
        let stream = ToolTarget.of(model)
        let agents = ToolTarget.of(model, can: { $0.accepts(PacketType.fluxHerdr) })
        let hasDesktop = Inbox.hasFeature(scope: scope, devices: devices, can: { DesktopPlugin.supported($0) })
        let hasInput = Inbox.hasFeature(scope: scope, devices: devices, can: { RemoteInputPlugin.supported($0) })
        let hasHerdr = Inbox.hasFeature(scope: scope, devices: devices, can: { $0.accepts(PacketType.fluxHerdr) })
        let herdrStates = model.connectedPaired
            .filter { scope == nil || $0.id == scope }
            .compactMap { herdr?.model.states[$0.id] }
        ScrollView {
            VStack(alignment: .leading, spacing: TiledMetrics.gap) {
                TargetLine(verb: "Acts on")
                if input != nil && (noPairing || hasDesktop) {
                    MasterTool(icon: "display", title: "Remote desktop",
                               line: desktopLine(desktop, input: input),
                               enabled: ToolTarget.ready(desktop)) {
                        ToolTarget.run(desktop, title: "Show the screen of", ask: $ask) { d in
                            DesktopWindows.shared.open(d, app: model)
                        }
                    }
                }
                if input != nil && (noPairing || hasInput) {
                    ToolRow(icon: "cursorarrow.motionlines", title: "Touchpad and keyboard",
                            line: offLine(touchpad, supported: RemoteInputPlugin.supported) ?? "Pointer, keys, and slides",
                            enabled: ToolTarget.ready(touchpad)) {
                        ToolTarget.run(touchpad, title: "Control the pointer of", ask: $ask) { d in
                            TouchpadWindows.shared.open(d, app: model)
                        }
                    }
                }
                if model.core.plugin(RunCommandPlugin.self) != nil {
                    ToolRow(icon: "terminal", title: "Commands", line: "Run the commands of the computer",
                            enabled: ToolTarget.ready(commands)) {
                        ToolTarget.run(commands, title: "Run the commands of", ask: $ask) { d in
                            model.push(.card(.commands, d.id))
                        }
                    }
                }
                if mpris != nil {
                    ToolRow(icon: "music.note", title: "Media", line: mediaLine(media, mpris: mpris),
                            enabled: ToolTarget.ready(media)) {
                        ToolTarget.run(media, title: "Control the media of", ask: $ask) { d in
                            model.push(.card(.media, d.id))
                        }
                    }
                }
                SectionLabel("Stream")
                if model.core.plugin(MicPlugin.self) != nil {
                    ToolRow(icon: "mic", title: "Mic", line: "Use this Mac as a microphone", enabled: ToolTarget.ready(mic)) {
                        ToolTarget.run(mic, title: "Use the microphone of this Mac on", ask: $ask) { d in
                            model.push(.card(.mic, d.id))
                        }
                    }
                }
                if model.core.plugin(WebcamPlugin.self) != nil || model.core.plugin(ScreenPlugin.self) != nil {
                    ToolRow(icon: "web.camera", title: "Webcam and screen mirror", line: "Use the camera or a display of this Mac",
                            enabled: ToolTarget.ready(stream)) {
                        ToolTarget.run(stream, title: "Stream to", ask: $ask) { d in
                            model.push(.card(.stream, d.id))
                        }
                    }
                }
                if herdr != nil && (noPairing || hasHerdr) {
                    SectionLabel("Agents")
                    ToolRow(icon: "brain", title: "Agents and terminals", line: agentsLine(herdrStates),
                            badge: herdrStates.reduce(0) { $0 + $1.blocked },
                            enabled: ToolTarget.ready(agents)) {
                        ToolTarget.run(agents, title: "Open the agents of", ask: $ask) { d in
                            AgentsWindows.shared.show(d.id, app: model)
                        }
                    }
                }
            }
            .padding(.horizontal, TiledMetrics.gutter)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: TiledMetrics.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .targetPicker($ask)
        .destinationRoot(.control)
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
        return "See and use the screen, with the Omarchy panel"
    }

    /// The title that plays on the computer, else the default line.
    private func mediaLine(_ target: ActionTarget, mpris: MprisPlugin?) -> String {
        if let d = ToolTarget.single(target), let player = mpris?.model.media(d.id).player, player.playing, !player.title.isEmpty {
            return player.title
        }
        return "Play, pause, and volume"
    }

    /// "<n> agents · <m> terminals" of the computers in scope.
    private func agentsLine(_ states: [HerdrState]) -> String {
        guard !states.isEmpty else { return "Read the agents and answer them" }
        let agents = states.reduce(0) { $0 + $1.agents.count }
        let terminals = states.reduce(0) { $0 + $1.panes.count }
        return "\(agents) \(agents == 1 ? "agent" : "agents") · \(terminals) \(terminals == 1 ? "terminal" : "terminals")"
    }
}
