import AppKit
import FluxKit
import SwiftUI

/// Do Not Disturb sync settings: the switch, the Focus state that the Flux
/// Focus filter reports, and the shortcuts that set Focus.
struct DndSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let dnd = app.core.plugin(DndPlugin.self) {
            DndSettingsSection(model: dnd.model)
        }
    }
}

private struct DndSettingsSection: View {
    @Bindable var model: DndModel

    private static let focusSettings = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")!

    var body: some View {
        Section {
            Toggle("Sync Do Not Disturb", isOn: $model.sync)
            LabeledContent("Focus on this Mac") {
                Text(focusText).foregroundStyle(.secondary)
            }
            shortcutPicker("Shortcut that turns Focus on", selection: $model.shortcutOn)
            shortcutPicker("Shortcut that turns Focus off", selection: $model.shortcutOff)
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            HStack {
                Button("Open Focus Settings…") { NSWorkspace.shared.open(Self.focusSettings) }
                Button("Open Shortcuts") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }
                Button("Reload shortcuts") { Task { await model.reloadShortcuts() } }
            }
        } header: {
            Text("Do Not Disturb")
        } footer: {
            Text("""
            To silence your computers with a Focus, add the Flux filter to that Focus in System Settings > Focus > Focus filters, \
            and turn on "Do Not Disturb on computers". To follow Do Not Disturb from your computers, make two shortcuts \
            with the Set Focus action, one that turns a Focus on and one that turns it off, and pick them here. \
            macOS offers apps no other way to read or set Focus.
            """)
        }
        .task { await model.reloadShortcuts() }
    }

    private var focusText: String {
        switch model.focusOn {
        case true?: "On (Flux filter)"
        case false?: "Off"
        case nil: "Unknown"
        }
    }

    private func shortcutPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag("")
            // Keep a saved name that `shortcuts list` does not report, for example after a rename.
            if !selection.wrappedValue.isEmpty && !model.shortcuts.contains(selection.wrappedValue) {
                Text(selection.wrappedValue).tag(selection.wrappedValue)
            }
            ForEach(model.shortcuts, id: \.self) { Text($0).tag($0) }
        }
    }
}
