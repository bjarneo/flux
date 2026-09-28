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
/// no quotes or dashes, because commands need the typed text.
struct TypeField: UIViewRepresentable {
    let keys: RemoteKeys
    let placeholder: String

    func makeUIView(context: Context) -> RemoteTextField {
        let field = RemoteTextField()
        field.keys = keys
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
        field.clearButtonMode = .never
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(field, action: #selector(RemoteTextField.edited), for: .editingChanged)
        field.delegate = field
        field.accessibilityLabel = placeholder
        return field
    }

    func updateUIView(_ field: RemoteTextField, context: Context) {
        field.keys = keys
        field.placeholder = placeholder
    }
}

/// A text field whose changes go to the computer.
final class RemoteTextField: UITextField, UITextFieldDelegate {
    var keys: RemoteKeys?
    private var buffer = TypeBuffer()
    /// The hardware key presses that went to the computer, so that their ends stay here too.
    private var sent = Set<UIPress>()

    @objc func edited() {
        guard let keys else { return }
        let text = self.text ?? ""
        // The text that the keyboard composes at the end waits until it is final.
        var stable = text
        if let marked = markedTextRange, offset(from: marked.end, to: endOfDocument) == 0 {
            stable = String(text.utf16.prefix(offset(from: beginningOfDocument, to: marked.start))) ?? text
        }
        switch buffer.change(stable, composing: markedTextRange != nil, modsHeld: keys.mods.any) {
        case .edit(let backspaces, let typed, let clear):
            keys.backspaces(backspaces)
            keys.text(typed)
            if clear { self.text = "" }
        case .shortcut(let typed):
            keys.text(typed)
            self.text = ""
        }
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
        keys?.key(.enter)
        unmarkText()
        text = ""
        buffer.reset()
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
