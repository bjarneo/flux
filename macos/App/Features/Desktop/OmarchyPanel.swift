import AppKit
import FluxKit
import SwiftUI

/// The Omarchy panel: move between workspaces and windows, and start the
/// shortcuts of the computer. The computer runs each action in Hyprland, so
/// the Omarchy key bindings work also where keys from this Mac do not.
struct OmarchyPanel: View {
    let controller: DesktopController
    @State private var move = false
    @State private var showAll = false

    /// The panel reads the workspaces again at this interval, because the computer can change them too.
    private static let refresh: Duration = .seconds(3)

    private var model: DesktopModel { controller.plugin.model }
    private var state: ShortcutsState? { model.shortcuts[controller.deviceId] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let error = state?.error {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                } else if state?.loaded != true {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading the shortcuts of \(controller.name)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                PanelCaption("Workspaces", "Option-click moves the window")
                Workspaces(state: state) { id, moveWindow in
                    controller.shortcut(moveWindow ? DesktopShortcuts.moveToWorkspace(id) : DesktopShortcuts.workspace(id))
                    if moveWindow { controller.app.show("Moved the window to workspace \(id)") }
                }
                PanelCaption("Window", move ? "the arrows move it" : "the arrows focus")
                HStack(alignment: .top, spacing: 8) {
                    DirectionPad(move: move, onToggle: { move.toggle() }) { dir in
                        controller.shortcut(move ? DesktopShortcuts.swap(dir) : DesktopShortcuts.focus(dir))
                    }
                    Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                        GridRow {
                            ActionKey(label: "close", help: "Close the window", tint: .red) { controller.shortcut(DesktopShortcuts.action(.close)) }
                            ActionKey(label: "full", help: "Full screen") { controller.shortcut(DesktopShortcuts.action(.fullscreen)) }
                        }
                        GridRow {
                            ActionKey(label: "float", help: "Float or tile the window") { controller.shortcut(DesktopShortcuts.action(.float)) }
                            ActionKey(label: "split", help: "Toggle the split") { controller.shortcut(DesktopShortcuts.action(.split)) }
                        }
                        GridRow {
                            ActionKey(label: "next", help: "Focus the next window") { controller.shortcut(DesktopShortcuts.action(.nextWindow)) }
                            ActionKey(label: "scratch", help: "Toggle the scratchpad") { controller.shortcut(DesktopShortcuts.action(.scratchpad)) }
                        }
                    }
                }
                HStack {
                    Text("Launch").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("All Shortcuts…") { showAll = true }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                let pinned = DesktopShortcuts.pinned(state?.shortcuts ?? [], pins: model.pins)
                if state?.loaded == true && pinned.isEmpty {
                    Text("Pin shortcuts with the star in All DesktopShortcuts.").font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(pinned) { s in
                        LaunchKey(shortcut: s) { controller.shortcut(DesktopShortcuts.run(s)) }
                    }
                }
            }
            .padding(12)
        }
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
            AllShortcuts(shortcuts: state?.shortcuts ?? [], model: model) { s in
                showAll = false
                controller.shortcut(DesktopShortcuts.run(s))
            } onDone: {
                showAll = false
            }
        }
    }
}

/// A caption of the panel with a note after it.
private struct PanelCaption: View {
    let title: String
    let note: String

    init(_ title: String, _ note: String) {
        self.title = title
        self.note = note
    }

    var body: some View {
        Text("\(Text(title).fontWeight(.semibold)) · \(note)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Workspaces 1 to 10 in 2 rows. The active one is filled, and a workspace
/// with windows has a dot. A click switches to the workspace, and an
/// Option-click moves the focused window there.
private struct Workspaces: View {
    let state: ShortcutsState?
    let onSelect: (Int, Bool) -> Void

    var body: some View {
        let windows = Dictionary((state?.workspaces ?? []).map { ($0.id, $0.windows) }, uniquingKeysWith: { a, _ in a })
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach([Array(1...5), Array(6...DesktopShortcuts.maxWorkspace)], id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { id in
                        WorkspaceKey(id: id, active: state?.active == id, used: (windows[id] ?? 0) > 0) { moveWindow in
                            onSelect(id, moveWindow)
                        }
                    }
                }
            }
        }
    }
}

private struct WorkspaceKey: View {
    let id: Int
    let active: Bool
    let used: Bool
    let action: (Bool) -> Void

    var body: some View {
        Button {
            action(NSEvent.modifierFlags.contains(.option))
        } label: {
            Text("\(id)")
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .foregroundStyle(active ? Color.white : used ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(active ? Color.accentColor : Color.primary.opacity(0.06)))
                .overlay(alignment: .bottom) {
                    if used && !active {
                        Circle().fill(Color.accentColor).frame(width: 4, height: 4).padding(.bottom, 3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Switch to workspace \(id). Option-click moves the window there.")
        .contextMenu {
            Button("Switch to Workspace \(id)") { action(false) }
            Button("Move the Window to Workspace \(id)") { action(true) }
        }
    }
}

/// The arrows for the windows: they focus a window, or with `move` they
/// swap the window. The key in the middle switches between the 2.
private struct DirectionPad: View {
    let move: Bool
    let onToggle: () -> Void
    let onDirection: (DesktopShortcuts.Direction) -> Void

    var body: some View {
        let tint: Color = move ? .pink : .accentColor
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                arrow(.up, "arrow.up", tint)
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            }
            GridRow {
                arrow(.left, "arrow.left", tint)
                Button(action: onToggle) {
                    Text(move ? "move" : "focus")
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 34, height: 30)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(tint))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(move ? "Let the arrows focus" : "Let the arrows move the window")
                arrow(.right, "arrow.right", tint)
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                arrow(.down, "arrow.down", tint)
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            }
        }
    }

    private func arrow(_ dir: DesktopShortcuts.Direction, _ symbol: String, _ tint: Color) -> some View {
        Button { onDirection(dir) } label: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 34, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help((move ? "Move the window " : "Focus the window ") + "\(dir)")
    }
}

/// A window action, with a mono label.
private struct ActionKey: View {
    let label: String
    let help: String
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A pinned shortcut: its description and its keys.
private struct LaunchKey: View {
    let shortcut: Shortcut
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shortcut.description).font(.callout.weight(.semibold)).lineLimit(1)
                Text(DesktopShortcuts.keysLabel(shortcut.keys)).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Run \(shortcut.description) on the computer")
    }
}

/// All shortcuts of the computer, with a search. A click runs a shortcut,
/// and the star pins it to the panel.
private struct AllShortcuts: View {
    let shortcuts: [Shortcut]
    let model: DesktopModel
    let onRun: (Shortcut) -> Void
    let onDone: () -> Void
    @State private var query = ""

    var body: some View {
        let found = DesktopShortcuts.search(shortcuts, query)
        VStack(alignment: .leading, spacing: 12) {
            Text("All Shortcuts · \(shortcuts.count)").font(.headline)
            TextField("Search, for example workspace or browser", text: $query)
                .textFieldStyle(.roundedBorder)
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
            .frame(minHeight: 320)
            HStack {
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 520)
    }
}
