import CoreTransferable
import FluxKit
import Observation
import PhotosUI
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The share state of the app: the received file that Quick Look shows.
@MainActor
@Observable
final class ShareFeature {
    static let shared = ShareFeature()

    /// The file that Quick Look shows, or nil.
    var preview: URL?
    /// A link that the user opened from its notification while Flux was
    /// not active yet. It opens when Flux becomes active.
    @ObservationIgnored private var pendingLink: URL?

    private init() {}

    /// Opens a received file with Quick Look and a received link in the
    /// browser. On iOS, the plugin calls these only after a tap on the
    /// notification of the file or the link, like the Android app.
    static func didLaunch(model: AppModel) {
        Outbox.clear()
        guard let share = model.core.plugin(SharePlugin.self) else { return }
        QueuedShares.shared.start(model: model)
        share.openFile = { url in ShareFeature.shared.preview = url }
        share.openLink = { url in
            guard UIApplication.shared.applicationState == .active else {
                ShareFeature.shared.pendingLink = url
                return
            }
            UIApplication.shared.open(url)
        }
    }

    /// Opens the link that waited for Flux to become active.
    func openPendingLink() {
        guard let url = pendingLink else { return }
        pendingLink = nil
        UIApplication.shared.open(url)
    }

    /// Copies the picked files into the outbox and sends them. The picker
    /// gives access to its files only for a short time, and the transfer
    /// runs later, so the copies go out. A folder does not go out.
    static func send(picked urls: [URL], to device: DeviceSnapshot, model: AppModel) {
        guard let share = model.core.plugin(SharePlugin.self), !urls.isEmpty else { return }
        let (files, folders) = Outbox.splitFolders(urls)
        if let folder = folders.first { model.show("\(folder.lastPathComponent) is a folder. Send the files inside it") }
        guard !files.isEmpty else { return }
        Task {
            do {
                let copies = try await Outbox.copy(files)
                await sendCopies(copies, to: device, share: share, model: model)
            } catch {
                model.show("Cannot read the files: \(error.localizedDescription)")
            }
        }
    }

    /// Sends copies in the outbox and removes them after the transfer.
    private static func sendCopies(_ copies: [URL], to device: DeviceSnapshot, share: SharePlugin, model: AppModel) async {
        do {
            try await share.sendAndWait(files: copies, to: device.id) { _, _ in }
        } catch {
            model.show("Not connected. Try again in a moment")
        }
        Outbox.remove(copies)
    }

    /// Loads the picked photos and videos into the outbox and sends them.
    static func send(photos items: [PhotosPickerItem], to device: DeviceSnapshot, model: AppModel) {
        guard let share = model.core.plugin(SharePlugin.self), !items.isEmpty else { return }
        Task {
            var files: [URL] = []
            for item in items {
                do {
                    if let media = try await item.loadTransferable(type: PickedMedia.self) { files.append(media.url) }
                } catch {
                    model.show("Cannot read a photo: \(error.localizedDescription)")
                }
            }
            if !files.isEmpty { await sendCopies(files, to: device, share: share, model: model) }
        }
    }
}

/// The folder of the copies of files that go out. Each send removes its
/// copies after the transfer, and Flux empties the folder at launch, for
/// copies of a send that did not end.
enum Outbox {
    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Outbox", isDirectory: true) }

    static func clear() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Removes copies with their folders in the outbox.
    static func remove(_ copies: [URL]) {
        let root = folder.standardizedFileURL.path
        for dir in Set(copies.map { $0.deletingLastPathComponent().standardizedFileURL }) where dir.path.hasPrefix(root + "/") {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Splits picked URLs into files and folders.
    static func splitFolders(_ urls: [URL]) -> (files: [URL], folders: [URL]) {
        var files: [URL] = []
        var folders: [URL] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { folders.append(url) } else { files.append(url) }
        }
        return (files, folders)
    }

    /// A new folder in the outbox, so that files with the same name do not clash.
    static func newFolder() throws -> URL {
        let dir = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies files that the file picker gave, off the main thread. Each
    /// file gets its own folder, so that 2 files with the same name from
    /// different folders both go. A failure removes the copies so far.
    static func copy(_ urls: [URL]) async throws -> [URL] {
        try await Task.detached {
            var copies: [URL] = []
            do {
                for url in urls {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let target = try newFolder().appendingPathComponent(url.lastPathComponent)
                    // Listed before the copy, so that a failure also removes its folder.
                    copies.append(target)
                    try FileManager.default.copyItem(at: url, to: target)
                }
            } catch {
                remove(copies)
                throw error
            }
            return copies
        }.value
    }
}

/// A photo or video from the photo picker, copied into the outbox.
struct PickedMedia: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in try PickedMedia(received) }
        FileRepresentation(importedContentType: .movie) { received in try PickedMedia(received) }
    }

    private init(_ received: ReceivedTransferredFile) throws {
        let target = try Outbox.newFolder().appendingPathComponent(received.file.lastPathComponent)
        try FileManager.default.copyItem(at: received.file, to: target)
        url = target
    }
}

/// Picks files in the Files app and sends them.
struct SendFilesQuickAction: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot
    @State private var picking = false

    var body: some View {
        if model.core.plugin(SharePlugin.self) != nil, device.accepts(PacketType.share) {
            QuickAction(title: "Files", systemImage: "doc.badge.arrow.up") { picking = true }
                .accessibilityLabel("Send files")
                .accessibilityHint("Choose files to send to \(device.name)")
                .fileImporter(isPresented: $picking, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                    switch result {
                    case .success(let urls): ShareFeature.send(picked: urls, to: device, model: model)
                    case .failure(let error): model.show("Cannot open the files: \(error.localizedDescription)")
                    }
                }
        }
    }
}

/// Picks photos and videos and sends them.
struct SendPhotosQuickAction: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot
    @State private var items: [PhotosPickerItem] = []

    var body: some View {
        if model.core.plugin(SharePlugin.self) != nil, device.accepts(PacketType.share) {
            PhotosPicker(selection: $items, matching: .any(of: [.images, .videos])) {
                QuickActionLabel(title: "Photos", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(QuickActionStyle())
            .accessibilityLabel("Send photos")
            .accessibilityHint("Choose photos and videos to send to \(device.name)")
            .onChange(of: items) { _, picked in
                guard !picked.isEmpty else { return }
                ShareFeature.send(photos: picked, to: device, model: model)
                items = []
            }
        }
    }
}

/// Sends the clipboard: an image, or else its text.
struct SendClipboardQuickAction: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if let clipboard = model.core.plugin(ClipboardPlugin.self), device.accepts(PacketType.clipboard) {
            QuickAction(title: "Clipboard", systemImage: "doc.on.clipboard") { clipboard.sendClipboard(to: device.id) }
                .accessibilityLabel("Send clipboard")
                .accessibilityHint("Sends what you copied to \(device.name)")
        }
    }
}

/// The share screen of a computer.
struct ShareTile: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if let share = model.core.plugin(SharePlugin.self), device.accepts(PacketType.share) {
            let running = share.model.transfers.filter { $0.deviceId == device.id && $0.state == .running }
            let waiting = QueuedShares.shared.items(for: device.id).count
            FeatureTile("Share", systemImage: "square.and.arrow.up", tint: .blue,
                        subtitle: Self.subtitle(running: running.count, waiting: waiting)) {
                ShareScreen(deviceId: device.id)
            }
        }
    }

    static func subtitle(running: Int, waiting: Int) -> String {
        if running > 0 { return "\(running) transferring" }
        if waiting > 0 { return "\(waiting) waiting to send" }
        return "Files, photos, text, and links"
    }
}

/// Sends files, photos, text, and links, and lists the transfers with the computer.
struct ShareScreen: View {
    @Environment(AppModel.self) private var model
    let deviceId: String
    @State private var text = ""
    @State private var pickingFiles = false
    @State private var photos: [PhotosPickerItem] = []
    @FocusState private var editing: Bool

    var body: some View {
        if let device = model.device(deviceId), let share = model.core.plugin(SharePlugin.self) {
            let transfers = share.model.transfers.filter { $0.deviceId == device.id }
            List {
                Section {
                    Button { pickingFiles = true } label: {
                        Label("Choose Files", systemImage: "folder")
                    }
                    PhotosPicker(selection: $photos, matching: .any(of: [.images, .videos])) {
                        Label("Choose Photos and Videos", systemImage: "photo.on.rectangle")
                    }
                } header: {
                    Text("Send to \(device.name)")
                }
                .disabled(!device.online)
                Section {
                    VoiceField(keyHeight: 36, onText: { text = DictationText.append(text, $0) }) {
                        TextField("Text or link", text: $text, axis: .vertical)
                            .lineLimit(1...6)
                            .focused($editing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    }
                    Button(ShareWire.isURL(trimmed) ? "Send Link" : "Send Text", systemImage: "paperplane.fill") { sendText(share, to: device) }
                        .disabled(trimmed.isEmpty || !device.online)
                } footer: {
                    Text("A link opens in the browser of \(device.name). Text goes on its clipboard.")
                }
                QueuedSection(deviceId: device.id, deviceName: device.name)
                Section {
                    if transfers.isEmpty {
                        Text("No transfers yet")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(transfers) { TransferRow(transfer: $0) }
                } header: {
                    HStack {
                        Text("Transfers")
                        Spacer()
                        if transfers.contains(where: { $0.state != .running }) {
                            Button("Clear") { share.model.clearFinished() }
                                .font(.subheadline)
                                .textCase(nil)
                        }
                    }
                } footer: {
                    Text("Received files are in the Files app, in On My iPhone > Flux.")
                }
            }
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): ShareFeature.send(picked: urls, to: device, model: model)
                case .failure(let error): model.show("Cannot open the files: \(error.localizedDescription)")
                }
            }
            .onChange(of: photos) { _, picked in
                guard !picked.isEmpty else { return }
                ShareFeature.send(photos: picked, to: device, model: model)
                photos = []
            }
        }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func sendText(_ share: SharePlugin, to device: DeviceSnapshot) {
        guard !trimmed.isEmpty else { return }
        guard text.utf8.count <= ShareQueue.maxTextBytes else {
            model.show("The text is larger than 1 MB. Send it as a file")
            return
        }
        share.send(text: text, to: device.id)
        text = ""
        editing = false
    }
}

/// The items from the share sheet that wait for the computer, each with
/// Remove.
private struct QueuedSection: View {
    let deviceId: String
    let deviceName: String

    var body: some View {
        let items = QueuedShares.shared.items(for: deviceId)
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    QueuedRow(item: item) { QueuedShares.shared.remove(item.id) }
                        .swipeActions {
                            Button("Remove", role: .destructive) { QueuedShares.shared.remove(item.id) }
                        }
                }
            } header: {
                Text("Waiting to send")
            } footer: {
                Text("What you share with Flux from other apps goes to \(deviceName) when it is connected.")
            }
            .onAppear { QueuedShares.shared.refresh() }
        }
    }
}

/// 1 queued item: its name or text, and why the last try failed.
private struct QueuedRow: View {
    let item: QueuedShare
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name ?? item.text ?? "")
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let failure = item.failure {
                    Text("Not sent: \(failure)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text("Waiting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove")
        }
    }

    private var symbol: String {
        switch item.kind {
        case .file: "doc"
        case .link: "link"
        case .text: "text.alignleft"
        }
    }
}

/// 1 transfer with its progress. A tap on a received file opens it with Quick Look.
struct TransferRow: View {
    let transfer: FileTransfer

    var body: some View {
        if transfer.incoming, transfer.state == .done, let file = transfer.file {
            Button { ShareFeature.shared.preview = file } label: { content }
                .tint(.primary)
                .accessibilityHint("Opens the file")
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            Image(systemName: transfer.incoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.title2)
                .foregroundStyle(transfer.incoming ? Color.green : Color.accentColor)
                .accessibilityLabel(transfer.incoming ? "Received" : "Sent")
            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                status
            }
            Spacer(minLength: 0)
            if transfer.incoming, transfer.state == .done, transfer.file != nil {
                Image(systemName: "eye")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch transfer.state {
        case .running:
            if let fraction = transfer.fraction {
                ProgressView(value: fraction)
            } else {
                Text("\(Self.bytes(transfer.bytes)) so far")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .done:
            Text("\(transfer.incoming ? "Received" : "Sent") · \(Self.bytes(max(transfer.size, transfer.bytes)))")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text("Failed: \(message)")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

/// Shows received files with Quick Look over the whole app.
struct ShareRoot: ViewModifier {
    func body(content: Content) -> some View {
        @Bindable var share = ShareFeature.shared
        content.quickLookPreview($share.preview)
    }
}
