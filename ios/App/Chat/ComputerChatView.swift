import FluxKit
import SwiftUI

/// The chat of 1 computer, above Chats: what happens between this iPhone
/// and the computer, with the newest at the bottom. The computer writes on
/// the leading side: approvals and the answers of this iPhone to them,
/// received files, and the last clip. What this iPhone sent shows on the
/// trailing side. An approval shows Deny and Approve in the thread. The
/// dock under it shows the clipboard of this iPhone with Send, and the
/// composer. The + key of the composer opens the tray with the recent
/// photos and the tools. The top bar shows the computer with its link and
/// battery, and a menu with Control, the agents and terminals, a new agent
/// or terminal, and the queue and transfers. Each agent has its own chat,
/// so the thread shows no agents. It follows the chat of a computer of
/// Flux for Android.
struct ComputerChatView: View {
    let deviceId: String
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @State private var newPane = false

    var body: some View {
        if let d = model.device(deviceId), d.paired {
            chat(d)
        } else {
            ContentUnavailableView("Not paired", systemImage: "laptopcomputer",
                                   description: Text("This computer is no longer paired. Pair it again in Computers."))
                .chatScreen("Chat")
        }
    }

    private func chat(_ d: DeviceSnapshot) -> some View {
        let all = model.inboxItems()
        let entries = model.chatEntries(of: d.id, all: all)
        let sent: [SentItem] = entries.compactMap { if case .sent(let s) = $0 { return s } else { return nil } }
        let running: [FileTransfer] = entries.compactMap {
            if case .file(let t) = $0, t.state == .running, t.size > 0 { return t } else { return nil }
        }
        let canCreate = SendTools.canCreate(model)(d)
        return VStack(spacing: 0) {
            ProgressLine {
                if !running.isEmpty {
                    let size = running.reduce(Int64(0)) { $0 + $1.size }
                    let done = running.reduce(Int64(0)) { $0 + $1.bytes }
                    LineFill(fraction: Double(done) / Double(max(size, 1)), color: tn.accent)
                }
            }
            ChatThread(entries: entries, deviceId: d.id)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ChatDock(device: d, sent: sent) { newPane = true }
                }
        }
        .chatScreen(d.name)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChatTitle(title: d.name, context: ChatTexts.link(model, d)) {
                    ChatAvatar(icon: d.symbol, tint: tn.text, size: 36, badge: d.online ? tn.green : nil)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        model.setScope(d.id)
                        model.controlPath = []
                        model.select(.control)
                    } label: { Label("Control", systemImage: "slider.horizontal.3") }
                    if d.accepts(PacketType.fluxHerdr) && model.core.plugin(HerdrPlugin.self) != nil {
                        Button { model.path.append(.feature(.agents(d.id))) } label: {
                            Label("Agents and terminals", systemImage: "brain")
                        }
                    }
                    if d.online && canCreate {
                        Button { newPane = true } label: { Label("New agent or terminal", systemImage: "plus") }
                    }
                    if SendTools.canShare(model)(d) {
                        Button { model.path.append(.feature(.share(d.id))) } label: {
                            Label("Queue and transfers", systemImage: "tray.full")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More actions")
            }
        }
        .sheet(isPresented: $newPane) {
            NewPaneSheet(deviceId: d.id) { what, pane in
                newPane = false
                model.path.append(.feature(what == "terminal" ? .terminal(d.id, pane) : .agent(d.id, pane)))
            }
        }
    }
}

// MARK: Thread

/// The entries of the chat of the computer `deviceId` with the day over
/// each new day, the newest at the bottom, and the notices under them. The
/// view starts at the newest entry and follows a new entry while it shows
/// the end. When the user scrolls up, it stays there, unless this iPhone
/// sent the new entry. Without entries, a line tells what shows here.
private struct ChatThread: View {
    let entries: [ChatEntry]
    let deviceId: String
    @Environment(\.tn) private var tn
    /// True while the end of the thread is on screen.
    @State private var atEnd = true

    var body: some View {
        GeometryReader { geo in
            // The width of the content, inside the side space of 12 pt.
            let inner = max(0, min(geo.size.width, TiledMetrics.maxContentWidth) - 24)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        if entries.isEmpty {
                            Text("Approvals and the files and clips from this computer show here. So do the photos, files, links, and text that you send.")
                                .font(.footnote)
                                .foregroundStyle(tn.sub)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 12)
                        }
                        ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                            if i == 0 || !Calendar.current.isDate(entries[i - 1].at, inSameDayAs: entry.at) {
                                Text(ThreadTime.day(entry.at))
                                    .font(.caption)
                                    .foregroundStyle(tn.sub)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 2)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            ChatEntryRow(entry: entry, width: inner)
                        }
                        ChatNotices(computer: deviceId)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                            .background(GeometryReader { g in
                                Color.clear.preference(key: ChatEndKey.self, value: g.frame(in: .named("chat")).minY)
                            })
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 14)
                    .padding(.bottom, 14)
                    .frame(maxWidth: TiledMetrics.maxContentWidth)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .bottom)
                }
                .coordinateSpace(name: "chat")
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
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

/// 1 entry of the chat of a computer. `width` is the width of the content
/// of the thread. The chat of a computer holds no agents, so an agent shows
/// nothing.
private struct ChatEntryRow: View {
    let entry: ChatEntry
    let width: CGFloat
    @Environment(AppModel.self) private var model

    var body: some View {
        let name: (String) -> String = { id in model.device(id)?.name ?? "the computer" }
        switch entry {
        case .sent(let s):
            if s.kind == .clipImage {
                SentFileCard(icon: "photo", name: "Image", meta: SendMeta.sent(s, many: false, name: name), state: .done, fraction: nil)
            } else {
                SentBubble(text: s.text.isEmpty ? "A private clip" : s.text, meta: SendMeta.sent(s, many: false, name: name), width: width,
                           mono: s.kind != .text)
            }
        case .file(let t):
            if t.incoming {
                ReceivedFileCard(transfer: t, width: width)
            } else {
                SentFileCard(icon: SendMeta.fileIcon(t.name), name: t.name, meta: SendMeta.file(t, many: false, name: name), state: t.state, fraction: t.fraction)
            }
        case .clip(let c):
            ClipCard(clip: c, width: width)
        case .answer(let r):
            AnswerCard(record: r, width: width)
        case .event(let item, let at):
            switch item.content {
            case .approval(let r):
                ApprovalCard(item: item, request: r, at: at, width: width)
            case .pair(let deviceId):
                PairCard(item: item, deviceId: deviceId, at: at, width: width)
            case .agent:
                EmptyView()
            }
        }
    }
}
