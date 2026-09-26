import AppKit
import FluxKit
import SwiftUI

/// Touch ID approval for 1 computer: the enrollment, the open request, and
/// the recent requests. The computer starts each enrollment with
/// `sudo flux approve setup` or `sudo flux approve enroll`.
struct ApproveSection: View {
    @Environment(AppModel.self) private var app
    let device: DeviceSnapshot

    var body: some View {
        if let plugin = app.core.plugin(ApprovePlugin.self), device.isFlux || plugin.model.keys[device.id] != nil {
            ApproveContent(plugin: plugin, device: device)
        }
    }
}

private struct ApproveContent: View {
    let plugin: ApprovePlugin
    let device: DeviceSnapshot
    @State private var touchIdProblem: String?
    @State private var confirmRemove = false

    private var model: ApproveModel { plugin.model }

    var body: some View {
        Section("Touch ID approval") {
            if let r = model.current, r.computerId == device.id {
                LabeledContent {
                    Button("Show…") { ApprovePromptWindow.show(plugin) }
                } label: {
                    Label(ApproveMessage.question(r), systemImage: "touchid")
                }
            }
            if let key = model.keys[device.id] {
                LabeledContent("Approves for", value: "\(key.user) on \(key.host)")
                LabeledContent("Key code") {
                    Text(key.code).monospaced().textSelection(.enabled)
                }
                LabeledContent("Enrolled", value: key.enrolled.formatted(date: .abbreviated, time: .shortened))
                LabeledContent {
                    Button("Remove Key…", role: .destructive) { confirmRemove = true }
                } label: {
                    Text("To enroll again, run `sudo flux approve enroll` on \(device.name).")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Approve sudo, polkit, and the lock screen of \(device.name) with Touch ID on this Mac. To set it up, run this command on \(device.name), then select Enroll on this Mac:")
                    .foregroundStyle(.secondary)
                CommandRow(command: "sudo flux approve setup")
            }
            if let touchIdProblem {
                Label(touchIdProblem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .task { touchIdProblem = ApprovePlugin.biometryProblem() }
        .confirmationDialog("Remove the approval key for \(device.name)?", isPresented: $confirmRemove) {
            Button("Remove Key", role: .destructive) { plugin.removeKey(device.id) }
        } message: {
            Text("This Mac can no longer approve requests of \(device.name). Run `sudo flux approve remove` on \(device.name) to delete its key file too.")
        }

        let records = model.history.filter { $0.computerId == device.id }
        if !records.isEmpty {
            Section("Recent approval requests") {
                ForEach(records) { RecordRow(record: $0) }
            }
        }
    }
}

private struct CommandRow: View {
    let command: String

    var body: some View {
        LabeledContent {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        } label: {
            Text(command).monospaced().textSelection(.enabled)
        }
    }
}

private struct RecordRow: View {
    let record: ApproveRecord

    var body: some View {
        LabeledContent {
            Text(record.received.formatted(date: .omitted, time: .shortened))
                .foregroundStyle(.secondary)
        } label: {
            Label {
                Text(record.summary)
                Text(record.outcome.text)
            } icon: {
                Image(systemName: symbol).foregroundStyle(color)
            }
        }
    }

    private var symbol: String {
        switch record.outcome {
        case .open: return "clock"
        case .approved, .enrolled: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .failed, .refused: return "exclamationmark.triangle.fill"
        case .cancelled, .expired: return "minus.circle"
        }
    }

    private var color: Color {
        switch record.outcome {
        case .approved, .enrolled: return .green
        case .denied: return .red
        case .failed, .refused: return .orange
        case .open, .cancelled, .expired: return .secondary
        }
    }
}

/// Reopens the prompt of an open request from the menu bar.
struct ApproveMenuItem: View {
    @Environment(AppModel.self) private var app
    let device: DeviceSnapshot

    var body: some View {
        if let plugin = app.core.plugin(ApprovePlugin.self), let r = plugin.model.current, r.computerId == device.id {
            Button(r.kind == .approve ? "Approve \(r.service) Request…" : "Enrollment Request…") { ApprovePromptWindow.show(plugin) }
        }
    }
}
