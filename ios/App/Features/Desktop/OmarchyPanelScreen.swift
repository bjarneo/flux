import FluxKit
import SwiftUI
import UIKit

/// The Omarchy panel of 1 computer on its own screen, from Control: the
/// workspaces as pills, the windows of the active workspace, and the pinned
/// shortcuts, with the keys for the focused window in the dock. The
/// computer runs each action in Hyprland. The panel sends input, so it asks
/// for Face ID or the passcode first, like the touchpad. No stream starts.
/// The remote desktop shows the smaller `OmarchyPanel`.
struct OmarchyPanelScreen: View {
    @Environment(AppModel.self) private var model
    let deviceId: String
    @State private var controller: DesktopController?

    var body: some View {
        let d = model.device(deviceId)
        let active = d.flatMap { model.core.plugin(DesktopPlugin.self)?.model.shortcuts[$0.id] }?.active ?? 0
        Group {
            if let d, let plugin = model.core.plugin(DesktopPlugin.self),
               let input = model.core.plugin(RemoteInputPlugin.self) {
                if !d.online {
                    unavailable("\(d.name) is not reachable", "wifi.slash", "The panel shows when \(d.name) is connected.")
                } else if !DesktopPlugin.shortcutsSupported(d) {
                    unavailable("Update Flux on \(d.name)", "square.grid.2x2",
                                "This version of Flux on \(d.name) does not send its workspaces and key bindings.")
                } else if !input.model.isOn(d.id) {
                    unavailable("Remote input is off", "square.grid.2x2",
                                "On \(d.name), set `remote_input = true` in `~/.config/flux/config.toml`, then run `systemctl --user reload fluxd`.")
                } else {
                    // Remote input can turn on while the screen is open, after the tool.
                    UnlockGate(reason: "Use the Omarchy panel of \(d.name).") {
                        if let controller {
                            OmarchyScreenBody(controller: controller)
                        } else {
                            Color.clear.onAppear {
                                controller = DesktopController(device: d, app: model, plugin: plugin, input: input)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .featureTitle("Omarchy panel", context: ScreenWords.join(d?.name ?? "", active > 0 ? "workspace \(active)" : ""))
        .onDisappear { controller?.close() }
    }

    private func unavailable(_ title: String, _ symbol: String, _ text: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(.init(text)))
    }
}

/// The workspaces, the windows, the shortcuts, and the dock of the window keys.
private struct OmarchyScreenBody: View {
    let controller: DesktopController
    @Environment(\.tn) private var tn
    @State private var showAll = false

    /// The panel reads the workspaces again at this interval, because the computer can change them too.
    private static let refresh: Duration = .seconds(3)

    private var model: DesktopModel { controller.plugin.model }
    private var state: ShortcutsState? { model.shortcuts[controller.deviceId] }

    var body: some View {
        let windows = state?.activeWindows ?? []
        VStack(spacing: 0) {
            WorkspacePills(state: state) { id in
                send(DesktopShortcuts.workspace(id))
            } onMove: { id in
                HoldFeedback.play()
                send(DesktopShortcuts.moveToWorkspace(id))
                controller.app.show("Moved the window to workspace \(id)")
            }
            ProgressLine()
            ScrollView {
                VStack(alignment: .leading, spacing: TiledMetrics.gap) {
                    if let error = state?.error {
                        Text(error).font(.footnote).foregroundStyle(tn.red).padding(.horizontal, 4).padding(.vertical, 8)
                    } else if state?.loaded != true {
                        LineSkeleton(widths: [0.7, 0.5], label: "Reading the workspaces of \(controller.name)").padding(4)
                    }
                    let count = state?.windows != nil ? windows.count : state?.workspaces.first { $0.id == state?.active }?.windows ?? 0
                    ListHeader("Windows", trailing: state?.loaded == true ? "\(count) \(count == 1 ? "window" : "windows")" : "")
                    if state?.loaded == true && state?.windows == nil {
                        note("Update Flux on \(controller.name) to see its windows here.")
                    } else if state?.loaded == true && windows.isEmpty {
                        note("No windows on this workspace.")
                    }
                    ForEach(windows) { w in
                        WindowCard(window: w) { if !w.focused { send(DesktopShortcuts.focusWindow(w.address)) } }
                    }
                    ListHeader(title: "Launch") {
                        Button("All shortcuts") { showAll = true }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(tn.accent)
                    }
                    let pinned = DesktopShortcuts.pinned(state?.shortcuts ?? [], pins: model.pins)
                    if state?.loaded == true && pinned.isEmpty {
                        note("Pin shortcuts with the star in All shortcuts.")
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(pinned) { s in
                            LaunchTile(shortcut: s) { send(DesktopShortcuts.run(s)) }
                        }
                    }
                }
                .padding(.horizontal, TiledMetrics.gutter)
                .padding(.top, 6)
                .padding(.bottom, 28)
                .frame(maxWidth: TiledMetrics.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                WindowDock(focused: windows.first { $0.focused }, send: send)
            }
        }
        // The list comes once. The workspaces come again while the panel shows.
        .task(id: controller.deviceId) {
            controller.shortcut(DesktopShortcuts.request())
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refresh)
                if Task.isCancelled { return }
                _ = controller.plugin.send(DesktopShortcuts.refresh(), to: controller.deviceId)
            }
        }
        .sheet(isPresented: $showAll) {
            AllShortcuts(shortcuts: state?.shortcuts ?? [], model: model) { s in
                showAll = false
                send(DesktopShortcuts.run(s))
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(tn.sub).padding(.horizontal, 4).padding(.vertical, 14)
    }

    private func send(_ p: Packet) {
        UISelectionFeedbackGenerator().selectionChanged()
        controller.shortcut(p)
    }
}

/// Workspaces 1 to 10 as pills that scroll to the side. The active one has
/// the accent, and a workspace with windows has a dot. A tap switches to the
/// workspace, and a long press moves the focused window there.
private struct WorkspacePills: View {
    let state: ShortcutsState?
    let onGo: (Int) -> Void
    let onMove: (Int) -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        let windows = Dictionary((state?.workspaces ?? []).map { ($0.id, $0.windows) }, uniquingKeysWith: { a, _ in a })
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(1...DesktopShortcuts.maxWorkspace, id: \.self) { id in
                    let active = state?.active == id
                    let used = (windows[id] ?? 0) > 0
                    HStack(spacing: 6) {
                        Text("\(id)")
                            .font(.footnote.monospaced().weight(.semibold))
                            .foregroundStyle(active ? tn.text : tn.sub)
                        if used { Circle().fill(active ? tn.accent : tn.sub).frame(width: 5, height: 5) }
                    }
                    .padding(.horizontal, 10)
                    .frame(minWidth: 40, minHeight: 36)
                    .background(Capsule().fill(active ? tn.accentTile : tn.tile))
                    .overlay(Capsule().strokeBorder(active ? tn.accent : tn.line))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .onTapGesture { onGo(id) }
                    .onLongPressGesture(minimumDuration: 0.45) { onMove(id) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Workspace \(id)")
                    .accessibilityValue(used ? "Has windows" : "Empty")
                    .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { onGo(id) }
                    .accessibilityAction(named: "Move the window to workspace \(id)") { onMove(id) }
                }
            }
            .padding(.horizontal, 10)
        }
        .padding(.bottom, 2)
    }
}

/// A window of the active workspace: the icon of its app, the app, and the
/// title in mono. The focused window has the accent.
private struct WindowCard: View {
    let window: WindowInfo
    let action: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        let w = window
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: Self.icon(w.windowClass))
                    .font(.system(size: 19))
                    .foregroundStyle(w.focused ? tn.accent : tn.sub)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(w.app.isEmpty ? "Window" : w.app)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tn.text)
                        .lineLimit(1)
                    if !w.title.isEmpty {
                        Text(w.title)
                            .font(.caption2.monospaced())
                            .foregroundStyle(tn.sub)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if w.focused {
                    Text("Focused").font(.caption.weight(.medium)).foregroundStyle(tn.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(tileShape().fill(w.focused ? tn.accentTile : tn.tile))
            .overlay(tileShape().strokeBorder(w.focused ? tn.accent : tn.line, lineWidth: w.focused ? 2 : 1))
            .contentShape(tileShape())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(w.focused ? "" : "Focuses the window")
    }

    /// The icon of the app of a window, from its class.
    static func icon(_ windowClass: String) -> String {
        let c = windowClass.lowercased()
        func has(_ names: String...) -> Bool { names.contains { c.contains($0) } }
        if has("alacritty", "kitty", "ghostty", "foot", "wezterm", "konsole", "terminal") { return "terminal" }
        if has("chrom", "firefox", "brave", "zen", "vivaldi", "librewolf", "edge", "qutebrowser", "browser") { return "globe" }
        if has("spotify", "music", "rhythmbox", "amberol") { return "music.note" }
        if has("obsidian", "typora", "notes", "logseq", "xournal") { return "square.and.pencil" }
        if has("signal", "telegram", "discord", "slack", "whatsapp", "element", "chat") { return "bubble.left" }
        if has("nautilus", "thunar", "dolphin", "files", "nemo") { return "folder" }
        if has("code", "zed", "cursor", "neovide", "jetbrains", "studio") { return "chevron.left.forwardslash.chevron.right" }
        if has("mpv", "vlc", "obs", "celluloid") { return "film" }
        if has("imv", "gimp", "krita", "pinta", "inkscape") { return "photo" }
        return "macwindow"
    }
}

/// A pinned shortcut: its description and its keys in mono.
private struct LaunchTile: View {
    let shortcut: Shortcut
    let action: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(shortcut.description)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tn.text)
                if !shortcut.keys.isEmpty {
                    Text(DesktopShortcuts.keysLabel(shortcut.keys))
                        .font(.caption2.monospaced())
                        .foregroundStyle(tn.sub)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        }
        .buttonStyle(TiledPressStyle(fill: tn.tile, border: tn.line))
    }
}

/// The keys for the focused window: the arrows focus the window in that
/// direction, and a long press swaps the window there. Under them, close,
/// full screen, float, and split.
private struct WindowDock: View {
    let focused: WindowInfo?
    let send: (Packet) -> Void
    @Environment(\.tn) private var tn

    private struct Arrow: Identifiable {
        let dir: DesktopShortcuts.Direction
        let icon: String
        let word: String
        var id: String { word }
    }

    private struct WindowAction: Identifiable {
        let label: String
        let name: String
        let action: DesktopShortcuts.Action
        var id: String { label }
    }

    private static let arrows = [
        Arrow(dir: .left, icon: "arrow.left", word: "left"), Arrow(dir: .up, icon: "arrow.up", word: "up"),
        Arrow(dir: .down, icon: "arrow.down", word: "down"), Arrow(dir: .right, icon: "arrow.right", word: "right"),
    ]
    private static let actions = [
        WindowAction(label: "close", name: "Close the window", action: .close), WindowAction(label: "full", name: "Full screen", action: .fullscreen),
        WindowAction(label: "float", name: "Float or tile the window", action: .float), WindowAction(label: "split", name: "Toggle the split", action: .split),
    ]

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("Window").font(.caption.weight(.medium)).foregroundStyle(tn.sub)
                Text("· " + (focused.map { [$0.app, $0.title].filter { !$0.isEmpty }.joined(separator: " · ") } ?? "tap an arrow to focus a window"))
                    .font(.caption2.monospaced())
                    .foregroundStyle(tn.sub)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            HStack(spacing: 6) {
                ForEach(Self.arrows) { a in
                    DockKeyButton(name: "Focus the window \(a.word). Hold to move the window \(a.word).", height: 44, corner: 10, border: tn.line,
                                  onHold: { send(DesktopShortcuts.swap(a.dir)) }, action: { send(DesktopShortcuts.focus(a.dir)) }) {
                        Image(systemName: a.icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(tn.text)
                    }
                }
            }
            HStack(spacing: 6) {
                ForEach(Self.actions) { k in
                    let red = k.action == .close
                    DockKeyButton(name: k.name, height: 44, corner: 10, border: red ? tn.red : tn.line, action: { send(DesktopShortcuts.action(k.action)) }) {
                        Text(k.label).font(.footnote.monospaced().weight(.medium)).foregroundStyle(red ? tn.red : tn.text)
                    }
                }
            }
            // The 2 actions of the old panel that the design has no key for.
            .contextMenu {
                Button("Focus the Next Window", systemImage: "rectangle.2.swap") { send(DesktopShortcuts.action(.nextWindow)) }
                Button("Toggle the Scratchpad", systemImage: "square.stack") { send(DesktopShortcuts.action(.scratchpad)) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .dockFrame()
    }
}
