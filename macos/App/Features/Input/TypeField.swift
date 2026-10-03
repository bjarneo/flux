import AppKit
import FluxKit
import SwiftUI

/// The text field that types on the computer. Each word goes out after its
/// space, Return sends the rest and presses Enter, and Backspace in the empty
/// field presses Backspace on the computer. `text` is the rest that waits in
/// the field, so that the clear key can empty it.
struct TypeField: NSViewRepresentable {
    let target: any RemoteKeyTarget
    let placeholder: String
    @Binding var text: String

    func makeNSView(context: Context) -> NSTextField {
        let field = PlainTextField()
        field.placeholderString = placeholder
        field.stringValue = text
        field.delegate = context.coordinator
        // The frame of the field comes from the voice field style around it.
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.isAutomaticTextCompletionEnabled = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        field.placeholderString = placeholder
        // The clear key empties the binding. Text that an input method composes stays.
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(target: target, text: $text) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let target: any RemoteKeyTarget
        var text: Binding<String>

        init(target: any RemoteKeyTarget, text: Binding<String>) {
            self.target = target
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // An input method or a dead key composes: wait for the text.
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
            let keep = target.fieldChanged(field.stringValue)
            if keep != field.stringValue { field.stringValue = keep }
            if text.wrappedValue != keep { text.wrappedValue = keep }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                target.fieldReturn(textView.string)
                control.stringValue = ""
                text.wrappedValue = ""
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
