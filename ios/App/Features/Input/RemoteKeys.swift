import FluxKit
import Observation
import SwiftUI
import UIKit

/// The keys that go to 1 computer from the touchpad or the remote desktop:
/// the sticky modifiers, the type field, and the hardware keyboard. A
/// modifier holds for the next key or text only. Super and a digit switch
/// the workspace through flux.shortcuts, because Omarchy binds them to key
/// codes that remote input cannot press.
@MainActor
@Observable
final class RemoteKeys {
    /// The modifiers that the next key or text holds, from the modifier buttons.
    var mods = RemoteInput.Mods()
    /// True when the computer switches the workspace for super and a digit.
    @ObservationIgnored var workspaceKeys: Bool
    /// Runs before each key or text goes out.
    @ObservationIgnored var willSend: (() -> Void)?
    @ObservationIgnored private let sendPacket: (Packet) -> Void

    init(workspaceKeys: Bool, send: @escaping (Packet) -> Void) {
        self.workspaceKeys = workspaceKeys
        sendPacket = send
    }

    private func send(_ p: Packet) {
        willSend?()
        sendPacket(p)
    }

    /// Presses a special key with the held and the sticky modifiers.
    func key(_ k: RemoteInput.Key, held: RemoteInput.Mods = .init()) {
        send(RemoteInput.key(k, mods: held.union(takeMods())))
    }

    /// Types text with the held and the sticky modifiers. `digit` is the
    /// number row key that typed it, for super and a digit.
    func text(_ s: String, held: RemoteInput.Mods = .init(), digit: Int? = nil) {
        guard !s.isEmpty else { return }
        let mods = held.union(takeMods())
        if workspaceKeys, let workspace = DesktopShortcuts.forDigit(digit.map(String.init) ?? s, mods: mods) {
            send(workspace)
            return
        }
        send(RemoteInput.text(s, mods: mods))
    }

    /// Presses Backspace `count` times.
    func backspaces(_ count: Int) {
        for _ in 0..<max(0, count) { send(RemoteInput.key(.backspace)) }
    }

    /// Sends 1 key of a hardware keyboard. It returns false for a key that
    /// stays on the iPhone. `characters` is the text of the key with its
    /// modifiers, for keys that type text, such as Option characters of the
    /// layout. iOS gives no dead key composition outside a text field, so a
    /// dead key types its accent.
    @discardableResult
    func press(_ press: RemoteInput.Press, characters: String, digit: Int?) -> Bool {
        switch press {
        case .key(let k, let held):
            key(k, held: held)
            return true
        case .text(let s, let held):
            text(s, held: held, digit: digit)
            return true
        case .compose:
            let typed = String(characters.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            guard !typed.isEmpty else { return false }
            text(typed, digit: digit)
            return true
        case .ignore:
            return false
        }
    }

    /// Sends 1 key of a hardware keyboard. Command is super, and Option
    /// types the characters of the layout, as on the Mac.
    @discardableResult
    func press(_ key: UIKey) -> Bool {
        press(RemoteInput.press(key: key, optionIsAlt: false, commandIsSuper: true),
              characters: key.characters, digit: RemoteInput.digit(hidUsage: key.keyCode))
    }

    private func takeMods() -> RemoteInput.Mods {
        defer { mods = .init() }
        return mods
    }
}

/// Sends the packets of remote input to 1 computer, and tells when the
/// computer is not reachable.
@MainActor
enum RemoteInputSender {
    static func make(deviceId: String, app: AppModel, input: RemoteInputPlugin) -> (Packet) -> Void {
        { [weak app] p in
            guard let app, !input.send(p, to: deviceId) else { return }
            app.show("\(app.device(deviceId)?.name ?? "The computer") is not reachable")
        }
    }
}

/// The key rows: Escape, Tab, the arrows, and then ctrl, alt, shift, and
/// super, which hold for the next key or text, Backspace, and Enter, like
/// the key panel of the Android app.
struct KeyRows: View {
    @Bindable var keys: RemoteKeys

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                PadKey(label: "esc", name: "Escape") { keys.key(.escape) }
                PadKey(label: "tab", name: "Tab") { keys.key(.tab) }
                PadKey(label: "←", name: "Left") { keys.key(.left) }
                PadKey(label: "↑", name: "Up") { keys.key(.up) }
                PadKey(label: "↓", name: "Down") { keys.key(.down) }
                PadKey(label: "→", name: "Right") { keys.key(.right) }
            }
            HStack(spacing: 6) {
                ModKey(label: "ctrl", isOn: $keys.mods.ctrl)
                ModKey(label: "alt", isOn: $keys.mods.alt)
                ModKey(label: "shift", isOn: $keys.mods.shift)
                ModKey(label: "super", isOn: $keys.mods.meta)
                PadKey(label: "⌫", name: "Backspace") { keys.key(.backspace) }
                PadKey(label: "⏎", name: "Enter") { keys.key(.enter) }
            }
        }
    }
}

/// A key of the panels, with a mono label.
struct PadKey: View {
    let label: String
    let name: String
    var height: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(.separator).opacity(0.5)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }
}

/// A modifier key. It stays on for the next key or text.
private struct ModKey: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(label)
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isOn ? Color.accentColor.opacity(0.15) : Color(.secondarySystemGroupedBackground)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isOn ? Color.accentColor : Color(.separator).opacity(0.5)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(isOn ? "Releases \(label)" : "Holds \(label) for the next key")
    }
}
