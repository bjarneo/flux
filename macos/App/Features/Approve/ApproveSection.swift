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
        let key = model.keys[device.id]
        let records = model.history.filter { $0.computerId == device.id }
        DashboardCard("Touch ID Approval", systemImage: "touchid", tint: .pink, detailsTitle: "Details") {
            StatusPill(text: key == nil ? "Not set up" : "Enrolled", color: key == nil ? .secondary : .green)
        } content: {
            if let key {
                Text("Approves sudo, polkit, and the lock screen for \(key.user) on \(key.host).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Approve sudo, polkit, and the lock screen of \(device.name) with Touch ID on this Mac. Run this command on \(device.name), then select Enroll on this Mac:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                CommandRow(command: "sudo flux approve setup")
            }
            if let touchIdProblem {
                Label(touchIdProblem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } details: {
            if let key {
                CardRow("Key code") { Text(key.code).monospaced().textSelection(.enabled) }
                CardRow("Enrolled") { Text(key.enrolled.formatted(date: .abbreviated, time: .shortened)) }
                HStack {
                    Text("To enroll again, run `sudo flux approve enroll` on \(device.name).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove Key…", role: .destructive) { confirmRemove = true }
                }
            }
            Text("Recent requests").font(.subheadline.weight(.semibold))
            if records.isEmpty {
                Text("No requests yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(records) { RecordRow(record: $0) }
            }
        }
        .task { touchIdProblem = ApprovePlugin.biometryProblem() }
        .confirmationDialog("Remove the approval key for \(device.name)?", isPresented: $confirmRemove) {
            Button("Remove Key", role: .destructive) { plugin.removeKey(device.id) }
        } message: {
            Text("This Mac can no longer approve requests of \(device.name). Run `sudo flux approve remove` on \(device.name) to delete its key file too.")
        }
    }
}

private struct CommandRow: View {
    let command: String

    var body: some View {
        HStack {
            Text(command)
                .monospaced()
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
    }
}

private struct RecordRow: View {
    let record: ApproveRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.summary)
                Text(record.outcome.text).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(record.received.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
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

/// A banner while a request of the computer waits for Touch ID.
struct ApproveBanner: View {
    @Environment(AppModel.self) private var app
    let device: DeviceSnapshot

    var body: some View {
        if let plugin = app.core.plugin(ApprovePlugin.self), let r = plugin.model.current, r.computerId == device.id {
            Banner(ApproveMessage.question(r), systemImage: "touchid", tint: .pink) {
                Button("Show…") { ApprovePromptWindow.show(plugin) }
            }
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
