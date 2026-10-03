import AppKit
import FluxKit
import SwiftUI

/// A window that types on the computer: the touchpad or the remote desktop.
/// The extension holds the rules that both share: the sticky modifiers, the
/// type field, and super with a digit for the workspaces.
@MainActor
protocol RemoteKeyTarget: AnyObject {
    /// True when keys go to the computer.
    var keysReady: Bool { get }
    /// Option is Alt for letters too. Off, Option types the characters of
    /// the Mac layout, such as @ on a Nordic keyboard.
    var optionIsAlt: Bool { get set }
    /// True when Command is Super. Else this Mac keeps its Command shortcuts.
    var commandIsSuper: Bool { get }
    /// True when the computer switches the workspace for super and a digit.
    var workspaceKeys: Bool { get }
    /// The modifiers that the next key or text holds, from the modifier buttons.
    var mods: RemoteInput.Mods { get set }
    /// The name of the computer, for the labels.
    var name: String { get }
    /// The text that waits in the type field: the rest after the last word that went out.
    var fieldText: String { get set }
    /// The text of the draft editor. It stays after the editor closes.
    var draft: String { get set }
    func send(_ packets: [Packet])
}

/// The defaults key of the Option setting, for the touchpad and the remote desktop.
let optionIsAltKey = "input.optionIsAlt"

extension RemoteKeyTarget {
    /// Presses a special key with the held and the sticky modifiers.
    func key(_ k: RemoteInput.Key, held: RemoteInput.Mods = .init()) {
        send([RemoteInput.key(k, mods: held.union(takeMods()))])
    }

    /// Types text with the held and the sticky modifiers. `digit` is the
    /// number row key that typed it, for super and a digit.
    func text(_ s: String, held: RemoteInput.Mods = .init(), digit: Int? = nil) {
        guard !s.isEmpty else { return }
        let mods = held.union(takeMods())
        if workspaceKeys, let workspace = DesktopShortcuts.forDigit(digit.map(String.init) ?? s, mods: mods) {
            send([workspace])
            return
        }
        send([RemoteInput.text(s, mods: mods)])
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

    /// True when the draft has text to type.
    var canTypeDraft: Bool { keysReady && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Types the draft on the computer: each line as text, and Shift+Enter
    /// between the lines. The sticky modifiers clear, and the draft empties.
    func typeDraft() {
        guard canTypeDraft else { return }
        let packets = RemoteInput.draft(draft)
        mods = .init()
        draft = ""
        send(packets)
    }

    private func takeMods() -> RemoteInput.Mods {
        defer { mods = .init() }
        return mods
    }
}

/// A view that sends the keys of this Mac to the computer. Special keys go
/// as special keys, shortcuts as text with modifiers, and other keys through
/// the text input system of macOS, so that dead keys, input methods, and the
/// Option characters of the layout work. While `commandIsSuper` is on, a
/// monitor takes each key before the menus of this Mac, so that Command
/// shortcuts reach the computer.
class RemoteKeyView: NSView, NSTextInputClient {
    let keyTarget: any RemoteKeyTarget
    /// The text of a dead key while macOS composes, such as ´ before e.
    private var marked = ""
    private var monitor: Any?

    init(keyTarget: any RemoteKeyTarget) {
        self.keyTarget = keyTarget
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    /// Runs before each key that goes to the computer.
    func willSendKey() {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let used = MainActor.assumeIsolated { self?.intercept(event) ?? false }
            return used ? nil : event
        }
    }

    private func intercept(_ event: NSEvent) -> Bool {
        guard keyTarget.keysReady, keyTarget.commandIsSuper, event.window === window, window?.firstResponder === self else { return false }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard keyTarget.keysReady else { return super.keyDown(with: event) }
        willSendKey()
        let press = RemoteInput.press(keyCode: event.keyCode, flags: event.modifierFlags, plain: event.charactersIgnoringModifiers,
                                      optionIsAlt: keyTarget.optionIsAlt, commandIsSuper: keyTarget.commandIsSuper)
        switch press {
        case .key(let k, let held):
            // A special key ends a dead key that waits.
            if !marked.isEmpty {
                inputContext?.discardMarkedText()
                marked = ""
            }
            keyTarget.key(k, held: held)
        case .text(let text, let held):
            keyTarget.text(text, held: held, digit: RemoteInput.digit(macKeyCode: event.keyCode))
        case .compose:
            interpretKeyEvents([event])
        case .ignore:
            super.keyDown(with: event)
        }
    }

    /// Commands of the text input system, such as moveLeft:, have their own
    /// special keys, so they do nothing here.
    override func doCommand(by selector: Selector) {}

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        marked = ""
        keyTarget.text(Self.plain(string))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) { marked = Self.plain(string) }

    /// macOS keeps the marked text as typed text.
    func unmarkText() {
        let text = marked
        marked = ""
        keyTarget.text(text)
    }

    func selectedRange() -> NSRange { NSRange(location: marked.utf16.count, length: 0) }

    func markedRange() -> NSRange {
        marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.utf16.count)
    }

    func hasMarkedText() -> Bool { !marked.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// An input method shows its window at the center of the view.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(NSRect(x: bounds.midX, y: bounds.midY, width: 0, height: 20), to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    private static func plain(_ string: Any) -> String {
        (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }
}

/// The type field of the touchpad and the remote desktop, with the clear
/// key and the expand key. The clear key empties the field. Only the text
/// after the last word is in the field, so no keys go to the computer. The
/// expand key opens the draft editor: the text goes to the computer only at
/// Type, so the spelling of this Mac can correct it first.
struct RemoteTypeField: View {
    let target: any RemoteKeyTarget
    @State private var drafting = false

    var body: some View {
        // The body reads the text, so that the field updates when the clear key empties it.
        let _ = target.fieldText
        let text = Binding(get: { target.fieldText }, set: { target.fieldText = $0 })
        TypeField(target: target, placeholder: "Type on \(target.name)", text: text)
            .frame(maxWidth: .infinity)
            .fieldKeys(text: text, expandHelp: "Write a longer text, then type it on \(target.name)") { drafting = true }
            .voiceFieldStyle()
            .sheet(isPresented: $drafting) {
                FieldEditor(
                    title: "Type on \(target.name)",
                    text: Binding(get: { target.draft }, set: { target.draft = $0 }),
                    hint: "Each line break goes as Shift+Enter. A draft holds at most \(RemoteInput.maxDraftLines) lines.",
                    limit: RemoteInput.maxDraft,
                    lineLimit: RemoteInput.maxDraftLines,
                    doneTitle: "Close",
                    action: FieldEditorAction(title: "Type", enabled: { target.canTypeDraft }) { target.typeDraft() }
                ) { drafting = false }
            }
    }
}

/// The key row and the modifier row: Escape, Tab, the arrows, Backspace,
/// Enter, and ctrl, alt, shift, and super, which hold for the next key or
/// text. The last control sets whether Option is Alt.
struct RemoteKeyRows: View {
    let target: any RemoteKeyTarget

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(PadKey.all) { k in
                    Button { target.key(k.key) } label: {
                        Image(systemName: k.symbol).frame(maxWidth: .infinity)
                    }
                    .help("Press \(k.name) on \(target.name)")
                    .accessibilityLabel(k.name)
                }
            }
            .controlSize(.large)
            HStack(spacing: 6) {
                ModKey(label: "ctrl", name: "Control", isOn: mod(\.ctrl))
                ModKey(label: "alt", name: "Alt", isOn: mod(\.alt))
                ModKey(label: "shift", name: "Shift", isOn: mod(\.shift))
                ModKey(label: "super", name: "Super", isOn: mod(\.meta))
                Spacer(minLength: 12)
                Toggle("Option is Alt", isOn: Binding(get: { target.optionIsAlt }, set: { target.optionIsAlt = $0 }))
                    .toggleStyle(.checkbox)
                    .help("On: Option is Alt for letters too. Off: Option types the characters of the Mac layout, such as @ on a Nordic keyboard.")
            }
        }
    }

    private func mod(_ path: WritableKeyPath<RemoteInput.Mods, Bool>) -> Binding<Bool> {
        Binding(get: { target.mods[keyPath: path] }, set: { target.mods[keyPath: path] = $0 })
    }
}

/// A special key of the key row.
private struct PadKey: Identifiable {
    let key: RemoteInput.Key
    let symbol: String
    let name: String

    var id: Int { key.rawValue }

    static let all = [
        PadKey(key: .escape, symbol: "escape", name: "Escape"),
        PadKey(key: .tab, symbol: "arrow.right.to.line", name: "Tab"),
        PadKey(key: .left, symbol: "arrow.left", name: "Left"),
        PadKey(key: .up, symbol: "arrow.up", name: "Up"),
        PadKey(key: .down, symbol: "arrow.down", name: "Down"),
        PadKey(key: .right, symbol: "arrow.right", name: "Right"),
        PadKey(key: .backspace, symbol: "delete.left", name: "Backspace"),
        PadKey(key: .enter, symbol: "return", name: "Enter"),
    ]
}

/// A modifier key. It stays on for the next key or text.
private struct ModKey: View {
    let label: String
    let name: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) { Text(label).monospaced() }
            .toggleStyle(.button)
            .help(isOn ? "Release \(name)" : "Hold \(name) for the next key or text")
    }
}
