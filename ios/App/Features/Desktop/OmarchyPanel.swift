import FluxKit
import SwiftUI

/// The Omarchy panel: move between workspaces and windows, and start the
/// shortcuts of the computer, like the panel of the Android app. The
/// computer runs each action in Hyprland, so the Omarchy key bindings work
/// also where keys from the iPhone do not.
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
                PanelCaption("Workspaces · hold to move the window")
                Workspaces(state: state) { id in
                    send(DesktopShortcuts.workspace(id))
                } onMove: { id in
                    HoldFeedback.play()
                    send(DesktopShortcuts.moveToWorkspace(id))
                    controller.app.show("Moved the window to workspace \(id)")
                }
                PanelCaption(move ? "Window · the arrows move it" : "Window · the arrows focus")
                HStack(alignment: .top, spacing: 10) {
                    DirectionPad(move: move, onToggle: { move.toggle() }) { dir in
                        send(move ? DesktopShortcuts.swap(dir) : DesktopShortcuts.focus(dir))
                    }
                    Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                        GridRow {
                            ActionKey(label: "close", name: "Close the window", tint: .red) { send(DesktopShortcuts.action(.close)) }
                            ActionKey(label: "full", name: "Full screen") { send(DesktopShortcuts.action(.fullscreen)) }
                        }
                        GridRow {
                            ActionKey(label: "float", name: "Float or tile the window") { send(DesktopShortcuts.action(.float)) }
                            ActionKey(label: "split", name: "Toggle the split") { send(DesktopShortcuts.action(.split)) }
                        }
                        GridRow {
                            ActionKey(label: "next", name: "Focus the next window") { send(DesktopShortcuts.action(.nextWindow)) }
                            ActionKey(label: "scratch", name: "Toggle the scratchpad") { send(DesktopShortcuts.action(.scratchpad)) }
                        }
                    }
                }
                HStack {
                    PanelCaption("Launch")
                    Spacer()
                    Button("All Shortcuts") { showAll = true }
                        .font(.caption.weight(.semibold))
                }
                let pinned = DesktopShortcuts.pinned(state?.shortcuts ?? [], pins: model.pins)
                if state?.loaded == true && pinned.isEmpty {
                    Text("Pin shortcuts with the star in All Shortcuts.").font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(pinned) { s in
                        LaunchKey(shortcut: s) { send(DesktopShortcuts.run(s)) }
                    }
                }
            }
            .padding(12)
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

    private func send(_ p: Packet) {
        UISelectionFeedbackGenerator().selectionChanged()
        controller.shortcut(p)
    }
}

/// A caption of the panel.
private struct PanelCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}

/// The look of a key of the panel.
private struct PanelKeyBackground: ViewModifier {
    var fill = Color(.secondarySystemGroupedBackground)
    var border = Color(.separator).opacity(0.5)

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(border))
            .contentShape(Rectangle())
    }
}

/// Workspaces 1 to 10 in 2 rows. The active one is filled, and a workspace
/// with windows has a dot. A tap switches to the workspace, and a hold
/// moves the focused window there.
private struct Workspaces: View {
    let state: ShortcutsState?
    let onGo: (Int) -> Void
    let onMove: (Int) -> Void

    var body: some View {
        let windows = Dictionary((state?.workspaces ?? []).map { ($0.id, $0.windows) }, uniquingKeysWith: { a, _ in a })
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach([Array(1...5), Array(6...DesktopShortcuts.maxWorkspace)], id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { id in
                        let active = state?.active == id
                        let used = (windows[id] ?? 0) > 0
                        Text("\(id)")
                            .font(.system(.callout, design: .monospaced, weight: .semibold))
                            .foregroundStyle(active ? Color.white : used ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .overlay(alignment: .bottom) {
                                if used && !active {
                                    Circle().fill(Color.accentColor).frame(width: 4, height: 4).padding(.bottom, 4)
                                }
                            }
                            .modifier(PanelKeyBackground(fill: active ? .accentColor : Color(.secondarySystemGroupedBackground),
                                                         border: active ? .accentColor : Color(.separator).opacity(0.5)))
                            .onTapGesture { onGo(id) }
                            .onLongPressGesture { onMove(id) }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Workspace \(id)")
                            .accessibilityValue(active ? "Active" : used ? "Has windows" : "")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { onGo(id) }
                            .accessibilityAction(named: "Move the window to workspace \(id)") { onMove(id) }
                    }
                }
            }
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
                arrow(.up, "arrow.up", "up", tint)
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            }
            GridRow {
                arrow(.left, "arrow.left", "left", tint)
                Button(action: onToggle) {
                    Text(move ? "move" : "focus")
                        .font(.system(.caption2, design: .monospaced, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .modifier(PanelKeyBackground(border: tint))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(move ? "Let the arrows focus" : "Let the arrows move the window")
                arrow(.right, "arrow.right", "right", tint)
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                arrow(.down, "arrow.down", "down", tint)
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            }
        }
    }

    private func arrow(_ dir: DesktopShortcuts.Direction, _ symbol: String, _ name: String, _ tint: Color) -> some View {
        Button { onDirection(dir) } label: {
            Image(systemName: symbol)
                .fontWeight(.semibold)
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: 40)
                .modifier(PanelKeyBackground())
        }
        .buttonStyle(.plain)
        .accessibilityLabel((move ? "Move the window " : "Focus the window ") + name)
    }
}

/// A window action, with a mono label.
private struct ActionKey: View {
    let label: String
    let name: String
    var tint: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 40)
                .modifier(PanelKeyBackground())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }
}

/// A pinned shortcut: its description and its keys.
private struct LaunchKey: View {
    let shortcut: Shortcut
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shortcut.description).font(.callout.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Text(DesktopShortcuts.keysLabel(shortcut.keys)).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .modifier(PanelKeyBackground())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Run \(shortcut.description)")
    }
}

/// All shortcuts of the computer, with a search. A tap runs a shortcut,
/// and the star pins it to the panel. A dictation replaces the search.
private struct AllShortcuts: View {
    let shortcuts: [Shortcut]
    let model: DesktopModel
    let onRun: (Shortcut) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var voice = VoiceTyping()

    var body: some View {
        NavigationStack {
            List {
                if voice.active || voice.error != nil || voice.dictation.error != nil {
                    Section { VoiceStatus(voice: voice) }
                }
                ForEach(DesktopShortcuts.search(shortcuts, query)) { s in row(s) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search, for example workspace or browser")
            .navigationTitle("All Shortcuts · \(shortcuts.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if voice.available {
                    ToolbarItem(placement: .topBarLeading) {
                        VoiceKey(voice: voice, height: 36) { query = DictationText.query($0) }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await voice.load() }
        .onDisappear { voice.cancel() }
    }

    private func row(_ s: Shortcut) -> some View {
        HStack(spacing: 8) {
            Button { onRun(s) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.description).fontWeight(.semibold).foregroundStyle(.primary)
                    if !s.keys.isEmpty {
                        Text(DesktopShortcuts.keysLabel(s.keys)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Run \(s.description)")
            let pinned = model.pins.contains(s.description)
            Button { model.togglePin(s) } label: {
                Image(systemName: pinned ? "star.fill" : "star")
                    .foregroundStyle(pinned ? Color.yellow : Color.secondary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(pinned ? "Unpin \(s.description)" : "Pin \(s.description) to Launch")
        }
    }
}
