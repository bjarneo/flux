import SwiftUI

/// A small key inside a text field, such as the clear key or the key that
/// opens the editor. It takes taps on 36 × 36 points.
struct FieldIconKey: View {
    let systemImage: String
    let name: String
    var hint: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityHint(hint ?? "")
    }
}

/// The clear key of a text field. It shows while the field has text, and a
/// tap empties the field.
struct ClearKey: View {
    @Binding var text: String
    var name = "Clear"

    var body: some View {
        if !text.isEmpty {
            FieldIconKey(systemImage: "xmark.circle.fill", name: name) { text = "" }
        }
    }
}

/// The key that opens the text of a field in a large editor.
struct ExpandKey: View {
    @Binding var isPresented: Bool

    var body: some View {
        FieldIconKey(systemImage: "arrow.up.left.and.arrow.down.right", name: "Open the editor",
                     hint: "Shows the text in a large editor") { isPresented = true }
    }
}

/// A large editor for the text of a field, for a long text. The text stays
/// in the field when the editor closes. `actionLabel` and `onAction` are
/// the action of the field, such as Send. The action closes the editor.
struct FieldEditor: View {
    let title: String
    @Binding var text: String
    var monospaced = false
    var corrects = true
    var actionLabel: String?
    var actionEnabled = true
    var onAction: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .trailing, spacing: 8) {
                TextEditor(text: $text)
                    .font(monospaced ? Font.body.monospaced() : Font.body)
                    .focused($focused)
                    .textInputAutocapitalization(corrects ? TextInputAutocapitalization.sentences : TextInputAutocapitalization.never)
                    .autocorrectionDisabled(!corrects)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(.separator).opacity(0.5)))
                    .accessibilityLabel(title)
                Button("Clear", role: .destructive) { text = "" }
                    .disabled(text.isEmpty)
            }
            .padding(16)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // With an action, Done moves to the left, and the action takes the right.
                ToolbarItem(placement: onAction == nil ? ToolbarItemPlacement.confirmationAction : ToolbarItemPlacement.cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if let actionLabel, let onAction {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(actionLabel) {
                            onAction()
                            dismiss()
                        }
                        .disabled(!actionEnabled)
                    }
                }
            }
            .onAppear { focused = true }
        }
    }
}
