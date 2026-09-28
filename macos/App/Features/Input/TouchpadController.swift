import AppKit
import FluxKit
import Observation

/// The state of 1 touchpad window. While the pad holds the pointer, the
/// cursor of this Mac hides and stays still, and each motion, click, scroll,
/// and key goes to the computer.
@MainActor
@Observable
final class TouchpadController {
    static let optionKey = "input.optionIsAlt"

    let deviceId: String
    let plugin: RemoteInputPlugin
    /// The name when the window opened, for a computer that is gone.
    @ObservationIgnored private let firstName: String
    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var tracker = PointerTracker()

    /// True while the pad holds the pointer of this Mac.
    private(set) var captured = false
    /// True while the pad has the keyboard focus, so that keys go to the computer.
    var padFocused = false
    /// The modifiers that the next key or text holds, from the modifier buttons.
    var mods = RemoteInput.Mods()
    /// Option is Alt for letters too. Off, Option types the characters of
    /// the Mac layout, such as @ on a Nordic keyboard.
    var optionIsAlt: Bool {
        didSet { defaults.set(optionIsAlt, forKey: Self.optionKey) }
    }

    init(device: DeviceSnapshot, app: AppModel, plugin: RemoteInputPlugin) {
        deviceId = device.id
        firstName = device.name
        self.app = app
        self.plugin = plugin
        defaults = app.core.defaults
        optionIsAlt = app.core.defaults.bool(forKey: Self.optionKey)
    }

    var device: DeviceSnapshot? { app.state.devices.first { $0.id == deviceId } }
    var name: String { device?.name ?? firstName }

    /// True when the computer is online and runs the input.
    var ready: Bool {
        guard let d = device else { return false }
        return d.paired && d.online && RemoteInputPlugin.supported(d) && plugin.model.isOn(deviceId)
    }

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
        send(tracker.cancel())
        _ = CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        captured = false
    }

    func leftDown() { tracker.leftDown() }
    func leftUp() { send(tracker.leftUp()) }
    func moved(dx: Double, dy: Double) { send(tracker.move(dx: dx, dy: dy)) }
    func click(_ c: RemoteInput.Click) { send([RemoteInput.click(c)]) }

    func scrolled(_ event: NSEvent) {
        guard let p = RemoteInput.scroll(macDeltaX: event.scrollingDeltaX, macDeltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas) else { return }
        send([p])
    }

    // MARK: Keys

    /// Presses a special key with the held and the sticky modifiers.
    func key(_ k: RemoteInput.Key, held: RemoteInput.Mods = .init()) {
        send([RemoteInput.key(k, mods: held.union(takeMods()))])
    }

    /// Types text with the held and the sticky modifiers.
    func text(_ s: String, held: RemoteInput.Mods = .init()) {
        guard !s.isEmpty else { return }
        send([RemoteInput.text(s, mods: held.union(takeMods()))])
    }

    /// Handles a change of the type field and returns the text that stays in
    /// it. Each word goes out after its space. With a sticky modifier, the
    /// text goes out at once as a shortcut, such as ctrl and c.
    func fieldChanged(_ value: String) -> String {
        if mods.any && !value.isEmpty {
            text(value)
            return ""
        }
        let (words, keep) = RemoteInput.words(value)
        text(words)
        return keep
    }

    /// Return in the type field sends the rest of the text and presses Enter.
    func fieldReturn(_ value: String) {
        text(value)
        key(.enter)
    }

    /// Ends the window: the pointer comes back, and the modifiers clear.
    func close() {
        release()
        mods = .init()
    }

    private func takeMods() -> RemoteInput.Mods {
        defer { mods = .init() }
        return mods
    }

    private func send(_ packets: [Packet]) {
        for p in packets { plugin.send(p, to: deviceId) }
    }
}
