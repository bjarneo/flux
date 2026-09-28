import Foundation

/// 1 key binding of Hyprland on the computer. `ref` runs it, and `keys` is
/// its combination, such as "SUPER SHIFT RETURN".
public struct Shortcut: Equatable, Sendable, Identifiable {
    public var ref: String
    public var keys: String
    public var description: String

    public init(ref: String, keys: String, description: String) {
        self.ref = ref
        self.keys = keys
        self.description = description
    }

    public var id: String { ref }
}

/// 1 workspace of the computer with its number of windows.
public struct WorkspaceInfo: Equatable, Sendable {
    public var id: Int
    public var windows: Int

    public init(id: Int, windows: Int) {
        self.id = id
        self.windows = windows
    }
}

/// The key bindings and the workspaces of a computer, for the Omarchy
/// panel. `loaded` is false until the first answer.
public struct ShortcutsState: Equatable, Sendable {
    public var shortcuts: [Shortcut] = []
    public var workspaces: [WorkspaceInfo] = []
    public var active = 0
    public var error: String?
    public var loaded = false

    public init() {}
}

/// flux.shortcuts: this Mac moves around Omarchy. The computer sends its
/// key bindings and workspaces, and it runs a binding or an action for this
/// Mac. It needs remote_input on the computer.
public enum DesktopShortcuts {
    public enum Action: String, CaseIterable, Sendable {
        case close, fullscreen, float, split, scratchpad, nextWindow, nextWorkspace, previousWorkspace
    }

    /// The directions of focus and swap.
    public enum Direction: String, CaseIterable, Sendable {
        case left = "l", up = "u", down = "d", right = "r"
    }

    /// The highest workspace that this Mac can select.
    public static let maxWorkspace = 10

    /// The shortcuts that the Omarchy panel pins until the user pins others.
    public static let defaultPins = ["Omarchy menu", "Apps menu", "Terminal", "Browser", "File manager", "Screenshot"]

    /// Asks for the key bindings and the workspaces.
    public static func request() -> Packet { Packet(PacketType.fluxShortcuts, ["request": true]) }

    /// Asks for the workspaces only.
    public static func refresh() -> Packet { Packet(PacketType.fluxShortcuts) }

    public static func run(_ s: Shortcut) -> Packet { Packet(PacketType.fluxShortcuts, ["run": s.ref]) }

    public static func action(_ a: Action) -> Packet { Packet(PacketType.fluxShortcuts, ["action": a.rawValue]) }

    public static func workspace(_ id: Int) -> Packet { Packet(PacketType.fluxShortcuts, ["action": "workspace", "workspace": id]) }

    public static func moveToWorkspace(_ id: Int) -> Packet { Packet(PacketType.fluxShortcuts, ["action": "moveToWorkspace", "workspace": id]) }

    public static func focus(_ d: Direction) -> Packet { Packet(PacketType.fluxShortcuts, ["action": "focus", "direction": d.rawValue]) }

    public static func swap(_ d: Direction) -> Packet { Packet(PacketType.fluxShortcuts, ["action": "swap", "direction": d.rawValue]) }

    /// The workspace action for a digit with super, as the Omarchy bindings
    /// do: super and a digit selects the workspace, and super, shift, and a
    /// digit moves the window there. 0 is workspace 10. It returns nil for
    /// other keys. Omarchy binds these to key codes, which the keys from
    /// this Mac cannot press, so the computer runs the action instead.
    public static func forDigit(_ text: String, mods: RemoteInput.Mods) -> Packet? {
        guard text.count == 1, let digit = text.first?.wholeNumberValue, text.first?.isASCII == true else { return nil }
        guard mods.meta, !mods.ctrl, !mods.alt else { return nil }
        let id = digit == 0 ? maxWorkspace : digit
        return mods.shift ? moveToWorkspace(id) : workspace(id)
    }

    /// Returns the state after an answer. An answer without the list keeps
    /// the list of `old`. An error keeps the rest of `old`.
    public static func merge(_ old: ShortcutsState?, _ p: Packet) -> ShortcutsState {
        var s = old ?? ShortcutsState()
        s.loaded = true
        if let error = p.string("error"), !error.isEmpty {
            s.error = error
            return s
        }
        if let list = p.array("shortcuts") {
            s.shortcuts = list.compactMap { e in
                guard let o = e.object, let ref = o["ref"]?.string, let description = o["description"]?.string else { return nil }
                return Shortcut(ref: ref, keys: o["keys"]?.string ?? "", description: description)
            }
        }
        if let list = p.array("workspaces") {
            s.workspaces = list.compactMap { e in
                guard let o = e.object, let id = o["id"]?.int else { return nil }
                return WorkspaceInfo(id: id, windows: o["windows"]?.int ?? 0)
            }
        }
        if let active = p.int("active") { s.active = active }
        s.error = nil
        return s
    }

    /// The shortcuts that the panel pins, in the order of `pins`.
    public static func pinned(_ all: [Shortcut], pins: [String]) -> [Shortcut] {
        pins.compactMap { name in all.first { $0.description == name } }
    }

    /// The shortcuts that match each word of `query` in the description or the keys.
    public static func search(_ all: [Shortcut], _ query: String) -> [Shortcut] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return all }
        return all.filter { s in
            let text = (s.description + " " + s.keys).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// The keys of a shortcut for a label, such as "super shift return".
    public static func keysLabel(_ keys: String) -> String { keys.lowercased() }
}
