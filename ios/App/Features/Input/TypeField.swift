import FluxKit
import SwiftUI
import UIKit

/// The text field that types on the computer. Each change goes out at once
/// as backspaces and new text, see `TypeBuffer`, so a word that the
/// keyboard changes changes on the computer too. Text that the keyboard
/// still composes, such as Japanese before its choice, goes out when it is
/// final. Backspace in the empty field presses Backspace on the computer,
/// and Send presses Enter. With a modifier held, the text goes as a
/// shortcut, such as ctrl and c. The field corrects no spelling and changes
/// no quotes or dashes, because commands need the typed text. `RemoteKeys`
/// holds what the computer has, so that a click or a key can end the field.
struct TypeField: UIViewRepresentable {
    let keys: RemoteKeys
    let placeholder: String

    func makeUIView(context: Context) -> RemoteTextField {
        let field = RemoteTextField()
        field.attach(keys)
        field.placeholder = placeholder
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.returnKeyType = .send
        // The clear key of `TypeFieldBox` also deletes the text on the computer.
        field.clearButtonMode = .never
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(field, action: #selector(RemoteTextField.edited), for: .editingChanged)
        field.delegate = field
        field.accessibilityLabel = placeholder
        return field
    }

    func updateUIView(_ field: RemoteTextField, context: Context) {
        field.attach(keys)
        field.placeholder = placeholder
    }
}

/// A text field whose changes go to the computer.
final class RemoteTextField: UITextField, UITextFieldDelegate {
    private(set) var keys: RemoteKeys?
    /// True while the app sets the text, so that the change does not go to the computer.
    private var setting = false
    /// The hardware key presses that went to the computer, so that their ends stay here too.
    private var sent = Set<UIPress>()

    /// Connects the field to the keys. The keys can then empty the field.
    func attach(_ keys: RemoteKeys) {
        self.keys = keys
        keys.setField = { [weak self] text in self?.show(text) }
    }

    /// Shows the text. The change does not go to the computer, and the
    /// text that the keyboard composes goes away.
    func show(_ text: String) {
        guard self.text != text || markedTextRange != nil else { return }
        setting = true
        if markedTextRange != nil { unmarkText() }
        self.text = text
        setting = false
    }

    @objc func edited() {
        guard let keys, !setting else { return }
        let text = self.text ?? ""
        // The text that the keyboard composes at the end waits until it is final.
        var stable = text
        if let marked = markedTextRange, offset(from: marked.end, to: endOfDocument) == 0 {
            stable = String(text.utf16.prefix(offset(from: beginningOfDocument, to: marked.start))) ?? text
        }
        if keys.fieldChanged(shown: text, stable: stable, composing: markedTextRange != nil) {
            show("")
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { keys?.fieldFocused = true }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { keys?.fieldFocused = false }
        return ok
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil && keys?.fieldFocused == true { keys?.fieldFocused = false }
    }

    /// iOS calls this for Backspace also when the field is empty.
    override func deleteBackward() {
        if (text ?? "").isEmpty && markedTextRange == nil {
            keys?.key(.backspace)
            return
        }
        super.deleteBackward()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        // Enter ends the field, so the field empties.
        keys?.fieldReturn()
        return false
    }

    /// A hardware keyboard: the special keys and the shortcuts go to the
    /// computer. Backspace and Return edit the field like the phone keyboard,
    /// and the other keys type in the field.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let keys, markedTextRange == nil else {
                rest.insert(press)
                continue
            }
            let mapped = RemoteInput.press(key: key, optionIsAlt: false, commandIsSuper: true)
            switch mapped {
            case .key(let k, _) where k == .backspace || k == .enter:
                rest.insert(press)
            case .key, .text:
                keys.press(mapped, characters: key.characters, digit: RemoteInput.digit(hidUsage: key.keyCode))
                sent.insert(press)
            case .compose, .ignore:
                rest.insert(press)
            }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(sent)
        sent.subtract(presses)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(sent)
        sent.subtract(presses)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }
}

/// The type field in its box, with the clear key while the field has text,
/// the key that hides the keyboard while the field has the focus, and the
/// key that opens the draft editor. The clear key deletes the text of the
/// field on the computer.
struct TypeFieldBox: View {
    @Bindable var keys: RemoteKeys
    /// The name of the computer.
    let name: String

    var body: some View {
        HStack(spacing: 0) {
            TypeField(keys: keys, placeholder: "Type on \(name)")
            if !keys.fieldText.isEmpty {
                FieldIconKey(systemImage: "xmark.circle.fill", name: "Clear", hint: "Deletes the typed text on \(name)") {
                    keys.clearTyped()
                }
            }
            // On the remote desktop, a tap on the video keeps the keyboard, so this key hides it.
            if keys.fieldFocused {
                FieldIconKey(systemImage: "keyboard.chevron.compact.down", name: "Hide the keyboard") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
            FieldIconKey(systemImage: "arrow.up.left.and.arrow.down.right", name: "Open the editor",
                         hint: "Write a longer text, then type all of it on \(name)") {
                keys.drafting = true
            }
        }
        .frame(height: 44)
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(.separator).opacity(0.5)))
        .sheet(isPresented: $keys.drafting) {
            DraftEditor(keys: keys, name: name)
        }
    }
}

/// The draft editor: a large field for a longer text, with the full
/// keyboard and its corrections, because the text goes out only at Type.
/// Type sends all text to the computer, with Shift+Enter for each line
/// break. Close keeps the draft for later.
struct DraftEditor: View {
    @Bindable var keys: RemoteKeys
    let name: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                VoiceField(onText: { keys.draft = DictationText.append(keys.draft, $0) }) {
                    TextEditor(text: $keys.draft)
                        .focused($focused)
                        .textInputAutocapitalization(.sentences)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(.separator).opacity(0.5)))
                        .accessibilityLabel("Text to type on \(name)")
                }
                HStack(spacing: 12) {
                    Text("Each line break goes as Shift+Enter. A draft holds at most \(RemoteInput.maxDraftLines) lines.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Clear", role: .destructive) { keys.draft = "" }
                        .disabled(keys.draft.isEmpty)
                }
            }
            .padding(16)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Type on \(name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Type") {
                        keys.typeDraft()
                        dismiss()
                    }
                    .disabled(!keys.canTypeDraft)
                }
            }
            // The text after the last line or character that fits goes away.
            .onChange(of: keys.draft) { _, text in
                let limited = RemoteInput.limitDraft(text)
                if limited != text { keys.draft = limited }
            }
            .onAppear { focused = true }
        }
    }
}
