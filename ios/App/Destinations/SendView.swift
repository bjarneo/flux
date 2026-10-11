import FluxKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Send destination: what this iPhone sent to the computers in scope,
/// and the files that came from them, as a thread with the newest at the
/// bottom. The dock under it shows the clipboard of this iPhone with Send,
/// the tools, and a field for text or a link. With all computers in scope
/// and more than 1 online, each action asks for the computer first.
struct SendView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @State private var filesTarget: DeviceSnapshot?
    @State private var pickingFiles = false
    @State private var photosTarget: DeviceSnapshot?
    @State private var pickingPhotos = false
    @State private var photos: [PhotosPickerItem] = []

    var body: some View {
        let share = model.core.plugin(SharePlugin.self)
        let scope = model.scope
        let sent = (model.demo ? DemoMode.sent : share?.model.sent ?? []).filter { scope == nil || $0.deviceId == scope }
        let transfers = (model.demo ? DemoMode.sendTransfers : share?.model.transfers ?? []).filter { scope == nil || $0.deviceId == scope }
        let rows = SendRow.merge(sent: sent, transfers: transfers)
        let running = transfers.filter { $0.state == .running && $0.size > 0 }
        VStack(spacing: 0) {
            ComputerStrip()
            ProgressLine {
                if !running.isEmpty {
                    let size = running.reduce(Int64(0)) { $0 + $1.size }
                    let done = running.reduce(Int64(0)) { $0 + $1.bytes }
                    LineFill(fraction: Double(done) / Double(max(size, 1)), color: tn.accent)
                }
            }
            SendThread(rows: rows, showComputer: scope == nil)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    SendDock(sent: sent, tools: tools, onText: sendText)
                }
        }
        .destinationRoot("Send", context: ScreenWords.join("to \(ScreenWords.scopeName(model))", ScreenWords.online(model)))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { pickPhotos() } label: { Label("Send photos", systemImage: "photo.on.rectangle") }
                    Button { open(canCamera, "Send from the camera to") { .cameraMode($0, .signature) } } label: {
                        Label(CameraMode.signature.label, systemImage: CameraMode.signature.systemImage)
                    }
                    Button { open(SendTools.canShare(model), "Show the queue and the transfers of") { .share($0) } } label: {
                        Label("Queue and transfers", systemImage: "tray.full")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More ways to send")
            }
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            guard let d = filesTarget else { return }
            switch result {
            case .success(let urls): ShareFeature.send(picked: urls, to: d, model: model)
            case .failure(let error): model.show("Cannot open the files: \(error.localizedDescription)")
            }
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $photos, matching: .any(of: [.images, .videos]))
        .onChange(of: photos) { _, picked in
            guard !picked.isEmpty else { return }
            if let d = photosTarget { ShareFeature.send(photos: picked, to: d, model: model) }
            photos = []
        }
    }

    /// The 6 tools of the dock.
    private var tools: [SendDockTool] {
        let share = SendTools.canShare(model)
        let browse = canBrowse
        let camera = canCamera
        return [
            SendDockTool(icon: "doc.badge.arrow.up", label: "Files", name: "Send files", enabled: TargetRun.enabled(model, can: share)) {
                TargetRun.run(model, can: share, title: "Send files to") { d in
                    filesTarget = d
                    pickingFiles = true
                }
            },
            SendDockTool(icon: "folder", label: "Get", name: "Get files from the computer", enabled: TargetRun.enabled(model, can: browse)) {
                open(browse, "Get files from") { .browse($0) }
            },
            SendDockTool(icon: CameraMode.photo.systemImage, label: "Photo", name: CameraMode.photo.hint, enabled: TargetRun.enabled(model, can: camera)) {
                open(camera, "Send from the camera to") { .cameraMode($0, .photo) }
            },
            SendDockTool(icon: CameraMode.document.systemImage, label: "Scan", name: CameraMode.document.hint, enabled: TargetRun.enabled(model, can: camera)) {
                open(camera, "Send from the camera to") { .cameraMode($0, .document) }
            },
            SendDockTool(icon: CameraMode.text.systemImage, label: "Text", name: CameraMode.text.hint, enabled: TargetRun.enabled(model, can: camera)) {
                open(camera, "Send from the camera to") { .cameraMode($0, .text) }
            },
            SendDockTool(icon: CameraMode.qr.systemImage, label: "QR", name: CameraMode.qr.hint, enabled: TargetRun.enabled(model, can: camera)) {
                open(camera, "Send from the camera to") { .cameraMode($0, .qr) }
            },
        ]
    }

    private func pickPhotos() {
        TargetRun.run(model, can: SendTools.canShare(model), title: "Send photos to") { d in
            photosTarget = d
            pickingPhotos = true
        }
    }

    /// Sends text or a link from the field. A web link opens in the browser
    /// of the computer, and other text goes to its clipboard.
    private func sendText(_ text: String) {
        TargetRun.run(model, can: SendTools.canShare(model), title: "Send to") { d in
            if model.demo {
                model.show(DemoMode.sendsNothing)
                return
            }
            guard text.utf8.count <= ShareQueue.maxTextBytes else {
                model.show("The text is larger than 1 MB. Send it as a file")
                return
            }
            model.core.plugin(SharePlugin.self)?.send(text: text, to: d.id)
        }
    }

    /// The computers that open their files, see `BrowseTile`.
    private var canBrowse: (DeviceSnapshot) -> Bool {
        let has = model.core.plugin(BrowsePlugin.self) != nil
        return { has && $0.accepts(PacketType.sftpRequest) }
    }

    /// The computers that take the camera modes, see `CameraTile`.
    private var canCamera: (DeviceSnapshot) -> Bool {
        return { $0.accepts(PacketType.share) }
    }

    /// Opens the screen of `route` for the computer of the tool.
    private func open(_ can: (DeviceSnapshot) -> Bool, _ title: String, _ route: @escaping (String) -> FeatureRoute) {
        TargetRun.run(model, can: can, title: title) { d in
            model.sendPath.append(.feature(route(d.id)))
        }
    }
}

// MARK: Thread

/// 1 row of the Send thread: an item that went out, or a file in either direction.
enum SendRow: Identifiable {
    case sent(SentItem)
    case transfer(FileTransfer)

    var id: UUID {
        switch self {
        case .sent(let s): return s.id
        case .transfer(let t): return t.id
        }
    }

    var at: Date {
        switch self {
        case .sent(let s): return s.at
        case .transfer(let t): return t.started
        }
    }

    /// The items and the transfers by time, oldest first.
    static func merge(sent: [SentItem], transfers: [FileTransfer]) -> [SendRow] {
        (sent.map { SendRow.sent($0) } + transfers.map { SendRow.transfer($0) }).sorted { $0.at < $1.at }
    }
}

/// The rows of the Send thread with the day over each new day, the newest
/// at the bottom. The view starts at the newest row and follows a new row.
/// Without rows, a line tells what shows here.
private struct SendThread: View {
    let rows: [SendRow]
    let showComputer: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        // Without a computer to send to, the line of the target tells why, with the next step.
        let none: Bool = {
            if case .unavailable = Inbox.target(scope: model.scope, devices: model.state.devices) { return true }
            return false
        }()
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    if rows.isEmpty && !none {
                        Text("Links, text, and files that you send show here. To send from another app, select the text or the file, then choose Flux in the Share menu.")
                            .font(.footnote)
                            .foregroundStyle(tn.sub)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                            .padding(.top, 24)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                        if i == 0 || !Calendar.current.isDate(rows[i - 1].at, inSameDayAs: row.at) {
                            Text(ThreadTime.day(row.at))
                                .font(.caption)
                                .foregroundStyle(tn.sub)
                                .frame(maxWidth: .infinity)
                                .accessibilityAddTraits(.isHeader)
                        }
                        rowView(row)
                    }
                    if none { TargetLine(verb: "Sends to") }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 14)
                .frame(maxWidth: TiledMetrics.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: rows.count) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    @ViewBuilder
    private func rowView(_ row: SendRow) -> some View {
        switch row {
        case .sent(let s):
            if s.kind == .clipImage {
                SendFileCard(icon: "photo", name: "Image", meta: meta(s), incoming: false, state: .done, fraction: nil, file: nil)
            } else {
                SendBubble(text: s.text.isEmpty ? "A private clip" : s.text, meta: meta(s))
            }
        case .transfer(let t):
            SendFileCard(icon: Self.fileIcon(t.name), name: t.name, meta: meta(t), incoming: t.incoming, state: t.state,
                         fraction: t.fraction, file: t.incoming && t.state == .done ? t.file : nil)
        }
    }

    private func name(_ id: String) -> String { model.device(id)?.name ?? "the computer" }

    private func meta(_ s: SentItem) -> String {
        let time = ThreadTime.clock(s.at)
        switch s.kind {
        case .link: return showComputer ? "Link · opened on \(name(s.deviceId)) · \(time)" : "Link · opened in the browser · \(time)"
        case .text: return showComputer ? "Text · on the clipboard of \(name(s.deviceId)) · \(time)" : "Text · on the clipboard · \(time)"
        case .scan: return showComputer ? "Scan · saved on \(name(s.deviceId)) · \(time)" : "Scan · saved as a text file · \(time)"
        case .clip, .clipImage: return showComputer ? "Clipboard · to \(name(s.deviceId)) · \(time)" : "Clipboard · \(time)"
        }
    }

    private func meta(_ t: FileTransfer) -> String {
        let time = ThreadTime.clock(t.ended ?? t.started)
        let size = TransferRow.bytes(max(t.size, 0))
        let pct = t.fraction.map { "\(Int($0 * 100))% of \(size)" } ?? "\(TransferRow.bytes(t.bytes)) so far"
        switch t.state {
        case .running:
            if t.incoming { return "From \(name(t.deviceId)) · \(pct)" }
            return (showComputer ? "Sending to \(name(t.deviceId))" : "Sending") + " · \(pct)"
        case .done:
            if t.incoming { return "Received · in Files" }
            return (showComputer ? "Sent to \(name(t.deviceId))" : "Sent") + " · \(time)"
        case .failed:
            return (t.incoming ? "Not received" : "Not sent") + " · \(time)"
        }
    }

    /// The icon of a file: an image, or a document.
    static func fileIcon(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "webp", "heic", "avif", "bmp"].contains(ext) ? "photo" : "doc.text"
    }
}

/// Text, a link, or a clip that went out: a bubble at the trailing side in
/// mono, with the meta line under it.
private struct SendBubble: View {
    let text: String
    let meta: String
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4, topTrailingRadius: 16, style: .continuous)
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 4) {
                Text(text)
                    .font(.footnote.monospaced())
                    .foregroundStyle(tn.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(shape.fill(tn.accentTile))
                    .overlay(shape.strokeBorder(tn.lineHi, lineWidth: 1))
                Text(meta)
                    .font(.caption2)
                    .foregroundStyle(tn.sub)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A file or an image clip: a card of 244 pt with its icon, its name, the
/// meta line, and a bar while it runs. A file from the computer is at the
/// leading side. A tap on a received file opens it with Quick Look.
private struct SendFileCard: View {
    let icon: String
    let name: String
    let meta: String
    let incoming: Bool
    let state: FileTransfer.State
    let fraction: Double?
    let file: URL?
    @Environment(\.tn) private var tn

    var body: some View {
        HStack {
            if !incoming { Spacer(minLength: 0) }
            card
                .onTapGesture { if let file { ShareFeature.shared.preview = file } }
                .accessibilityAddTraits(file != nil ? .isButton : [])
                .accessibilityHint(file != nil ? "Opens the file" : "")
            if incoming { Spacer(minLength: 0) }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                    .foregroundStyle(tn.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.footnote.monospaced().weight(.medium))
                        .foregroundStyle(tn.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(failed ? tn.red : tn.sub)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                mark
            }
            if state == .running {
                ZStack(alignment: .leading) {
                    Capsule().fill(tn.line)
                    LineFill(fraction: fraction ?? 0, color: tn.accent).clipShape(Capsule())
                }
                .frame(height: 3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 244)
        .background(tileShape().fill(tn.tile))
        .overlay(tileShape().strokeBorder(tn.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var mark: some View {
        switch state {
        case .running: RingSpinner(size: 14, color: tn.accent)
        case .done: Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(tn.green)
        case .failed: Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(tn.red)
        }
    }

    private var failed: Bool {
        if case .failed = state { return true }
        return false
    }
}

// MARK: Dock

/// A tool of the Send dock. `name` is the label for VoiceOver.
struct SendDockTool: Identifiable {
    let icon: String
    let label: String
    let name: String
    var enabled = true
    let action: () -> Void

    var id: String { label }
}

/// The dock of Send: the clipboard of this iPhone with Send, the 6 tools,
/// and the field for text or a link. iOS asks before an app reads the
/// clipboard, so the dock shows only the kind of the copy, and the text of a
/// copy that went out from here.
private struct SendDock: View {
    let sent: [SentItem]
    let tools: [SendDockTool]
    let onText: (String) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""
    /// The change count of the clipboard and the kind of the copy.
    @State private var clip = PhoneClip(count: 0, kind: .empty)

    var body: some View {
        let last = sent.last { clip.count != 0 && $0.clipStamp == clip.count && ($0.kind == .clip || $0.kind == .clipImage) }
        let canClip = TargetRun.enabled(model, can: SendTools.canClipboard(model)) && clip.kind != .empty
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(tn.cyan).frame(width: 8, height: 8)
                Text("Clipboard")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(tn.cyan)
                Text("· " + clipMeta(last))
                    .font(.caption2.monospaced())
                    .foregroundStyle(tn.sub)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            HStack(spacing: 8) {
                Text(clipText(last))
                    .font(.caption.monospaced())
                    .foregroundStyle(last.map { !$0.text.isEmpty } ?? false ? tn.text : tn.sub)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tn.bg))
                Button {
                    if let last {
                        model.show("The clip is on \(model.device(last.deviceId)?.name ?? "the computer") already")
                    } else {
                        SendTools.sendClipboard(model)
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: last != nil ? "checkmark" : "doc.on.clipboard")
                            .font(.system(size: 18))
                        Text(last != nil ? "Sent" : "Send")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(last != nil ? tn.text : tn.onAccent)
                    .frame(width: 88)
                    .frame(maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(last != nil ? tn.line : tn.accent))
                }
                .buttonStyle(.plain)
                .disabled(!canClip)
                .opacity(canClip ? 1 : TiledMetrics.disabledAlpha)
                .accessibilityLabel("Send the clipboard")
            }
            .frame(height: 56)
            HStack(spacing: 6) {
                ForEach(tools) { k in
                    DockKeyButton(name: k.name, enabled: k.enabled, action: k.action) {
                        VStack(spacing: 3) {
                            Image(systemName: k.icon)
                                .font(.system(size: 18))
                                .foregroundStyle(tn.accent)
                            Text(k.label)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(tn.text)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                }
            }
            composer
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .dockFrame()
        .onAppear { clip = PhoneClip.now() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { clip = PhoneClip.now() } }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in clip = PhoneClip.now() }
        .task {
            // iOS posts no notice for a copy in another app, so the dock checks the change count while it shows.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let next = PhoneClip.now()
                if next != clip { clip = next }
            }
        }
    }

    private var composer: some View {
        let can = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: 8) {
            TextField("Type text or a link", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .font(.subheadline)
                .foregroundStyle(tn.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .frame(minHeight: 48)
                .background(Capsule().fill(tn.bg))
                .overlay(Capsule().strokeBorder(tn.lineHi, lineWidth: 1))
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(can ? tn.onAccent : tn.sub)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(can ? tn.accent : tn.line))
            }
            .buttonStyle(.plain)
            .disabled(!can)
            .accessibilityLabel("Send")
        }
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onText(t)
        text = ""
    }

    private func clipMeta(_ last: SentItem?) -> String {
        if let last { return "sent to \(model.device(last.deviceId)?.name ?? "the computer") at \(ThreadTime.clock(last.at))" }
        switch clip.kind {
        case .empty: return "empty"
        case .text, .image: return "on this iPhone"
        }
    }

    private func clipText(_ last: SentItem?) -> String {
        if let last, !last.text.isEmpty { return last.text }
        switch clip.kind {
        case .empty: return "Copy text or an image on this iPhone"
        case .image: return "An image"
        case .text: return "Text. Tap Send to paste it on the computer"
        }
    }
}

/// The kind of the copy on the clipboard of this iPhone, and its change
/// count. The checks do not read the copy, so iOS does not ask.
struct PhoneClip: Equatable {
    enum Kind: Equatable { case empty, text, image }

    let count: Int
    let kind: Kind

    @MainActor
    static func now() -> PhoneClip {
        let pb = UIPasteboard.general
        let kind: Kind = pb.hasImages && !pb.hasStrings ? .image : (pb.hasStrings || pb.hasURLs ? .text : .empty)
        return PhoneClip(count: pb.changeCount, kind: kind)
    }
}
