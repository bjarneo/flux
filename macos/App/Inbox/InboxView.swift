import FluxKit
import SwiftUI

/// The Inbox: what happens on the computers in scope, as a Hyprland master
/// layout. The item that comes first takes the master tile with its whole
/// action, and the rest wait in the stack. A detail column of 600 pt or
/// more splits: the master on the left, the status line and the stack on
/// the right.
struct InboxView: View {
    var body: some View {
        // The clock ends a finished transfer, the clip, and a paused player after 30 minutes.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            InboxBody(now: context.date)
        }
        .destinationRoot(.inbox)
    }
}

private struct InboxBody: View {
    let now: Date
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tiles

    var body: some View {
        let all = model.inboxItems(now: now)
        let scoped = Inbox.inScope(all, scope: model.scope)
        let arranged = model.arrangement.arrange(scoped)
        let status = InboxStatus.make(model, all: all, scoped: scoped)
        let mpris = model.core.plugin(MprisPlugin.self)
        let online = model.connectedPaired.map(\.id)
        let playing = model.connectedPaired.filter { mpris?.model.devices[$0.id]?.player?.playing == true }.map(\.id)
        GeometryReader { geo in
            if arranged.isEmpty {
                ScrollView {
                    EmptyInbox(status: status)
                        .padding(.horizontal, TiledMetrics.gutter)
                        .padding(.top, 4)
                        .padding(.bottom, 16)
                        .frame(maxWidth: TiledMetrics.maxContentWidth)
                        .frame(maxWidth: .infinity)
                }
            } else if geo.size.width >= 600 {
                SplitInbox(items: arranged, status: status, size: geo.size, tiles: tiles)
            } else {
                StackedInbox(items: arranged, status: status, size: geo.size, tiles: tiles)
            }
        }
        .animation(Motion.standard(reduceMotion), value: arranged.map(\.key))
        // A change of the scope changes the scoped items, so it syncs the order too.
        .onChange(of: [all.map(\.key), scoped.map(\.key)], initial: true) { model.inboxChanged(all: all, scoped: scoped) }
        // A paused player stays for 30 minutes after it played last.
        .onChange(of: PlayStamp(ids: playing, minute: Int(now.timeIntervalSince1970 / 60)), initial: true) {
            let next = Inbox.notePlaying(model.playedAt, devices: model.state.devices,
                                         media: mpris?.model.devices ?? [:], now: Date())
            if next != model.playedAt { model.playedAt = next }
        }
        // The Inbox asks each computer that comes online for its agents and its players.
        .task(id: online) {
            let herdr = model.core.plugin(HerdrPlugin.self)
            for id in online {
                herdr?.request(id)
                mpris?.requestPlayers(id)
            }
        }
    }
}

/// The players that play now, and the minute of the clock.
private struct PlayStamp: Equatable {
    let ids: [String]
    let minute: Int
}

/// The texts of the status line and the notices.
struct InboxStatus: Equatable {
    /// The items in scope that need the user.
    let needs: Int
    /// The items out of scope that need the user.
    let elsewhere: Int
    /// The computer in scope, or nil for all computers.
    let scopeName: String?
    /// The computers in scope that are not reachable, while Flux does not connect.
    let offline: [String]
    /// The computer that paired in the last 6 seconds, when the scope shows it.
    let pairedName: String?

    var nothing: String {
        scopeName.map { "Nothing on \($0) needs you" } ?? "Nothing needs you"
    }

    /// "omarchy is not reachable. Its agents do not show here." or the form for more computers.
    var offlineLine: String? {
        switch offline.count {
        case 0: return nil
        case 1: return "\(offline[0]) is not reachable. Its agents do not show here."
        default: return "\(offline.count) computers are not reachable. Their agents do not show here."
        }
    }

    @MainActor
    static func make(_ model: AppModel, all: [InboxItem], scoped: [InboxItem]) -> InboxStatus {
        let reach = Inbox.reach(scope: model.scope, devices: model.state.devices)
        let needs = Inbox.needsYou(scoped)
        var paired: String?
        if let id = model.newlyPairedId, model.scope == nil || model.scope == id {
            paired = model.pairedDevice(id)?.name
        }
        return InboxStatus(
            needs: needs,
            elsewhere: Inbox.needsYou(all) - needs,
            scopeName: model.pairedDevice(model.scope)?.name,
            offline: model.connecting ? [] : reach.offline.map(\.name),
            pairedName: paired
        )
    }
}

/// The Inbox of a wide detail column: the master on the left at 60% and
/// full height, the status line and the stack in 1 column on the right.
private struct SplitInbox: View {
    let items: [InboxItem]
    let status: InboxStatus
    let size: CGSize
    let tiles: Namespace.ID

    var body: some View {
        let gutter = TiledMetrics.gutter
        let gap = TiledMetrics.gap
        let inner = max(0, size.width - gutter * 2 - gap)
        let left = (inner * 0.6).rounded(.down)
        let right = inner - left
        let column = size.height - 8
        let compact = column < 460
        HStack(alignment: .top, spacing: gap) {
            ScrollView {
                if let first = items.first {
                    MasterTile(item: first, compact: compact, count: items.count, minHeight: column - 8)
                        .id(first.key)
                        .matchedGeometryEffect(id: first.key, in: tiles)
                        .padding(.bottom, 8)
                }
            }
            .frame(width: left)
            .focusSection()
            ScrollView {
                VStack(spacing: gap) {
                    StatusBlock(status: status)
                    ForEach(items.dropFirst()) { item in
                        StackTile(item: item)
                            .matchedGeometryEffect(id: item.key, in: tiles)
                    }
                }
                .padding(.bottom, 16)
            }
            .frame(width: right)
            .focusSection()
        }
        .padding(.horizontal, gutter)
        .padding(.top, 8)
    }
}

/// The Inbox of a narrow detail column: the status line, the master, and
/// the stack in 2 columns, in 1 scroll.
private struct StackedInbox: View {
    let items: [InboxItem]
    let status: InboxStatus
    let size: CGSize
    let tiles: Namespace.ID

    var body: some View {
        let gap = TiledMetrics.gap
        ScrollView {
            VStack(spacing: gap) {
                StatusBlock(status: status)
                if let first = items.first {
                    MasterTile(item: first, compact: false, count: items.count)
                        .id(first.key)
                        .matchedGeometryEffect(id: first.key, in: tiles)
                        .focusSection()
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: gap), GridItem(.flexible(), spacing: gap)], spacing: gap) {
                    ForEach(items.dropFirst()) { item in
                        StackTile(item: item)
                            .matchedGeometryEffect(id: item.key, in: tiles)
                    }
                }
                .focusSection()
            }
            .padding(.horizontal, TiledMetrics.gutter)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
    }
}

/// The status line and the notices under it.
private struct StatusBlock: View {
    let status: InboxStatus
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: TiledMetrics.gap) {
            StatusLine(status: status) { model.retry() }
            InboxNotices(status: status, pairedTile: false, offlineInLine: true)
        }
    }
}

/// The line above the stack: a red dot and the count of the items that
/// need the user, or the "nothing" title. When a computer in scope is not
/// reachable, the line says it, with Retry.
struct StatusLine: View {
    let status: InboxStatus
    let retry: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        let offline = status.offlineLine
        HStack(alignment: .center, spacing: 10) {
            if status.needs > 0 {
                Circle().fill(tn.red).frame(width: 8, height: 8)
            } else if offline != nil {
                LinkDot(online: false)
            }
            VStack(alignment: .leading, spacing: 2) {
                if status.needs > 0 {
                    Text(needsText(status.needs))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tn.text)
                } else {
                    Text(status.nothing)
                        .font(.system(size: 13))
                        .foregroundStyle(tn.sub)
                }
                if let offline {
                    Text(offline)
                        .font(.system(size: 12))
                        .foregroundStyle(tn.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if offline != nil {
                Button("Retry", action: retry)
                    .buttonStyle(FluxButtonStyle(kind: .text))
            }
        }
        .padding(.leading, 4)
        .frame(minHeight: offline == nil ? 28 : 36)
    }
}
