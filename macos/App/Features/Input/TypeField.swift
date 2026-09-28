import AppKit
import FluxKit
import SwiftUI

/// The text field that types on the computer. Each word goes out after its
/// space, Return sends the rest and presses Enter, and Backspace in the empty
/// field presses Backspace on the computer.
struct TypeField: NSViewRepresentable {
    let target: any RemoteKeyTarget
    let placeholder: String

    func makeNSView(context: Context) -> NSTextField {
        let field = PlainTextField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.isAutomaticTextCompletionEnabled = false
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) { field.placeholderString = placeholder }

    func makeCoordinator() -> Coordinator { Coordinator(target: target) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let target: any RemoteKeyTarget

        init(target: any RemoteKeyTarget) { self.target = target }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // An input method or a dead key composes: wait for the text.
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
            let keep = target.fieldChanged(field.stringValue)
            if keep != field.stringValue { field.stringValue = keep }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                target.fieldReturn(textView.string)
                control.stringValue = ""
                return true
            case #selector(NSResponder.deleteBackward(_:)) where textView.string.isEmpty:
                target.key(.backspace)
                return true
            default:
                return false
            }
        }
    }
}

/// A text field that types what the keys say. Commands need straight quotes
/// and dashes, and a correction after the word left would not reach the
/// computer, so the field changes no text.
private final class PlainTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if let editor = currentEditor() as? NSTextView {
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isContinuousSpellCheckingEnabled = false
        }
        return true
    }
}
