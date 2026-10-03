import FluxKit
import Observation
import SwiftUI
import UIKit

/// The state of the remote desktop of 1 computer: the stream, the zoom,
/// the touches, the keys, the panels, and the dictation. The computer shows
/// its screen while remote_desktop is on, and it takes the touches and the
/// keys while remote_input is on.
@MainActor
@Observable
final class DesktopController {
    enum Panel { case omarchy, keys }

    let deviceId: String
    let plugin: DesktopPlugin
    let input: RemoteInputPlugin
    let keys: RemoteKeys
    let dictation = Dictation()
    @ObservationIgnored let app: AppModel
    /// The name when the screen opened, for a computer that is gone.
    @ObservationIgnored private let firstName: String
    @ObservationIgnored private let sendInput: (Packet) -> Void
    @ObservationIgnored private var touches = DesktopTouches()
    @ObservationIgnored private let hold = Deadline()
    /// True after a dictation typed its text, so that the next one starts with a space.
    @ObservationIgnored private var afterVoice = false
    /// True after the view-only notice showed, so that it shows once.
    @ObservationIgnored private var warned = false
    /// The position of the last click, hold, or move. A new view size keeps it in view.
    @ObservationIgnored private var focus: DesktopPoint?

    /// The panel that shows, or nil.
    var panel: Panel?
    /// The monitor that the user selected. A restart of the stream keeps it.
    private(set) var monitor: String?
    /// The zoom and the pan of the video in its view.
    private(set) var viewport = DesktopViewport(view: .zero, video: DesktopController.placeholderSize)
    /// True after the stream stopped because Flux left the screen.
    private(set) var paused = false
    var voiceError: String?

    /// The shape of the video before the computer tells its size.
    static let placeholderSize = CGSize(width: 16, height: 10)

    init(device: DeviceSnapshot, app: AppModel, plugin: DesktopPlugin, input: RemoteInputPlugin) {
        deviceId = device.id
        firstName = device.name
        self.app = app
        self.plugin = plugin
        self.input = input
        let send = RemoteInputSender.make(deviceId: device.id, app: app, input: input)
        sendInput = send
        let id = device.id
        keys = RemoteKeys(workspaceKeys: DesktopPlugin.shortcutsSupported(device), send: send,
                          canRepeat: { [weak input] in input?.model.canRepeat(id) ?? false })
        keys.willSend = { [weak self] in self?.afterVoice = false }
    }

    var device: DeviceSnapshot? { app.device(deviceId) }
    var name: String { device?.name ?? firstName }
    var desktopOn: Bool { input.model.isDesktopOn(deviceId) }
    var shortcutsSupported: Bool { device.map(DesktopPlugin.shortcutsSupported) ?? false }

    /// True when the computer is online and shows its screen.
    var ready: Bool {
        guard let d = device else { return false }
        return d.paired && d.online && DesktopPlugin.supported(d) && desktopOn
    }

    /// True when the touches and the keys control the computer.
    var control: Bool { ready && input.model.isOn(deviceId) }

    /// The stream of this computer, or nil when the stream shows another computer.
    var status: DesktopModel.Status? { plugin.model.status.deviceId == deviceId ? plugin.model.status : nil }

    /// True while the video shows and has its size.
    var live: Bool { status?.phase == .live && (status?.width ?? 0) > 0 && (status?.height ?? 0) > 0 }

    /// The monitor after the one that shows, for the monitor chip, or nil
    /// when the computer has 1 monitor.
    var nextMonitor: String? {
        guard let s = status, s.monitors.count > 1 else { return nil }
        let i = s.monitors.firstIndex(of: s.monitor) ?? -1
        return s.monitors[(i + 1) % s.monitors.count]
    }

    // MARK: Stream

    /// The longest side of the stream. The iPhone asks for 1920 pixels,
    /// like the Android app: the phone shows less than that at the fit, and
    /// a larger stream costs the computer more to encode, on the CPU with
    /// wf-recorder, and the Wi-Fi more to carry.
    static let maxSize = DesktopPackets.defaultSize

    /// Starts the stream, with the monitor that the user selected.
    func start() {
        guard ready else { return }
        paused = false
        plugin.start(deviceId, monitor: monitor, maxSize: Self.maxSize)
    }

    /// Shows the next monitor of the computer.
    func showNextMonitor() {
        guard let next = nextMonitor else { return }
        monitor = next
        start()
    }

    /// Stops the stream of this computer.
    func stop(_ status: DesktopModel.Status = .init()) {
        endTouches()
        guard self.status?.active == true else { return }
        plugin.stop(status: status)
    }

    /// Stops the stream while Flux is off the screen.
    func pause() {
        guard status?.active == true else { return }
        stop(.init(.idle, "Stopped while Flux was in the background", deviceId: deviceId))
        paused = true
    }

    /// Starts the stream again after a pause.
    func resume() {
        guard paused else { return }
        start()
    }

    /// Ends the screen: the stream stops, and a dictation ends without text.
    func close() {
        dictation.cancel()
        stop()
        keys.mods = .init()
    }

    // MARK: Touches

    /// The view or the video has a new size. A new video starts again at
    /// scale 1. A new view size, for example when the keyboard or a panel
    /// shows, keeps the zoom and keeps the last tapped point in view.
    func layout(view: CGSize) {
        let video = live ? CGSize(width: status?.width ?? 0, height: status?.height ?? 0) : Self.placeholderSize
        let next = viewport.resized(view: view, video: video, focus: video == viewport.video ? focus : nil)
        if next.video != viewport.video { focus = nil }
        if next != viewport { viewport = next }
    }

    /// The fingers on the video after a touch event. The touches work only
    /// on a live video, so that a tap over a wait or an error does not click.
    func touched(_ points: [Int: CGPoint]) {
        guard live else { return }
        run(touches.touches(points, at: Deadline.now, viewport: viewport))
        hold.set(touches.holdDeadline) { [weak self] in
            guard let self else { return }
            self.run(self.touches.holdIfDue(at: Deadline.now, viewport: self.viewport))
        }
    }

    /// iOS took the touches. A drag ends.
    func endTouches() {
        hold.cancel()
        run(touches.cancel(viewport: viewport))
    }

    private func run(_ actions: [DesktopTouches.Action]) {
        for a in actions {
            switch a {
            case .move(let p):
                focus = p
                send(RemoteInput.at(x: p.x, y: p.y))
            case .click(let c, let p):
                // A click can move the cursor of the computer, so the type field ends.
                focus = p
                keys.endTyping()
                send(RemoteInput.clickAt(c, x: p.x, y: p.y))
            case .hold(let down, let p):
                focus = p
                keys.endTyping()
                send(RemoteInput.holdAt(down, x: p.x, y: p.y))
            case .scroll(let dx, let dy): send(RemoteInput.scroll(dx: dx, dy: dy))
            case .viewport(let v): viewport = v
            case .held: HoldFeedback.play()
            }
        }
    }

    /// Sends a touch to the computer. A touch on a view-only screen explains once why nothing happens.
    private func send(_ p: Packet) {
        guard control else {
            if !warned {
                warned = true
                app.show("View only. To control \(name), set remote_input = true on it.")
            }
            return
        }
        sendInput(p)
    }

    // MARK: Panels

    func toggle(_ p: Panel) {
        panel = panel == p ? nil : p
    }

    /// The panel changed. Without the keys panel, the type field ends.
    func panelChanged() {
        if panel != .keys { keys.endTyping() }
    }

    /// Sends a flux.shortcuts packet of the Omarchy panel.
    func shortcut(_ p: Packet) {
        if !plugin.send(p, to: deviceId) { app.show("\(name) is not reachable") }
    }

    // MARK: Dictation

    /// Dictates on the iPhone. The computer types the text at its cursor.
    func dictate() {
        voiceError = nil
        panel = .keys
        if let problem = MicFeature.dictationProblem(app.core) {
            voiceError = problem
            return
        }
        Task { @MainActor [weak self] in
            if let problem = await Dictation.authorize() {
                self?.voiceError = problem
                return
            }
            guard let self else { return }
            // The dictation uses the languages of the iPhone.
            self.dictation.start(language: "", hints: []) { [weak self] spoken in self?.typeSpoken(spoken) }
        }
    }

    /// Types the words of a dictation. A dictation right after another starts with a space.
    private func typeSpoken(_ spoken: String) {
        let words = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard control, !words.isEmpty else { return }
        // The words go to the cursor of the computer, so the type field ends.
        keys.endTyping()
        sendInput(RemoteInput.text(afterVoice ? " " + words : words))
        afterVoice = true
    }
}
