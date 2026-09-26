import AppKit
import FluxKit
import SwiftUI
import UniformTypeIdentifiers

/// Sends files, text, and links to a computer, and lists the transfers with it.
struct ShareSection: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot
    @State private var text = ""
    @State private var dropping = false

    var body: some View {
        if let share = model.core.plugin(SharePlugin.self) {
            Section("Share") {
                dropZone(share)
                HStack {
                    TextField("Text or link", text: $text, prompt: Text("Text or link"))
                        .labelsHidden()
                        .onSubmit { sendText(share) }
                    Button("Send") { sendText(share) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .disabled(!device.online)
            }
            let transfers = share.model.transfers.filter { $0.deviceId == device.id }
            if !transfers.isEmpty {
                Section {
                    ForEach(transfers) { TransferRow(transfer: $0) }
                } header: {
                    HStack {
                        Text("Transfers")
                        Spacer()
                        Button("Clear") { share.model.clearFinished() }
                            .buttonStyle(.link)
                            .disabled(!transfers.contains { $0.state != .running })
                    }
                }
            }
        }
    }

    private func dropZone(_ share: SharePlugin) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.up.on.square")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Drop files, text, or links here")
                .foregroundStyle(.secondary)
            Button("Send Files…") { ShareActions.pickFiles(to: device, model: model) }
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(dropping ? Color.accentColor : Color.secondary.opacity(0.4))
        }
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $dropping) { providers in
            guard device.online else { return false }
            ShareActions.drop(providers, to: device.id, share: share)
            return true
        }
        .disabled(!device.online)
    }

    private func sendText(_ share: SharePlugin) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, device.online else { return }
        share.send(text: text, to: device.id)
        text = ""
    }
}

/// 1 transfer with its progress, and Open and Show in Finder for a received file.
struct TransferRow: View {
    let transfer: FileTransfer

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.incoming ? "arrow.down.circle" : "arrow.up.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                status
            }
            Spacer()
            if transfer.incoming, transfer.state == .done, let file = transfer.file {
                Button("Open") { NSWorkspace.shared.open(file) }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show in Finder")
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch transfer.state {
        case .running:
            if let fraction = transfer.fraction {
                ProgressView(value: fraction)
                    .controlSize(.small)
            } else {
                Text("\(bytes(transfer.bytes)) so far")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .done:
            Text("\(transfer.incoming ? "Received" : "Sent") · \(bytes(max(transfer.size, transfer.bytes)))")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text("Failed: \(message)")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

/// Clipboard sync and Send Clipboard.
struct ClipboardSection: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if let clipboard = model.core.plugin(ClipboardPlugin.self) {
            Section {
                Toggle("Sync clipboard", isOn: Binding(get: { clipboard.model.sync }, set: { clipboard.setSync($0) }))
                Button("Send Clipboard") { clipboard.sendClipboard(to: device.id) }
                    .disabled(!device.online)
            } header: {
                Text("Clipboard")
            } footer: {
                Text("With sync on, text that you copy goes to your connected computers, and text that they copy comes here.")
            }
        }
    }
}
