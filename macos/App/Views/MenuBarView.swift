import AppKit
import FluxKit
import SwiftUI

/// The panel of the menu bar extra: the count of the items that need the
/// user, the master item of all computers with its one-tap choices, the
/// next 3 items, a menu for each online computer, and the app actions. The
/// panel is a window, so the master reads a fresh output when it opens.
struct MenuBarView: View {
    var body: some View {
        // The clock ends a finished transfer, the clip, and a paused player after 30 minutes.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            MenuBarPanel(now: context.date)
        }
    }
}

private struct MenuBarPanel: View {
    let now: Date
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let all = model.inboxItems(now: now)
        let scoped = Inbox.inScope(all, scope: model.scope)
        let arranged = model.arrangement.arrange(all)
        let online = model.connectedPaired
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if Inbox.needsYou(all) > 0 {
                    Circle().fill(tn.red).frame(width: 8, height: 8)
                }
                Text(needsText(Inbox.needsYou(all)))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tn.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            if model.paired.isEmpty {
                Text("No computer is paired. Open Flux to pair your Omarchy computer.")
                    .font(.system(size: 12))
                    .foregroundStyle(tn.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let first = arranged.first {
                MasterTile(item: first, compact: true, count: arranged.count)
                    .id(first.key)
            }
            ForEach(Array(arranged.dropFirst().prefix(3))) { item in
                PanelRow(item: item) { showFirst(item) }
            }
            if !online.isEmpty {
                Divider()
                ForEach(online) { device in
                    Menu(device.name) {
                        FeatureMenuItems(device: device)
                        Button("Ping") { model.core.plugin(PingPlugin.self)?.ping(device.id) }
                    }
                }
            }
            Divider()
            HStack(spacing: 4) {
                Button("Open Flux") { showMain() }
                    .keyboardShortcut("o")
                Button("Settings…") { showSettings() }
                    .keyboardShortcut(",")
                Spacer(minLength: 8)
                Button("Quit Flux") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(FluxButtonStyle(kind: .text))
        }
        .padding(12)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: [all.map(\.key), scoped.map(\.key)], initial: true) { model.inboxChanged(all: all, scoped: scoped) }
    }

    /// Opens the main window and brings Flux to the front.
    private func showMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Brings Flux to the front and opens the Settings window. A click in
    /// the menu bar panel does not make Flux the active app, so without
    /// this step the Settings window can open behind other apps.
    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    /// Moves the item to the master position of the Inbox and shows it. An
    /// item out of scope makes the scope all computers.
    private func showFirst(_ item: InboxItem) {
        if Inbox.inScope([item], scope: model.scope).isEmpty { model.setScope(nil) }
        model.showFirst(item.key)
        model.go(.inbox)
        showMain()
    }
}

/// A next item in the panel: the window title and the title. A click shows
/// it first in the Inbox of the main window.
private struct PanelRow: View {
    let item: InboxItem
    let action: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TiledMetrics.smallCorner, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                WindowTitle(item: item, size: .stack)
                Text(item.stackTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tn.text)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: TiledMetrics.rowHeight, alignment: .leading)
            .background(shape.fill(tn.tile))
            .overlay(shape.strokeBorder(item.kind.needsYou ? tn.red : tn.line, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(TilePressStyle())
        .accessibilityLabel(item.spokenTitle)
        .accessibilityValue(item.stateWord)
        .accessibilityHint("Shows it first in Flux")
    }
}
