import FluxKit
import Observation
import SwiftUI
import UIKit

/// The keys that go to 1 computer from the touchpad or the remote desktop:
/// the sticky modifiers, the type field, the draft, and the hardware
/// keyboard. A modifier holds for the next key or text only. Super and a
/// digit switch the workspace through flux.shortcuts, because Omarchy
/// binds them to key codes that remote input cannot press.
///
/// The type field shows the text that it typed on the computer since the
/// last click, key, or dictation. Its clear key deletes that text on the
/// computer. Each other input can move the cursor of the computer, so it
/// ends the field: the field empties, and no key goes out.
@MainActor
@Observable
final class RemoteKeys {
    /// The modifiers that the next key or text holds, from the modifier buttons.
    var mods = RemoteInput.Mods()
    /// The text of the type field, also the text that the keyboard composes.
    /// The clear key shows while it is not empty.
    private(set) var fieldText = ""
    /// The text of the draft editor. It stays while the screen shows.
    var draft = ""
    /// True while the draft editor shows.
    var drafting = false
    /// True when the computer switches the workspace for super and a digit.
    @ObservationIgnored var workspaceKeys: Bool
    /// Runs before each key or text goes out.
    @ObservationIgnored var willSend: (() -> Void)?
    /// True while the type field has the keyboard focus. A touch on the
    /// video then keeps the keyboard of the iPhone, and the field shows the
    /// key that hides the keyboard.
    var fieldFocused = false
    /// Sets the text of the type field that shows, or nil without a field.
    @ObservationIgnored var setField: ((String) -> Void)?
    /// The text of the type field that the computer has.
    @ObservationIgnored private var buffer = TypeBuffer()
    @ObservationIgnored private let sendPacket: (Packet) -> Void
    @ObservationIgnored private let canRepeat: @MainActor () -> Bool

    /// `canRepeat` tells whether 1 packet can press a key many times on the computer.
    init(workspaceKeys: Bool, send: @escaping (Packet) -> Void, canRepeat: @escaping @MainActor () -> Bool = { false }) {
        self.workspaceKeys = workspaceKeys
        sendPacket = send
        self.canRepeat = canRepeat
    }

    private func send(_ p: Packet) {
        willSend?()
        sendPacket(p)
    }

    /// Presses a special key with the held and the sticky modifiers. The
    /// Backspace key without modifiers deletes the last character of the
    /// type field. Each other key ends the type field.
    func key(_ k: RemoteInput.Key, held: RemoteInput.Mods = .init()) {
        let mods = held.union(takeMods())
        if k == .backspace && !mods.any {
            let count = buffer.dropLast()
            if count > 0 {
                showField(buffer.sent)
                backspaces(count)
                return
            }
        }
        endTyping()
        send(RemoteInput.key(k, mods: mods))
    }

    /// Types text with the held and the sticky modifiers, for a shortcut or
    /// a key of a hardware keyboard. `digit` is the number row key that
    /// typed it, for super and a digit. It ends the type field.
    func text(_ s: String, held: RemoteInput.Mods = .init(), digit: Int? = nil) {
        guard !s.isEmpty else { return }
        endTyping()
        sendText(s, held: held, digit: digit)
    }

    private func sendText(_ s: String, held: RemoteInput.Mods = .init(), digit: Int? = nil) {
        guard !s.isEmpty else { return }
        let mods = held.union(takeMods())
        if workspaceKeys, let workspace = DesktopShortcuts.forDigit(digit.map(String.init) ?? s, mods: mods) {
            send(workspace)
            return
        }
        send(RemoteInput.text(s, mods: mods))
    }

    /// Presses Backspace `count` times, with 1 packet when the computer can.
    private func backspaces(_ count: Int) {
        for p in RemoteInput.keys(.backspace, count: count, repeat: canRepeat()) { send(p) }
    }

    // MARK: Type field

    /// Handles a change of the type field. `shown` is all text of the
    /// field, and `stable` leaves out the text that the keyboard composes
    /// at the end. It returns true when the field must empty, after a
    /// shortcut such as ctrl and c. A fluxd without keyRepeat presses 1 key
    /// for each packet, so for it a long field empties after a word, and a
    /// clear or an edit needs few Backspace packets.
    func fieldChanged(shown: String, stable: String, composing: Bool) -> Bool {
        switch buffer.change(stable, composing: composing, modsHeld: mods.any, restart: !canRepeat()) {
        case .edit(let count, let typed, let clear):
            fieldText = clear ? "" : shown
            backspaces(count)
            sendText(typed)
            return clear
        case .shortcut(let typed):
            fieldText = ""
            sendText(typed)
            return true
        }
    }

    /// Enter in the type field: the field empties, and Enter goes out.
    func fieldReturn() {
        key(.enter)
    }

    /// Deletes the text that the type field typed on the computer, then
    /// empties the field. Text that the keyboard composes did not go out,
    /// so it only goes away.
    func clearTyped() {
        let count = buffer.clear()
        showField("")
        backspaces(count)
    }

    /// Ends the type field: the field empties, and no key goes out. The
    /// computer keeps the text. Call it after each input that can move the
    /// cursor of the computer, such as a click or a dictation.
    func endTyping() {
        buffer.reset()
        showField("")
    }

    private func showField(_ text: String) {
        fieldText = text
        setField?(text)
    }

    // MARK: Draft

    /// True when the draft has text to type.
    var canTypeDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Types the draft on the computer: each line as text, and Shift+Enter
    /// between the lines. The type field ends, the sticky modifiers turn
    /// off, and the draft empties.
    func typeDraft() {
        let packets = RemoteInput.draft(RemoteInput.limitDraft(draft))
        guard canTypeDraft, !packets.isEmpty else { return }
        endTyping()
        mods = .init()
        for p in packets { send(p) }
        draft = ""
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
