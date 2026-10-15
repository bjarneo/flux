import AppKit
import FluxKit
import SwiftUI

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

/// The dock of the chat: the clipboard of this Mac with Send, and the
/// field for text or a link. The + key at the left of the field opens a
/// menu with the tools and the other destinations. While a reply to an
/// agent is open, a row with Cancel takes the place of the clipboard, the +
/// key hides, and the field writes to the agent.
struct ChatDock: View {
    @Binding var ask: TargetAsk?
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @State private var clip: MacClip?
    @State private var text = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        let share = model.core.plugin(SharePlugin.self)
        let clipboard = model.core.plugin(ClipboardPlugin.self)
        let sent = share?.model.sent ?? []
        let target = ToolTarget.of(model)
        let browse = ToolTarget.of(model, can: { $0.accepts(PacketType.sftpRequest) })
        let on = ToolTarget.ready(target)
        let current = clip ?? MacClip()
        let sentClip = current.stamp == 0 ? nil : sent.last(where: { ($0.kind == .clip || $0.kind == .clipImage) && $0.clipStamp == current.stamp })
        VStack(alignment: .leading, spacing: 10) {
            if let reply = model.chatReply {
                replyRow(reply)
            } else {
                if clipboard != nil {
                    HStack(spacing: 8) {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            clipBox(current, sentClip: sentClip, now: context.date)
                        }
                        sendKey(on: on && !current.empty, sentClip: sentClip) {
                            ToolTarget.run(target, title: "Send the clipboard to", ask: $ask) { d in
                                _ = clipboard?.sendClipboard(to: d.id)
                            }
                        }
                    }
                    .frame(height: 44)
                }
            }
            if share != nil || model.chatReply != nil {
                composer(on: on, share: share, target: target, tools: tools(share: share, target: target, browse: browse))
            }
        }
        .pageDock(top: 12)
        .task {
            // The change count tells a new copy without a read of the data, so the page reads only a new clip.
            while !Task.isCancelled {
                let next = MacClip.read(after: clip)
                if next != clip { clip = next }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // A reply that starts from the menu bar panel is set before this page shows, so the first value counts too.
        .onChange(of: model.chatReply, initial: true) { _, reply in
            text = ""
            if reply != nil { focused = true }
        }
    }

    /// The row of a reply: the agent and its project, and Cancel.
    private func replyRow(_ reply: ChatReply) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tn.accent)
                .accessibilityHidden(true)
            Text("Reply to \(reply.agent)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tn.text)
                .lineLimit(1)
            if !reply.project.isEmpty {
                Text("· \(reply.project)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(tn.sub)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Cancel") { model.chatReply = nil }
                .buttonStyle(FluxButtonStyle(kind: .text))
                .help("Close the reply. The agent keeps its question.")
        }
        .padding(.leading, 4)
        .frame(minHeight: TiledMetrics.buttonHeight)
    }

    /// The clipboard in a box: where the clip came from or went, in cyan,
    /// and 1 line of the clip in mono, or a line about it.
    private func clipBox(_ c: MacClip, sentClip: SentItem?, now: Date) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let meta: String
        if let sentClip {
            meta = "Clipboard · sent at \(clockTime(sentClip.at))"
        } else if c.empty {
            meta = "Clipboard on this Mac · empty"
        } else if let at = c.copiedAt {
            meta = "Clipboard on this Mac · \(AgoText.text(at, now: now))"
        } else {
            meta = "Clipboard on this Mac"
        }
        let note = c.image ? "An image"
            : c.hidden ? "Hidden, because its app marks it as private"
            : c.unread ? "Send pastes the clipboard of this Mac on the computer"
            : "Copy text or an image on this Mac"
        return VStack(alignment: .leading, spacing: 1) {
            Text(meta)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(tn.cyan)
                .lineLimit(1)
            if let t = c.text {
                Text(t.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(tn.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(tn.sub)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
            HStack(spacing: 6) {
                Image(systemName: done ? "checkmark" : "doc.on.clipboard")
                    .font(.system(size: 14, weight: .medium))
                Text(done ? "Sent" : "Send")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 14)
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

    /// Send files, Get files, and the camera modes, for the menu of the + key. The camera window holds the other modes in its mode bar.
    private func tools(share: SharePlugin?, target: ActionTarget, browse: ActionTarget) -> [DockTool] {
        var list: [DockTool] = []
        if share != nil {
            list.append(DockTool(id: "files", icon: "doc.badge.arrow.up", label: "Send files", help: "Send files", enabled: ToolTarget.ready(target)) {
                ToolTarget.run(target, title: "Send files to", ask: $ask) { d in ShareActions.pickFiles(to: d, model: model) }
            })
        }
        if model.paired.isEmpty || Inbox.hasFeature(scope: model.scope, devices: model.state.devices, can: { $0.accepts(PacketType.sftpRequest) }) {
            list.append(DockTool(id: "get", icon: "folder", label: "Get files", help: "Open the home folder of the computer, read-only",
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

    /// The + key of the tools and the other destinations. It is a menu of
    /// the Mac: a click opens it, and a press, a drag, and a release on an
    /// item selects the item.
    private func plusMenu(_ tools: [DockTool]) -> some View {
        Menu {
            ForEach(tools) { k in
                Button(action: k.run) { Label(k.label, systemImage: k.icon) }
                    .disabled(!k.enabled)
                    .help(k.help)
            }
            Divider()
            Section("Go to") {
                ForEach([MacDestination.control, .computers]) { d in
                    Button { model.go(d) } label: { Label(d.title, systemImage: d.systemImage) }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tn.text)
                .frame(width: DictationLayout.keySize, height: DictationLayout.keySize)
                .background(Circle().fill(tn.line))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Files, the camera, and the other screens")
        .accessibilityLabel("Files, camera, and the other screens")
    }

    /// The + key, the field with the mic key, and the send key. A web link
    /// opens in the browser of the computer, and other text goes to its
    /// clipboard. While the field has the focus or a reply is open, the
    /// field has the accent border. The text of a reply goes to the agent
    /// after its choice, see `HerdrPlugin.tell`.
    private func composer(on: Bool, share: SharePlugin?, target: ActionTarget, tools: [DockTool]) -> some View {
        let reply = model.chatReply
        let enabled = reply != nil || on
        let canSend = enabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let send = {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            if let reply {
                tell(reply, value)
                return
            }
            guard on, let share else { return }
            ToolTarget.run(target, title: "Send to", ask: $ask) { d in
                if share.send(text: value, to: d.id) { text = "" }
            }
        }
        let placeholder: String
        if let reply {
            placeholder = "Tell \(reply.agent) what to do differently"
        } else if let one = ToolTarget.single(target) {
            placeholder = "Type text or a link for \(one.name)"
        } else {
            placeholder = "Type text or a link"
        }
        let shape = RoundedRectangle(cornerRadius: DictationLayout.keySize / 2, style: .continuous)
        return HStack(alignment: .top, spacing: 8) {
            if reply == nil { plusMenu(tools) }
            VoiceBar(language: model.dictationLanguage, enabled: enabled, onText: { spoken in
                text = DictationText.insert(text, start: text.utf16.count, end: text.utf16.count, spoken: spoken).text
            }) {
                TextField(placeholder, text: $text, prompt: Text(placeholder))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .fieldKeys(text: $text) { editing = true }
                    .padding(.horizontal, 14)
                    .frame(minHeight: DictationLayout.keySize)
                    .background(shape.fill(tn.bg))
                    // The border takes no clicks, so the clear and expand keys under it get them.
                    .overlay(shape.strokeBorder(reply != nil || focused ? tn.accent : tn.lineHi).allowsHitTesting(false))
                    .onSubmit(send)
                    .onExitCommand { if model.chatReply != nil { model.chatReply = nil } }
                    .disabled(!enabled)
                    .sheet(isPresented: $editing) {
                        // The editor checks the text at each change.
                        let ready = { enabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        FieldEditor(title: reply.map { "Reply to \($0.agent)" } ?? "Text or link", text: $text,
                                    action: FieldEditorAction(title: "Send", enabled: ready, run: send)) { editing = false }
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
                .help(reply == nil ? "Send the text or the link" : "Send the reply to \(reply?.agent ?? "the agent")")
                .accessibilityLabel("Send")
            }
        }
    }

    /// Sends the choice of the reply, then the text as the next prompt,
    /// after Touch ID or the password, as each answer to an agent does.
    private func tell(_ reply: ChatReply, _ value: String) {
        let model = model
        ReplyLock.run(reason: "answer agents on \(reply.computer)", action: {
            guard let plugin = model.core.plugin(HerdrPlugin.self) else { return }
            // The keys of the choice go out only while the agent shows the question that the user read.
            guard model.chatReply == reply, plugin.model.prompt(reply.deviceId, pane: reply.pane)?.lines == reply.lines else {
                model.chatReply = nil
                model.show("The question changed. Read it, then answer again.")
                return
            }
            ChatAnswers.shared.sent(value, reply.deviceId, pane: reply.pane, lines: reply.lines)
            plugin.tell(reply.deviceId, pane: reply.pane, keys: reply.choice.keys, text: value)
            text = ""
            model.chatReply = nil
        }, onError: { model.show($0) })
    }
}
