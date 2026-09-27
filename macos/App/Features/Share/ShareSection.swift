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
            let transfers = share.model.transfers.filter { $0.deviceId == device.id }
            DashboardCard("Share", systemImage: "square.and.arrow.up", tint: .blue) {
                if transfers.contains(where: { $0.state != .running }) {
                    Button("Clear") { share.model.clearFinished() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            } content: {
                dropZone(share)
                HStack {
                    TextField("Text or link", text: $text, prompt: Text("Text or link"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { sendText(share) }
                    Button("Send") { sendText(share) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .disabled(!device.online)
                if !transfers.isEmpty {
                    Divider()
                    ForEach(transfers) { TransferRow(transfer: $0) }
                }
            }
        }
    }

    private func dropZone(_ share: SharePlugin) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.up")
                .font(.title2)
                .foregroundStyle(dropping ? Color.accentColor : .secondary)
            Text("Drop files, text, or links here")
                .foregroundStyle(.secondary)
            Button("Choose Files…") { ShareActions.pickFiles(to: device, model: model) }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 104)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
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

/// Clipboard sync.
struct ClipboardSection: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if let clipboard = model.core.plugin(ClipboardPlugin.self) {
            DashboardCard("Clipboard", systemImage: "doc.on.clipboard", tint: .teal) {
                SwitchRow(
                    title: "Sync clipboard",
                    subtitle: "Text that you copy goes to your connected computers, and text that they copy comes here.",
                    isOn: Binding(get: { clipboard.model.sync }, set: { clipboard.setSync($0) })
                )
            }
        }
    }
}

/// The header actions that send files and the clipboard.
struct ShareQuickActions: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if model.core.plugin(SharePlugin.self) != nil {
            Tile(title: "Send Files", systemImage: "doc.badge.arrow.up") { ShareActions.pickFiles(to: device, model: model) }
                .help("Choose files to send to \(device.name)")
        }
        if let clipboard = model.core.plugin(ClipboardPlugin.self) {
            Tile(title: "Send Clipboard", systemImage: "doc.on.clipboard") { clipboard.sendClipboard(to: device.id) }
                .help("Send the clipboard of this Mac to \(device.name)")
        }
    }
}
