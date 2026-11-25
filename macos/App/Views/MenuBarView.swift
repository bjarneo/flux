import AppKit
import FluxKit
import SwiftUI

/// The panel of the menu bar extra: the count of the items that need the
/// user, the 2 newest items that need the user as chat cards with their
/// one-tap choices or their buttons, the next 3 items, a menu for each
/// online computer, and the app actions. The panel is a window, so a card
/// reads a fresh output when it opens. A click on a next item opens its
/// chat in the window.
struct MenuBarView: View {
    var body: some View {
        MenuBarPanel()
    }
}

private struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let all = model.inboxItems()
        let seen = model.chatSeen(all)
        let herdr = model.core.plugin(HerdrPlugin.self)
        // The newest first, by the time that each item got its state.
        let times = Dictionary(all.map { item -> (String, Date) in
            var at = seen[item.key] ?? Date()
            if case .agent(let deviceId, let agent, _) = item.content, let since = herdr?.model.agentSince(device: deviceId, pane: agent.pane) {
                at = since
            }
            return (item.key, at)
        }, uniquingKeysWith: { first, _ in first })
        let newest = all.sorted { (times[$0.key] ?? .distantPast) > (times[$1.key] ?? .distantPast) }
        let urgent = newest.filter { $0.kind.needsYou }
        let rest = Array(urgent.dropFirst(2)) + newest.filter { !$0.kind.needsYou }
        let online = model.connectedPaired
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if !urgent.isEmpty {
                    Circle().fill(tn.red).frame(width: 8, height: 8)
                }
                Text(needsText(urgent.count))
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
            ForEach(Array(urgent.prefix(2))) { item in
                EventCard(item: item, at: times[item.key] ?? Date())
                    .id(item.key)
            }
            ForEach(Array(rest.prefix(3))) { item in
                PanelRow(item: item) { showChat(item) }
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
        .environment(\.chatColumn, 336)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
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

    /// Opens the chat of the item in the main window: the chat of an agent,
    /// the chat of the computer of an approval, or the pairing page of a
    /// computer that asks to pair.
    private func showChat(_ item: InboxItem) {
        switch item.content {
        case .agent(let deviceId, let agent, _):
            model.open(.agent(deviceId, pane: agent.pane))
        case .approval(let request):
            if model.pairedDevice(request.computerId) != nil { model.open(.computer(request.computerId)) } else { model.go(.chats) }
        case .pair(let deviceId):
            model.destination = .computers
            model.computersPath = [.pairing(deviceId)]
        }
        showMain()
    }
}

/// A next item in the panel: the state, the source, and the title. A
/// click opens its chat in the main window.
private struct PanelRow: View {
    let item: InboxItem
    let action: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TiledMetrics.smallCorner, style: .continuous)
        let source = item.sourceParts.joined(separator: " · ")
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if case .agent(_, let agent, _) = item.content {
                        StatusMark(status: agent.status, dot: 7, ring: 10)
                    } else {
                        PulseDot(color: tn.tone(item.tone), size: 7, pulse: false)
                    }
                    Text(item.stateWord)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tn.tone(item.tone))
                        .fixedSize()
                    if !source.isEmpty {
                        Text("· " + source)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(tn.sub)
                            .lineLimit(1)
                    }
                }
                Text(item.title)
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
        .accessibilityLabel(([item.title] + item.sourceParts + [item.computer]).filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityValue(item.stateWord)
        .accessibilityHint("Opens its chat in Flux")
    }
}
