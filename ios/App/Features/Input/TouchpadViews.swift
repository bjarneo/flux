import FluxKit
import Observation
import SwiftUI
import UIKit

/// Opens the touchpad and the keyboard of a computer that takes remote
/// input. Remote input can type in any window of the computer, so the tile
/// asks for Face ID or the passcode first, like the Android app.
struct TouchpadTile: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if RemoteInputPlugin.supported(device), let input = model.core.plugin(RemoteInputPlugin.self) {
            let on = input.model.isOn(device.id)
            FeatureTile("Touchpad", systemImage: "hand.point.up.left", tint: .green, subtitle: on ? "Pointer and keys" : "Off") {
                let route = Route.feature(.touchpad(device.id))
                guard on else { return model.path.append(route) }
                ReplyLock.run(reason: "Use the touchpad of \(device.name).") {
                    model.path.append(route)
                } onError: { model.show($0) }
            }
            .disabled(!device.online)
        }
    }
}

/// The state of the touchpad of 1 computer: the gestures, the buttons, and the keys.
@MainActor
@Observable
final class TouchpadController {
    let deviceId: String
    let keys: RemoteKeys
    /// True while the left button is held with the button under the pad.
    var leftHeld = false
    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private let send: (Packet) -> Void
    @ObservationIgnored private var gesture = TouchpadGesture()
    @ObservationIgnored private let hold = Deadline()
    @ObservationIgnored private var spoken = SpokenSpacing()

    init(deviceId: String, app: AppModel, input: RemoteInputPlugin) {
        self.deviceId = deviceId
        self.app = app
        send = RemoteInputSender.make(deviceId: deviceId, app: app, input: input)
        keys = RemoteKeys(workspaceKeys: app.device(deviceId).map(DesktopPlugin.shortcutsSupported) ?? false, send: send)
        // Keys can move the cursor of the computer, so the next dictation starts with no space.
        keys.willSend = { [weak self] in self?.spoken.moved() }
    }

    var name: String { app.device(deviceId)?.name ?? "The computer" }

    func touches(_ points: [Int: CGPoint]) {
        run(gesture.touches(points, at: Deadline.now))
        armHold()
    }

    func cancel() {
        hold.cancel()
        run(gesture.cancel())
    }

    /// The left button under the pad, for a drag with 2 hands.
    func left(_ down: Bool) {
        guard leftHeld != down else { return }
        leftHeld = down
        spoken.moved()
        send(RemoteInput.hold(down))
    }

    func rightClick() {
        spoken.moved()
        send(RemoteInput.click(.right))
    }

    /// Types the words of a dictation on the computer. A dictation right
    /// after another starts with a space.
    func typeSpoken(_ words: String) {
        guard let text = spoken.text(words) else { return }
        send(RemoteInput.text(text))
    }

    /// Ends a drag when the screen closes.
    func close() {
        cancel()
        left(false)
        keys.mods = .init()
    }

    private func armHold() {
        hold.set(gesture.holdDeadline) { [weak self] in
            guard let self else { return }
            self.run(self.gesture.holdIfDue(at: Deadline.now))
        }
    }

    private func run(_ actions: [TouchpadGesture.Action]) {
        for a in actions {
            switch a {
            case .move(let dx, let dy): send(RemoteInput.move(dx: dx, dy: dy))
            case .scroll(let dx, let dy): send(RemoteInput.scroll(dx: dx, dy: dy))
            case .click(let c):
                // A click can move the cursor of the computer.
                spoken.moved()
                send(RemoteInput.click(c))
            case .hold(let down):
                if down { HoldFeedback.play() }
                spoken.moved()
                send(RemoteInput.hold(down))
            }
        }
    }

}

/// The text that a dictation types on a computer. A dictation right after
/// another starts with a space. After a key or a click, the cursor of the
/// computer can be elsewhere, so the next dictation starts with no space.
struct SpokenSpacing {
    private var afterVoice = false

    /// The text to type for the words, or nil for no words.
    mutating func text(_ spoken: String) -> String? {
        let words = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return nil }
        defer { afterVoice = true }
        return afterVoice ? " " + words : words
    }

    /// Notes a key or a click.
    mutating func moved() { afterVoice = false }
}

/// The touchpad and the keyboard for a computer. The computer runs the
/// input only while its remote_input setting is on.
struct TouchpadScreen: View {
    @Environment(AppModel.self) private var model
    let deviceId: String

    var body: some View {
        Group {
            if let device = model.device(deviceId), let input = model.core.plugin(RemoteInputPlugin.self) {
                if !device.online {
                    ContentUnavailableView("\(device.name) is not reachable", systemImage: "wifi.slash",
                                           description: Text("The touchpad works when \(device.name) is connected."))
                } else if !RemoteInputPlugin.supported(device) {
                    ContentUnavailableView("Update Flux on \(device.name)", systemImage: "hand.point.up.left",
                                           description: Text("This version of Flux on \(device.name) does not take input from the iPhone."))
                } else if !input.model.isOn(device.id) {
                    ContentUnavailableView("Remote input is off", systemImage: "hand.point.up.left",
                                           description: Text("On \(device.name), set `remote_input = true` in `~/.config/flux/config.toml`, then run `systemctl --user reload fluxd`."))
                } else {
                    TouchpadContent(deviceId: device.id, input: input)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Touchpad")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TouchpadContent: View {
    @Environment(AppModel.self) private var model
    let deviceId: String
    let input: RemoteInputPlugin
    @State private var controller: TouchpadController?

    var body: some View {
        VStack(spacing: 10) {
            if let controller {
                Pad(controller: controller)
                HStack(spacing: 10) {
                    HoldKey(controller: controller)
                    PadKey(label: "right", name: "Right button", height: 52) { controller.rightClick() }
                }
                KeyRows(keys: controller.keys)
                // A dictation types its words on the computer.
                VoiceField(onText: { controller.typeSpoken($0) }) {
                    TypeField(keys: controller.keys, placeholder: "Type on \(model.device(deviceId)?.name ?? "the computer")")
                        .frame(height: 44)
                        .padding(.horizontal, 12)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(.separator).opacity(0.5)))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .padding(.top, 6)
        .onAppear {
            if controller == nil { controller = TouchpadController(deviceId: deviceId, app: model, input: input) }
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            controller?.close()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

/// The pad: it reports the fingers to the controller and takes the keys of a hardware keyboard.
private struct Pad: View {
    let controller: TouchpadController

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground))
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(.separator).opacity(0.5))
            Text("1 finger moves · tap clicks\n2 fingers scroll · tap for the right button\nHold still to drag")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .accessibilityHidden(true)
            TouchSurface(controller: controller)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Touchpad")
        .accessibilityHint("Move 1 finger to move the pointer, and tap to click")
    }

    private struct TouchSurface: UIViewRepresentable {
        let controller: TouchpadController

        func makeUIView(context: Context) -> TouchSurfaceView {
            let view = TouchSurfaceView()
            view.backgroundColor = .clear
            update(view)
            return view
        }

        func updateUIView(_ view: TouchSurfaceView, context: Context) { update(view) }

        private func update(_ view: TouchSurfaceView) {
            let controller = controller
            view.onTouches = { controller.touches($0) }
            view.onCancel = { controller.cancel() }
            view.onKey = { controller.keys.press($0) }
        }
    }
}

/// The left button: it stays down while the finger is on it, for a drag
/// with the other hand.
private struct HoldKey: View {
    let controller: TouchpadController

    var body: some View {
        let down = controller.leftHeld
        Text("left")
            .font(.system(.subheadline, design: .monospaced, weight: .semibold))
            .foregroundStyle(down ? Color.green : .secondary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(down ? Color.green.opacity(0.15) : Color(.secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(down ? Color.green : Color(.separator).opacity(0.5)))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in controller.left(true) }
                    .onEnded { _ in controller.left(false) }
            )
            .accessibilityLabel("Left button")
            .accessibilityHint("Stays down while you hold it")
            .accessibilityAddTraits(.isButton)
    }
}
