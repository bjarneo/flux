import AppKit
import FluxKit
import SwiftUI

/// The text field that types on the computer. Each word goes out after its
/// space, Return sends the rest and presses Enter, and Backspace in the empty
/// field presses Backspace on the computer.
struct TypeField: NSViewRepresentable {
    let controller: TouchpadController
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

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let controller: TouchpadController

        init(controller: TouchpadController) { self.controller = controller }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // An input method or a dead key composes: wait for the text.
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
            let keep = controller.fieldChanged(field.stringValue)
            if keep != field.stringValue { field.stringValue = keep }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                controller.fieldReturn(textView.string)
                control.stringValue = ""
                return true
            case #selector(NSResponder.deleteBackward(_:)) where textView.string.isEmpty:
                controller.key(.backspace)
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
