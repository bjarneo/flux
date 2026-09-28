import FluxKit
import SwiftUI
import UIKit

/// Opens the approval screen of a Flux computer, or of one with a key.
struct ApproveTile: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if let plugin = model.core.plugin(ApprovePlugin.self), device.isFlux || plugin.model.keys[device.id] != nil {
            let waiting = plugin.model.current?.computerId == device.id
            FeatureTile("Approval", systemImage: ApproveTexts.current.symbol, tint: .pink,
                        subtitle: Self.subtitle(user: plugin.model.keys[device.id]?.user, waiting: waiting, availability: ApprovePlugin.availability()),
                        badge: waiting ? 1 : 0) {
                model.path.append(.feature(.approve(device.id)))
            }
        }
    }

    /// The state of approval for the computer in a few words.
    /// `user` is the user of the enrolled key, or nil without a key.
    static func subtitle(user: String?, waiting: Bool, availability: ApproveAvailability) -> String {
        if waiting { return "A request waits" }
        if let user { return "Enrolled for \(user)" }
        if case .noSecureEnclave = availability { return "Not available on this iPhone" }
        return "Approve sudo on the computer"
    }
}

/// The approval screen of 1 computer: how to enroll, the key, and the recent
/// requests. The computer starts each enrollment with
/// `sudo flux-cli approve setup` or `sudo flux-cli approve enroll`.
struct ApproveScreen: View {
    @Environment(AppModel.self) private var model
    let deviceId: String

    var body: some View {
        Group {
            if let plugin = model.core.plugin(ApprovePlugin.self) {
                ApproveContent(plugin: plugin, deviceId: deviceId, name: model.device(deviceId)?.name ?? "the computer")
            }
        }
        .navigationTitle("Approval")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ApproveContent: View {
    let plugin: ApprovePlugin
    let deviceId: String
    let name: String
    /// Whether this device can approve now. It reads the Secure Enclave and
    /// the biometry of the device.
    let readAvailability: () -> ApproveAvailability
    @State private var availability: ApproveAvailability
    @State private var confirmRemove = false

    init(plugin: ApprovePlugin, deviceId: String, name: String, readAvailability: @escaping () -> ApproveAvailability = ApprovePlugin.availability) {
        self.plugin = plugin
        self.deviceId = deviceId
        self.name = name
        self.readAvailability = readAvailability
        _availability = State(initialValue: readAvailability())
    }
    @Environment(\.scenePhase) private var scenePhase

    private var model: ApproveModel { plugin.model }
    private var texts: ApproveTexts { .current }

    var body: some View {
        let key = model.keys[deviceId]
        let records = model.history.filter { $0.computerId == deviceId }
        Form {
            Section {
                HStack(spacing: 14) {
                    FeatureIcon(systemImage: texts.symbol, tint: .pink, size: 44)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(texts.biometry.prefix(1).uppercased() + texts.biometry.dropFirst()) approval")
                            .font(.headline)
                        status(key: key)
                    }
                }
                .padding(.vertical, 4)
                explanation(key: key)
            } footer: {
                Text("Requests reach this iPhone only while Flux is open. Without an answer, the computer asks for the password.")
            }
            if let key {
                Section("Key") {
                    LabeledContent("Key code") {
                        Text(key.code).monospaced().textSelection(.enabled)
                    }
                    LabeledContent("Enrolled", value: key.enrolled.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("For", value: "\(key.user) on \(key.host)")
                    Button("Remove Key…", role: .destructive) { confirmRemove = true }
                }
            }
            Section("Recent requests") {
                if records.isEmpty {
                    Text("No requests yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(records) { RecordRow(record: $0) }
                }
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // The user may set up Face ID in Settings and come back.
            if phase == .active { availability = readAvailability() }
        }
        .confirmationDialog("Remove the approval key for \(name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Key", role: .destructive) { plugin.removeKey(deviceId) }
        } message: {
            Text("\(texts.deviceNoun.prefix(1).uppercased() + texts.deviceNoun.dropFirst()) can no longer approve requests of \(name). Run sudo flux-cli approve remove on \(name) to delete its key file too.")
        }
    }

    @ViewBuilder
    private func status(key: ApproveKeyInfo?) -> some View {
        if key != nil {
            StatusPill(text: "Enrolled", color: .green)
        } else if case .noSecureEnclave = availability {
            StatusPill(text: "Not available", color: .orange)
        } else {
            StatusPill(text: "Not set up", color: .secondary)
        }
    }

    @ViewBuilder
    private func explanation(key: ApproveKeyInfo?) -> some View {
        switch availability {
        case .noSecureEnclave(let message):
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message)
                    Text("Flux keeps the approval key only in the Secure Enclave, so this iPhone refuses each request.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        case .biometry(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            if key == nil { setup }
        case .ready:
            if let key {
                Text("Approves sudo, polkit, and the lock screen for \(key.user) on \(key.host) with \(texts.biometry). To enroll again, run sudo flux-cli approve enroll on \(name).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                setup
            }
        }
    }

    @ViewBuilder
    private var setup: some View {
        Text("Approve sudo, polkit, and the lock screen of \(name) with \(texts.biometry) on \(texts.deviceNoun). Run this command on \(name), then select Enroll on \(texts.deviceNoun):")
            .font(.callout)
            .foregroundStyle(.secondary)
        CommandRow(command: "sudo flux-cli approve setup")
    }
}

/// A command to run on the computer, with Copy.
private struct CommandRow: View {
    @Environment(AppModel.self) private var model
    let command: String

    var body: some View {
        HStack {
            Text(command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            Button("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = command
                model.show("Copied")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy the command")
        }
    }
}

private struct RecordRow: View {
    let record: ApproveRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.summary)
                Text(record.outcome.text).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(record.received.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
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

/// A banner on the computer's screen while its request waits.
struct ApproveBanner: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if let plugin = model.core.plugin(ApprovePlugin.self), let r = plugin.model.current, r.computerId == device.id {
            HStack(spacing: 12) {
                FeatureIcon(systemImage: ApproveTexts.current.symbol, tint: .pink)
                Text(ApproveMessage.question(r))
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Show") { ApprovePresenter.shared.state.present() }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
        }
    }
}
