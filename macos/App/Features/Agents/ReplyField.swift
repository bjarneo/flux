import AppKit
import SwiftUI

/// The reply field: a text view of 1 to 5 lines that reports its cursor, so
/// dictation can put words at the cursor. Return sends. Shift-Return and
/// Option-Return add a line break.
struct ReplyField: NSViewRepresentable {
    @Binding var text: String
    /// The selection in UTF-16 units, or nil for the end of the text.
    @Binding var selection: NSRange?
    let placeholder: String
    let onSubmit: () -> Void

    static let minHeight: CGFloat = 34
    static let maxHeight: CGFloat = 104

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let view = PlaceholderTextView()
        view.isRichText = false
        view.allowsUndo = true
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.textColor = .labelColor
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 4, height: 8)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.placeholder = placeholder
        view.string = text
        // A new field, for example after a dictation, keeps the cursor of the draft.
        let length = (text as NSString).length
        if let selection, selection.location + selection.length <= length { view.setSelectedRange(selection) }
        view.delegate = context.coordinator
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? PlaceholderTextView else { return }
        view.placeholder = placeholder
        // The delegate ignores the changes that come from the bindings.
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        if view.string != text {
            view.string = text
            view.needsDisplay = true
        }
        let length = (text as NSString).length
        let wanted = selection ?? NSRange(location: length, length: 0)
        if wanted.location + wanted.length <= length, view.selectedRange() != wanted {
            view.setSelectedRange(wanted)
            view.scrollRangeToVisible(wanted)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let view = nsView.documentView as? NSTextView, let layout = view.layoutManager, let container = view.textContainer else { return nil }
        let width = proposal.width ?? 300
        container.containerSize = NSSize(width: max(width - view.textContainerInset.width * 2, 10), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = layout.usedRect(for: container).height + view.textContainerInset.height * 2
        return CGSize(width: width, height: min(max(height, Self.minHeight), Self.maxHeight))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ReplyField
        var updating = false

        init(_ parent: ReplyField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            parent.selection = view.selectedRange()
            view.invalidateIntrinsicContentSize()
            view.enclosingScrollView?.invalidateIntrinsicContentSize()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView, !view.hasMarkedText() else { return }
            let range = view.selectedRange()
            if parent.selection != range { parent.selection = range }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            parent.onSubmit()
            return true
        }
    }
}

/// A text view that shows a placeholder while it is empty.
final class PlaceholderTextView: NSTextView {
    var placeholder = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ]
        let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
        NSAttributedString(string: placeholder, attributes: attributes)
            .draw(at: NSPoint(x: x, y: textContainerInset.height))
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
