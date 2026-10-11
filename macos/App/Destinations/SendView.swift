import AppKit
import FluxKit
import SwiftUI
import UniformTypeIdentifiers

/// Send: what this Mac sent to the computers in scope, and the files that
/// came from them, as a thread with the newest at the bottom. The dock under
/// it shows the clipboard of this Mac with Send, the tools, and a field for
/// text or a link. Files, text, and links that you drop on the page go to
/// the computer too. With all computers in scope and more than 1 online,
/// each tool asks for the computer.
struct SendView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @State private var ask: TargetAsk?
    @State private var dropping = false

    var body: some View {
        let share = model.core.plugin(SharePlugin.self)
        let scope = model.scope
        let sent = (share?.model.sent ?? []).filter { scope == nil || $0.deviceId == scope }
        let transfers = (share?.model.transfers ?? []).filter { scope == nil || $0.deviceId == scope }
        let running = transfers.filter { $0.state == .running && $0.size > 0 }
        VStack(spacing: 0) {
            ComputerPills()
            ProgressLine {
                if !running.isEmpty {
                    let size = running.reduce(Int64(0)) { $0 + $1.size }
                    let done = running.reduce(Int64(0)) { $0 + min($1.bytes, $1.size) }
                    LineFill(fraction: size > 0 ? Double(done) / Double(size) : 0, color: tn.accent)
                }
            }
            SendThread(sent: sent, transfers: transfers, showComputer: scope == nil) { share?.model.clearFinished() }
            SendDock(sent: sent, ask: $ask)
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: TiledMetrics.tileCorner, style: .continuous)
                    .strokeBorder(tn.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $dropping) { providers in
            guard let share, let id = ShareActions.target(model) else { return false }
            ShareActions.drop(providers, to: id, share: share)
            return true
        }
        .targetPicker($ask)
        .navigationSubtitle(contextLine(["to \(scopeName(model))", onlineText(model)]))
        .destinationRoot(.send)
    }
}

// MARK: Thread

/// 1 entry of the thread: a link, a text, or a clip that went out, or a file.
private enum SendEntry: Identifiable {
    case sent(SentItem)
    case file(FileTransfer)

    var id: UUID {
        switch self {
        case .sent(let s): return s.id
        case .file(let f): return f.id
        }
    }

    var at: Date {
        switch self {
        case .sent(let s): return s.at
        case .file(let f): return f.started
        }
    }
}

/// The entries of the thread with the day over each new day, the newest at
/// the bottom. The view follows a new entry. Without entries, a line tells
/// what shows here. Without a computer to send to, the line of the target
/// tells why, with the next step.
private struct SendThread: View {
    let sent: [SentItem]
    let transfers: [FileTransfer]
    let showComputer: Bool
    let clearFinished: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let entries = (sent.map(SendEntry.sent) + transfers.map(SendEntry.file)).sorted { $0.at < $1.at }
        let target = ToolTarget.of(model)
        let unavailable: Bool = {
            if case .unavailable = target { return true }
            return false
        }()
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        Spacer(minLength: 0)
                        if entries.isEmpty && !unavailable {
                            Text("Links, text, and files that you send show here. To send files from Finder, drop them on this page or on the Dock icon, or select Services > Send to Flux.")
                                .font(.system(size: 12))
                                .foregroundStyle(tn.sub)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 24)
                        }
                        ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                            if i == 0 || !Calendar.current.isDate(entries[i - 1].at, inSameDayAs: e.at) {
                                Text(dayText(e.at))
                                    .font(.system(size: 11))
                                    .foregroundStyle(tn.sub)
                                    .frame(maxWidth: .infinity)
                            }
                            switch e {
                            case .sent(let s):
                                if s.kind == .clipImage {
                                    FileCard(icon: "photo", name: "Image", meta: sentMeta(s), state: .done, incoming: false)
                                } else {
                                    SentBubble(text: s.text.isEmpty ? "A private clip" : s.text, meta: sentMeta(s))
                                }
                            case .file(let f):
                                FileCard(icon: fileSymbol(f.name), name: f.name, meta: fileMeta(f), state: f.state, incoming: f.incoming,
                                         fraction: f.fraction, file: f.file, clearFinished: clearFinished)
                            }
                        }
                        if unavailable { TargetLine(verb: "Sends to") }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
                    .frame(maxWidth: TiledMetrics.maxContentWidth)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .bottom)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: entries.last?.id) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private func name(_ deviceId: String) -> String {
        model.state.devices.first { $0.id == deviceId }?.name ?? "the computer"
    }

    /// The line under a link, a text, or a clip, such as "Link · opened in the browser · 13:20".
    private func sentMeta(_ s: SentItem) -> String {
        let time = clockTime(s.at)
        switch s.kind {
        case .link: return showComputer ? "Link · opened on \(name(s.deviceId)) · \(time)" : "Link · opened in the browser · \(time)"
        case .text: return showComputer ? "Text · on the clipboard of \(name(s.deviceId)) · \(time)" : "Text · on the clipboard · \(time)"
        case .scan: return showComputer ? "Scan · saved on \(name(s.deviceId)) · \(time)" : "Scan · saved as a text file · \(time)"
        case .clip, .clipImage: return showComputer ? "Clipboard · to \(name(s.deviceId)) · \(time)" : "Clipboard · \(time)"
        }
    }

    /// The line under a file, such as "Sending · 22% of 18 KB" or "Received · in Downloads".
    private func fileMeta(_ f: FileTransfer) -> String {
        let from = name(f.deviceId)
        let pct = f.fraction.map { "\(Int($0 * 100))% of \(bytes(f.size))" } ?? "\(bytes(f.bytes)) so far"
        let time = clockTime(f.ended ?? f.started)
        switch f.state {
        case .running:
            return f.incoming ? "From \(from) · \(pct)" : (showComputer ? "Sending to \(from)" : "Sending") + " · \(pct)"
        case .done:
            return f.incoming ? "Received · in Downloads" : (showComputer ? "Sent to \(from)" : "Sent") + " · \(time)"
        case .failed:
            return (f.incoming ? "Not received" : "Not sent") + " · \(time)"
        }
    }

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// The symbol of a file of the thread: an image, or a document.
    private func fileSymbol(_ name: String) -> String {
        let type = UTType(filenameExtension: (name as NSString).pathExtension)
        return type?.conforms(to: .image) == true ? "photo" : "doc.text"
    }
}

/// A link, a text, or a clip that went out: a bubble at the right in mono,
/// with `meta` under it.
private struct SentBubble: View {
    let text: String
    let meta: String
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4, topTrailingRadius: 16, style: .continuous)
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 4) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(3)
                    .foregroundStyle(tn.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(shape.fill(tn.accentTile))
                    .overlay(shape.strokeBorder(tn.lineHi, lineWidth: 1))
                Text(meta)
                    .font(.system(size: 10.5))
                    .foregroundStyle(tn.sub)
            }
            .frame(maxWidth: 520, alignment: .trailing)
        }
    }
}

/// A file or an image clip: a card with its symbol, its name, and `meta`,
/// and a bar while it runs. A file from the computer is at the left. A
/// received file opens on a double click, and its menu shows it in Finder.
private struct FileCard: View {
    let icon: String
    let name: String
    let meta: String
    let state: FileTransfer.State
    let incoming: Bool
    var fraction: Double?
    var file: URL?
    var clearFinished: (() -> Void)?
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = tileShape()
        let failed: Bool = {
            if case .failed = state { return true }
            return false
        }()
        HStack {
            if !incoming { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 18))
                        .foregroundStyle(tn.accent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(tn.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(meta)
                            .font(.system(size: 11))
                            .foregroundStyle(failed ? tn.red : tn.sub)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    switch state {
                    case .running:
                        RingSpinner(size: 13)
                    case .done:
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(tn.green)
                    case .failed:
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(tn.red)
                    }
                }
                if state == .running, let fraction {
                    ZStack(alignment: .leading) {
                        Capsule().fill(tn.line)
                        LineFill(fraction: fraction, color: tn.accent).clipShape(Capsule())
                    }
                    .frame(height: 3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: 270)
            .background(shape.fill(tn.tile))
            .overlay(shape.strokeBorder(tn.line, lineWidth: 1))
            .contentShape(shape)
            .onTapGesture(count: 2) {
                if incoming, state == .done, let file { NSWorkspace.shared.open(file) }
            }
            .contextMenu {
                if let file, state == .done {
                    Button("Open") { NSWorkspace.shared.open(file) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
                if let clearFinished {
                    Divider()
                    Button("Clear Finished Transfers", action: clearFinished)
                }
            }
            .help(incoming && state == .done ? "Double-click to open \(name)" : name)
            if incoming { Spacer(minLength: 60) }
        }
    }
}

// MARK: Dock

/// The clipboard of this Mac for the dock. `text` is nil for an image, a
/// clip that its app marks as private (`hidden`), a clipboard that macOS
/// does not let Flux read (`unread`), or an empty clipboard. `stamp` is the
/// change count of the pasteboard. `copiedAt` is the time that this page saw
/// the change, or nil for a clip from before.
private struct MacClip: Equatable {
    var text: String?
    var image = false
    var hidden = false
    var unread = false
    var stamp = 0
    var copiedAt: Date?

    var empty: Bool { text == nil && !image && !hidden && !unread }

    /// The types that a password manager and similar apps put on a private clip.
    private static let privateTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    ]

    /// False when macOS asks before each read or denies it. The page then
    /// does not read the text, so that it shows no prompt.
    private static var mayRead: Bool {
        guard #available(macOS 15.4, *) else { return true }
        switch NSPasteboard.general.accessBehavior {
        case .ask, .alwaysDeny: return false
        default: return true
        }
    }

    /// Reads the pasteboard again when its change count is new. The types
    /// tell an image and a private clip apart without a read of the data.
    static func read(after previous: MacClip?) -> MacClip {
        let pb = NSPasteboard.general
        let stamp = pb.changeCount
        if let previous, previous.stamp == stamp { return previous }
        var clip = MacClip(stamp: stamp, copiedAt: previous == nil ? nil : Date())
        let types = Set(pb.types ?? [])
        guard !types.isEmpty else { return clip }
        if !types.isDisjoint(with: privateTypes) {
            clip.hidden = true
        } else if !types.contains(.string) && (types.contains(.png) || types.contains(.tiff)) {
            clip.image = true
        } else if !mayRead {
            clip.unread = true
        } else if let text = pb.string(forType: .string).map({ String($0.prefix(2000)) })?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            // The box shows 400 characters, so only the start of a large copy is trimmed.
            clip.text = String(text.prefix(400))
        }
        return clip
    }
}

/// A tool of the dock.
private struct DockTool: Identifiable {
    let id: String
    let icon: String
    let label: String
    let help: String
    let enabled: Bool
    let run: () -> Void
}

/// The dock of Send: the clipboard of this Mac with Send, the tools, and the
/// field for text or a link. `sent` tells whether the clip went out already.
private struct SendDock: View {
    let sent: [SentItem]
    @Binding var ask: TargetAsk?
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @State private var clip: MacClip?
    @State private var text = ""
    @State private var editing = false

    var body: some View {
        let share = model.core.plugin(SharePlugin.self)
        let clipboard = model.core.plugin(ClipboardPlugin.self)
        let target = ToolTarget.of(model)
        let browse = ToolTarget.of(model, can: { $0.accepts(PacketType.sftpRequest) })
        let on = ToolTarget.ready(target)
        let current = clip ?? MacClip()
        let sentClip = current.stamp == 0 ? nil : sent.last(where: { ($0.kind == .clip || $0.kind == .clipImage) && $0.clipStamp == current.stamp })
        VStack(alignment: .leading, spacing: 10) {
            if clipboard != nil {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    clipRow(current, sentClip: sentClip, now: context.date)
                }
                HStack(spacing: 8) {
                    clipBox(current)
                    sendKey(on: on && !current.empty, sentClip: sentClip) {
                        ToolTarget.run(target, title: "Send the clipboard to", ask: $ask) { d in
                            _ = clipboard?.sendClipboard(to: d.id)
                        }
                    }
                }
                .frame(height: 52)
            }
            HStack(spacing: 6) {
                ForEach(tools(share: share, target: target, browse: browse)) { k in
                    DockKey(help: k.help, enabled: k.enabled, action: k.run) {
                        VStack(spacing: 3) {
                            Image(systemName: k.icon)
                                .font(.system(size: 16))
                                .foregroundStyle(tn.accent)
                            Text(k.label)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(tn.text)
                                .lineLimit(1)
                        }
                    }
                }
            }
            if share != nil { composer(on: on, share: share, target: target) }
        }
        .pageDock()
        .task {
            // The change count tells a new copy without a read of the data, so the page reads only a new clip.
            while !Task.isCancelled {
                let next = MacClip.read(after: clip)
                if next != clip { clip = next }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// "Clipboard" and its state: where the clip went, when this Mac copied it, or that it is empty.
    private func clipRow(_ c: MacClip, sentClip: SentItem?, now: Date) -> some View {
        let meta: String
        if let sentClip {
            let to = model.state.devices.first { $0.id == sentClip.deviceId }?.name ?? "the computer"
            meta = "sent to \(to) at \(clockTime(sentClip.at))"
        } else if c.empty {
            meta = "empty"
        } else if let at = c.copiedAt {
            meta = "copied \(AgoText.text(at, now: now)) on this Mac"
        } else {
            meta = "on this Mac"
        }
        return HStack(spacing: 8) {
            Circle().fill(tn.cyan).frame(width: 7, height: 7).accessibilityHidden(true)
            Text("Clipboard")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(tn.cyan)
            Text("· \(meta)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(tn.sub)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    /// The clip in mono, or a line about it.
    private func clipBox(_ c: MacClip) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let note = c.image ? "An image"
            : c.hidden ? "Hidden, because the app that copied it marks it as private"
            : c.unread ? "Send pastes the clipboard of this Mac on the computer"
            : "Copy text or an image on this Mac"
        return Group {
            if let t = c.text {
                Text(t)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(tn.text)
                    .lineLimit(2)
            } else {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(tn.sub)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(tn.bg))
        .accessibilityElement(children: .combine)
    }

    /// Send, or Sent while the clip on the pasteboard went out already.
    private func sendKey(on: Bool, sentClip: SentItem?, send: @escaping () -> Void) -> some View {
        let done = sentClip != nil
        let ink = done ? tn.text : tn.onAccent
        let shape = RoundedRectangle(cornerRadius: TiledMetrics.tileCorner, style: .continuous)
        return Button {
            if done {
                model.show("The clip is on the computer already")
            } else {
                send()
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: done ? "checkmark" : "doc.on.clipboard")
                    .font(.system(size: 15, weight: .medium))
                Text(done ? "Sent" : "Send")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(ink)
            .frame(width: 84)
            .frame(maxHeight: .infinity)
            .background(shape.fill(done ? tn.line : tn.accent))
            .contentShape(shape)
        }
        .buttonStyle(TilePressStyle())
        .disabled(!on)
        .opacity(on ? 1 : TiledMetrics.disabledAlpha)
        .help(done ? "The clip went out already" : "Send the clipboard of this Mac")
        .accessibilityLabel(done ? "Sent" : "Send the clipboard")
    }

    /// Files, Get, and the camera modes of Send. The camera window holds the other modes in its mode bar.
    private func tools(share: SharePlugin?, target: ActionTarget, browse: ActionTarget) -> [DockTool] {
        var list: [DockTool] = []
        if share != nil {
            list.append(DockTool(id: "files", icon: "doc.badge.arrow.up", label: "Files", help: "Send files", enabled: ToolTarget.ready(target)) {
                ToolTarget.run(target, title: "Send files to", ask: $ask) { d in ShareActions.pickFiles(to: d, model: model) }
            })
        }
        if model.paired.isEmpty || Inbox.hasFeature(scope: model.scope, devices: model.state.devices, can: { $0.accepts(PacketType.sftpRequest) }) {
            list.append(DockTool(id: "get", icon: "folder", label: "Get", help: "Open the home folder of the computer, read-only",
                                 enabled: ToolTarget.ready(browse)) {
                ToolTarget.run(browse, title: "Get files from", ask: $ask) { d in BrowseWindows.shared.show(d.id, app: model) }
            })
        }
        let modes: [(CameraMode, String)] = [(.photo, "Photo"), (.document, "Scan"), (.text, "Text"), (.qr, "QR")]
        for (mode, label) in modes {
            list.append(DockTool(id: mode.rawValue, icon: mode.systemImage, label: label, help: mode.hint, enabled: ToolTarget.ready(target)) {
                ToolTarget.run(target, title: "Open the camera for", ask: $ask) { d in CameraWindows.shared.show(d, mode: mode, app: model) }
            })
        }
        return list
    }

    /// The field for text or a link, with the mic key and the send key. A
    /// web link opens in the browser of the computer, and other text goes to
    /// its clipboard.
    private func composer(on: Bool, share: SharePlugin?, target: ActionTarget) -> some View {
        let canSend = on && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let send = {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard on, !value.isEmpty, let share else { return }
            ToolTarget.run(target, title: "Send to", ask: $ask) { d in
                if share.send(text: value, to: d.id) { text = "" }
            }
        }
        let shape = RoundedRectangle(cornerRadius: DictationLayout.keySize / 2, style: .continuous)
        return VoiceBar(language: model.dictationLanguage, enabled: on, onText: { spoken in
            text = DictationText.insert(text, start: text.utf16.count, end: text.utf16.count, spoken: spoken).text
        }) {
            TextField("Type text or a link", text: $text, prompt: Text("Type text or a link"))
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .fieldKeys(text: $text) { editing = true }
                .padding(.horizontal, 14)
                .frame(minHeight: DictationLayout.keySize)
                .background(shape.fill(tn.bg))
                .overlay(shape.strokeBorder(tn.lineHi))
                .onSubmit(send)
                .disabled(!on)
                .sheet(isPresented: $editing) {
                    // The editor checks the text at each change.
                    let enabled = { on && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    FieldEditor(title: "Text or link", text: $text,
                                action: FieldEditorAction(title: "Send", enabled: enabled, run: send)) { editing = false }
                }
        } send: {
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(canSend ? tn.onAccent : tn.sub)
                    .frame(width: DictationLayout.keySize, height: DictationLayout.keySize)
                    .background(Circle().fill(canSend ? tn.accent : tn.line))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send the text or the link")
            .accessibilityLabel("Send")
        }
    }
}
