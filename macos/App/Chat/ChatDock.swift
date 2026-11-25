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
            // The row shows 1 line, so only the start of a large copy is trimmed.
            clip.text = String(text.prefix(400))
        }
        return clip
    }
}

/// The dock of the chat of a computer: the clipboard of this Mac in a row
/// with Send, the composer, and the tray under it while it is open. The +
/// key of the composer opens and closes the tray, and it turns into an
/// accent key with a cross. The screenshots that the tray selects go out
/// with the send key. The field and the tray exclude each other: a click in
/// the field closes the tray. Escape also closes it.
struct ChatDock: View {
    let device: DeviceSnapshot
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clip: MacClip?
    @State private var text = ""
    @State private var editing = false
    @State private var tray = false
    /// The screenshots that the tray selected, in the order of the clicks.
    @State private var shots: [URL] = []
    @FocusState private var focused: Bool

    var body: some View {
        let share = model.core.plugin(SharePlugin.self)
        let clipboard = model.core.plugin(ClipboardPlugin.self)
        let sent = share?.model.sent ?? []
        let on = device.online
        let current = clip ?? MacClip()
        let sentClip = current.stamp == 0 ? nil : sent.last(where: {
            ($0.kind == .clip || $0.kind == .clipImage) && $0.clipStamp == current.stamp && $0.deviceId == device.id
        })
        VStack(alignment: .leading, spacing: 10) {
            if clipboard != nil {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    clipRow(current, sentClip: sentClip, on: on && !current.empty, now: context.date) {
                        _ = clipboard?.sendClipboard(to: device.id)
                    }
                }
            }
            if share != nil {
                composer(on: on, share: share)
            }
            if tray {
                ChatTray(device: device, shots: $shots) { tray = false }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(Motion.standard(reduceMotion), value: tray)
        .pageDock(top: 12)
        .task {
            // The change count tells a new copy without a read of the data, so the page reads only a new clip.
            while !Task.isCancelled {
                let next = MacClip.read(after: clip)
                if next != clip { clip = next }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: focused) { _, now in
            if now { tray = false }
        }
    }

    /// The clipboard of this Mac in a row on `bg`: the clipboard icon in
    /// cyan, where the clip came from or went in cyan, 1 line of the clip in
    /// mono or a line about it, and Send as a text action. After a send, the
    /// action shows Sent.
    private func clipRow(_ c: MacClip, sentClip: SentItem?, on: Bool, now: Date, send: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let done = sentClip != nil
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
        return HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 14))
                .foregroundStyle(tn.cyan)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
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
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button(done ? "Sent" : "Send") {
                if done {
                    model.show("The clip is on the computer already")
                } else {
                    send()
                }
            }
            .buttonStyle(FluxButtonStyle(kind: .text))
            .disabled(!on)
            .help(done ? "The clip went out already" : "Send the clipboard of this Mac to \(device.name)")
            .accessibilityLabel(done ? "Sent" : "Send the clipboard")
        }
        .padding(.leading, 11)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .background(shape.fill(tn.bg))
    }

    /// The + key of the tray: `line` with a plus while the tray is closed,
    /// and the accent with a cross while it is open.
    private var trayKey: some View {
        Button {
            if !tray { focused = false }
            tray.toggle()
        } label: {
            Image(systemName: tray ? "xmark" : "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tray ? tn.onAccent : tn.text)
                .frame(width: DictationLayout.keySize, height: DictationLayout.keySize)
                .background(Circle().fill(tray ? tn.accent : tn.line))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(tray ? .cancelAction : nil)
        .help(tray ? "Close the tools" : "Files, the camera, and the other tools")
        .accessibilityLabel(tray ? "Close the tools" : "Files, camera, and tools")
    }

    /// The + key, the field with the mic key, and the send key. The send key
    /// sends the selected screenshots and the text, and it shows the number
    /// of screenshots. A web link opens in the browser of the computer, and
    /// other text goes to its clipboard. While the field has the focus, it
    /// has the accent border.
    private func composer(on: Bool, share: SharePlugin?) -> some View {
        let count = shots.count
        let sendShots = count == 1 ? "Send 1 screenshot" : "Send \(count) screenshots"
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canSend = on && (hasText || count > 0)
        let send = {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard on, let share else { return }
            if !shots.isEmpty {
                share.send(files: shots, to: device.id)
                shots = []
                tray = false
            }
            if !value.isEmpty, share.send(text: value, to: device.id) { text = "" }
        }
        let placeholder = "Message \(device.name)"
        let shape = RoundedRectangle(cornerRadius: DictationLayout.keySize / 2, style: .continuous)
        return HStack(alignment: .top, spacing: 8) {
            trayKey
            VoiceBar(language: model.dictationLanguage, enabled: on, onText: { spoken in
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
                    .overlay(shape.strokeBorder(focused ? tn.accent : tn.lineHi).allowsHitTesting(false))
                    .onSubmit(send)
                    .disabled(!on)
                    .sheet(isPresented: $editing) {
                        // The editor checks the text at each change.
                        let ready = { on && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        FieldEditor(title: "Message \(device.name)", text: $text,
                                    action: FieldEditorAction(title: "Send", enabled: ready, run: send)) { editing = false }
                    }
            } send: {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(canSend ? tn.onAccent : tn.sub)
                        .frame(width: DictationLayout.keySize, height: DictationLayout.keySize)
                        .background(Circle().fill(canSend ? tn.accent : tn.line))
                        .overlay(alignment: .topTrailing) {
                            if count > 0 {
                                Text("\(count)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(tn.bg)
                                    .frame(width: 16, height: 16)
                                    .background(Circle().fill(tn.text))
                                    .offset(x: 4, y: -4)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help(count > 0 ? sendShots : "Send the text or the link")
                .accessibilityLabel(count > 0 ? sendShots : "Send")
            }
        }
    }
}
