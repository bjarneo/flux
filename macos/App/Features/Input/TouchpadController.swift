import AppKit
import FluxKit
import Observation

/// The state of 1 touchpad window. While the pad holds the pointer, the
/// cursor of this Mac hides and stays still, and each motion, click, scroll,
/// and key goes to the computer.
@MainActor
@Observable
final class TouchpadController: RemoteKeyTarget {
    let deviceId: String
    let plugin: RemoteInputPlugin
    /// The name when the window opened, for a computer that is gone.
    @ObservationIgnored private let firstName: String
    @ObservationIgnored let app: AppModel
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var tracker = PointerTracker()
    /// True after a dictation typed its text, so that the next one starts with a space.
    @ObservationIgnored private var afterVoice = false

    /// True while the pad holds the pointer of this Mac.
    private(set) var captured = false
    /// True while the pad has the keyboard focus, so that keys go to the computer.
    var padFocused = false
    var mods = RemoteInput.Mods()
    var optionIsAlt: Bool {
        didSet { defaults.set(optionIsAlt, forKey: optionIsAltKey) }
    }

    init(device: DeviceSnapshot, app: AppModel, plugin: RemoteInputPlugin) {
        deviceId = device.id
        firstName = device.name
        self.app = app
        self.plugin = plugin
        defaults = app.core.defaults
        optionIsAlt = app.core.defaults.bool(forKey: optionIsAltKey)
    }

    var device: DeviceSnapshot? { app.state.devices.first { $0.id == deviceId } }
    var name: String { device?.name ?? firstName }

    /// True when the computer is online and runs the input.
    var ready: Bool {
        guard let d = device else { return false }
        return d.paired && d.online && RemoteInputPlugin.supported(d) && plugin.model.isOn(deviceId)
    }

    var keysReady: Bool { ready }
    /// Command is Super while the pad holds the pointer.
    var commandIsSuper: Bool { captured }
    var workspaceKeys: Bool { device.map(DesktopPlugin.shortcutsSupported) ?? false }

    // MARK: Pointer

    /// Takes the pointer of this Mac: the cursor hides and stays still, and
    /// the motion goes to the computer.
    func capture() {
        guard ready, !captured else { return }
        _ = CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        captured = true
    }

    /// Gives the pointer back to this Mac. A drag on the computer ends.
    func release() {
        guard captured else { return }
        post(tracker.cancel())
        _ = CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        captured = false
    }

    func leftDown() { tracker.leftDown() }
    func leftUp() { send(tracker.leftUp()) }
    func moved(dx: Double, dy: Double) { post(tracker.move(dx: dx, dy: dy)) }
    func click(_ c: RemoteInput.Click) { send([RemoteInput.click(c)]) }

    func scrolled(_ event: NSEvent) {
        guard let p = RemoteInput.scroll(macDeltaX: event.scrollingDeltaX, macDeltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas) else { return }
        post([p])
    }

    /// Ends the window: the pointer comes back, and the modifiers clear.
    func close() {
        release()
        mods = .init()
    }

    /// Sends keys and clicks. They can move the cursor of the computer, so the next dictation starts with no space.
    func send(_ packets: [Packet]) {
        afterVoice = false
        post(packets)
    }

    /// Types the words of a dictation. A dictation right after another starts with a space.
    func typeSpoken(_ spoken: String) {
        let words = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready, !words.isEmpty else { return }
        post([RemoteInput.text(afterVoice ? " " + words : words)])
        afterVoice = true
    }

    /// Sends packets that do not move the cursor of the computer: motion and scrolls.
    private func post(_ packets: [Packet]) {
        for p in packets { plugin.send(p, to: deviceId) }
    }
}
