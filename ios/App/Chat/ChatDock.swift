import FluxKit
import SwiftUI
import UIKit

/// The dock of the chat of a computer: the clipboard of this iPhone with
/// Send, the composer, and the tray under the composer while it is open.
/// The + key of the composer opens and closes the tray, see `ChatTray`.
/// The photos that the tray selects go out with the send key. iOS asks
/// before an app reads the clipboard, so the dock shows only the kind of
/// the copy, and the text of a copy that went out from here. `sent` tells
/// whether the copy went out already. `onNewAgent` opens the new pane
/// sheet for the computer.
struct ChatDock: View {
    let device: DeviceSnapshot
    let sent: [SentItem]
    let onNewAgent: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""
    /// The change count of the clipboard and the kind of the copy.
    @State private var clip = PhoneClip(count: 0, kind: .empty)
    @State private var voice = VoiceTyping()
    @State private var editing = false
    @State private var trayOpen = false
    /// The local IDs of the photos that the tray selected, in the order of the taps.
    @State private var picked: [String] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 10) {
            clipRow
            composer
            VoiceStatus(voice: voice)
            if trayOpen {
                ChatTray(device: device, picked: $picked, onClose: { trayOpen = false }, onNewAgent: onNewAgent)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .dockFrame()
        .animation(.snappy(duration: 0.2), value: trayOpen)
        .onAppear { clip = PhoneClip.now() }
        .task { await voice.load() }
        // The field is gone, so the words of a dictation have no place.
        .onDisappear { voice.cancel() }
        .sheet(isPresented: $editing) {
            FieldEditor(title: "Message \(device.name)", text: $text, actionLabel: "Send", actionEnabled: canSend, onAction: send)
        }
        // The tray and the keyboard take the same place, so 1 closes the other.
        .onChange(of: focused) { _, on in if on { trayOpen = false } }
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

    /// True when the send key can send: the computer is online, and the
    /// field holds text or the tray selected photos.
    private var canSend: Bool {
        device.online && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !picked.isEmpty)
    }

    /// The clipboard of this iPhone and its Send action, on `bg` with 10 pt
    /// corners: the icon, where the copy is, its text on 1 line, and Send.
    /// After a send, the action shows Sent.
    private var clipRow: some View {
        let last = sent.last { clip.count != 0 && $0.clipStamp == clip.count && ($0.kind == .clip || $0.kind == .clipImage) }
        let can = device.online && SendTools.canClipboard(model)(device) && clip.kind != .empty
        let shown = last.map { !$0.text.isEmpty } ?? false
        return HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tn.cyan)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(clipMeta(last))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(tn.cyan)
                    .lineLimit(1)
                Text(clipText(last))
                    .font(shown ? .caption.monospaced() : .caption)
                    .foregroundStyle(shown ? tn.text : tn.sub)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button {
                if let last {
                    model.show("The clip is on \(model.device(last.deviceId)?.name ?? "the computer") already")
                } else if model.demo {
                    model.show(DemoMode.sendsNothing)
                } else {
                    model.core.plugin(ClipboardPlugin.self)?.sendClipboard(to: device.id)
                }
            } label: {
                Text(last != nil ? "Sent" : "Send")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(last != nil ? tn.sub : tn.accent)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!can)
            .opacity(can ? 1 : TiledMetrics.disabledAlpha)
            .accessibilityLabel(last != nil ? "Sent" : "Send the clipboard")
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tn.bg))
    }

    /// The + key, the field, the mic key, and the send key. The + key opens
    /// the tray, and while the tray is open it is an accent key with a
    /// cross that closes it. While the field has the focus, the + key
    /// hides, so the field takes its width and grows to 6 lines. With text,
    /// the field shows the key of the large editor. The words of a
    /// dictation go at the end of the text. The send key shows the number of
    /// the selected photos.
    private var composer: some View {
        let can = canSend
        let count = picked.count
        return HStack(alignment: .bottom, spacing: 8) {
            if !focused && !voice.active {
                Button {
                    if !trayOpen { focused = false }
                    trayOpen.toggle()
                } label: {
                    Image(systemName: trayOpen ? "xmark" : "plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(trayOpen ? tn.onAccent : tn.text)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(trayOpen ? tn.accent : tn.line))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(trayOpen ? "Close the photos and tools" : "Photos, files, and tools")
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            HStack(alignment: .bottom, spacing: 0) {
                TextField("Message \(device.name)", text: $text, axis: .vertical)
                    .lineLimit(focused ? 1...6 : 1...4)
                    .font(.subheadline)
                    .foregroundStyle(tn.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .onSubmit(send)
                    .focused($focused)
                    .padding(.vertical, 13)
                // Only the key of the large editor shows, so the text keeps the width. The editor has Clear.
                if !text.isEmpty { ExpandKey(isPresented: $editing).padding(.bottom, 6) }
            }
            .padding(.leading, 16)
            .padding(.trailing, text.isEmpty ? 16 : 4)
            .frame(minHeight: 48)
            .background(Capsule().fill(tn.bg))
            .overlay(Capsule().strokeBorder(focused ? tn.accent : tn.lineHi, lineWidth: 1))
            if voice.available {
                Button {
                    voice.toggle(model.core) { spoken in text = DictationText.append(text, spoken) }
                } label: {
                    Image(systemName: voice.active ? "stop.fill" : "mic")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(voice.active ? tn.onAccent : tn.text)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(voice.active ? tn.green : tn.line))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(voice.active ? "Stop the dictation" : "Dictate")
            }
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(can ? tn.onAccent : tn.sub)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(can ? tn.accent : tn.line))
                    .overlay(alignment: .topTrailing) {
                        if count > 0 {
                            Text("\(count)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(tn.bg)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(tn.text))
                                .offset(x: 2, y: -2)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(!can)
            .accessibilityLabel(count == 0 ? "Send" : count == 1 ? "Send 1 photo" : "Send \(count) photos")
        }
        .animation(.snappy(duration: 0.2), value: focused)
        .animation(.snappy(duration: 0.2), value: voice.active)
    }

    /// Sends the selected photos, then the text of the field. A web link
    /// opens in the browser of the computer, and other text goes to its
    /// clipboard.
    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        editing = false
        guard SendTools.canShare(model)(device) else {
            model.show(TargetRun.noTarget(device))
            return
        }
        if model.demo {
            model.show(DemoMode.sendsNothing)
            picked = []
            text = ""
            trayOpen = false
            return
        }
        if !picked.isEmpty {
            ShareFeature.send(assets: picked, to: device, model: model)
            picked = []
            trayOpen = false
        }
        guard !t.isEmpty else { return }
        guard t.utf8.count <= ShareQueue.maxTextBytes else {
            model.show("The text is larger than 1 MB. Send it as a file")
            return
        }
        model.core.plugin(SharePlugin.self)?.send(text: t, to: device.id)
        text = ""
    }

    private func clipMeta(_ last: SentItem?) -> String {
        if let last { return "Clipboard · sent at \(ThreadTime.clock(last.at))" }
        switch clip.kind {
        case .empty: return "Clipboard on this iPhone · empty"
        case .text, .image: return "Clipboard on this iPhone"
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
