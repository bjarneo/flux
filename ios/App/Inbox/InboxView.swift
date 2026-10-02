import FluxKit
import SwiftUI

/// The Inbox: 1 list of what happens on the computers in scope, as the
/// Hyprland master layout. The first item is the master tile with its
/// whole action. The other items wait in the stack. A swipe on the master,
/// or Later, moves it to the end of the stack. A tap on a stack tile moves
/// that tile to the master. Under a width of 600 pt, the master takes about
/// 55% of the height and the stack has 2 columns under it. From 600 pt, the
/// master takes 60% of the width at full height, and the status line and
/// the stack fill a column on the right.
struct InboxView: View {
    var body: some View {
        // Finished items leave after 30 minutes, so the Inbox reads them again each minute.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            InboxContent(now: context.date)
        }
        .tabRoot("Inbox")
    }
}

/// The items at the time `now`, and the layout for the width.
private struct InboxContent: View {
    let now: Date
    @Environment(AppModel.self) private var model

    /// The players that play, and the time, so that a player that plays
    /// for a long time keeps its last play time.
    private struct PlayCheck: Equatable {
        var ids: [String]
        var now: Date
    }

    var body: some View {
        let all = model.inboxItems(now: now)
        let scoped = Inbox.inScope(all, scope: model.scope)
        let arranged = model.arrangement.arrange(scoped)
        let devices = model.state.devices
        let media = model.core.plugin(MprisPlugin.self)?.model.devices ?? [:]
        let playing = devices.filter { $0.paired && $0.online && media[$0.id]?.player?.playing == true }.map(\.id)
        let online = devices.filter { $0.paired && $0.online }.map(\.id)
        GeometryReader { geo in
            if arranged.isEmpty {
                EmptyInbox(all: all)
            } else if geo.size.width < 600 {
                StackedInbox(items: arranged, scoped: scoped, all: all, height: geo.size.height)
            } else {
                SplitInbox(items: arranged, scoped: scoped, all: all, size: geo.size)
            }
        }
        .onChange(of: [all.map(\.key), scoped.map(\.key)], initial: true) {
            model.inboxChanged(all: all, scoped: scoped)
        }
        .onChange(of: PlayCheck(ids: playing, now: now), initial: true) {
            guard !model.demo else { return }
            let next = Inbox.notePlaying(model.playedAt, devices: model.state.devices, media: media, now: Date())
            if next != model.playedAt { model.playedAt = next }
        }
        // The computers send their changes. Each visit asks again for the agents and the players.
        .task(id: online) {
            guard !model.demo else { return }
            let herdr = model.core.plugin(HerdrPlugin.self)
            let mpris = model.core.plugin(MprisPlugin.self)
            for d in model.state.devices where d.paired && d.online {
                if d.accepts(PacketType.fluxHerdr) { herdr?.request(d.id) }
                if d.accepts(PacketType.mprisRequest) { mpris?.requestPlayers(d.id) }
            }
        }
    }
}

/// The Inbox under a width of 600 pt: the status line, the master, and the
/// stack in 2 columns, in 1 scroll view. At the accessibility text sizes,
/// the stack has 1 column.
struct StackedInbox: View {
    /// The items in the order of the user. It is not empty.
    let items: [InboxItem]
    let scoped: [InboxItem]
    let all: [InboxItem]
    let height: CGFloat
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tiles

    var body: some View {
        let master = items[0]
        let stack = Array(items.dropFirst())
        ScrollView {
            VStack(spacing: TiledMetrics.gap) {
                StatusLine(scoped: scoped, all: all)
                // The master takes about 55% of the height under the status
                // line, so that 2 rows of the stack show, and its actions sit
                // at thumb height.
                MasterTile(item: master, compact: false, push: true, count: items.count,
                           minHeight: max(0, (height - 44 - TiledMetrics.gap) * 0.55))
                    .matchedGeometryEffect(id: master.key, in: tiles)
                if typeSize.isAccessibilitySize {
                    ForEach(stack) { item in
                        StackTile(item: item)
                            .matchedGeometryEffect(id: item.key, in: tiles)
                    }
                } else {
                    ForEach(Array(stride(from: 0, to: stack.count, by: 2)), id: \.self) { i in
                        HStack(spacing: TiledMetrics.gap) {
                            StackTile(item: stack[i])
                                .matchedGeometryEffect(id: stack[i].key, in: tiles)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            if i + 1 < stack.count {
                                StackTile(item: stack[i + 1])
                                    .matchedGeometryEffect(id: stack[i + 1].key, in: tiles)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                Color.clear
                                    .frame(maxWidth: .infinity)
                                    .accessibilityHidden(true)
                            }
                        }
                        // The 2 tiles of a row have the same height.
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, TiledMetrics.gutter)
            .padding(.bottom, 16)
            .animation(Motion.standard(reduceMotion), value: items.map(\.key))
        }
    }
}

/// The Inbox from a width of 600 pt: the master at the left, 60% of the
/// width and of full height, and the status line and the stack in 1
/// column on the right. The choices sit directly under the prompt. Below a
/// height of 460 pt, the master is compact.
struct SplitInbox: View {
    /// The items in the order of the user. It is not empty.
    let items: [InboxItem]
    let scoped: [InboxItem]
    let all: [InboxItem]
    let size: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tiles

    var body: some View {
        let inner = max(0, size.width - 2 * TiledMetrics.gutter - TiledMetrics.gap)
        let left = inner * 0.6
        let master = items[0]
        HStack(alignment: .top, spacing: TiledMetrics.gap) {
            ScrollView {
                MasterTile(item: master, compact: size.height < 460, push: false, count: items.count,
                           minHeight: max(0, size.height - 8))
                    .matchedGeometryEffect(id: master.key, in: tiles)
                    .padding(.bottom, 8)
            }
            .frame(width: left)
            ScrollView {
                VStack(spacing: TiledMetrics.gap) {
                    StatusLine(scoped: scoped, all: all)
                    ForEach(Array(items.dropFirst())) { item in
                        StackTile(item: item)
                            .matchedGeometryEffect(id: item.key, in: tiles)
                    }
                }
                .padding(.bottom, 16)
            }
            .frame(width: inner - left)
        }
        .padding(.horizontal, TiledMetrics.gutter)
        .animation(Motion.standard(reduceMotion), value: items.map(\.key))
    }
}
