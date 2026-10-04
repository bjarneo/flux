import AppKit
import FluxKit
import Observation

/// The state of the remote desktop window of 1 computer: the stream, the
/// mouse over the video, the keys, the panels, and the dictation. The
/// computer shows its screen while remote_desktop is on, and it takes the
/// mouse and the keys while remote_input is on.
@MainActor
@Observable
final class DesktopController: RemoteKeyTarget {
    enum Panel { case omarchy, keys }

    let deviceId: String
    let plugin: DesktopPlugin
    let input: RemoteInputPlugin
    let dictation = Dictation()
    @ObservationIgnored let app: AppModel
    /// The name when the window opened, for a computer that is gone.
    @ObservationIgnored private let firstName: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var pointer = DesktopPointer()
    @ObservationIgnored private var throttle = MotionThrottle()
    @ObservationIgnored private var flush: Task<Void, Never>?
    /// True after a dictation typed its text, so that the next one starts with a space.
    @ObservationIgnored private var afterVoice = false
    /// Waits for the permissions of a new dictation. `close` cancels it.
    @ObservationIgnored private var starting: Task<Void, Never>?

    /// The panel that shows, or nil.
    var panel: Panel?
    var mods = RemoteInput.Mods()
    var fieldText = ""
    var draft = ""
    var optionIsAlt: Bool {
        didSet { defaults.set(optionIsAlt, forKey: optionIsAltKey) }
    }
    /// True while the pointer of this Mac is over the video.
    var pointerInside = false
    /// The monitor that the user selected. A restart of the stream keeps it.
    var monitor: String?
    /// True after the stream stopped because this Mac slept, locked, or hid
    /// the window, or when it was to start while `hidden`. `resume` starts it.
    private(set) var paused = false
    /// True while this Mac sleeps or locks, or the window is in the Dock.
    /// The stream does not start then, also not after a reconnect.
    private(set) var hidden = false
    /// True after a click on a view-only screen, to explain it.
    var viewOnlyNotice = false
    var voiceError: String?
    var audioOn = false
    private var previousAudioVolume: Double = 1
    var audioVolume: Double = 1 {
        didSet { if audioVolume > 0 { previousAudioVolume = audioVolume }; plugin.setAudioVolume(Float(audioVolume)) }
    }

    func toggleAudio() { audioOn.toggle(); start() }
    func toggleMute() { audioVolume = audioVolume == 0 ? previousAudioVolume : 0 }

    init(device: DeviceSnapshot, app: AppModel, plugin: DesktopPlugin, input: RemoteInputPlugin) {
        deviceId = device.id
        firstName = device.name
        self.app = app
        self.plugin = plugin
        self.input = input
        defaults = app.core.defaults
        optionIsAlt = app.core.defaults.bool(forKey: optionIsAltKey)
    }

    var device: DeviceSnapshot? { app.state.devices.first { $0.id == deviceId } }
    var name: String { device?.name ?? firstName }
    var desktopOn: Bool { input.model.isDesktopOn(deviceId) }
    var shortcutsSupported: Bool { device.map(DesktopPlugin.shortcutsSupported) ?? false }

    /// True when the computer is online and shows its screen.
    var ready: Bool {
        guard let d = device else { return false }
        return d.paired && d.online && DesktopPlugin.supported(d) && desktopOn
    }

    /// True when the mouse and the keys control the computer.
    var control: Bool { ready && input.model.isOn(deviceId) }

    /// The stream of this computer, or nil when the stream shows another computer.
    var status: DesktopModel.Status? { plugin.model.status.deviceId == deviceId ? plugin.model.status : nil }

    /// True while the video shows and has its size.
    var live: Bool { status?.phase == .live && (status?.width ?? 0) > 0 && (status?.height ?? 0) > 0 }

    // MARK: RemoteKeyTarget

    var keysReady: Bool { control }
    /// Command is Super while the pointer is over the video.
    var commandIsSuper: Bool { pointerInside && live }
    var workspaceKeys: Bool { shortcutsSupported }

    func send(_ packets: [Packet]) {
        afterVoice = false
        sendPointer(packets)
    }

    // MARK: Stream

    /// Starts the stream, with the monitor that the user selected. While
    /// `hidden`, it only marks the stream to start at `resume`.
    func start() {
        guard ready else { return }
        if hidden {
            paused = true
            return
        }
        paused = false
        plugin.start(deviceId, monitor: monitor, maxSize: Self.maxSize(), audio: audioOn)
    }

    /// Shows another monitor of the computer.
    func show(monitor m: String) {
        monitor = m
        start()
    }

    /// Stops the stream of this computer.
    func stop(_ status: DesktopModel.Status = .init()) {
        endPointer()
        guard self.status?.active == true else { return }
        plugin.stop(status: status)
    }

    /// Stops the stream while this Mac sleeps, locks, or hides the window.
    func pause(_ reason: String) {
        hidden = true
        guard status?.active == true else { return }
        stop(.init(.idle, reason, deviceId: deviceId))
        paused = true
    }

    /// Starts the stream again after a pause, when this Mac and the window are back.
    func resume() {
        hidden = false
        guard paused else { return }
        paused = false
        start()
    }

    /// Ends the window: the stream stops, and a dictation ends without text.
    func close() {
        starting?.cancel()
        dictation.cancel()
        stop()
        mods = .init()
    }

    /// The longest side of the stream: the longest side of the screen of
    /// this Mac in pixels, from 640 to 3840.
    private static func maxSize() -> Int {
        guard let screen = NSScreen.main else { return DesktopPackets.defaultSize }
        let side = max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor
        return DesktopPackets.size(forScreen: Int(side))
    }

    // MARK: Pointer

    /// The pointer of this Mac moves over the video. The computer pointer
    /// follows, at most 60 times each second.
    func hover(_ at: DesktopPoint?) {
        guard control, live, let at else { return }
        if let p = throttle.move(to: at, now: Self.now()) {
            sendPointer([RemoteInput.at(x: p.x, y: p.y)])
        } else if throttle.pending != nil && flush == nil {
            flush = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(17))
                guard let self else { return }
                self.flush = nil
                if let p = self.throttle.flush(now: Self.now()) { self.sendPointer([RemoteInput.at(x: p.x, y: p.y)]) }
            }
        }
    }

    func leftDown(_ point: CGPoint, at: DesktopPoint) {
        guard allowed() else { return }
        cancelFlush()
        pointer.leftDown(point, at: at)
    }

    func leftDragged(_ point: CGPoint, at: DesktopPoint) {
        guard control else { return }
        sendPointer(pointer.leftDragged(point, at: at))
    }

    func leftUp(_ point: CGPoint, at: DesktopPoint, clickCount: Int) {
        guard control, pointer.pressed else { return }
        sendPointer(pointer.leftUp(point, at: at, clickCount: clickCount))
        throttle.reset(sent: at, now: Self.now())
    }

    func click(_ c: RemoteInput.Click, at: DesktopPoint) {
        guard allowed() else { return }
        cancelFlush()
        sendPointer([RemoteInput.clickAt(c, x: at.x, y: at.y)])
        throttle.reset(sent: at, now: Self.now())
    }

    /// Scrolls the window under the pointer. `scale` is the view points for
    /// 1 video pixel, so that the content moves as far as the fingers.
    func scrolled(_ event: NSEvent, at: DesktopPoint, scale: Double) {
        guard control, scale > 0,
              let p = RemoteInput.scroll(macDeltaX: event.scrollingDeltaX, macDeltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas),
              let dx = p.double("dx"), let dy = p.double("dy") else { return }
        let factor = event.hasPreciseScrollingDeltas ? 1 / scale : 1
        sendPointer([RemoteInput.scrollAt(dx: dx * factor, dy: dy * factor, x: at.x, y: at.y)])
    }

    /// Ends a drag, for example when the window closes.
    func endPointer() {
        cancelFlush()
        sendPointer(pointer.cancel(at: nil))
    }

    /// True when a click may go to the computer. A click on a view-only
    /// screen explains why nothing happens.
    private func allowed() -> Bool {
        guard live else { return false }
        if !control { viewOnlyNotice = true }
        return control
    }

    private func cancelFlush() {
        flush?.cancel()
        flush = nil
    }

    private func sendPointer(_ packets: [Packet]) {
        for p in packets { input.send(p, to: deviceId) }
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Omarchy panel

    /// Sends a flux.shortcuts packet of the Omarchy panel.
    func shortcut(_ p: Packet) {
        if !plugin.send(p, to: deviceId) { app.show("\(name) is not reachable") }
    }

    func toggle(_ p: Panel) {
        panel = panel == p ? nil : p
    }

    // MARK: Dictation

    /// Dictates on this Mac. The computer types the text at its cursor.
    func dictate() {
        voiceError = nil
        panel = .keys
        let language = app.core.plugin(HerdrPlugin.self)?.model.dictationLanguage ?? ""
        starting?.cancel()
        starting = Task { @MainActor [weak self] in
            let problem = await Dictation.authorize()
            // The window closed while macOS asked for the permissions.
            guard !Task.isCancelled, let self else { return }
            if let problem {
                self.voiceError = problem
                return
            }
            self.dictation.start(language: language, hints: []) { [weak self] spoken in self?.typeSpoken(spoken) }
        }
    }

    /// Types the words of a dictation. A dictation right after another starts with a space.
    private func typeSpoken(_ spoken: String) {
        let words = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard control, !words.isEmpty else { return }
        sendPointer([RemoteInput.text(afterVoice ? " " + words : words)])
        afterVoice = true
    }
}
