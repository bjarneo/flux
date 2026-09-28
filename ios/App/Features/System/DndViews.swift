import FluxKit
import SwiftUI
import UIKit

/// Do Not Disturb of a computer, in the header. The iPhone shows it and does
/// not follow it.
struct DndBadge: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if model.core.plugin(DndPlugin.self)?.model.computers[device.id] == true {
            Label("Do Not Disturb", systemImage: "moon.fill")
                .accessibilityLabel("Do Not Disturb is on")
        }
    }
}

/// The Focus report: the switch and the Focus state that the Flux Focus filter reports.
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

    var body: some View {
        Section {
            Toggle("Silence computers with Focus", isOn: $model.sync)
            LabeledContent("Focus on this iPhone", value: focusText)
        } header: {
            Text("Focus")
        } footer: {
            Text("""
            In Settings > Focus, open a Focus, add the Flux filter under Focus Filters, and turn on \
            "Do Not Disturb on computers". While that Focus is on, your computers turn on Do Not Disturb. \
            iOS does not let apps set the Focus, so this iPhone does not follow the computers.
            """)
        }
    }

    private var focusText: String {
        switch model.focusOn {
        case true?: "On (Flux filter)"
        case false?: "Off"
        case nil: "Unknown"
        }
    }
}

@MainActor
enum SystemFeature {
    /// Connects the Focus filter to the Focus report.
    static func didLaunch(model: AppModel) {
        if let dnd = model.core.plugin(DndPlugin.self) {
            FocusBridge.start(dnd)
        }
    }
}
