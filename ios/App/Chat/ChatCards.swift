import FluxKit
import SwiftUI

// The cards of the chat of a computer: the cards of the computer on the
// leading side, and the bubbles and file cards of this iPhone on the
// trailing side. The list of chats shows the approval and the pair request
// with the same cards. They follow the Chat of Flux for Android.

// MARK: Card of a computer

/// The text action at the bottom of a card, such as Open thread. Without
/// `run`, the label only tells a state, such as "Writing a reply below".
struct ChatCardAction {
    let label: String
    var run: (() -> Void)?
}

/// A card from a computer, on the leading side: the mark and the state in
/// `color`, the source in mono, and the time at the end. The title and the
/// detail follow, then the progress bar, `extra`, and the action. A card
/// that needs the user (`ask`) takes the full `width` and a red border of
/// 2 pt. The other cards take 88% of it. `mono` sets the title in mono,
/// for a file name or a clip. `tile` gives the card the tile corners, for
/// the list of chats. VoiceOver reads the top row as 1 line.
struct ChatCard<Mark: View, Extra: View>: View {
    let state: String
    let color: Color
    let source: String
    let time: Date
    let title: String
    let mono: Bool
    let detail: String
    let ask: Bool
    let progress: Double?
    let action: ChatCardAction?
    let titleLines: Int?
    let width: CGFloat
    let tile: Bool
    let mark: Mark
    let extra: Extra
    @Environment(\.tn) private var tn

    init(state: String, color: Color, source: String, time: Date, title: String, mono: Bool = false, detail: String = "",
         ask: Bool = false, progress: Double? = nil, action: ChatCardAction? = nil, titleLines: Int? = nil, width: CGFloat,
         tile: Bool = false, @ViewBuilder mark: () -> Mark, @ViewBuilder extra: () -> Extra) {
        self.state = state
        self.color = color
        self.source = source
        self.time = time
        self.title = title
        self.mono = mono
        self.detail = detail
        self.ask = ask
        self.progress = progress
        self.action = action
        self.titleLines = titleLines
        self.width = width
        self.tile = tile
        self.mark = mark()
        self.extra = extra()
    }

    var body: some View {
        let corner: CGFloat = tile ? TiledMetrics.tileCorner : 14
        let shape = UnevenRoundedRectangle(topLeadingRadius: corner, bottomLeadingRadius: tile ? corner : 4, bottomTrailingRadius: corner,
                                           topTrailingRadius: corner, style: .continuous)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    mark
                    Text(state)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .fixedSize()
                    if !source.isEmpty {
                        Text("· " + source)
                            .font(.caption.monospaced())
                            .foregroundStyle(tn.sub)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(ThreadTime.clock(time))
                        .font(.caption2.monospaced())
                        .foregroundStyle(tn.sub)
                        .lineLimit(1)
                        .fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([state, source, ThreadTime.clock(time)].filter { !$0.isEmpty }.joined(separator: ", "))
                Text(title)
                    .font(mono ? .subheadline.monospaced().weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(tn.text)
                    .lineLimit(titleLines)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(tn.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let progress {
                    ZStack(alignment: .leading) {
                        Capsule().fill(tn.line)
                        LineFill(fraction: progress, color: tn.accent).clipShape(Capsule())
                    }
                    .frame(height: 3)
                    .padding(.top, 2)
                }
                extra
                if let action {
                    // The action reaches into the padding of the card, as in the design, and takes taps on 44 pt.
                    Group {
                        if let run = action.run {
                            Button(action: run) {
                                Text(action.label)
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(action.label).frame(minHeight: 44)
                        }
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tn.accent)
                    .padding(.top, -6)
                    .padding(.bottom, -12)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: ask ? width : width * 0.88, alignment: .leading)
            .background(shape.fill(tn.tile))
            .overlay(shape.strokeBorder(ask ? tn.red : tn.line, lineWidth: ask ? 2 : 1))
            Spacer(minLength: 0)
        }
    }
}

extension ChatCard where Extra == EmptyView {
    init(state: String, color: Color, source: String, time: Date, title: String, mono: Bool = false, detail: String = "",
         ask: Bool = false, progress: Double? = nil, action: ChatCardAction? = nil, titleLines: Int? = nil, width: CGFloat,
         @ViewBuilder mark: () -> Mark) {
        self.init(state: state, color: color, source: source, time: time, title: title, mono: mono, detail: detail, ask: ask,
                  progress: progress, action: action, titleLines: titleLines, width: width, tile: false, mark: mark) { EmptyView() }
    }
}

/// A button of a card that needs the user, `height` high: `primary` has
/// the accent fill, the other the tonal fill.
private struct CardButton: View {
    let label: String
    var icon: String?
    let primary: Bool
    var height: CGFloat = 48
    let action: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.body)
                        .accessibilityHidden(true)
                }
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(primary ? tn.onAccent : tn.text)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(tileShape(12).fill(primary ? tn.accent : tn.line))
            .contentShape(tileShape(12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: Approval and pairing

/// The user and the terminal of a request, such as "user dev · pts/3".
private func approvalLine(_ r: ApproveRequest) -> String {
    ["user \(r.user)", r.tty].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: " · ")
}

/// A sudo, polkit, or enrollment request, with Deny and Approve. Deny acts
/// in place. Approve opens the approval sheet, which asks for Face ID or
/// Touch ID. It never approves by itself. `list` shows the card in the
/// list of chats: the computer follows the service, the corners are the
/// tile corners, and the buttons are 44 pt high.
struct ApprovalCard: View {
    let item: InboxItem
    let request: ApproveRequest
    let at: Date
    let width: CGFloat
    var list = false
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        // Deny and Approve share the width 1 to 1.6, as in the design.
        let inner = max(0, width - 24 - 8)
        let height: CGFloat = list ? 44 : 48
        ChatCard(state: item.stateWord, color: tn.red, source: list ? "\(request.service) · \(request.computerName)" : request.service,
                 time: at, title: item.title, detail: approvalLine(request), ask: true, width: width, tile: list) {
            PulseDot(color: tn.red, size: 8)
        } extra: {
            HStack(spacing: 8) {
                CardButton(label: "Deny", primary: false, height: height) {
                    if model.demo {
                        model.show(DemoMode.sendsNothing)
                    } else if let plugin = model.core.plugin(ApprovePlugin.self), plugin.model.current?.id == request.id {
                        // Deny acts on the open request, so it must be the request of this card.
                        plugin.deny()
                    }
                }
                .frame(width: inner / 2.6)
                .accessibilityHint("Denies the request")
                CardButton(label: request.kind == .approve ? "Approve" : "Enroll", icon: ApproveTexts.current.symbol, primary: true, height: height) {
                    if model.demo {
                        model.show(DemoMode.sendsNothing)
                    } else {
                        ApprovePresenter.shared.state.present()
                    }
                }
                .accessibilityHint("Opens the approval")
            }
            .padding(.top, 6)
        }
    }
}

/// A computer that asks to pair. Compare the key opens the pairing sheet
/// with the full key. It never pairs by itself. `list` shows the card in
/// the list of chats, with the tile corners and a 44 pt button.
struct PairCard: View {
    let item: InboxItem
    let deviceId: String
    let at: Date
    let width: CGFloat
    var list = false
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        ChatCard(state: item.stateWord, color: tn.red, source: "", time: at, title: item.title,
                 detail: "Compare the key on both screens.", ask: true, width: width, tile: list) {
            PulseDot(color: tn.red, size: 8)
        } extra: {
            CardButton(label: "Compare the key", primary: true, height: list ? 44 : 48) { model.pairingSheet = deviceId }
                .padding(.top, 6)
        }
    }
}

/// The answer of this iPhone to a request: Approved or Denied.
struct AnswerCard: View {
    let record: ApproveRecord
    let width: CGFloat
    @Environment(\.tn) private var tn

    var body: some View {
        let ok = record.outcome == .approved || record.outcome == .enrolled
        let r = record.request
        let color = ok ? tn.green : tn.sub
        ChatCard(state: ok ? "Approved" : "Denied", color: color, source: r?.service ?? "", time: record.resolved ?? record.received,
                 title: title(ok: ok, r), detail: r.map(approvalLine) ?? "", width: width) {
            PulseDot(color: color, size: 8, pulse: false)
        }
    }

    private func title(ok: Bool, _ r: ApproveRequest?) -> String {
        guard let r else { return record.summary }
        if r.kind == .enroll {
            return ok ? "Enrolled \(FluxPlatform.current.deviceNoun) on \(r.host)" : "Denied the enrollment on \(r.host)"
        }
        return (ok ? "Approved " : "Denied ") + "\(r.service) for \(r.user)"
    }
}

// MARK: Files and clips of the computers

/// A file from a computer: its progress while it comes in, then Open, which
/// shows it with Quick Look.
struct ReceivedFileCard: View {
    let transfer: FileTransfer
    let width: CGFloat
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let t = transfer
        let name = model.device(t.deviceId)?.name ?? "the computer"
        switch t.state {
        case .running:
            ChatCard(state: "Receiving", color: tn.accent, source: name, time: t.started, title: t.name, mono: true,
                     detail: t.fraction.map { "\(Int($0 * 100))% of \(TransferRow.bytes(t.size))" } ?? "\(TransferRow.bytes(t.bytes)) so far",
                     progress: t.fraction, width: width) {
                RingSpinner(size: 11, color: tn.accent)
            }
        case .done:
            ChatCard(state: "Received", color: tn.green, source: name, time: t.started, title: t.name, mono: true, detail: "In Files",
                     action: t.file.map { file in ChatCardAction(label: "Open", run: { ShareFeature.shared.preview = file }) }, width: width) {
                PulseDot(color: tn.green, size: 8, pulse: false)
            }
        case .failed:
            ChatCard(state: "Not received", color: tn.red, source: name, time: t.started, title: t.name, mono: true,
                     detail: "Send it again from \(name)", width: width) {
                PulseDot(color: tn.red, size: 8, pulse: false)
            }
        }
    }
}

/// The last clip from a computer. It is on the clipboard of this iPhone
/// already, and the chat keeps only a short preview, so the card has no Copy.
struct ClipCard: View {
    let clip: ClipEvent
    let width: CGFloat
    @Environment(\.tn) private var tn

    var body: some View {
        let c = clip
        ChatCard(state: "Clipboard", color: tn.cyan, source: c.computer, time: c.at,
                 title: c.image ? "An image" : (c.secret ? ClipEvent.hiddenText : c.preview),
                 mono: !c.image && !c.secret, titleLines: 4, width: width) {
            PulseDot(color: tn.cyan, size: 8, pulse: false)
        }
    }
}

// MARK: What this iPhone sent

/// Text, a link, or a clip that went out: a bubble at the trailing side,
/// at most 82% of `width`, with the meta line under it. Text is in the body
/// face, and a link or a clip with `mono` in mono.
struct SentBubble: View {
    let text: String
    let meta: String
    let width: CGFloat
    var mono = true
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4, topTrailingRadius: 16, style: .continuous)
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Text(text)
                    .font(mono ? .footnote.monospaced() : .subheadline)
                    .foregroundStyle(tn.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(shape.fill(tn.accentTile))
                    .overlay(shape.strokeBorder(tn.lineHi, lineWidth: 1))
                Text(meta)
                    .font(.caption2)
                    .foregroundStyle(tn.sub)
            }
            .frame(maxWidth: width * 0.82, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A file or an image clip that went out: a card of 236 pt at the trailing
/// side with its icon, its name, the meta line, and a bar while it runs.
struct SentFileCard: View {
    let icon: String
    let name: String
    let meta: String
    let state: FileTransfer.State
    let fraction: Double?
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 4, topTrailingRadius: 14, style: .continuous)
        HStack(spacing: 0) {
            Spacer(minLength: 0)
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
            .frame(width: 236)
            .background(shape.fill(tn.accentTile))
            .overlay(shape.strokeBorder(tn.lineHi, lineWidth: 1))
            .accessibilityElement(children: .combine)
        }
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

/// The meta lines of what this iPhone sent. With `many` computers in scope,
/// the line names the computer. `name` gives the name of a computer.
@MainActor
enum SendMeta {
    static func sent(_ s: SentItem, many: Bool, name: (String) -> String) -> String {
        let time = ThreadTime.clock(s.at)
        switch s.kind {
        case .link: return many ? "Link · opened on \(name(s.deviceId)) · \(time)" : "Link · opened in the browser · \(time)"
        case .text: return many ? "Text · on the clipboard of \(name(s.deviceId)) · \(time)" : "Text · on the clipboard · \(time)"
        case .scan: return many ? "Scan · saved on \(name(s.deviceId)) · \(time)" : "Scan · saved as a text file · \(time)"
        case .clip, .clipImage: return many ? "Clipboard · to \(name(s.deviceId)) · \(time)" : "Clipboard · \(time)"
        }
    }

    static func file(_ t: FileTransfer, many: Bool, name: (String) -> String) -> String {
        let time = ThreadTime.clock(t.ended ?? t.started)
        let size = TransferRow.bytes(max(t.size, 0))
        let pct = t.fraction.map { "\(Int($0 * 100))% of \(size)" } ?? "\(TransferRow.bytes(t.bytes)) so far"
        switch t.state {
        case .running: return (many ? "Sending to \(name(t.deviceId))" : "Sending") + " · \(pct)"
        case .done: return (many ? "Sent to \(name(t.deviceId))" : "Sent") + " · \(time)"
        case .failed: return "Not sent · \(time)"
        }
    }

    /// The icon of a file: an image, or a document.
    static func fileIcon(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "webp", "heic", "avif", "bmp"].contains(ext) ? "photo" : "doc.text"
    }
}
