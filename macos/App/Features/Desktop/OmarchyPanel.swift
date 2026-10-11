import AppKit
import FluxKit
import SwiftUI

/// The Omarchy panel: the workspaces as pills, the windows of the active
/// workspace, and the pinned shortcuts, with the keys of the focused window
/// in the dock at the bottom. The computer runs each action in Hyprland, so
/// the Omarchy key bindings work also where keys from this Mac do not. A
/// click on a window focuses it. An Option-click on a workspace or an arrow
/// moves the focused window.
struct OmarchyPanel: View {
    let controller: DesktopController
    @State private var showAll = false
    @Environment(\.tn) private var tn

    /// The panel reads the workspaces again at this interval, because the computer can change them too.
    private static let refresh: Duration = .seconds(3)

    private var model: DesktopModel { controller.plugin.model }
    private var state: ShortcutsState? { model.shortcuts[controller.deviceId] }

    var body: some View {
        let windows = state?.activeWindows ?? []
        let count = state?.windows != nil ? windows.count : state?.workspaces.first { $0.id == state?.active }?.windows ?? 0
        VStack(spacing: 0) {
            WorkspaceStrip(state: state) { id, moveWindow in
                controller.shortcut(moveWindow ? DesktopShortcuts.moveToWorkspace(id) : DesktopShortcuts.workspace(id))
                if moveWindow { controller.app.show("Moved the window to workspace \(id)") }
            }
            ProgressLine()
            ScrollView {
                VStack(alignment: .leading, spacing: TiledMetrics.gap) {
                    if let error = state?.error {
                        Text(error).font(.system(size: 12)).foregroundStyle(tn.red).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4).padding(.top, 8)
                    } else if state?.loaded != true {
                        HStack(spacing: 8) {
                            FluxSpinner(size: 12)
                            Text("Reading the shortcuts of \(controller.name)").font(.system(size: 12)).foregroundStyle(tn.sub)
                        }
                        .padding(.horizontal, 4).padding(.top, 8)
                    }
                    ListHeading("Windows", trailing: state?.loaded == true ? "\(count) \(count == 1 ? "window" : "windows")" : "")
                    if state?.loaded == true && state?.windows == nil {
                        PanelNote(text: "Update Flux on \(controller.name) to see its windows here.")
                    } else if state?.loaded == true && windows.isEmpty {
                        PanelNote(text: "No windows on this workspace.")
                    }
                    ForEach(windows) { w in
                        WindowCard(window: w) {
                            if !w.focused { controller.shortcut(DesktopShortcuts.focusWindow(w.address)) }
                        }
                    }
                    ListHeading("Launch") {
                        Button("All Shortcuts…") { showAll = true }
                            .buttonStyle(.link)
                            .font(.system(size: 11.5))
                    }
                    let pinned = DesktopShortcuts.pinned(state?.shortcuts ?? [], pins: model.pins)
                    if state?.loaded == true && pinned.isEmpty {
                        PanelNote(text: "Pin shortcuts with the star in All Shortcuts.")
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        ForEach(pinned) { s in
                            LaunchKey(shortcut: s) { controller.shortcut(DesktopShortcuts.run(s)) }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .padding(.bottom, 16)
            }
            WindowKeys(focused: windows.first { $0.focused }) { controller.shortcut($0) }
        }
        .background(tn.bg)
        // The list comes once.
        .task(id: controller.deviceId) {
            controller.shortcut(DesktopShortcuts.request())
        }
        // The workspaces come again while the panel shows. They stop while
        // the stream pauses, for example while the window is in the Dock.
        .task(id: controller.paused) {
            guard !controller.paused else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refresh)
                if Task.isCancelled { return }
                _ = controller.plugin.send(DesktopShortcuts.refresh(), to: controller.deviceId)
            }
        }
        .sheet(isPresented: $showAll) {
            AllShortcuts(shortcuts: state?.shortcuts ?? [], model: model, language: controller.app.dictationLanguage) { s in
                showAll = false
                controller.shortcut(DesktopShortcuts.run(s))
            } onDone: {
                showAll = false
            }
        }
    }
}

/// A line of the panel in the second ink, such as an empty list.
private struct PanelNote: View {
    let text: String
    @Environment(\.tn) private var tn

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(tn.sub)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
    }
}

/// Workspaces 1 to 10 as pills that scroll to the side. The active one has
/// the accent, and a workspace with windows has a dot. A click switches to
/// the workspace, and an Option-click moves the focused window there.
private struct WorkspaceStrip: View {
    let state: ShortcutsState?
    let onSelect: (Int, Bool) -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        let windows = Dictionary((state?.workspaces ?? []).map { ($0.id, $0.windows) }, uniquingKeysWith: { a, _ in a })
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(1...DesktopShortcuts.maxWorkspace, id: \.self) { id in
                    let active = state?.active == id
                    let used = (windows[id] ?? 0) > 0
                    Button {
                        onSelect(id, NSEvent.modifierFlags.contains(.option))
                    } label: {
                        HStack(spacing: 5) {
                            Text("\(id)")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(active ? tn.text : tn.sub)
                            if used {
                                Circle().fill(active ? tn.accent : tn.sub).frame(width: 4, height: 4)
                            }
                        }
                        .padding(.horizontal, 9)
                        .frame(minWidth: 34, minHeight: 28)
                        .background(Capsule().fill(active ? tn.accentTile : tn.tile))
                        .overlay(Capsule().strokeBorder(active ? tn.accent : tn.line, lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(TilePressStyle())
                    .help("Switch to workspace \(id). Option-click moves the window there.")
                    .accessibilityAddTraits(active ? .isSelected : [])
                    .contextMenu {
                        Button("Switch to Workspace \(id)") { onSelect(id, false) }
                        Button("Move the Window to Workspace \(id)") { onSelect(id, true) }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}

/// The symbol of the app of a window, from its class.
func windowSymbol(_ windowClass: String) -> String {
    let c = windowClass.lowercased()
    func has(_ names: String...) -> Bool { names.contains { c.contains($0) } }
    if has("alacritty", "kitty", "ghostty", "foot", "wezterm", "konsole", "terminal") { return "terminal" }
    if has("chrom", "firefox", "brave", "zen", "vivaldi", "librewolf", "edge", "qutebrowser", "browser") { return "globe" }
    if has("spotify", "music", "rhythmbox", "amberol") { return "music.note" }
    if has("obsidian", "typora", "notes", "logseq", "xournal") { return "note.text" }
    if has("signal", "telegram", "discord", "slack", "whatsapp", "element", "chat") { return "bubble.left.and.bubble.right" }
    if has("nautilus", "thunar", "dolphin", "files", "nemo") { return "folder" }
    if has("code", "zed", "cursor", "neovide", "jetbrains", "studio") { return "chevron.left.forwardslash.chevron.right" }
    if has("mpv", "vlc", "obs", "celluloid") { return "film" }
    if has("imv", "gimp", "krita", "pinta", "inkscape") { return "photo" }
    return "macwindow"
}

/// A window of the active workspace: the symbol of its app, the app, and
/// the title in mono. The focused window has the accent.
private struct WindowCard: View {
    let window: WindowInfo
    let action: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = tileShape()
        let f = window.focused
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: windowSymbol(window.windowClass))
                    .font(.system(size: 15))
                    .foregroundStyle(f ? tn.accent : tn.sub)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(window.app.isEmpty ? "Window" : window.app)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tn.text)
                        .lineLimit(1)
                    if !window.title.isEmpty {
                        Text(window.title)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(tn.sub)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                if f {
                    Text("Focused")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tn.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .background(shape.fill(f ? tn.accentTile : tn.tile))
            .overlay(shape.strokeBorder(f ? tn.accent : tn.line, lineWidth: f ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(TilePressStyle())
        .help(f ? window.title : "Focus \(window.app)")
        .accessibilityValue(f ? "Focused" : "")
    }
}

/// The keys of the focused window in the dock: the arrows focus the window
/// in that direction, and an Option-click swaps the window there. Under
/// them, close, full screen, float, and split. The menu of the action keys
/// holds Focus the Next Window and Toggle the Scratchpad.
private struct WindowKeys: View {
    let focused: WindowInfo?
    let send: (Packet) -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Window")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(tn.sub)
                Text("· " + (focused.map { contextLine([$0.app, $0.title]) } ?? "an arrow focuses a window"))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(tn.sub)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 4)
            HStack(spacing: 6) {
                ForEach(Self.arrows, id: \.self) { dir in
                    DockKey(help: "Focus the window \(Self.name(dir)). Option-click moves it.", border: tn.line, corner: 10, height: 36) {
                        send(NSEvent.modifierFlags.contains(.option) ? DesktopShortcuts.swap(dir) : DesktopShortcuts.focus(dir))
                    } label: {
                        Image(systemName: Self.symbol(dir))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tn.text)
                    }
                    .contextMenu {
                        Button("Focus the Window \(Self.name(dir).capitalized)") { send(DesktopShortcuts.focus(dir)) }
                        Button("Move the Window \(Self.name(dir).capitalized)") { send(DesktopShortcuts.swap(dir)) }
                    }
                }
            }
            HStack(spacing: 6) {
                ForEach(Self.actions, id: \.label) { key in
                    let red = key.action == .close
                    DockKey(help: key.help, border: red ? tn.red : tn.line, corner: 10, height: 36) {
                        send(DesktopShortcuts.action(key.action))
                    } label: {
                        Text(key.label)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(red ? tn.red : tn.text)
                    }
                }
            }
            .contextMenu {
                Button("Focus the Next Window") { send(DesktopShortcuts.action(.nextWindow)) }
                Button("Toggle the Scratchpad") { send(DesktopShortcuts.action(.scratchpad)) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(DockShape().fill(tn.tile))
        .overlay(alignment: .top) {
            // The line along the top edge and the round corners.
            DockShape().stroke(tn.line, lineWidth: 1).frame(height: 40).mask(alignment: .top) { Rectangle().frame(height: 20) }
        }
    }

    private static let arrows: [DesktopShortcuts.Direction] = [.left, .up, .down, .right]

    /// An action key: its label, its help, and its action.
    private struct ActionKey {
        let label: String
        let help: String
        let action: DesktopShortcuts.Action
    }

    private static let actions = [
        ActionKey(label: "close", help: "Close the window", action: .close),
        ActionKey(label: "full", help: "Full screen", action: .fullscreen),
        ActionKey(label: "float", help: "Float or tile the window", action: .float),
        ActionKey(label: "split", help: "Toggle the split", action: .split),
    ]

    private static func symbol(_ d: DesktopShortcuts.Direction) -> String {
        switch d {
        case .left: return "arrow.left"
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .right: return "arrow.right"
        }
    }

    private static func name(_ d: DesktopShortcuts.Direction) -> String {
        switch d {
        case .left: return "left"
        case .up: return "up"
        case .down: return "down"
        case .right: return "right"
        }
    }
}

/// A pinned shortcut: its description and its keys in mono.
private struct LaunchKey: View {
    let shortcut: Shortcut
    let action: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = tileShape()
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shortcut.description)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(tn.text)
                    .lineLimit(1)
                Text(DesktopShortcuts.keysLabel(shortcut.keys))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(tn.sub)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(shape.fill(tn.tile))
            .overlay(shape.strokeBorder(tn.line, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(TilePressStyle())
        .help("Run \(shortcut.description) on the computer")
    }
}

/// All shortcuts of the computer, with a search. A click runs a shortcut,
/// and the star pins it to the panel. A dictation replaces the search.
private struct AllShortcuts: View {
    let shortcuts: [Shortcut]
    let model: DesktopModel
    @Binding var language: String
    let onRun: (Shortcut) -> Void
    let onDone: () -> Void
    @State private var query = ""

    var body: some View {
        let found = DesktopShortcuts.search(shortcuts, query)
        VStack(alignment: .leading, spacing: 12) {
            Text("All Shortcuts · \(shortcuts.count)").font(.headline)
            VoiceBar(language: $language, onText: { query = DictationText.query($0) }) {
                TextField("Search, for example workspace or browser", text: $query)
                    .fieldKeys(text: $query)
                    .voiceFieldStyle()
            }
            List(found) { s in
                HStack(spacing: 8) {
                    Button { onRun(s) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.description).fontWeight(.semibold)
                            if !s.keys.isEmpty {
                                Text(DesktopShortcuts.keysLabel(s.keys)).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Run \(s.description)")
                    let pinned = model.pins.contains(s.description)
                    Button { model.togglePin(s) } label: {
                        Image(systemName: pinned ? "star.fill" : "star")
                            .foregroundStyle(pinned ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(pinned ? "Unpin \(s.description)" : "Pin \(s.description) to Launch")
                }
            }
            .frame(minHeight: 200)
            HStack {
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 520)
    }
}
