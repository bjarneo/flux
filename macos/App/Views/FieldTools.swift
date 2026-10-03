import SwiftUI

/// The clear key of a text field. It shows while the field has text, and a
/// click empties the field. `onClear` runs after the field empties, for
/// example to move the cursor of a dictation to the start.
struct ClearKey: View {
    @Binding var text: String
    var onClear: (() -> Void)?

    var body: some View {
        if !text.isEmpty {
            Button {
                text = ""
                onClear?()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Clear the text")
            .accessibilityLabel("Clear")
        }
    }
}

/// The key that opens a larger editor for the text of a field.
struct ExpandKey: View {
    var help = "Open a larger editor"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

extension View {
    /// Puts the clear key at the trailing edge of a text field, and the
    /// expand key after it when `expand` is set.
    func fieldKeys(text: Binding<String>, expandHelp: String = "Open a larger editor", expand: (() -> Void)? = nil) -> some View {
        HStack(spacing: 6) {
            self
            ClearKey(text: text)
            if let expand {
                ExpandKey(help: expandHelp, action: expand)
            }
        }
    }
}

/// An action of a field editor, such as Send. It closes the editor first.
/// The editor calls `enabled` at each change of the text.
struct FieldEditorAction {
    let title: String
    let enabled: () -> Bool
    let run: () -> Void
}

/// A larger editor for the text of a field, in a sheet. The text changes in
/// the field at once, so Done only closes the sheet. With `limit`, the text
/// stops at that many characters, and with `lineLimit`, at that many lines.
/// Command-Return runs the action.
struct FieldEditor: View {
    let title: String
    @Binding var text: String
    var hint: String?
    var limit: Int?
    var lineLimit: Int?
    var doneTitle = "Done"
    var action: FieldEditorAction?
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextEditor(text: limited)
                .font(.body)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.4)))
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            // The count shows near the limit, so that the end of the text does not surprise.
            if let limit, text.count > limit * 9 / 10 {
                Text("\(text.count) of \(limit) characters").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Clear") { text = "" }
                    .disabled(text.isEmpty)
                Spacer()
                Button(doneTitle, action: onDone)
                    .keyboardShortcut(.cancelAction)
                if let action {
                    Button(action.title) {
                        onDone()
                        action.run()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!action.enabled())
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 380)
    }

    private var limited: Binding<String> {
        guard limit != nil || lineLimit != nil else { return $text }
        return Binding(get: { text }, set: { text = cut($0) })
    }

    /// Cuts the text after `limit` characters and after `lineLimit` lines.
    private func cut(_ value: String) -> String {
        var s = value
        if let limit, s.count > limit { s = String(s.prefix(limit)) }
        guard let lineLimit else { return s }
        var breaks = 0
        var end: String.Index?
        for i in s.indices where s[i].isNewline {
            breaks += 1
            // This line break starts the line after the last allowed line.
            if breaks == lineLimit {
                end = i
                break
            }
        }
        if let end { s = String(s[..<end]) }
        return s
    }
}
