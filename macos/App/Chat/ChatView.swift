import AppKit
import FluxKit
import SwiftUI
import UniformTypeIdentifiers

/// The detail column of Chats: the chat that the sidebar selects. A
/// computer opens its own chat, and an agent opens its agent chat. Before
/// the first pairing, the column shows the pairing guide. Without a
/// selected chat, it tells the user to select one.
struct ChatDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        Group {
            switch model.chat {
            case .computer(let id):
                if let device = model.pairedDevice(id) {
                    ComputerChat(device: device)
                        .id(id)
                } else {
                    ContentUnavailableView("The computer is gone", systemImage: "desktopcomputer",
                                           description: Text("The computer is no longer paired."))
                        .navigationTitle("Chats")
                }
            case .agent(let id, let pane):
                AgentChat(deviceId: id, pane: pane)
                    .id("\(id)|\(pane)")
            case nil:
                if model.paired.isEmpty {
                    ScrollView {
                        ChatPairGuide()
                            .pageColumn(top: 12, bottom: 16)
                    }
                    .navigationTitle("Chats")
                } else {
                    ContentUnavailableView("Select a chat", systemImage: "text.bubble",
                                           description: Text("Each agent and each paired computer has a chat in the sidebar."))
                        .navigationTitle("Chats")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(tn.bg)
        .navigationDestination(for: MacRoute.self) { MacRouteView(route: $0) }
    }
}

/// The chat of 1 computer: what happens between this Mac and the computer,
/// with the newest entry at the bottom. The computer writes on the left:
/// approvals, received files, the last clip, and the answers to approvals.
/// What this Mac sent shows on the right. An approval shows Deny and
/// Approve. The dock under the thread shows the clipboard of this Mac with
/// Send, and the composer, with the tray under it. Files, text, and links
/// that you drop on the page go to the computer. The toolbar shows the
/// picture of the computer, its name, its link and battery, and a menu.
struct ComputerChat: View {
    let device: DeviceSnapshot
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @State private var dropping = false

    var body: some View {
        let id = device.id
        let share = model.core.plugin(SharePlugin.self)
        let battery = model.core.plugin(BatteryPlugin.self)?.model.computers[id]
        // The thread shows the approvals of this computer, and no agents.
        let approvals = model.inboxItems().filter { item in
            if case .approval = item.content { return item.deviceIds.contains(id) }
            return false
        }
        let transfers = share?.model.transfers ?? []
        let running = transfers.filter { $0.state == .running && $0.size > 0 && $0.deviceId == id }
        let entries = Chat.entries(
            sent: share?.model.sent ?? [],
            transfers: transfers,
            clip: model.core.plugin(ClipboardPlugin.self)?.model.last,
            answers: model.core.plugin(ApprovePlugin.self)?.model.history ?? [],
            items: approvals,
            since: { _, _ in nil },
            seen: model.chatSeen(approvals),
            scope: id
        )
        VStack(spacing: 0) {
            ProgressLine {
                if !running.isEmpty {
                    let size = running.reduce(Int64(0)) { $0 + $1.size }
                    let done = running.reduce(Int64(0)) { $0 + min($1.bytes, $1.size) }
                    LineFill(fraction: size > 0 ? Double(done) / Double(size) : 0, color: tn.accent)
                }
            }
            ChatThread(device: device, entries: entries, status: ChatStatus.computer(model, device)) { share?.model.clearFinished() }
            ChatDock(device: device)
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
            guard let share else { return false }
            guard device.online else {
                model.show("\(device.name) is not reachable")
                return false
            }
            ShareActions.drop(providers, to: id, share: share)
            return true
        }
        .navigationTitle(device.name)
        .navigationSubtitle(computerContext(device, battery: battery))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ComputerAvatar(device: device, size: 28)
            }
            ToolbarItem(placement: .primaryAction) {
                ComputerMenu(device: device)
            }
        }
    }
}

/// The menu of the chat of a computer: Control with the computer in scope,
/// the agents window, a new agent, and the page of the computer.
private struct ComputerMenu: View {
    let device: DeviceSnapshot
    @Environment(AppModel.self) private var model

    var body: some View {
        let herdr = model.core.plugin(HerdrPlugin.self)?.model.states[device.id]
        let canStart = device.online && herdr?.running == true && herdr?.control == true
        Menu {
            Button {
                model.setScope(device.id)
                model.go(.control)
            } label: {
                Label("Control", systemImage: MacDestination.control.systemImage)
            }
            if device.accepts(PacketType.fluxHerdr) {
                Button {
                    AgentsWindows.shared.show(device.id, app: model)
                } label: {
                    Label("Agents Window", systemImage: "macwindow")
                }
                .disabled(!device.online)
                Button {
                    model.startAgent = device.id
                } label: {
                    Label("Start an Agent…", systemImage: "plus")
                }
                .disabled(!canStart)
            }
            Divider()
            Button {
                model.destination = .computers
                model.computersPath = [.computer(device.id)]
            } label: {
                Label("Computer Page", systemImage: device.symbol)
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .help("Control, the agents, and the page of \(device.name)")
    }
}

/// The entries with the day over each new day, the newest at the bottom,
/// and the notices under them. The view follows a new entry while it shows
/// the end. When the user scrolls up, it stays there, unless this Mac sent
/// the new entry. The column is at most the content width, so that the
/// cards stay easy to read in a wide window.
private struct ChatThread: View {
    let device: DeviceSnapshot
    let entries: [ChatEntry]
    let status: ChatStatus
    let clearFinished: () -> Void
    @Environment(\.tn) private var tn
    /// True while the end of the thread is on screen.
    @State private var atEnd = true

    var body: some View {
        GeometryReader { geo in
            let column = max(240, min(geo.size.width, TiledMetrics.maxContentWidth) - 28)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        Spacer(minLength: 0)
                        if entries.isEmpty {
                            Text("Approvals and the files and clips from \(device.name) show here. So do the links, text, and files that you send. To send files from Finder, drop them on this page.")
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
                                    .padding(.vertical, 2)
                            }
                            ChatEntryView(entry: e, computer: device.name, clearFinished: clearFinished)
                        }
                        ChatNotices(status: status)
                        Color.clear.frame(height: 1).id("end")
                            .background(GeometryReader { g in
                                Color.clear.preference(key: ChatEndKey.self, value: g.frame(in: .named("chat")).minY)
                            })
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 16)
                    .environment(\.chatColumn, column)
                    .frame(maxWidth: TiledMetrics.maxContentWidth)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .bottom)
                }
                .coordinateSpace(name: "chat")
                .defaultScrollAnchor(.bottom)
                .onPreferenceChange(ChatEndKey.self) { y in atEnd = y <= geo.size.height + 48 }
                .onChange(of: entries.last?.id) {
                    let mine: Bool
                    if case .sent = entries.last { mine = true } else if case .file(let t) = entries.last { mine = !t.incoming } else { mine = false }
                    if atEnd || mine { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
    }
}

/// The top of the end mark of the thread in the coordinate space of the scroll view.
private struct ChatEndKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 1 entry of the chat of `computer`. The thread holds no agents and no
/// pair requests, so an event is an approval.
private struct ChatEntryView: View {
    let entry: ChatEntry
    let computer: String
    let clearFinished: () -> Void

    var body: some View {
        switch entry {
        case .sent(let s):
            if s.kind == .clipImage {
                SentFileCard(icon: "photo", name: "Image", meta: sentMeta(s), state: .done)
            } else {
                SentBubble(text: s.text.isEmpty ? "A private clip" : s.text, meta: sentMeta(s))
            }
        case .file(let f):
            if f.incoming {
                ReceivedFileCard(transfer: f, computer: computer, clearFinished: clearFinished)
            } else {
                SentFileCard(icon: fileSymbol(f.name), name: f.name, meta: fileMeta(f), state: f.state,
                             fraction: f.fraction, file: f.file, clearFinished: clearFinished)
            }
        case .clip(let c):
            ReceivedClipCard(clip: c)
        case .answer(let r):
            AnswerCard(record: r)
        case .event(let item, let at):
            if case .approval(let request) = item.content {
                ApprovalCard(item: item, request: request, at: at)
            }
        }
    }

    /// The line under a link, a text, or a clip, such as "Link · opened in the browser · 13:20".
    private func sentMeta(_ s: SentItem) -> String {
        let time = clockTime(s.at)
        switch s.kind {
        case .link: return "Link · opened in the browser · \(time)"
        case .text: return "Text · on the clipboard · \(time)"
        case .scan: return "Scan · saved as a text file · \(time)"
        case .clip, .clipImage: return "Clipboard · \(time)"
        }
    }

    /// The line under a file that went out, such as "Sending · 22% of 18 KB" or "Sent · 13:41".
    private func fileMeta(_ f: FileTransfer) -> String {
        let pct = f.fraction.map { "\(Int($0 * 100))% of \(byteText(f.size))" } ?? "\(byteText(f.bytes)) so far"
        let time = clockTime(f.ended ?? f.started)
        switch f.state {
        case .running: return "Sending · \(pct)"
        case .done: return "Sent · \(time)"
        case .failed: return "Not sent · \(time)"
        }
    }

    /// The symbol of a file: an image, or a document.
    private func fileSymbol(_ name: String) -> String {
        let type = UTType(filenameExtension: (name as NSString).pathExtension)
        return type?.conforms(to: .image) == true ? "photo" : "doc.text"
    }
}
